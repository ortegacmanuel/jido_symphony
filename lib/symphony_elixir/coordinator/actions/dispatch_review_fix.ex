defmodule SymphonyElixir.Coordinator.Actions.DispatchReviewFix do
  @moduledoc """
  For each PR awaiting changes, emits a directive to dispatch a coding agent
  to the existing branch with reviewer feedback as context.

  The agent works on the SAME branch (not a fresh clone), reads the review
  comments, makes the requested changes, and pushes to the same PR.

  ## State consumed

  - `:prs_awaiting_changes` — from FetchPRsAwaitingChanges

  ## State produced

  - `:review_fixes_dispatched` — count of PRs dispatched for review fixes
  """

  use Jido.Action,
    name: "dispatch_review_fix",
    description: "Dispatches coding agents to address PR review comments",
    schema: []

  require Logger

  @impl true
  def run(_params, context) do
    prs = context.state[:prs_awaiting_changes] || []
    project_id = context.state[:project_id]

    if prs == [] do
      {:ok, %{review_fixes_dispatched: 0}}
    else
      directives =
        Enum.map(prs, fn %{pr: pr, review_comments: comments, reviews: reviews} ->
          Logger.info(
            "Coordinator[#{project_id}]: dispatching review fix for PR ##{pr["number"]} " <>
              "(#{length(comments)} inline comments, #{length(reviews)} review bodies)"
          )

          %SymphonyElixir.Coordinator.Directive.DispatchReviewFix{
            project_id: project_id,
            pr: pr,
            review_comments: comments,
            reviews: reviews
          }
        end)

      {:ok, %{review_fixes_dispatched: length(directives)}, directives}
    end
  end
end
