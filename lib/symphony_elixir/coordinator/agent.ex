defmodule SymphonyElixir.Coordinator.Agent do
  @moduledoc """
  Jido Agent that orchestrates the development lifecycle for a project.

  The CoordinatorAgent monitors GitHub Issues, classifies them, groups
  event model slices into delivery units, builds a dependency DAG, and
  dispatches ready work to coding agents.

  ## FSM States

  - `idle` — Waiting for next poll cycle
  - `analyzing` — Fetching and classifying issues, grouping into DUs
  - `dispatching` — Sending ready delivery units to the orchestrator
  - `monitoring` — Tracking active agents, handling completions

  ## Signal Routes

  - `coordinator.poll` → Full pipeline: fetch → triage slices (LLM) → coordinate non-slices (LLM) → DAG → dispatch
  - `coordinator.review_poll` → PR review pipeline (find → extract comments → dispatch fix)
  - `coordinator.feedback_poll` → Feedback pipeline (analyze patterns → classify gaps → propose updates)
  - `coordinator.du_completed` → Mark DU done, unblock dependents
  - `coordinator.du_failed` → Cascade failure to dependent DUs

  ## Two Coordination Modes

  **Event model slices** (prooph board → bridge → issues with `event-model-slice` label):
  LLM triage with project-specific architecture context. Groups into delivery units,
  judges independent implementability, handles incremental slice arrivals.

  **Everything else** (manual bugs, features, refactors):
  open-multi-agent coordinator pattern. LLM decomposes complex issues into task DAG
  with dependsOn edges. Simple issues pass through as single tasks.

  ## Design

  Following Jido patterns from Cerbo production code:
  - Signal type maps to action chain (sequential execution)
  - Actions merge state via context.state (each reads prior results)
  - Side effects described as directives, never inline
  - Completion is a state change, not process death
  """

  use Jido.Agent,
    name: "coordinator",
    description: "Orchestrates the development lifecycle for a project",
    schema: [
      project_id: [type: :string, required: true],
      status: [type: :atom, default: :idle],

      # Issue tracking
      issues: [type: {:list, :any}, default: []],
      slice_issues: [type: {:list, :any}, default: []],
      other_issues: [type: {:list, :any}, default: []],

      # Review tracking
      prs_awaiting_changes: [type: {:list, :any}, default: []],
      review_fixes_dispatched: [type: :integer, default: 0],

      # Feedback tracking
      review_patterns: [type: {:list, :any}, default: []],
      guidance_gaps: [type: {:list, :any}, default: []],
      guidance_updates_proposed: [type: :integer, default: 0],

      # Delivery units (populated by TriageSlices + CoordinateIssues)
      delivery_units: [type: {:map, :string, :any}, default: %{}],
      triage_cache_key: [type: :any, default: nil],
      slices_waiting: [type: {:list, :any}, default: []],
      coordinated_tasks: [type: {:list, :any}, default: []],

      # DAG state
      dag: [type: :any, default: nil],

      # Metrics
      last_poll_at: [type: :any, default: nil],
      polls_completed: [type: :integer, default: 0]
    ]

  alias SymphonyElixir.Coordinator.Actions

  @doc """
  Signal routes map event types to action chains.

  The coordinator responds to three signal types:
  - Poll trigger → full analysis + dispatch pipeline
  - DU completed → unblock dependents
  - DU failed → cascade failure
  """
  def signal_routes(_ctx) do
    [
      # Full poll cycle:
      # 1. Fetch all open issues from GitHub
      # 2. Triage slices: LLM groups into DUs with project-specific context (cached)
      # 3. Coordinate non-slices: open-multi-agent pattern (LLM decompose complex, pass-through simple)
      # 4. Build unified DAG from both sources
      # 5. Dispatch ready units
      {"coordinator.poll", [
        Actions.FetchOpenIssues,
        Actions.TriageSlices,
        Actions.CoordinateIssues,
        Actions.BuildTaskDAG,
        Actions.DispatchReadyUnits
      ]},

      # PR review pipeline: find PRs with changes_requested → dispatch fix agents
      {"coordinator.review_poll", [
        Actions.FetchPRsAwaitingChanges,
        Actions.DispatchReviewFix
      ]},

      # Feedback pipeline: analyze review history → classify gaps → propose guidance updates
      {"coordinator.feedback_poll", [
        Actions.AnalyzeReviewPatterns,
        Actions.ClassifyGuidanceGap,
        Actions.ProposeGuidanceUpdate
      ]},

      # Delivery unit lifecycle events
      {"coordinator.du_completed", [
        Actions.HandleDUCompleted
      ]},

      {"coordinator.du_failed", [
        Actions.HandleDUFailed
      ]}
    ]
  end
end
