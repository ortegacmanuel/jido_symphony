defmodule SymphonyElixir.Coordinator.FeedbackAgent do
  @moduledoc """
  Jido Agent that learns from PR review history and proposes guidance updates.

  Runs independently from CoordinatorAgent and ReviewAgent. Analyzes merged
  PRs for recurring rejection patterns, classifies whether guidance rules
  are missing or unclear, and creates "guidance-update" issues.

  ## Signal Routes

  - `feedback.poll` → Analyze review patterns → classify gaps → propose updates
  """

  use Jido.Agent,
    name: "feedback_agent",
    description: "Learns from review history and improves coding guidance",
    schema: [
      project_id: [type: :string, required: true],
      review_patterns: [type: {:list, :any}, default: []],
      guidance_gaps: [type: {:list, :any}, default: []],
      guidance_updates_proposed: [type: :integer, default: 0],
      prs_analyzed: [type: :integer, default: 0],
      last_feedback_poll_at: [type: :any, default: nil]
    ]

  alias SymphonyElixir.Coordinator.Actions

  def signal_routes(_ctx) do
    [
      {"feedback.poll", [
        Actions.AnalyzeReviewPatterns,
        Actions.ClassifyGuidanceGap,
        Actions.ProposeGuidanceUpdate
      ]}
    ]
  end
end
