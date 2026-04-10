defmodule SymphonyElixir.Coordinator.Actions.HandleDUFailed do
  @moduledoc """
  Handles delivery unit failure. Marks the DU as failed and
  cascades failure to all transitive dependents.
  """

  use Jido.Action,
    name: "handle_du_failed",
    description: "Marks a delivery unit failed and cascades to dependents",
    schema: [
      du_id: [type: :string, required: true],
      reason: [type: :string, default: "unknown"]
    ]

  require Logger

  @impl true
  def run(%{du_id: du_id} = params, context) do
    units = context.state[:delivery_units] || %{}
    project_id = context.state[:project_id]

    case Map.get(units, du_id) do
      nil ->
        {:ok, %{}}

      du ->
        Logger.warning(
          "Coordinator[#{project_id}]: DU #{du_id} failed: #{params.reason}"
        )

        updated_units =
          units
          |> Map.put(du_id, %{du | status: :failed})
          |> cascade_failure(du_id)

        {:ok, %{delivery_units: updated_units}}
    end
  end

  defp cascade_failure(units, failed_du_id) do
    # Find all DUs that depend on the failed one (directly or transitively)
    dependents = find_transitive_dependents(units, failed_du_id, MapSet.new())

    Map.new(units, fn {du_id, du} ->
      if MapSet.member?(dependents, du_id) && du.status not in [:completed, :failed] do
        Logger.warning("Coordinator: cascade failure #{failed_du_id} → #{du_id}")
        {du_id, %{du | status: :failed}}
      else
        {du_id, du}
      end
    end)
  end

  defp find_transitive_dependents(units, du_id, visited) do
    direct =
      Enum.filter(units, fn {_id, du} ->
        du_id in (du.depends_on || [])
      end)
      |> Enum.map(fn {id, _du} -> id end)
      |> Enum.reject(&MapSet.member?(visited, &1))

    new_visited = Enum.reduce(direct, visited, &MapSet.put(&2, &1))

    Enum.reduce(direct, new_visited, fn dep_id, acc ->
      find_transitive_dependents(units, dep_id, acc)
    end)
  end
end
