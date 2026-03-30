defmodule SymphonyElixir.Tracker.Beads do
  @moduledoc """
  Tracker adapter that reads from a local Beads (br) workspace.

  Shells out to the `br` CLI with `--json` to fetch issues,
  update statuses, and post comments. The beads workspace directory
  is resolved from `tracker.beads_root` in WORKFLOW.md config, falling
  back to the current working directory.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Issue

  @br_cmd "br"

  # -- Behaviour callbacks --

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, ready_items} <- run_br(["ready", "--json"]),
         {:ok, open_items} <- run_br(["list", "--status", "open", "--json"]) do
      all_items = ready_items ++ open_items
      seen = MapSet.new()

      issues =
        all_items
        |> Enum.reduce({[], seen}, fn item, {acc, seen_ids} ->
          id = Map.get(item, "id")

          if id && !MapSet.member?(seen_ids, id) do
            {[parse_issue(item) | acc], MapSet.put(seen_ids, id)}
          else
            {acc, seen_ids}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      {:ok, issues}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized = Enum.map(state_names, &normalize_state/1)
    includes_terminal = Enum.any?(normalized, &(&1 in ["done", "closed", "cancelled", "canceled"]))
    list_args = if includes_terminal, do: ["list", "--all", "--json"], else: ["list", "--json"]

    case run_br(list_args) do
      {:ok, items} ->
        issues =
          items
          |> Enum.map(&parse_issue/1)
          |> Enum.filter(fn %Issue{state: state} ->
            normalize_state(state) in normalized
          end)

        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    results =
      Enum.reduce_while(issue_ids, {:ok, []}, fn id, {:ok, acc} ->
        case run_br(["show", id, "--json"]) do
          {:ok, [item | _]} -> {:cont, {:ok, [parse_issue(item) | acc]}}
          {:ok, []} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    case run_br_raw(["comments", "add", issue_id, body]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_all_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_all_issues do
    case run_br(["list", "--all", "--json"]) do
      {:ok, items} -> {:ok, Enum.map(items, &parse_issue/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) do
    title = Map.get(attrs, :title, "")
    args = ["create", title, "--json"]

    args = if desc = Map.get(attrs, :description), do: args ++ ["--description", desc], else: args
    args = if type = Map.get(attrs, :type), do: args ++ ["--type", type], else: args
    args = if pri = Map.get(attrs, :priority), do: args ++ ["--priority", to_string(pri)], else: args
    args = if labels = Map.get(attrs, :labels), do: args ++ ["--labels", labels], else: args

    case run_br(args) do
      {:ok, [item | _]} -> {:ok, parse_issue(item)}
      {:ok, []} -> {:error, :no_issue_returned}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    br_status = to_br_status(state_name)

    case run_br_raw(["update", issue_id, "--status", br_status]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Helpers --

  defp beads_root do
    Application.get_env(:symphony_elixir, :beads_root, nil) ||
      System.get_env("BEADS_ROOT") ||
      File.cwd!()
  end

  defp run_br(args) do
    case run_br_raw(args) do
      {:ok, output} ->
        case extract_json(output) do
          {:ok, items} when is_list(items) -> {:ok, items}
          {:ok, item} when is_map(item) -> {:ok, [item]}
          {:error, reason} -> {:error, {:json_parse_error, reason, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract JSON from br output that may contain log lines before/after the JSON payload
  defp extract_json(output) do
    trimmed = String.trim(output)

    # Try to find the outermost JSON array or object
    cond do
      json_start = find_json_start(trimmed, "[") ->
        parse_from(trimmed, json_start, "[", "]")

      json_start = find_json_start(trimmed, "{") ->
        parse_from(trimmed, json_start, "{", "}")

      true ->
        {:error, :no_json_found}
    end
  end

  defp find_json_start(text, bracket) do
    case :binary.match(text, bracket) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp parse_from(text, start, _open, _close) do
    candidate = binary_part(text, start, byte_size(text) - start)
    Jason.decode(candidate)
  end

  defp run_br_raw(args) do
    br_path = System.find_executable(@br_cmd)

    if is_nil(br_path) do
      {:error, :br_not_installed}
    else
      case System.cmd(br_path, args, cd: beads_root(), stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, {:br_exit, code, output}}
      end
    end
  end

  @doc false
  def parse_issue(item) when is_map(item) do
    %Issue{
      id: Map.get(item, "id"),
      identifier: Map.get(item, "id"),
      title: Map.get(item, "title"),
      description: Map.get(item, "description"),
      priority: Map.get(item, "priority"),
      state: from_br_status(Map.get(item, "status", "open")),
      labels: Map.get(item, "labels", []),
      created_at: parse_timestamp(Map.get(item, "created_at")),
      updated_at: parse_timestamp(Map.get(item, "updated_at"))
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp to_br_status(state_name) do
    case normalize_state(state_name) do
      "todo" -> "open"
      "in progress" -> "in_progress"
      "in review" -> "in_progress"
      "human review" -> "in_progress"
      "merging" -> "in_progress"
      "rework" -> "open"
      "done" -> "closed"
      "closed" -> "closed"
      "cancelled" -> "closed"
      "canceled" -> "closed"
      other -> other
    end
  end

  defp from_br_status(status) do
    case normalize_state(status) do
      "open" -> "Todo"
      "in_progress" -> "In Progress"
      "closed" -> "Done"
      other -> other
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
