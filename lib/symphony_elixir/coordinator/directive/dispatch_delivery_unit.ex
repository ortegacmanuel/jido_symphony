defmodule SymphonyElixir.Coordinator.Directive.DispatchDeliveryUnit do
  @moduledoc """
  Directive emitted by DispatchReadyUnits action.

  When executed by the AgentServer drain loop, this creates a GitHub issue
  for the delivery unit (grouping its slice issues) and signals the
  project's Orchestrator to assign a coding agent.

  Following Cerbo pattern: custom directives for side effects,
  executed via `Jido.AgentServer.DirectiveExec` protocol.
  """

  @enforce_keys [:project_id, :delivery_unit]
  defstruct [:project_id, :delivery_unit]
end

defimpl Jido.AgentServer.DirectiveExec,
  for: SymphonyElixir.Coordinator.Directive.DispatchDeliveryUnit do
  require Logger

  def exec(
        %{project_id: project_id, delivery_unit: du},
        _input_signal,
        state
      ) do
    Logger.info(
      "DirectiveExec: dispatching DU #{du.id} for project #{project_id} " <>
        "(issues: #{inspect(du.issue_numbers)})"
    )

    # TODO: Phase 1a integration
    # 1. Create a parent GitHub issue for the DU (linking slice issues)
    # 2. Label it "Todo" so the Orchestrator picks it up
    # 3. Include all slice context in the issue body
    #
    # For now, log the dispatch intent. The existing Orchestrator will
    # pick up individual slice issues as before, and this directive
    # serves as the integration point for DU-aware dispatch.

    {:ok, state}
  end
end
