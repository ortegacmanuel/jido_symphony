defmodule SymphonyElixir.Coordinator.Directive.DispatchReviewFix do
  @moduledoc """
  Directive to dispatch a coding agent to address PR review comments.

  The key difference from DispatchDeliveryUnit: this works on an EXISTING
  branch, not a fresh clone. The agent receives:

  1. The PR context (title, body, branch)
  2. All inline review comments (file, line, body)
  3. Review-level feedback bodies
  4. Instructions to fix and push to the same PR

  ## Execution

  The directive creates a GitHub Issue with a special "review-fix" label
  that the Orchestrator picks up. The issue body contains the review
  context as the agent prompt. The after_create hook checks out the
  existing branch instead of cloning fresh.
  """

  @enforce_keys [:project_id, :pr]
  defstruct [:project_id, :pr, :review_comments, :reviews]
end

defimpl Jido.AgentServer.DirectiveExec,
  for: SymphonyElixir.Coordinator.Directive.DispatchReviewFix do
  require Logger

  def exec(
        %{project_id: project_id, pr: pr, review_comments: comments, reviews: reviews},
        _input_signal,
        state
      ) do
    repo =
      SymphonyElixir.Config.github_repo(project_id) || System.get_env("GITHUB_REPO")

    pr_number = pr["number"]
    branch = pr["headRefName"]

    Logger.info(
      "DirectiveExec: dispatching review fix for PR ##{pr_number} branch=#{branch} project=#{project_id}"
    )

    issue_body = build_review_fix_body(pr, comments, reviews)

    # Create a GitHub issue that the Orchestrator will pick up.
    # The "review-fix" label + branch reference tells the hooks
    # to checkout the existing branch instead of cloning fresh.
    args = [
      "issue",
      "create",
      "--title",
      "Review fix: PR ##{pr_number} — #{pr["title"]}",
      "--body",
      issue_body,
      "--label",
      "Todo,review-fix",
      "--repo",
      repo
    ]

    case run_gh(args) do
      {:ok, url} ->
        Logger.info("DirectiveExec: review fix issue created: #{url}")

      {:error, reason} ->
        Logger.error("DirectiveExec: failed to create review fix issue: #{inspect(reason)}")
    end

    {:ok, state}
  end

  defp build_review_fix_body(pr, comments, reviews) do
    sections = [
      "## Review Fix Request",
      "",
      "Address the review comments on PR ##{pr["number"]} (`#{pr["headRefName"]}`).",
      "",
      "**Original PR:** #{pr["url"]}",
      "**Branch:** `#{pr["headRefName"]}`",
      ""
    ]

    # Review-level feedback
    sections =
      if reviews != [] do
        review_lines =
          Enum.flat_map(reviews, fn r ->
            ["**@#{r.user}** (#{r.state}):", "", r.body, ""]
          end)

        sections ++ ["## Reviewer Feedback", ""] ++ review_lines
      else
        sections
      end

    # Inline comments grouped by file
    sections =
      if comments != [] do
        by_file = Enum.group_by(comments, & &1.path)

        file_sections =
          Enum.flat_map(by_file, fn {path, file_comments} ->
            comment_lines =
              Enum.flat_map(file_comments, fn c ->
                line_ref = if c.line, do: " (line #{c.line})", else: ""
                ["- **@#{c.user}**#{line_ref}: #{c.body}", ""]
              end)

            ["### `#{path}`", ""] ++ comment_lines
          end)

        sections ++ ["## Inline Review Comments", ""] ++ file_sections
      else
        sections
      end

    # Agent instructions
    sections =
      sections ++
        [
          "## Instructions",
          "",
          "1. This is a review fix. Work on the EXISTING branch `#{pr["headRefName"]}`.",
          "2. Read each review comment carefully.",
          "3. Make the requested changes. If a comment is unclear, make your best judgment.",
          "4. Run tests and phpstan after changes.",
          "5. Run `/deep-review` to self-check.",
          "6. Do NOT create a new PR. Push to the same branch — the existing PR will update.",
          "7. Write a summary of changes in `.symphony/review-fix-summary.md`.",
          ""
        ]

    Enum.join(sections, "\n")
  end

  defp run_gh(args) do
    case System.find_executable("gh") do
      nil ->
        {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end
end
