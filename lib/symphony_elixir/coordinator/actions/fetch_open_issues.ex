defmodule SymphonyElixir.Coordinator.Actions.FetchOpenIssues do
  @moduledoc """
  Fetches open GitHub issues for the project and extracts structured metadata.

  Issues with an `event-model-slice` label and valid JSON metadata block
  are classified as slice issues. All others are classified as regular issues.

  ## State produced

  - `:issues` — all open issues (raw)
  - `:slice_issues` — issues with proophboard structured metadata
  - `:other_issues` — issues without structured metadata (bugs, features, etc.)
  - `:last_poll_at` — timestamp of this poll
  """

  use Jido.Action,
    name: "fetch_open_issues",
    description: "Fetches open GitHub issues and extracts structured metadata",
    schema: [
      project_id: [type: :string, required: true]
    ]

  require Logger

  @gh_cmd "gh"

  @impl true
  def run(params, context) do
    project_id = params.project_id || context.state[:project_id]
    repo = resolve_repo(project_id)

    case fetch_issues(repo, project_id) do
      {:ok, issues} ->
        {slices, others} = partition_issues(issues)

        Logger.info(
          "Coordinator[#{project_id}]: fetched #{length(issues)} issues " <>
            "(#{length(slices)} slices, #{length(others)} other)"
        )

        {:ok,
         %{
           issues: issues,
           slice_issues: slices,
           other_issues: others,
           last_poll_at: DateTime.utc_now(),
           polls_completed: (context.state[:polls_completed] || 0) + 1
         }}

      {:error, reason} ->
        Logger.error("Coordinator[#{project_id}]: failed to fetch issues: #{inspect(reason)}")
        {:error, "Failed to fetch issues: #{inspect(reason)}"}
    end
  end

  defp fetch_issues(repo, project_id) do
    gh_token_env = resolve_gh_token_env(project_id)

    args = [
      "issue",
      "list",
      "--state",
      "open",
      "--limit",
      "100",
      "--json",
      "number,title,body,state,labels,createdAt,updatedAt,url,assignees",
      "--repo",
      repo
    ]

    env = if gh_token_env, do: [{"GH_TOKEN", gh_token_env}], else: []

    case System.find_executable(@gh_cmd) do
      nil ->
        {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, args, stderr_to_stdout: true, env: env) do
          {output, 0} ->
            Jason.decode(output)

          {output, code} ->
            {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end

  defp partition_issues(issues) do
    Enum.split_with(issues, fn issue ->
      has_slice_label?(issue) && has_structured_metadata?(issue)
    end)
  end

  defp has_slice_label?(issue) do
    labels = issue["labels"] || []

    Enum.any?(labels, fn label ->
      name = if is_map(label), do: label["name"], else: label
      name == "event-model-slice"
    end)
  end

  defp has_structured_metadata?(issue) do
    case extract_structured_metadata(issue["body"]) do
      {:ok, _metadata} -> true
      :none -> false
    end
  end

  @doc """
  Extracts the structured JSON metadata block from an issue body.

  Looks for a fenced code block after a "Structured Metadata" heading:

      ## Structured Metadata
      ```json
      { "source": "proophboard", ... }
      ```
  """
  @spec extract_structured_metadata(String.t() | nil) :: {:ok, map()} | :none
  def extract_structured_metadata(nil), do: :none

  def extract_structured_metadata(body) when is_binary(body) do
    case Regex.run(
           ~r/```json\s*\n(.*?)\n\s*```/s,
           body
         ) do
      [_match, json_str] ->
        case Jason.decode(json_str) do
          {:ok, %{"source" => "proophboard"} = metadata} -> {:ok, metadata}
          {:ok, _other} -> :none
          {:error, _} -> :none
        end

      nil ->
        :none
    end
  end

  defp resolve_repo(project_id) do
    SymphonyElixir.Config.github_repo(project_id) ||
      System.get_env("GITHUB_REPO")
  end

  defp resolve_gh_token_env(project_id) do
    env_key =
      "GH_TOKEN_" <>
        (project_id || "DEFAULT")
        |> String.upcase()
        |> String.replace(~r/[^A-Z0-9]/, "_")

    System.get_env(env_key) || System.get_env("GH_TOKEN")
  end
end
