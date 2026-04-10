defmodule SymphonyElixir.Coordinator.Actions.BuildTaskDAG do
  @moduledoc """
  Builds a dependency DAG from delivery units.

  Resolves cross-DU dependencies: if DU2 contains a slice that consumes
  something produced by a slice in DU1, then DU2 depends on DU1.

  Marks each DU as `:ready` (no unsatisfied deps) or `:blocked`.

  ## State consumed

  - `:delivery_units` — from IdentifyDeliveryUnits
  - `:classified_slices` — from ClassifySlicePattern (for produces/consumes)

  ## State produced

  - `:delivery_units` — updated with `depends_on` and `status` fields
  - `:dag` — `%{ready: [du_ids], blocked: [du_ids], edges: [{from, to}]}`
  """

  use Jido.Action,
    name: "build_task_dag",
    description: "Builds a dependency DAG from delivery units",
    schema: []

  @impl true
  def run(_params, context) do
    units = context.state[:delivery_units] || %{}

    if map_size(units) == 0 do
      {:ok, %{dag: %{ready: [], blocked: [], edges: []}}}
    else
      {updated_units, dag} = resolve_cross_du_dependencies(units)
      {:ok, %{delivery_units: updated_units, dag: dag}}
    end
  end

  defp resolve_cross_du_dependencies(units) do
    # Build index: produced name → DU ID
    produces_by_du =
      Enum.flat_map(units, fn {du_id, du} ->
        Enum.flat_map(du.slices, fn slice ->
          Enum.map(slice.produces, fn p -> {p.name, du_id} end)
        end)
      end)
      |> Map.new()

    # For each DU, find which other DUs produce what it consumes
    edges =
      Enum.flat_map(units, fn {du_id, du} ->
        consumed_names =
          Enum.flat_map(du.slices, fn slice ->
            Enum.map(slice.consumes, fn c -> c.name end)
          end)

        consumed_names
        |> Enum.flat_map(fn name ->
          case Map.get(produces_by_du, name) do
            nil -> []
            ^du_id -> []
            producer_du_id -> [{producer_du_id, du_id}]
          end
        end)
        |> Enum.uniq()
      end)

    # Update units with depends_on
    deps_map =
      Enum.group_by(edges, fn {_from, to} -> to end, fn {from, _to} -> from end)

    updated_units =
      Map.new(units, fn {du_id, du} ->
        deps = Map.get(deps_map, du_id, []) |> Enum.uniq()
        status = if deps == [], do: :ready, else: :blocked
        {du_id, %{du | depends_on: deps, status: status}}
      end)

    ready = for {id, du} <- updated_units, du.status == :ready, do: id
    blocked = for {id, du} <- updated_units, du.status == :blocked, do: id

    dag = %{
      ready: Enum.sort(ready),
      blocked: Enum.sort(blocked),
      edges: edges
    }

    {updated_units, dag}
  end
end
