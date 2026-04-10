defmodule SymphonyElixir.Coordinator.Actions.DispatchReadyUnits do
  @moduledoc """
  Identifies delivery units with satisfied dependencies and dispatches them.

  For each ready DU, emits a `DispatchDeliveryUnit` directive that the
  runtime will execute — creating a GitHub issue for the DU (if needed)
  and signaling the Orchestrator to assign a coding agent.

  ## State consumed

  - `:delivery_units` — from BuildTaskDAG (with status :ready/:blocked)
  - `:dag` — from BuildTaskDAG

  ## State produced

  - `:delivery_units` — DUs marked as :dispatched
  - `:status` — set to :monitoring if any DUs dispatched
  """

  use Jido.Action,
    name: "dispatch_ready_units",
    description: "Dispatches delivery units that have satisfied dependencies",
    schema: []

  require Logger

  @impl true
  def run(_params, context) do
    units = context.state[:delivery_units] || %{}
    project_id = context.state[:project_id]

    ready_units =
      Enum.filter(units, fn {_id, du} -> du.status == :ready end)

    if ready_units == [] do
      Logger.debug("Coordinator[#{project_id}]: no ready delivery units to dispatch")
      {:ok, %{status: :idle}}
    else
      # Mark dispatched units and build directives
      {updated_units, directives} =
        Enum.reduce(ready_units, {units, []}, fn {du_id, du}, {acc_units, acc_directives} ->
          Logger.info(
            "Coordinator[#{project_id}]: dispatching #{du_id} " <>
              "(#{length(du.slices)} slices, patterns: #{inspect(du.patterns)})"
          )

          updated = %{du | status: :dispatched}
          directive = %SymphonyElixir.Coordinator.Directive.DispatchDeliveryUnit{
            project_id: project_id,
            delivery_unit: updated
          }

          {Map.put(acc_units, du_id, updated), [directive | acc_directives]}
        end)

      {:ok, %{delivery_units: updated_units, status: :monitoring}, directives}
    end
  end
end
