defmodule SymphonyElixir.Coordinator.Actions.AnalyzeReviewPatterns do
  @moduledoc """
  Analyzes review history on recently merged Symphony PRs to detect
  recurring patterns in reviewer feedback.

  Scans PRs merged in the last N days that went through at least one
  round of `CHANGES_REQUESTED`. Extracts reviewer comments and groups
  them by theme (domain purity, test coverage, naming, etc.).

  ## State produced

  - `:review_patterns` — list of `%{theme: str, comments: [comment], frequency: int, prs: [number]}`
  - `:prs_analyzed` — count of PRs scanned
  """

  use Jido.Action,
    name: "analyze_review_patterns",
    description: "Detects recurring patterns in PR review feedback",
    schema: [
      lookback_days: [type: :integer, default: 30],
      min_frequency: [type: :integer, default: 2]
    ]

  require Logger

  @gh_cmd "gh"

  # Keywords that indicate common review themes
  @theme_patterns [
    {:domain_purity, ~r/(domain.*(?:http|status.?code|transport)|transport.?agnostic|layer.?purity)/i},
    {:test_coverage, ~r/(test.*(?:missing|coverage|every.*branch|modified.*method)|missing.*test)/i},
    {:test_placement, ~r/(tests?.?unit.*laravel|test.?case.*phpunit|integration.*unit)/i},
    {:exception_hierarchy, ~r/(abstract.*base|final.*concrete|exception.*hierarchy|constructor.*arg)/i},
    {:duplication, ~r/(duplicat|already.*exist|mapper.*already|validation.*logic.*exist)/i},
    {:method_visibility, ~r/(public.*private|interface.*method|visibility|should.*be.*private)/i},
    {:git_hygiene, ~r/(composer.?setup|\.phar|tooling.*artifact|committed.*artifact)/i},
    {:naming, ~r/(naming.*convention|semantic.*name|named.*constructor|rename)/i},
    {:entity_coupling, ~r/(coupled.*partner|getMissing.*Fields|entity.*specific.*partner)/i},
    {:cqrs_violation, ~r/(command.*return|void.*command|query.*side.?effect)/i}
  ]

  @impl true
  def run(params, context) do
    project_id = context.state[:project_id]
    repo = SymphonyElixir.Config.github_repo(project_id) || System.get_env("GITHUB_REPO")

    if is_nil(repo) do
      {:ok, %{review_patterns: [], prs_analyzed: 0}}
    else
      case fetch_merged_prs_with_reviews(repo, params.lookback_days) do
        {:ok, prs_with_comments} ->
          all_comments = Enum.flat_map(prs_with_comments, fn {pr, comments} ->
            Enum.map(comments, &Map.put(&1, :pr_number, pr["number"]))
          end)

          patterns = detect_patterns(all_comments, params.min_frequency)

          Logger.info(
            "Coordinator[#{project_id}]: analyzed #{length(prs_with_comments)} PRs, " <>
              "found #{length(patterns)} recurring patterns"
          )

          {:ok, %{review_patterns: patterns, prs_analyzed: length(prs_with_comments)}}

        {:error, reason} ->
          Logger.error("Coordinator[#{project_id}]: review analysis failed: #{inspect(reason)}")
          {:ok, %{review_patterns: [], prs_analyzed: 0}}
      end
    end
  end

  defp fetch_merged_prs_with_reviews(repo, lookback_days) do
    since = Date.utc_today() |> Date.add(-lookback_days) |> Date.to_iso8601()

    args = [
      "pr", "list",
      "--repo", repo,
      "--state", "merged",
      "--limit", "50",
      "--json", "number,title,headRefName,mergedAt,reviewDecision"
    ]

    case run_gh_json(args) do
      {:ok, prs} ->
        # Filter: Symphony PRs merged after cutoff that had review rounds
        relevant =
          prs
          |> Enum.filter(fn pr ->
            (String.starts_with?(pr["headRefName"] || "", "symphony/") ||
               pr["reviewDecision"] == "CHANGES_REQUESTED") &&
              (pr["mergedAt"] || "") >= since
          end)

        prs_with_comments =
          Enum.map(relevant, fn pr ->
            comments = fetch_all_review_comments(repo, pr["number"])
            {pr, comments}
          end)
          |> Enum.reject(fn {_pr, comments} -> comments == [] end)

        {:ok, prs_with_comments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_review_comments(repo, pr_number) do
    inline = fetch_inline_comments(repo, pr_number)
    review_bodies = fetch_review_bodies(repo, pr_number)
    inline ++ review_bodies
  end

  defp fetch_inline_comments(repo, pr_number) do
    case run_gh_json(["api", "repos/#{repo}/pulls/#{pr_number}/comments"]) do
      {:ok, comments} when is_list(comments) ->
        Enum.map(comments, fn c ->
          %{
            type: :inline,
            user: get_in(c, ["user", "login"]),
            body: c["body"] || "",
            path: c["path"],
            line: c["line"]
          }
        end)

      _ ->
        []
    end
  end

  defp fetch_review_bodies(repo, pr_number) do
    case run_gh_json(["api", "repos/#{repo}/pulls/#{pr_number}/reviews"]) do
      {:ok, reviews} when is_list(reviews) ->
        reviews
        |> Enum.filter(fn r ->
          r["state"] in ["CHANGES_REQUESTED", "COMMENTED"] &&
            is_binary(r["body"]) && String.trim(r["body"]) != ""
        end)
        |> Enum.map(fn r ->
          %{
            type: :review,
            user: get_in(r, ["user", "login"]),
            body: r["body"],
            path: nil,
            line: nil
          }
        end)

      _ ->
        []
    end
  end

  defp detect_patterns(all_comments, min_frequency) do
    @theme_patterns
    |> Enum.map(fn {theme, regex} ->
      matching =
        Enum.filter(all_comments, fn c ->
          Regex.match?(regex, c.body)
        end)

      pr_numbers = matching |> Enum.map(& &1.pr_number) |> Enum.uniq()

      %{
        theme: theme,
        comments: matching,
        frequency: length(pr_numbers),
        prs: pr_numbers,
        example_comments: matching |> Enum.take(3) |> Enum.map(& &1.body)
      }
    end)
    |> Enum.filter(fn p -> p.frequency >= min_frequency end)
    |> Enum.sort_by(& &1.frequency, :desc)
  end

  defp run_gh_json(args) do
    case System.find_executable(@gh_cmd) do
      nil -> {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, args, stderr_to_stdout: true) do
          {output, 0} -> Jason.decode(output)
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end
end
