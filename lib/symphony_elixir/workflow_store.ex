defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.

  In multi-project mode, each project gets its own WorkflowStore registered
  via `ProjectRegistry` under `{project_id, :workflow_store}`.

  ## Starting

  Per-project (via ProjectSupervisor):

      {SymphonyElixir.WorkflowStore, project_id: "partner-middleware", workflow_path: "/path/to/WORKFLOW.md"}

  Legacy single-project (backward compatible):

      SymphonyElixir.WorkflowStore
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{ProjectRegistry, Workflow}

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:project_id, :path, :stamp, :workflow]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    name =
      if project_id do
        ProjectRegistry.via(project_id, :workflow_store)
      else
        __MODULE__
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current workflow. Looks up by project_id if given,
  falls back to the global singleton for backward compatibility.
  """
  @spec current(String.t() | nil) :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current(project_id \\ nil) do
    server = resolve_server(project_id)

    case server do
      nil -> Workflow.load()
      pid -> GenServer.call(pid, :current)
    end
  end

  @doc "Force reload of the workflow file."
  @spec force_reload(String.t() | nil) :: :ok | {:error, term()}
  def force_reload(project_id \\ nil) do
    server = resolve_server(project_id)

    case server do
      nil ->
        case Workflow.load() do
          {:ok, _workflow} -> :ok
          {:error, reason} -> {:error, reason}
        end

      pid ->
        GenServer.call(pid, :force_reload)
    end
  end

  @impl true
  def init(opts) do
    project_id = Keyword.get(opts, :project_id)

    workflow_path =
      Keyword.get(opts, :workflow_path) || Workflow.workflow_file_path()

    case load_state(project_id, workflow_path) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{path: current_path} = state) do
    reload_current_path(current_path, state)
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, state.project_id, reason)
        {:error, reason, state}
    end
  end

  defp reload_path(path, state) do
    case load_state(state.project_id, path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, state.project_id, reason)
        {:error, reason, state}
    end
  end

  defp load_state(project_id, path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{project_id: project_id, path: path, stamp: stamp, workflow: workflow}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_server(nil) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp resolve_server(project_id) do
    ProjectRegistry.whereis(project_id, :workflow_store)
  end

  defp log_reload_error(path, nil, reason) do
    Logger.error(
      "Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration"
    )
  end

  defp log_reload_error(path, project_id, reason) do
    Logger.error(
      "Failed to reload workflow project=#{project_id} path=#{path} reason=#{inspect(reason)}; keeping last known good configuration"
    )
  end
end
