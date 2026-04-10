defmodule SymphonyElixir.Coordinator.Actions.HandleDUCompleted do
  @moduledoc """
  Handles delivery unit completion. Marks the DU as completed and
  unblocks any dependent DUs whose dependencies are now all satisfied.

  ## Expected signal data

  - `du_id` — the completed delivery unit ID
  """

  use Jido.Action,
    name: "handle_du_completed",
    description: "Marks a delivery unit complete and unblocks dependents",
    schema: [
      du_id: [type: :string, required: true]
    ]

  require Logger

  @impl true
  def run(%{du_id: du_id}, context) do
    units = context.state[:delivery_units] || %{}
    project_id = context.state[:project_id]

    case Map.get(units, du_id) do
      nil ->
        Logger.warning("Coordinator[#{project_id}]: DU #{du_id} not found, ignoring completion")
        {:ok, %{}}

      du ->
        Logger.info("Coordinator[#{project_id}]: DU #{du_id} completed")

        updated_units =
          units
          |> Map.put(du_id, %{du | status: :completed})
          |> unblock_dependents(du_id)

        newly_ready =
          Enum.filter(updated_units, fn {id, u} ->
            u.status == :ready && Map.get(units, id, %{}) |> Map.get(:status) == :blocked
          end)
          |> Enum.map(fn {id, _} -> id end)

        if newly_ready != [] do
          Logger.info("Coordinator[#{project_id}]: unblocked DUs: #{inspect(newly_ready)}")
        end

        {:ok, %{delivery_units: updated_units}}
    end
  end

  defp unblock_dependents(units, completed_du_id) do
    Map.new(units, fn {du_id, du} ->
      if du.status == :blocked && completed_du_id in du.depends_on do
        remaining_deps =
          Enum.filter(du.depends_on, fn dep_id ->
            case Map.get(units, dep_id) do
              %{status: :completed} -> false
              _ -> true
            end
          end)

        new_status = if remaining_deps == [], do: :ready, else: :blocked
        {du_id, %{du | depends_on: remaining_deps, status: new_status}}
      else
        {du_id, du}
      end
    end)
  end
end
