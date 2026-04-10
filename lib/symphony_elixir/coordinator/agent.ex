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

  - `coordinator.poll` → Full analysis pipeline (fetch → classify → group → dispatch)
  - `coordinator.du_completed` → Mark DU done, unblock dependents
  - `coordinator.du_failed` → Cascade failure to dependent DUs

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

      # Delivery units
      delivery_units: [type: {:map, :string, :any}, default: %{}],

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
      # Full poll cycle: fetch issues → classify → group → build DAG → dispatch
      {"coordinator.poll", [
        Actions.FetchOpenIssues,
        Actions.ClassifySlicePattern,
        Actions.IdentifyDeliveryUnits,
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
