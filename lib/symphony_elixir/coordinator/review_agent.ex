defmodule SymphonyElixir.Coordinator.ReviewAgent do
  @moduledoc """
  Jido Agent that monitors PR reviews and dispatches fix agents.

  Runs independently from the CoordinatorAgent. When a human reviewer
  requests changes on a Symphony-created PR, this agent detects it and
  creates a "review-fix" issue so a coding agent addresses the comments.

  ## Signal Routes

  - `review.poll` → Find PRs with changes_requested → dispatch fix agents
  """

  use Jido.Agent,
    name: "review_agent",
    description: "Monitors PR reviews and dispatches fix agents",
    schema: [
      project_id: [type: :string, required: true],
      prs_awaiting_changes: [type: {:list, :any}, default: []],
      review_fixes_dispatched: [type: :integer, default: 0],
      last_review_poll_at: [type: :any, default: nil]
    ]

  alias SymphonyElixir.Coordinator.Actions

  def signal_routes(_ctx) do
    [
      {"review.poll", [
        Actions.FetchPRsAwaitingChanges,
        Actions.DispatchReviewFix
      ]}
    ]
  end
end
