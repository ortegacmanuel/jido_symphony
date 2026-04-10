defmodule SymphonyElixir.Coordinator.Actions.ClassifySlicePattern do
  @moduledoc """
  Classifies event model slice issues by their pattern.

  Reads structured metadata from slice issues (populated by FetchOpenIssues)
  and classifies each into one of the specialization patterns.

  ## Classification Schemes

  **`:crud_domain_events`** (Partner Middleware):
  - `sc_internal` — State Change on Hub database (Command → Entity → Event)
  - `sc_external` — State Change on external API (ProcessManager → HTTP)
  - `sv_internal` — State View of Hub database (Query → Entity → DTO)
  - `sv_external` — State View of external API (Query → ReadModel via ACL)
  - `compound` — Translation pattern (SV→External + SC→Internal)

  **`:event_sourcing`** (ConectaZen):
  - `simple_state_change` — UI + Command + Event
  - `webhook_state_change` — Command + Event (no UI)
  - `automation_state_change` — Automation + Command + Event
  - `internal_state_view` — UI + Information + Event
  - `todo_state_view` — Information + Event (no UI)

  ## State consumed

  - `:slice_issues` — from FetchOpenIssues

  ## State produced

  - `:classified_slices` — list of `%{issue: issue, metadata: map, pattern: atom, produces: list, consumes: list}`
  """

  use Jido.Action,
    name: "classify_slice_pattern",
    description: "Classifies event model slice issues by pattern",
    schema: [
      scheme: [type: :atom, default: :crud_domain_events]
    ]

  alias SymphonyElixir.Coordinator.Actions.FetchOpenIssues

  @impl true
  def run(params, context) do
    slice_issues = context.state[:slice_issues] || []
    scheme = params.scheme || :crud_domain_events

    classified =
      Enum.flat_map(slice_issues, fn issue ->
        case FetchOpenIssues.extract_structured_metadata(issue["body"]) do
          {:ok, metadata} ->
            pattern = classify(metadata, scheme)
            produces = extract_produces(metadata)
            consumes = extract_consumes(metadata)

            [
              %{
                issue: issue,
                metadata: metadata,
                pattern: pattern,
                produces: produces,
                consumes: consumes
              }
            ]

          :none ->
            []
        end
      end)

    {:ok, %{classified_slices: classified}}
  end

  defp classify(metadata, :crud_domain_events) do
    elements = metadata["elements"] || []
    slice_type = metadata["slice_type"]

    has_command = Enum.any?(elements, &(&1["type"] == "command"))
    has_information = Enum.any?(elements, &(&1["type"] == "information"))
    has_automation = Enum.any?(elements, &(&1["type"] == "automation"))

    cond do
      slice_type == "STATE_CHANGE" && has_command && has_automation ->
        :sc_external

      slice_type == "STATE_CHANGE" && has_command ->
        :sc_internal

      slice_type == "STATE_VIEW" && has_information && has_automation ->
        :sv_external

      slice_type == "STATE_VIEW" && has_information ->
        :sv_internal

      has_command && has_information ->
        :compound

      true ->
        :unknown
    end
  end

  defp classify(metadata, :event_sourcing) do
    elements = metadata["elements"] || []

    has_command = Enum.any?(elements, &(&1["type"] == "command"))
    has_ui = Enum.any?(elements, &(&1["type"] == "ui"))
    has_automation = Enum.any?(elements, &(&1["type"] == "automation"))
    has_information = Enum.any?(elements, &(&1["type"] == "information"))
    has_event = Enum.any?(elements, &(&1["type"] == "event"))

    cond do
      has_command && has_event && has_ui -> :simple_state_change
      has_command && has_event && has_automation -> :automation_state_change
      has_command && has_event -> :webhook_state_change
      has_information && has_event && has_ui -> :internal_state_view
      has_information && has_event && !has_ui -> :todo_state_view
      true -> :unknown
    end
  end

  defp extract_produces(metadata) do
    elements = metadata["elements"] || []

    elements
    |> Enum.filter(&(&1["type"] in ["command", "information"]))
    |> Enum.map(fn el ->
      %{type: el["type"], name: el["name"]}
    end)
  end

  defp extract_consumes(metadata) do
    # Consumes are harder to determine from metadata alone.
    # For now, we extract from a "consumes" field if present,
    # or infer from the chapter timeline (items referenced in "before").
    case metadata["consumes"] do
      consumes when is_list(consumes) ->
        Enum.map(consumes, fn c ->
          %{type: c["type"] || "unknown", name: c["name"]}
        end)

      _ ->
        []
    end
  end
end
