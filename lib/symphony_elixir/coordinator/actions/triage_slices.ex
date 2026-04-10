defmodule SymphonyElixir.Coordinator.Actions.TriageSlices do
  @moduledoc """
  LLM-assisted triage of event model slices into delivery units.

  Replaces the deterministic ClassifySlicePattern + IdentifyDeliveryUnits
  with a single LLM call that understands the PROJECT'S architecture.

  ## What the LLM receives

  1. All open slice issues with their element metadata
  2. Chapter context (how many slices total, which are planned, timeline)
  3. Project architecture context (from WORKFLOW.md prompt template)

  ## What the LLM decides

  1. What each slice PRODUCES and CONSUMES (dependency edges)
  2. Which slices should be grouped into delivery units
  3. Whether each DU is independently implementable NOW
  4. Whether more slices are needed before dispatching

  ## Caching

  Results are cached per chapter. Re-triaged only when new slices appear
  (detected by comparing issue numbers against last triage).

  ## State consumed

  - `:slice_issues` — from FetchOpenIssues
  - `:project_id` — for WORKFLOW.md context

  ## State produced

  - `:delivery_units` — map of DU id → %{slices, depends_on, status, rationale}
  - `:triage_cache_key` — hash of slice issue numbers (for cache invalidation)
  - `:slices_waiting` — slices not yet ready (waiting for more to arrive)
  """

  use Jido.Action,
    name: "triage_slices",
    description: "LLM-assisted triage of event model slices into delivery units",
    schema: []

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-20250514"

  @impl true
  def run(_params, context) do
    slice_issues = context.state[:slice_issues] || []
    project_id = context.state[:project_id]

    if slice_issues == [] do
      {:ok, %{delivery_units: %{}, slices_waiting: []}}
    else
      # Check cache — skip LLM if slices haven't changed
      current_cache_key = cache_key(slice_issues)
      previous_cache_key = context.state[:triage_cache_key]

      if current_cache_key == previous_cache_key && context.state[:delivery_units] != %{} do
        Logger.debug("Coordinator[#{project_id}]: slice triage cache hit, skipping LLM")
        {:ok, %{}}
      else
        case triage_via_llm(slice_issues, project_id) do
          {:ok, result} ->
            Logger.info(
              "Coordinator[#{project_id}]: triaged #{length(slice_issues)} slices → " <>
                "#{map_size(result.delivery_units)} DUs, #{length(result.slices_waiting)} waiting"
            )

            {:ok, Map.put(result, :triage_cache_key, current_cache_key)}

          {:error, reason} ->
            Logger.error("Coordinator[#{project_id}]: triage failed: #{inspect(reason)}")
            {:ok, %{delivery_units: %{}, slices_waiting: []}}
        end
      end
    end
  end

  defp triage_via_llm(slice_issues, project_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      project_context = load_project_context(project_id)
      slices_description = build_slices_description(slice_issues)

      prompt = """
      You are a technical coordinator for the project "#{project_id}".

      ## Project Architecture
      #{project_context}

      ## Open Event Model Slices
      #{slices_description}

      ## Your Task

      Analyze these slices and determine:

      1. **Dependencies**: For each slice, what does it PRODUCE (command handlers, query handlers, entities, repositories) and what does it CONSUME from other slices?

      2. **Delivery Units**: Group tightly-coupled slices into delivery units. A delivery unit is a set of slices that MUST be in the same PR because they share compile-time dependencies (one imports classes from another).

      3. **Implementability**: For each delivery unit, can it be implemented RIGHT NOW independently? Or does it depend on:
         - Another DU that hasn't been dispatched yet → mark as blocked
         - Slices that haven't been planned yet → mark as waiting
         - Nothing (all dependencies exist in main) → mark as ready

      4. **Standalone slices**: Slices with no cross-slice dependencies can be their own DU.

      Return ONLY this JSON:
      {
        "delivery_units": [
          {
            "id": "DU1",
            "name": "descriptive capability name",
            "issue_numbers": [101, 102],
            "rationale": "why these are grouped",
            "status": "ready|blocked|waiting",
            "depends_on_dus": [],
            "depends_on_unplanned": [],
            "produces": ["HandlerX", "EntityY"],
            "consumes": ["HandlerZ from DU2"]
          }
        ],
        "slices_waiting": [103],
        "reasoning": "overall assessment"
      }
      """

      body =
        Jason.encode!(%{
          model: @model,
          max_tokens: 4096,
          messages: [%{role: "user", content: prompt}],
          system:
            "You are a senior software architect. Analyze slice dependencies precisely. " <>
              "Return only valid JSON, no markdown fences, no explanation outside the JSON."
        })

      case Req.post(@anthropic_url,
             body: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          parse_triage_response(text, slice_issues)

        {:ok, %{status: status, body: error_body}} ->
          {:error, {:api_error, status, error_body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp parse_triage_response(text, slice_issues) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*\n?/, "")
      |> String.replace(~r/\n?```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"delivery_units" => dus}} when is_list(dus) ->
        # Build issue lookup
        issue_map = Map.new(slice_issues, fn i -> {i["number"], i} end)

        units =
          Map.new(dus, fn du ->
            id = du["id"]
            issue_numbers = du["issue_numbers"] || []

            slices =
              Enum.flat_map(issue_numbers, fn num ->
                case Map.get(issue_map, num) do
                  nil -> []
                  issue -> [issue]
                end
              end)

            status =
              case du["status"] do
                "ready" -> :ready
                "blocked" -> :blocked
                "waiting" -> :waiting
                _ -> :pending
              end

            {id,
             %{
               id: id,
               name: du["name"],
               slices: slices,
               issue_numbers: issue_numbers,
               rationale: du["rationale"],
               status: status,
               depends_on: du["depends_on_dus"] || [],
               depends_on_unplanned: du["depends_on_unplanned"] || [],
               produces: du["produces"] || [],
               consumes: du["consumes"] || [],
               patterns: []
             }}
          end)

        waiting = Map.get(Jason.decode!(cleaned), "slices_waiting", [])

        {:ok, %{delivery_units: units, slices_waiting: waiting}}

      {:ok, _} ->
        {:error, :unexpected_json_shape}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp build_slices_description(slice_issues) do
    Enum.map_join(slice_issues, "\n\n", fn issue ->
      metadata = extract_metadata(issue["body"])
      elements_desc = format_elements(metadata)
      timeline_desc = format_timeline(metadata)

      """
      ### Issue ##{issue["number"]}: #{issue["title"]}
      #{elements_desc}
      #{timeline_desc}
      """
    end)
  end

  defp extract_metadata(nil), do: %{}

  defp extract_metadata(body) do
    case Regex.run(~r/```json\s*\n(.*?)\n\s*```/s, body) do
      [_match, json_str] ->
        case Jason.decode(json_str) do
          {:ok, %{"source" => "proophboard"} = m} -> m
          _ -> %{}
        end

      nil ->
        %{}
    end
  end

  defp format_elements(%{"elements" => elements}) when is_list(elements) do
    elements
    |> Enum.map(fn e -> "- #{e["type"]}: #{e["name"]} (#{e["lane"] || "unknown lane"})" end)
    |> Enum.join("\n")
  end

  defp format_elements(_), do: "No element metadata available."

  defp format_timeline(%{"chapter_timeline" => t}) when is_map(t) do
    "Timeline: position #{t["position"]} of #{t["total"]}. Before: #{inspect(t["before"])}. After: #{inspect(t["after"])}."
  end

  defp format_timeline(_), do: ""

  defp load_project_context(project_id) do
    case SymphonyElixir.Config.current_workflow(project_id) do
      {:ok, %{prompt_template: prompt}} when is_binary(prompt) and prompt != "" ->
        # Extract the architecture/tech stack section from the prompt template
        prompt |> String.slice(0, 2000)

      _ ->
        "No project architecture context available."
    end
  end

  defp cache_key(slice_issues) do
    slice_issues
    |> Enum.map(fn i -> i["number"] end)
    |> Enum.sort()
    |> :erlang.phash2()
  end
end
