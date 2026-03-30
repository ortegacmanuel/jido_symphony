defmodule SymphonyElixir.AgentAdapters.Claude do
  @moduledoc """
  Agent adapter for Claude Code CLI (`claude --print`).

  Runs Claude Code in headless mode with `--print` and `--output-format json`.
  Each turn spawns a `claude` subprocess in the issue workspace directory,
  bypassing permissions for unattended execution.

  ## WORKFLOW.md config

      agent:
        kind: claude
      claude:
        model: sonnet                    # sonnet | opus | haiku (optional)
        max_turns: 10                    # max agent turns per invocation (optional)
        permission_mode: bypassPermissions  # permission mode (optional)
        max_budget_usd: 5.0             # cost cap per turn (optional)
  """

  @behaviour SymphonyElixir.AgentAdapter

  require Logger

  @claude_cmd "claude"

  @impl true
  def start_session(workspace, opts \\ []) do
    expanded = Path.expand(workspace)

    unless File.dir?(expanded) do
      {:error, {:workspace_not_found, expanded}}
    else
      session_id = "claude-#{System.unique_integer([:positive])}"
      Logger.info("Claude adapter: session #{session_id} in #{expanded}")

      {:ok,
       %{
         session_id: session_id,
         workspace: expanded,
         opts: opts
       }}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    %{session_id: session_id, workspace: workspace} = session
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    config = Keyword.get(opts, :config, %{})

    emit(on_message, :session_started, %{session_id: session_id})

    identifier = Map.get(issue, :identifier) || Map.get(issue, :id, "unknown")
    Logger.info("Claude adapter: running turn for #{identifier}")

    args = build_cli_args(prompt, config)

    emit(on_message, :agent_thought, %{
      text: "Starting claude --print for #{identifier} (#{length(args)} args)"
    })

    case run_claude(args, workspace) do
      {:ok, output} ->
        emit(on_message, :agent_text, %{text: truncate(output.text, 2000)})

        if output.cost_usd do
          emit(on_message, :usage, %{
            model: output.model,
            input_tokens: output.input_tokens,
            output_tokens: output.output_tokens,
            cost: output.cost_usd
          })
        end

        emit(on_message, :turn_completed, %{session_id: session_id})

        Logger.info("Claude adapter: completed for #{identifier}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           thread_id: session_id,
           turn_id: "turn-1"
         }}

      {:error, reason} ->
        emit(on_message, :turn_ended_with_error, %{
          session_id: session_id,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{session_id: session_id}) do
    Logger.info("Claude adapter: stopped session #{session_id}")
    :ok
  end

  def stop_session(_), do: :ok

  @impl true
  def tool_specs, do: []

  # -- Private --

  defp build_cli_args(prompt, config) do
    args = [
      "--print",
      "--output-format",
      "json",
      "--no-session-persistence",
      "-p",
      prompt
    ]

    args = maybe_add(args, "--model", config["model"])
    args = maybe_add(args, "--max-turns", config["max_turns"])
    args = maybe_add(args, "--max-budget-usd", config["max_budget_usd"])

    permission_mode = config["permission_mode"] || "bypassPermissions"
    args ++ ["--permission-mode", to_string(permission_mode)]
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]

  defp run_claude(args, workspace) do
    Logger.debug("Claude CLI: #{@claude_cmd} #{Enum.join(args, " ")}")

    try do
      case System.cmd(@claude_cmd, args,
             cd: workspace,
             stderr_to_stdout: true,
             env: [{"CLAUDE_CODE_ENTRYPOINT", "cli"}]
           ) do
        {output, 0} ->
          parse_output(output)

        {output, exit_code} ->
          Logger.error("Claude CLI exited with code #{exit_code}: #{truncate(output, 500)}")
          {:error, {:exit_code, exit_code, truncate(output, 500)}}
      end
    rescue
      e in ErlangError ->
        Logger.error("Claude CLI failed to start: #{inspect(e)}")
        {:error, {:command_failed, inspect(e)}}
    end
  end

  defp parse_output(raw) do
    case Jason.decode(raw) do
      {:ok, %{"result" => result} = json} ->
        {:ok,
         %{
           text: result || "",
           model: json["model"],
           input_tokens: get_in(json, ["usage", "input_tokens"]),
           output_tokens: get_in(json, ["usage", "output_tokens"]),
           cost_usd: get_in(json, ["usage", "cost_usd"]) || json["cost_usd"],
           session_id: json["session_id"]
         }}

      {:ok, json} when is_map(json) ->
        # Fallback: try to extract text from any structure
        text = json["result"] || json["content"] || json["text"] || inspect(json, limit: 2000)

        {:ok,
         %{
           text: text,
           model: json["model"],
           input_tokens: nil,
           output_tokens: nil,
           cost_usd: nil,
           session_id: nil
         }}

      {:error, _} ->
        # Not JSON — raw text output
        {:ok,
         %{
           text: raw,
           model: nil,
           input_tokens: nil,
           output_tokens: nil,
           cost_usd: nil,
           session_id: nil
         }}
    end
  end

  defp emit(on_message, event, details) when is_function(on_message) do
    on_message.(Map.merge(details, %{event: event, timestamp: DateTime.utc_now()}))
  end

  defp emit(_, _, _), do: :ok

  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "... (truncated)"
  end

  defp truncate(text, _max), do: text
end
