defmodule SymphonyElixir.ProophboardBridge do
  @moduledoc """
  Simple translator: prooph board planned slices → GitHub Issues with structured metadata.

  Polls prooph board for slices with status "planned". For each slice in our system lanes,
  creates a GitHub Issue with human-readable element listing AND a machine-readable JSON
  metadata block. The CoordinatorAgent handles classification, grouping, and dispatch.

  ## What this module does

  1. Poll prooph board for planned slices
  2. Filter: skip slices with all events in external lanes
  3. Create GitHub Issue with structured JSON metadata + element listing
  4. Update slice status to "in-progress"
  5. Label issue as `event-model-slice` + `Todo`

  ## What this module does NOT do (moved to CoordinatorAgent)

  - Pattern classification (SC→Internal, SV→External, etc.)
  - Implementation notes generation
  - Delivery unit grouping
  - Agent-specific instructions

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
    :project_id,
    :api_key,
    :workspace_id,
    :github_repo,
    :our_system_lanes,
    :poll_interval_ms,
    :processed_slices
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    name =
      if project_id do
        SymphonyElixir.ProjectRegistry.via(project_id, :proophboard_bridge)
      else
        __MODULE__
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  def check_now(project_id) do
    case SymphonyElixir.ProjectRegistry.whereis(project_id, :proophboard_bridge) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, :check_now)
    end
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
      project_id: Keyword.get(opts, :project_id),
      api_key: Keyword.get(opts, :api_key, System.get_env("PROOPHBOARD_API_KEY")),
      workspace_id: Keyword.get(opts, :workspace_id, System.get_env("PROOPHBOARD_WORKSPACE_ID")),
      github_repo: Keyword.get(opts, :github_repo, System.get_env("GITHUB_REPO")),
      our_system_lanes: our_lanes,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      processed_slices: MapSet.new()
    }

    if configured?(state) do
      Logger.info(
        "ProophboardBridge started: project=#{state.project_id} workspace=#{state.workspace_id} repo=#{state.github_repo}"
      )

      send(self(), :poll)
      {:ok, state}
    else
      Logger.warning("ProophboardBridge disabled: missing configuration")
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
    case list_chapters(state) do
      {:ok, chapters} when is_list(chapters) ->
        Enum.reduce(chapters, state, &process_chapter/2)

      {:ok, _} ->
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
        Logger.error("ProophboardBridge: failed to get chapter '#{chapter_name}': #{inspect(reason)}")
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

      if has_our_system_elements?(slice_elements, lane_map, state.our_system_lanes) do
        case create_issue(slice, all_slices, slice_elements, lane_map, chapter_id, chapter_name, state) do
          {:ok, _url} ->
            update_slice_status(state, chapter_id, slice_id, "in-progress")
            %{state | processed_slices: MapSet.put(state.processed_slices, slice_id)}

          {:error, reason} ->
            Logger.error("ProophboardBridge: issue creation failed for '#{slice["label"]}': #{inspect(reason)}")
            state
        end
      else
        # External slice — mark processed, don't create issue
        %{state | processed_slices: MapSet.put(state.processed_slices, slice_id)}
      end
    end
  end

  # -- Filtering --

  defp has_our_system_elements?(slice_elements, lane_map, our_system_lanes) do
    Enum.any?(slice_elements, fn el ->
      lane_label = get_in(lane_map, [el["laneId"], :label]) || ""
      lane_in_our_system?(lane_label, our_system_lanes)
    end)
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

  # -- Issue creation (dumb translator with structured metadata) --

  defp create_issue(slice, all_slices, slice_elements, lane_map, chapter_id, chapter_name, state) do
    slice_label = slice["label"] || "Unnamed Slice"
    slice_type = infer_slice_type(slice_elements)
    title = "#{clean_label(slice_label)} (#{slice_type})"

    body = build_issue_body(slice, all_slices, slice_elements, lane_map, chapter_id, chapter_name, state)

    run_gh([
      "issue", "create",
      "--title", title,
      "--body", body,
      "--label", "Todo,event-model-slice",
      "--repo", state.github_repo
    ])
  end

  defp build_issue_body(slice, all_slices, slice_elements, lane_map, chapter_id, chapter_name, state) do
    slice_id = slice["id"]
    grouped = Enum.group_by(slice_elements, & &1["type"])
    slice_type = infer_slice_type(slice_elements)
    timeline = build_timeline(slice, all_slices)

    # Human-readable section
    human = [
      "## Event Model Slice",
      "",
      "- **Chapter:** #{chapter_name}",
      "- **Slice:** #{slice["label"]}",
      "- **Type:** #{slice_type}",
      ""
    ]

    human =
      if (slice["details"] || "") != "" do
        human ++ ["## Slice Details", "", slice["details"], ""]
      else
        human
      end

    human =
      human
      |> append_elements("### Command", grouped["command"], lane_map)
      |> append_elements("### Event", grouped["event"], lane_map)
      |> append_elements("### Read Model", grouped["information"], lane_map)
      |> append_elements("### UI Screen", grouped["ui"], lane_map)
      |> append_elements("### Automation", grouped["automation"], lane_map)

    # Machine-readable structured metadata (for CoordinatorAgent)
    metadata = %{
      source: "proophboard",
      workspace_id: state.workspace_id,
      chapter_id: chapter_id,
      chapter_name: chapter_name,
      slice_id: slice_id,
      slice_type: slice_type,
      elements:
        Enum.map(slice_elements, fn el ->
          lane_info = Map.get(lane_map, el["laneId"], %{})

          %{
            type: el["type"],
            name: el["name"],
            lane: lane_info[:label],
            lane_id: el["laneId"],
            description: el["description"],
            details: el["details"]
          }
        end),
      chapter_timeline: timeline
    }

    metadata_json = Jason.encode!(metadata, pretty: true)

    footer = [
      "## Structured Metadata",
      "",
      "```json",
      metadata_json,
      "```",
      "",
      "---",
      "_Auto-generated by ProophboardBridge._"
    ]

    Enum.join(human ++ footer, "\n")
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

        header ++ desc
      end)

    sections ++ [heading, ""] ++ lines
  end

  defp build_timeline(slice, all_slices) do
    index = slice["index"] || 0
    total = length(all_slices)

    before =
      all_slices
      |> Enum.filter(&((&1["index"] || 0) < index))
      |> Enum.sort_by(& &1["index"])
      |> Enum.take(-3)
      |> Enum.map(& &1["label"])

    after_slices =
      all_slices
      |> Enum.filter(&((&1["index"] || 0) > index))
      |> Enum.sort_by(& &1["index"])
      |> Enum.take(3)
      |> Enum.map(& &1["label"])

    %{
      position: index,
      total: total,
      before: before,
      after: after_slices
    }
  end

  defp infer_slice_type(elements) do
    has_command = Enum.any?(elements, &(&1["type"] == "command"))
    has_information = Enum.any?(elements, &(&1["type"] == "information"))

    cond do
      has_command -> "STATE_CHANGE"
      has_information -> "STATE_VIEW"
      true -> "UNKNOWN"
    end
  end

  defp clean_label(label) do
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
          {output, 0} -> {:ok, String.trim(output)}
          {output, code} -> {:error, {:gh_exit, code, String.slice(output, 0, 500)}}
        end
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
