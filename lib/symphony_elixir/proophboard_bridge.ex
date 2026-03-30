defmodule SymphonyElixir.ProophboardBridge do
  @moduledoc """
  Bridges prooph board event models to GitHub Issues.

  Polls prooph board for slices with status "planned", classifies them by pattern,
  creates rich GitHub issues for implementable slices, and skips external/documentation-only slices.

  ## Slice Patterns

  Implementable (creates issue):
  - SIMPLE_STATE_CHANGE: UI + Command + Event (our system)
  - WEBHOOK_STATE_CHANGE: Automation + Command + Event (our system), no UI
  - AUTOMATION_STATE_CHANGE: Automation + Command + Event (our system), reads TODO
  - INTERNAL_STATE_VIEW: UI + Information + Event(s) (our system)
  - TODO_STATE_VIEW: Information + Event(s) (our system), no UI — drives a processor
  - DOCUMENTATION_STATE_VIEW: UI + Information + Event(s) (our system), read model update

  Not implementable (skipped):
  - EXTERNAL_STATE_VIEW: Information + Event(s) in external system lane
  - TRANSLATION_EXTERNAL: Command + Event in external system lane

  ## Configuration

  Environment variables:
  - PROOPHBOARD_API_KEY: API key for prooph board
  - PROOPHBOARD_WORKSPACE_ID: workspace to watch
  - PROOPHBOARD_OUR_SYSTEM_LANES: comma-separated list of our system lane labels
  - GITHUB_REPO: target repo for issues (e.g., "owner/repo")
  """

  use GenServer
  require Logger

  @mcp_url "https://flow.prooph-board.com/mcp"
  @default_poll_interval_ms 30_000

  defstruct [
    :api_key,
    :workspace_id,
    :github_repo,
    :our_system_lanes,
    :poll_interval_ms,
    :processed_slices
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    our_lanes =
      Keyword.get_lazy(opts, :our_system_lanes, fn ->
        (System.get_env("PROOPHBOARD_OUR_SYSTEM_LANES") || "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
      end)

    state = %__MODULE__{
      api_key: Keyword.get(opts, :api_key, System.get_env("PROOPHBOARD_API_KEY")),
      workspace_id: Keyword.get(opts, :workspace_id, System.get_env("PROOPHBOARD_WORKSPACE_ID")),
      github_repo: Keyword.get(opts, :github_repo, System.get_env("GITHUB_REPO")),
      our_system_lanes: our_lanes,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      processed_slices: MapSet.new()
    }

    if configured?(state) do
      Logger.info(
        "ProophboardBridge started: workspace=#{state.workspace_id} repo=#{state.github_repo} lanes=#{inspect(state.our_system_lanes)} poll=#{state.poll_interval_ms}ms"
      )

      send(self(), :poll)
      {:ok, state}
    else
      missing =
        []
        |> then(fn acc -> if is_nil(state.api_key), do: ["PROOPHBOARD_API_KEY" | acc], else: acc end)
        |> then(fn acc ->
          if is_nil(state.workspace_id), do: ["PROOPHBOARD_WORKSPACE_ID" | acc], else: acc
        end)
        |> then(fn acc -> if is_nil(state.github_repo), do: ["GITHUB_REPO" | acc], else: acc end)
        |> then(fn acc ->
          if state.our_system_lanes == [], do: ["PROOPHBOARD_OUR_SYSTEM_LANES" | acc], else: acc
        end)

      Logger.warning("ProophboardBridge disabled: missing #{Enum.join(missing, ", ")}")
      {:ok, state}
    end
  end

  @impl true
  def handle_cast(:check_now, state) do
    if configured?(state) do
      {:noreply, poll_for_planned_slices(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      if configured?(state) do
        poll_for_planned_slices(state)
      else
        state
      end

    schedule_poll(state.poll_interval_ms || @default_poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Core logic --

  defp configured?(%{api_key: key, workspace_id: ws, github_repo: repo, our_system_lanes: lanes}) do
    is_binary(key) && is_binary(ws) && is_binary(repo) && is_list(lanes) && lanes != []
  end

  defp poll_for_planned_slices(state) do
    Logger.debug("ProophboardBridge: polling for planned slices...")

    case list_chapters(state) do
      {:ok, chapters} when is_list(chapters) ->
        Enum.reduce(chapters, state, &process_chapter/2)

      {:ok, _unexpected} ->
        Logger.warning("ProophboardBridge: unexpected chapters response")
        state

      {:error, reason} ->
        Logger.error("ProophboardBridge: failed to list chapters: #{inspect(reason)}")
        state
    end
  end

  defp process_chapter(chapter, state) do
    chapter_id = chapter["id"]
    chapter_name = chapter["name"]

    case get_chapter(state, chapter_id) do
      {:ok, full_chapter} when is_map(full_chapter) ->
        slices = full_chapter["slices"] || []
        elements = full_chapter["elements"] || []
        lanes = full_chapter["lanes"] || []

        slices
        |> Enum.filter(&(&1["status"] == "planned"))
        |> Enum.reduce(state, fn slice, acc ->
          process_planned_slice(slice, slices, elements, lanes, chapter_id, chapter_name, acc)
        end)

      {:error, reason} ->
        Logger.error(
          "ProophboardBridge: failed to get chapter '#{chapter_name}': #{inspect(reason)}"
        )

        state
    end
  end

  defp process_planned_slice(slice, all_slices, elements, lanes, chapter_id, chapter_name, state) do
    slice_id = slice["id"]

    if MapSet.member?(state.processed_slices, slice_id) do
      state
    else
      lane_map = build_lane_map(lanes)
      slice_elements = Enum.filter(elements, &(&1["sliceId"] == slice_id))
      pattern = classify_pattern(slice_elements, lane_map, state.our_system_lanes)

      if implementable?(pattern) do
        Logger.info(
          "ProophboardBridge: planned slice '#{slice["label"]}' classified as #{pattern} in '#{chapter_name}'"
        )

        case create_issue_for_slice(
               slice,
               all_slices,
               elements,
               lane_map,
               chapter_id,
               chapter_name,
               pattern,
               state
             ) do
          {:ok, issue_url} ->
            case update_slice_status(state, chapter_id, slice_id, "in-progress") do
              {:ok, _} ->
                Logger.info("ProophboardBridge: slice '#{slice["label"]}' moved to in_progress")

              {:error, reason} ->
                Logger.warning(
                  "ProophboardBridge: could not update slice status: #{inspect(reason)} (issue created: #{issue_url})"
                )
            end

            %{state | processed_slices: MapSet.put(state.processed_slices, slice_id)}

          {:error, reason} ->
            Logger.error(
              "ProophboardBridge: failed to create issue for '#{slice["label"]}': #{inspect(reason)}"
            )

            state
        end
      else
        Logger.info(
          "ProophboardBridge: skipping external slice '#{slice["label"]}' (#{pattern}) in '#{chapter_name}'"
        )

        # Mark as processed so we don't re-evaluate every poll
        %{state | processed_slices: MapSet.put(state.processed_slices, slice_id)}
      end
    end
  end

  # -- Pattern classification --

  defp classify_pattern(slice_elements, lane_map, our_system_lanes) do
    has_command = Enum.any?(slice_elements, &(&1["type"] == "command"))
    has_ui = Enum.any?(slice_elements, &(&1["type"] == "ui"))
    has_automation = Enum.any?(slice_elements, &(&1["type"] == "automation"))
    has_information = Enum.any?(slice_elements, &(&1["type"] == "information"))

    events = Enum.filter(slice_elements, &(&1["type"] == "event"))

    has_event_in_our_system =
      Enum.any?(events, fn e ->
        lane_label = Map.get(lane_map, e["laneId"], %{})[:label] || ""
        lane_in_our_system?(lane_label, our_system_lanes)
      end)

    has_event_in_external_system =
      Enum.any?(events, fn e ->
        lane_label = Map.get(lane_map, e["laneId"], %{})[:label] || ""
        not lane_in_our_system?(lane_label, our_system_lanes)
      end)

    cond do
      # External patterns — skip
      has_command && has_event_in_external_system && !has_event_in_our_system ->
        :translation_external

      !has_command && has_information && has_event_in_external_system && !has_event_in_our_system ->
        :external_state_view

      # State changes — our system
      has_command && has_event_in_our_system && has_ui ->
        :simple_state_change

      has_command && has_event_in_our_system && has_automation ->
        :automation_state_change

      has_command && has_event_in_our_system ->
        :webhook_state_change

      # State views — our system
      has_information && has_event_in_our_system && has_ui ->
        :internal_state_view

      has_information && has_event_in_our_system && !has_ui ->
        :todo_state_view

      has_information && !has_event_in_our_system && !has_command ->
        :external_state_view

      true ->
        :unknown
    end
  end

  defp implementable?(pattern) do
    pattern in [
      :simple_state_change,
      :webhook_state_change,
      :automation_state_change,
      :internal_state_view,
      :todo_state_view
    ]
  end

  defp lane_in_our_system?(lane_label, our_system_lanes) do
    Enum.any?(our_system_lanes, fn our_lane ->
      String.downcase(lane_label) == String.downcase(our_lane)
    end)
  end

  defp build_lane_map(lanes) do
    Map.new(lanes, fn lane ->
      {lane["id"], %{label: lane["label"], type: lane["type"]}}
    end)
  end

  # -- Issue creation --

  defp create_issue_for_slice(
         slice,
         all_slices,
         all_elements,
         lane_map,
         chapter_id,
         chapter_name,
         pattern,
         state
       ) do
    slice_label = slice["label"] || "Unnamed Slice"
    pattern_label = pattern_to_label(pattern)

    title = "#{clean_slice_label(slice_label)} (#{pattern_label})"

    body =
      build_rich_issue_body(
        slice,
        all_slices,
        all_elements,
        lane_map,
        chapter_id,
        chapter_name,
        pattern,
        state
      )

    case run_gh([
           "issue",
           "create",
           "--title",
           title,
           "--body",
           body,
           "--label",
           "Todo",
           "--repo",
           state.github_repo
         ]) do
      {:ok, output} ->
        url = String.trim(output)
        Logger.info("ProophboardBridge: GitHub issue created: #{url}")
        {:ok, url}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_rich_issue_body(
         slice,
         all_slices,
         all_elements,
         lane_map,
         chapter_id,
         chapter_name,
         pattern,
         state
       ) do
    slice_id = slice["id"]
    slice_elements = Enum.filter(all_elements, &(&1["sliceId"] == slice_id))
    grouped = Enum.group_by(slice_elements, & &1["type"])

    sections = [
      "## Event Model Slice",
      "",
      "- **Chapter:** #{chapter_name}",
      "- **Slice:** #{slice["label"]}",
      "- **Pattern:** `#{pattern_to_label(pattern)}`",
      "- **Prooph Board:** workspace=`#{state.workspace_id}` chapter=`#{chapter_id}` slice=`#{slice_id}`",
      ""
    ]

    # Slice details if present
    sections =
      if (slice["details"] || "") != "" do
        sections ++ ["## Slice Details", "", slice["details"], ""]
      else
        sections
      end

    # Elements grouped by type
    sections =
      sections
      |> append_elements("### UI Screen", grouped["ui"], lane_map)
      |> append_elements("### Command", grouped["command"], lane_map)
      |> append_elements("### Event", grouped["event"], lane_map)
      |> append_elements("### Read Model", grouped["information"], lane_map)
      |> append_elements("### Automation / Processor", grouped["automation"], lane_map)

    # Chapter timeline context
    sections = sections ++ build_timeline_context(slice, all_slices, all_elements, lane_map, state)

    # Pattern-specific implementation notes
    sections = sections ++ build_implementation_notes(pattern)

    # Agent instructions
    sections = sections ++ build_agent_instructions(state)

    Enum.join(sections, "\n")
  end

  defp append_elements(sections, _heading, nil, _lane_map), do: sections
  defp append_elements(sections, _heading, [], _lane_map), do: sections

  defp append_elements(sections, heading, elements, lane_map) do
    lines =
      Enum.flat_map(elements, fn elem ->
        lane_info = Map.get(lane_map, elem["laneId"], %{})
        lane_label = lane_info[:label] || ""
        lane_suffix = if lane_label != "", do: " _(#{lane_label})_", else: ""

        header = ["**#{elem["name"]}**#{lane_suffix}", ""]

        desc =
          if (elem["description"] || "") != "" do
            [elem["description"], ""]
          else
            []
          end

        details =
          if (elem["details"] || "") != "" do
            ["```", elem["details"], "```", ""]
          else
            []
          end

        header ++ desc ++ details
      end)

    sections ++ [heading, ""] ++ lines
  end

  defp build_timeline_context(slice, all_slices, all_elements, lane_map, state) do
    slice_index = slice["index"] || 0
    total = length(all_slices)

    before_slices =
      all_slices
      |> Enum.filter(&((&1["index"] || 0) < slice_index))
      |> Enum.sort_by(& &1["index"])
      |> Enum.take(-3)

    after_slices =
      all_slices
      |> Enum.filter(&((&1["index"] || 0) > slice_index))
      |> Enum.sort_by(& &1["index"])
      |> Enum.take(3)

    context = [
      "## Chapter Timeline",
      "",
      "This is step #{slice_index} of #{total - 1} in the **#{slice["label"]}** flow.",
      ""
    ]

    context =
      if before_slices != [] do
        before_lines =
          Enum.map(before_slices, fn s ->
            s_elements = Enum.filter(all_elements, &(&1["sliceId"] == s["id"]))
            s_pattern = classify_pattern(s_elements, lane_map, state.our_system_lanes)
            "- #{s["label"]} (`#{pattern_to_label(s_pattern)}`) — #{s["status"]}"
          end)

        context ++ ["**Before:**"] ++ before_lines ++ [""]
      else
        context
      end

    if after_slices != [] do
      after_lines =
        Enum.map(after_slices, fn s ->
          s_elements = Enum.filter(all_elements, &(&1["sliceId"] == s["id"]))
          s_pattern = classify_pattern(s_elements, lane_map, state.our_system_lanes)
          "- #{s["label"]} (`#{pattern_to_label(s_pattern)}`) — #{s["status"]}"
        end)

      context ++ ["**After:**"] ++ after_lines ++ [""]
    else
      context
    end
  end

  defp build_implementation_notes(pattern) do
    notes =
      case pattern do
        :simple_state_change ->
          """
          UI triggers command, system persists event.

          Create:
          - Command struct (defstruct with fields from Command element)
          - Event struct + FactEvent protocol implementation (to_fact/1 with type, data, tags)
          - Core module with StateChange behaviour (query, initial_state, apply_event, execute)
          - Context module (public API, calls Decide.execute)
          - LiveView or controller for the UI interaction
          - ExUnit tests for core (Given/When/Then)
          """

        :webhook_state_change ->
          """
          External system calls us via webhook/callback, we persist event.

          Create:
          - Command struct
          - Event struct + FactEvent protocol
          - Core module with StateChange behaviour
          - Context module
          - Phoenix controller endpoint to receive the webhook/callback
          - ExUnit tests for core
          """

        :automation_state_change ->
          """
          Processor polls a TODO read model, triggers command, persists event.
          May include inline external API call (translation pattern).

          Create:
          - Command struct
          - Event struct + FactEvent protocol
          - Core module with StateChange behaviour
          - Context module
          - processor.ex (GenServer + Process.send_after + Task.Supervisor)
            - Polls the TODO read model for pending items
            - For each item, spawns async task
            - If external API needed: call inline in the task, then trigger the command
          - ExUnit tests for core
          - Add processor to application.ex supervision tree
          """

        :internal_state_view ->
          """
          Read model projected from events, displayed in UI.

          Create:
          - Core module with StateView behaviour (query, initial_state, apply_event)
          - Context module (reads from Fact DB, folds events into state)
          - LiveView or controller for the UI display
          - ExUnit tests for apply_event projections
          """

        :todo_state_view ->
          """
          Work-queue read model that drives a processor. No UI — consumed by automation.

          Create:
          - Core module with StateView behaviour (query, initial_state, apply_event)
          - Context module with pending/0 function that filters actionable items
          - ExUnit tests for apply_event and pending filter logic
          """

        _ ->
          "Follow existing code patterns in lib/conecta_zen/slices/."
      end

    [
      "## Implementation Notes",
      "",
      String.trim(notes),
      ""
    ]
  end

  defp build_agent_instructions(state) do
    [
      "## Agent Instructions",
      "",
      "You have access to the prooph board event model via MCP for additional context.",
      "Use these tools if you need more details about the chapter, related slices, or element connections:",
      "",
      "- `mcp__proophboard__get_chapter` — workspace_id=`#{state.workspace_id}` to read the full chapter timeline",
      "- `mcp__proophboard__search_elements` — find related elements across chapters",
      "",
      "Follow the event-modeling skill at `.claude/skills/event-modeling/` for implementation patterns.",
      "Follow existing code patterns in `lib/conecta_zen/slices/` for naming and structure conventions.",
      "",
      "---",
      "",
      "_Auto-generated by ProophboardBridge from prooph board event model._"
    ]
  end

  # -- Helpers --

  defp pattern_to_label(:simple_state_change), do: "SIMPLE_STATE_CHANGE"
  defp pattern_to_label(:webhook_state_change), do: "WEBHOOK_STATE_CHANGE"
  defp pattern_to_label(:automation_state_change), do: "AUTOMATION_STATE_CHANGE"
  defp pattern_to_label(:internal_state_view), do: "INTERNAL_STATE_VIEW"
  defp pattern_to_label(:todo_state_view), do: "TODO_STATE_VIEW"
  defp pattern_to_label(:external_state_view), do: "EXTERNAL_STATE_VIEW"
  defp pattern_to_label(:translation_external), do: "TRANSLATION_EXTERNAL"
  defp pattern_to_label(_), do: "UNKNOWN"

  defp clean_slice_label(label) do
    label
    |> String.replace(~r/^slice:\s*/i, "")
    |> String.trim()
  end

  # -- prooph board MCP calls --

  defp list_chapters(state) do
    call_mcp(state, "list_chapters", %{workspace_id: state.workspace_id})
  end

  defp get_chapter(state, chapter_id) do
    call_mcp(state, "get_chapter", %{workspace_id: state.workspace_id, chapter_id: chapter_id})
  end

  defp update_slice_status(state, chapter_id, slice_id, new_status) do
    old_status =
      case get_chapter(state, chapter_id) do
        {:ok, chapter} when is_map(chapter) ->
          chapter
          |> Map.get("slices", [])
          |> Enum.find(fn s -> s["id"] == slice_id end)
          |> case do
            nil -> "draft"
            s -> s["status"] || "draft"
          end

        _ ->
          "draft"
      end

    call_mcp(state, "update_slice_status", %{
      workspace_id: state.workspace_id,
      chapter_id: chapter_id,
      slice_id: slice_id,
      old_status: old_status,
      new_status: new_status
    })
  end

  defp call_mcp(state, tool_name, arguments) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: tool_name, arguments: arguments}
      })

    case Req.post(@mcp_url,
           body: body,
           headers: [
             {"authorization", "Bearer #{state.api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"result" => %{"content" => [%{"text" => text} | _]}}}} ->
        Jason.decode(text)

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- GitHub CLI --

  defp run_gh(args) do
    case System.find_executable("gh") do
      nil ->
        {:error, :gh_not_installed}

      gh_path ->
        case System.cmd(gh_path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
