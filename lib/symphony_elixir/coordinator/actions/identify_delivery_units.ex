defmodule SymphonyElixir.Coordinator.Actions.IdentifyDeliveryUnits do
  @moduledoc """
  Groups classified slices into delivery units based on dependency analysis.

  ## Grouping Rules

  1. If Slice B consumes a command/query that Slice A produces → **group A + B**
  2. If Slice B writes to an entity that Slice A creates → **group A + B**
  3. If Slice B listens to an event from Slice A → **separate** (loose coupling)
  4. If Slice depends only on existing infrastructure in main → **standalone**

  Connected components in the hard-dependency graph form delivery units.

  ## State consumed

  - `:classified_slices` — from ClassifySlicePattern

  ## State produced

  - `:delivery_units` — map of `du_id => %{id, slices, depends_on, status}`
  """

  use Jido.Action,
    name: "identify_delivery_units",
    description: "Groups classified slices into delivery units by dependency analysis",
    schema: []

  require Logger

  @impl true
  def run(_params, context) do
    classified = context.state[:classified_slices] || []

    if classified == [] do
      {:ok, %{delivery_units: %{}}}
    else
      units = group_into_delivery_units(classified)
      {:ok, %{delivery_units: units}}
    end
  end

  defp group_into_delivery_units(classified) do
    # Build produces index: name → slice index
    produces_index = build_produces_index(classified)

    # Build adjacency list for hard dependencies
    edges = build_hard_dependency_edges(classified, produces_index)

    # Find connected components (Union-Find)
    components = find_connected_components(length(classified), edges)

    # Group slices by component
    components
    |> Enum.with_index()
    |> Enum.group_by(fn {component_id, _idx} -> component_id end, fn {_component_id, idx} ->
      Enum.at(classified, idx)
    end)
    |> Enum.with_index(1)
    |> Map.new(fn {{_component_id, slices}, du_number} ->
      du_id = "DU#{du_number}"

      {du_id,
       %{
         id: du_id,
         slices: slices,
         issue_numbers: Enum.map(slices, fn s -> s.issue["number"] end),
         patterns: Enum.map(slices, fn s -> s.pattern end) |> Enum.uniq(),
         depends_on: [],
         status: :pending
       }}
    end)
  end

  defp build_produces_index(classified) do
    classified
    |> Enum.with_index()
    |> Enum.flat_map(fn {slice, idx} ->
      Enum.map(slice.produces, fn p -> {p.name, idx} end)
    end)
    |> Map.new()
  end

  defp build_hard_dependency_edges(classified, produces_index) do
    classified
    |> Enum.with_index()
    |> Enum.flat_map(fn {slice, consumer_idx} ->
      Enum.flat_map(slice.consumes, fn consumed ->
        case Map.get(produces_index, consumed.name) do
          nil -> []
          producer_idx when producer_idx != consumer_idx -> [{producer_idx, consumer_idx}]
          _self -> []
        end
      end)
    end)
  end

  defp find_connected_components(n, edges) do
    # Simple Union-Find
    parent = Enum.into(0..(n - 1), %{}, fn i -> {i, i} end)

    parent =
      Enum.reduce(edges, parent, fn {a, b}, parent ->
        root_a = find_root(parent, a)
        root_b = find_root(parent, b)

        if root_a != root_b do
          Map.put(parent, root_a, root_b)
        else
          parent
        end
      end)

    Enum.map(0..(n - 1), fn i -> find_root(parent, i) end)
  end

  defp find_root(parent, i) do
    case Map.get(parent, i) do
      ^i -> i
      p -> find_root(parent, p)
    end
  end
end
