defmodule SymphonyElixir.Tracker.GitHub do
  @moduledoc """
  Tracker adapter that reads from GitHub Issues via the `gh` CLI.

  Uses label-based Kanban conventions since GitHub Issues only has
  open/closed states natively:

  - `Todo` label → candidate for dispatch
  - `In Progress` label → agent is working on it
  - `Done` label → completed (issue also closed)

  ## WORKFLOW.md config

      tracker:
        kind: github
        github_repo: owner/repo       # e.g. ortegacmanuel/saluton_phoenix

  Requires `gh` CLI authenticated with access to the repo.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Issue

  @gh_cmd "gh"

  # Labels used for Kanban state tracking
  @state_labels ["Todo", "In Progress", "Done", "Cancelled"]

  # -- Behaviour callbacks --

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    # Candidates are ONLY open issues with explicit "Todo" label
    with {:ok, items} <- run_gh_issue_list(state: "open") do
      candidates =
        items
        |> Enum.map(&parse_issue/1)
        |> Enum.filter(fn %Issue{state: state} ->
          normalize_state(state) == "todo"
        end)

      {:ok, candidates}
    end
  end

  @spec fetch_all_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_all_issues do
    with {:ok, items} <- run_gh_issue_list(state: "all") do
      {:ok, Enum.map(items, &parse_issue/1)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized = Enum.map(state_names, &normalize_state/1)
    includes_terminal = Enum.any?(normalized, &(&1 in ["done", "cancelled", "canceled", "closed"]))
    gh_state = if includes_terminal, do: "all", else: "open"

    with {:ok, items} <- run_gh_issue_list(state: gh_state) do
      issues =
        items
        |> Enum.map(&parse_issue/1)
        |> Enum.filter(fn %Issue{state: state} ->
          normalize_state(state) in normalized
        end)

      {:ok, issues}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    results =
      Enum.reduce_while(issue_ids, {:ok, []}, fn id, {:ok, acc} ->
        case run_gh_issue_view(id) do
          {:ok, item} -> {:cont, {:ok, [parse_issue(item) | acc]}}
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
    case run_gh(["issue", "comment", issue_id, "--body", body, "--repo", repo()]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) do
    title = Map.get(attrs, :title, "")
    args = ["issue", "create", "--title", title, "--repo", repo()]

    args = if desc = Map.get(attrs, :description), do: args ++ ["--body", desc], else: args
    args = if labels = Map.get(attrs, :labels), do: args ++ ["--label", labels], else: args ++ ["--label", "Todo"]

    case run_gh_json(args ++ ["--json", "number,title,body,state,labels,createdAt,updatedAt,url"]) do
      {:ok, item} -> {:ok, parse_issue(item)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    normalized = normalize_state(state_name)

    # Remove existing state labels, add new one
    current_state_label = current_state_label_for_issue(issue_id)

    # Remove old state label if present
    if current_state_label do
      run_gh(["issue", "edit", issue_id, "--remove-label", current_state_label, "--repo", repo()])
    end

    # Add new state label
    new_label = to_github_label(normalized)
    run_gh(["issue", "edit", issue_id, "--add-label", new_label, "--repo", repo()])

    # Close the issue if terminal state
    if normalized in ["done", "closed", "cancelled", "canceled"] do
      run_gh(["issue", "close", issue_id, "--repo", repo()])
    end

    :ok
  end

  # -- Private helpers --

  defp repo do
    SymphonyElixir.Config.github_repo() ||
      System.get_env("GITHUB_REPO") ||
      detect_repo()
  end

  defp detect_repo do
    case System.cmd(@gh_cmd, ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> ""
    end
  end

  defp run_gh_issue_list(opts) do
    state = Keyword.get(opts, :state, "open")
    limit = Keyword.get(opts, :limit, "100")

    args = [
      "issue", "list",
      "--state", state,
      "--limit", limit,
      "--json", "number,title,body,state,labels,createdAt,updatedAt,url,assignees",
      "--repo", repo()
    ]

    run_gh_json(args)
  end

  defp run_gh_issue_view(issue_id) do
    args = [
      "issue", "view", issue_id,
      "--json", "number,title,body,state,labels,createdAt,updatedAt,url,assignees",
      "--repo", repo()
    ]

    run_gh_json(args)
  end

  defp run_gh_json(args) do
    case run_gh(args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_parse_error, reason, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_gh(args) do
    gh_path = System.find_executable(@gh_cmd)

    if is_nil(gh_path) do
      {:error, :gh_not_installed}
    else
      case System.cmd(gh_path, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
      end
    end
  end

  @doc false
  def parse_issue(item) when is_map(item) do
    labels = extract_labels(item)
    state = derive_state(item, labels)
    number = item["number"]

    %Issue{
      id: to_string(number),
      identifier: "GH-#{number}",
      title: item["title"],
      description: item["body"],
      priority: priority_from_labels(labels),
      state: state,
      labels: labels,
      url: item["url"],
      created_at: parse_timestamp(item["createdAt"]),
      updated_at: parse_timestamp(item["updatedAt"])
    }
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      label when is_binary(label) -> label
      _ -> ""
    end)
  end

  defp extract_labels(_), do: []

  defp derive_state(item, labels) do
    # Check for explicit state labels only
    state_label = Enum.find(labels, fn label ->
      normalize_state(label) in Enum.map(@state_labels, &normalize_state/1)
    end)

    cond do
      state_label -> state_label
      item["state"] == "CLOSED" || item["state"] == "closed" -> "Done"
      true -> ""
    end
  end

  defp priority_from_labels(labels) do
    cond do
      "P0" in labels || "critical" in labels -> 0
      "P1" in labels || "high" in labels -> 1
      "P2" in labels || "medium" in labels -> 2
      "P3" in labels || "low" in labels -> 3
      true -> 2
    end
  end

  defp current_state_label_for_issue(issue_id) do
    case run_gh_issue_view(issue_id) do
      {:ok, item} ->
        labels = extract_labels(item)
        Enum.find(labels, fn label ->
          normalize_state(label) in Enum.map(@state_labels, &normalize_state/1)
        end)

      _ ->
        nil
    end
  end

  defp to_github_label(normalized_state) do
    case normalized_state do
      "todo" -> "Todo"
      "in progress" -> "In Progress"
      "in review" -> "In Progress"
      "human review" -> "In Progress"
      "merging" -> "In Progress"
      "rework" -> "Todo"
      "done" -> "Done"
      "closed" -> "Done"
      "cancelled" -> "Cancelled"
      "canceled" -> "Cancelled"
      other -> other
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
