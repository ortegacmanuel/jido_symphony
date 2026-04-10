defmodule SymphonyElixir.Coordinator.Starter do
  @moduledoc """
  Starts and manages the CoordinatorAgent for a project.

  This is a simple GenServer that:
  1. On init, starts a CoordinatorAgent via the Jido runtime
  2. Schedules periodic poll signals to the coordinator
  3. Stops the coordinator agent on termination

  Lives in the ProjectSupervisor alongside WorkflowStore and Orchestrator.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Coordinator

  @default_poll_interval_ms 30_000
  @default_review_poll_interval_ms 60_000

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
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    agent_id = "coordinator-#{project_id}"

    case start_coordinator_agent(agent_id, project_id) do
      {:ok, agent_pid} ->
        Logger.info("Coordinator.Starter[#{project_id}]: agent started pid=#{inspect(agent_pid)}")
        review_interval = Keyword.get(opts, :review_poll_interval_ms, @default_review_poll_interval_ms)
        schedule_poll(poll_interval)
        schedule_review_poll(review_interval)

        {:ok,
         %{
           project_id: project_id,
           agent_id: agent_id,
           agent_pid: agent_pid,
           poll_interval_ms: poll_interval,
           review_poll_interval_ms: review_interval
         }}

      {:error, reason} ->
        Logger.error(
          "Coordinator.Starter[#{project_id}]: failed to start agent: #{inspect(reason)}"
        )

        # Don't crash the supervisor — start without coordinator
        # It can be retried later
        {:ok,
         %{
           project_id: project_id,
           agent_id: agent_id,
           agent_pid: nil,
           poll_interval_ms: poll_interval
         }}
    end
  end

  @impl true
  def handle_info(:poll, %{agent_pid: nil} = state) do
    # Agent not started, try again
    case start_coordinator_agent(state.agent_id, state.project_id) do
      {:ok, pid} ->
        Logger.info("Coordinator.Starter[#{state.project_id}]: agent recovered pid=#{inspect(pid)}")
        send_poll_signal(pid)
        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | agent_pid: pid}}

      {:error, _} ->
        schedule_poll(state.poll_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{agent_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      send_poll_signal(pid)
    else
      Logger.warning("Coordinator.Starter[#{state.project_id}]: agent pid dead, clearing")
      state = %{state | agent_pid: nil}
      send(self(), :poll)
      {:noreply, state}
      |> then(fn _ -> nil end)
    end

    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:review_poll, %{agent_pid: nil} = state) do
    # Agent not started, skip review poll
    schedule_review_poll(state.review_poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:review_poll, %{agent_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      send_review_poll_signal(pid)
    end

    schedule_review_poll(state.review_poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{agent_pid: pid, agent_id: agent_id}) when is_pid(pid) do
    Logger.info("Coordinator.Starter: stopping agent #{agent_id}")

    try do
      SymphonyElixir.Jido.stop_agent(agent_id)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_coordinator_agent(agent_id, project_id) do
    SymphonyElixir.Jido.start_agent(
      Coordinator.Agent,
      id: agent_id,
      initial_state: %{project_id: project_id}
    )
  end

  defp send_poll_signal(agent_pid) do
    {:ok, signal} =
      Jido.Signal.new(
        "coordinator.poll",
        %{},
        source: "/coordinator/starter"
      )

    Jido.AgentServer.cast(agent_pid, signal)
  end

  defp send_review_poll_signal(agent_pid) do
    {:ok, signal} =
      Jido.Signal.new(
        "coordinator.review_poll",
        %{},
        source: "/coordinator/starter"
      )

    Jido.AgentServer.cast(agent_pid, signal)
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_review_poll(interval_ms) do
    Process.send_after(self(), :review_poll, interval_ms)
  end
end
