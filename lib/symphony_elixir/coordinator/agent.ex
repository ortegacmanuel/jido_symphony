defmodule SymphonyElixir.Coordinator.Agent do
  @moduledoc """
  Jido Agent that orchestrates work dispatch for a project.

  Monitors GitHub Issues, triages event model slices into delivery units,
  coordinates non-slice issues (open-multi-agent pattern), builds a
  dependency DAG, and dispatches ready work to coding agents.

  Runs alongside ReviewAgent (PR feedback) and FeedbackAgent (guidance
  improvement) — each is a separate Jido Agent with independent lifecycle.

  ## Signal Routes

  - `coordinator.poll` → Full pipeline: fetch → triage → coordinate → DAG → dispatch
  - `coordinator.du_completed` → Mark DU done, unblock dependents
  - `coordinator.du_failed` → Cascade failure to dependent DUs

  ## Two Coordination Modes

  **Event model slices** (prooph board → bridge → issues with `event-model-slice` label):
  LLM triage with project-specific architecture context. Groups into delivery units,
  judges independent implementability, handles incremental slice arrivals.

  **Everything else** (manual bugs, features, refactors):
  open-multi-agent coordinator pattern. LLM decomposes complex issues into task DAG
  with dependsOn edges. Simple issues pass through as single tasks.
  """

  use Jido.Agent,
    name: "coordinator",
    description: "Orchestrates work dispatch for a project",
    schema: [
      project_id: [type: :string, required: true],
      status: [type: :atom, default: :idle],

      # Issue tracking
      issues: [type: {:list, :any}, default: []],
      slice_issues: [type: {:list, :any}, default: []],
      other_issues: [type: {:list, :any}, default: []],

      # Delivery units (populated by TriageSlices + CoordinateIssues)
      delivery_units: [type: {:map, :string, :any}, default: %{}],
      triage_cache_key: [type: :any, default: nil],
      slices_waiting: [type: {:list, :any}, default: []],

      # DAG state
      dag: [type: :any, default: nil],

      # Metrics
      last_poll_at: [type: :any, default: nil],
      polls_completed: [type: :integer, default: 0]
    ]

  alias SymphonyElixir.Coordinator.Actions

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
