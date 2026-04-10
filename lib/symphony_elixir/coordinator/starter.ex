defmodule SymphonyElixir.Coordinator.Starter do
  @moduledoc """
  Starts and manages three Jido Agents per project:

  1. **CoordinatorAgent** — triages issues, groups DUs, dispatches work (every 30s)
  2. **ReviewAgent** — monitors PR reviews, dispatches fix agents (every 60s)
  3. **FeedbackAgent** — analyzes review history, proposes guidance updates (every 6h)

  Each agent is an independent Jido AgentServer process. If one crashes,
  the others continue. The Starter monitors all three and restarts any
  that die.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Coordinator

  @default_poll_interval_ms 30_000
  @default_review_poll_interval_ms 60_000
  @default_feedback_poll_interval_ms 6 * 60 * 60 * 1_000

  defmodule AgentRef do
    @moduledoc false
    defstruct [:id, :module, :pid, :signal_type, :interval_ms]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    GenServer.start_link(__MODULE__, opts,
      name: SymphonyElixir.ProjectRegistry.via(project_id, :coordinator_starter)
    )
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    agents = [
      %AgentRef{
        id: "coordinator-#{project_id}",
        module: Coordinator.Agent,
        signal_type: "coordinator.poll",
        interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
      },
      %AgentRef{
        id: "review-#{project_id}",
        module: Coordinator.ReviewAgent,
        signal_type: "review.poll",
        interval_ms: Keyword.get(opts, :review_poll_interval_ms, @default_review_poll_interval_ms)
      },
      %AgentRef{
        id: "feedback-#{project_id}",
        module: Coordinator.FeedbackAgent,
        signal_type: "feedback.poll",
        interval_ms: Keyword.get(opts, :feedback_poll_interval_ms, @default_feedback_poll_interval_ms)
      }
    ]

    # Start each agent and schedule its poll
    started_agents =
      Enum.map(agents, fn ref ->
        case start_agent(ref, project_id) do
          {:ok, pid} ->
            schedule_poll(ref.id, ref.interval_ms)
            Logger.info("Coordinator.Starter[#{project_id}]: #{ref.id} started pid=#{inspect(pid)}")
            %{ref | pid: pid}

          {:error, reason} ->
            Logger.error("Coordinator.Starter[#{project_id}]: #{ref.id} failed: #{inspect(reason)}")
            schedule_poll(ref.id, ref.interval_ms)
            ref
        end
      end)

    {:ok, %{project_id: project_id, agents: started_agents}}
  end

  @impl true
  def handle_info({:poll, agent_id}, state) do
    agent_ref = find_agent(state.agents, agent_id)

    if agent_ref do
      agent_ref = maybe_recover_agent(agent_ref, state.project_id)

      if agent_ref.pid && Process.alive?(agent_ref.pid) do
        send_signal(agent_ref.pid, agent_ref.signal_type)
      end

      schedule_poll(agent_ref.id, agent_ref.interval_ms)
      {:noreply, update_agent(state, agent_ref)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.agents, fn ref ->
      if ref.pid do
        Logger.info("Coordinator.Starter: stopping #{ref.id}")

        try do
          SymphonyElixir.Jido.stop_agent(ref.id)
        rescue
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # -- Private --

  defp start_agent(%AgentRef{id: id, module: module}, project_id) do
    SymphonyElixir.Jido.start_agent(
      module,
      id: id,
      initial_state: %{project_id: project_id}
    )
  end

  defp maybe_recover_agent(%AgentRef{pid: nil} = ref, project_id) do
    case start_agent(ref, project_id) do
      {:ok, pid} ->
        Logger.info("Coordinator.Starter[#{project_id}]: #{ref.id} recovered pid=#{inspect(pid)}")
        %{ref | pid: pid}

      {:error, _} ->
        ref
    end
  end

  defp maybe_recover_agent(%AgentRef{pid: pid} = ref, project_id) do
    if Process.alive?(pid) do
      ref
    else
      Logger.warning("Coordinator.Starter[#{project_id}]: #{ref.id} pid dead, recovering")
      maybe_recover_agent(%{ref | pid: nil}, project_id)
    end
  end

  defp send_signal(pid, signal_type) do
    {:ok, signal} =
      Jido.Signal.new(
        signal_type,
        %{},
        source: "/coordinator/starter"
      )

    Jido.AgentServer.cast(pid, signal)
  end

  defp schedule_poll(agent_id, interval_ms) do
    Process.send_after(self(), {:poll, agent_id}, interval_ms)
  end

  defp find_agent(agents, agent_id) do
    Enum.find(agents, fn ref -> ref.id == agent_id end)
  end

  defp update_agent(state, updated_ref) do
    agents =
      Enum.map(state.agents, fn ref ->
        if ref.id == updated_ref.id, do: updated_ref, else: ref
      end)

    %{state | agents: agents}
  end
end
