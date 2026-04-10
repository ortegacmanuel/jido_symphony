defmodule SymphonyElixir.Coordinator.Actions.FetchPRsAwaitingChanges do
  @moduledoc """
  Fetches PRs created by Symphony that have `CHANGES_REQUESTED` review status.

  Identifies PRs by checking if the branch name starts with `symphony/`.
  For each matching PR, fetches inline review comments and review bodies.

  ## State produced

  - `:prs_awaiting_changes` — list of `%{pr: map, review_comments: [comment], reviews: [review]}`
  """

  use Jido.Action,
    name: "fetch_prs_awaiting_changes",
    description: "Finds Symphony PRs with changes requested by reviewers",
    schema: [
      branch_prefix: [type: :string, default: "symphony/"]
    ]

  require Logger

  @gh_cmd "gh"

  @impl true
  def run(params, context) do
    project_id = context.state[:project_id]
    repo = SymphonyElixir.Config.github_repo(project_id) || System.get_env("GITHUB_REPO")

    if is_nil(repo) do
      {:ok, %{prs_awaiting_changes: []}}
    else
      case fetch_prs_with_changes_requested(repo, params.branch_prefix) do
        {:ok, prs} ->
          enriched =
            Enum.map(prs, fn pr ->
              comments = fetch_review_comments(repo, pr["number"])
              reviews = fetch_reviews(repo, pr["number"])

              %{
                pr: pr,
                review_comments: comments,
                reviews: reviews
              }
            end)

          Logger.info(
            "Coordinator[#{project_id}]: found #{length(enriched)} PRs awaiting changes"
          )

          {:ok, %{prs_awaiting_changes: enriched}}

        {:error, reason} ->
          Logger.error("Coordinator[#{project_id}]: failed to fetch PRs: #{inspect(reason)}")
          {:ok, %{prs_awaiting_changes: []}}
      end
    end
  end

  defp fetch_prs_with_changes_requested(repo, branch_prefix) do
    args = [
      "pr", "list",
      "--repo", repo,
      "--state", "open",
      "--limit", "50",
      "--json", "number,title,headRefName,reviewDecision,url,body,createdAt"
    ]

    case run_gh(args) do
      {:ok, prs} ->
        filtered =
          prs
          |> Enum.filter(fn pr ->
            pr["reviewDecision"] == "CHANGES_REQUESTED" &&
              String.starts_with?(pr["headRefName"] || "", branch_prefix)
          end)

        {:ok, filtered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_review_comments(repo, pr_number) do
    case run_gh_api("repos/#{repo}/pulls/#{pr_number}/comments") do
      {:ok, comments} when is_list(comments) ->
        Enum.map(comments, fn c ->
          %{
            user: get_in(c, ["user", "login"]),
            path: c["path"],
            line: c["line"],
            body: c["body"],
            created_at: c["created_at"]
          }
        end)

      _ ->
        []
    end
  end

  defp fetch_reviews(repo, pr_number) do
    case run_gh_api("repos/#{repo}/pulls/#{pr_number}/reviews") do
      {:ok, reviews} when is_list(reviews) ->
        reviews
        |> Enum.filter(fn r -> r["state"] in ["CHANGES_REQUESTED", "COMMENTED"] end)
        |> Enum.map(fn r ->
          %{
            user: get_in(r, ["user", "login"]),
            state: r["state"],
            body: r["body"]
          }
        end)
        |> Enum.reject(fn r -> r.body == "" || is_nil(r.body) end)

      _ ->
        []
    end
  end

  defp run_gh(args) do
    case System.find_executable(@gh_cmd) do
      nil -> {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, args, stderr_to_stdout: true) do
          {output, 0} -> Jason.decode(output)
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end

  defp run_gh_api(endpoint) do
    case System.find_executable(@gh_cmd) do
      nil -> {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, ["api", endpoint], stderr_to_stdout: true) do
          {output, 0} -> Jason.decode(output)
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end
end
