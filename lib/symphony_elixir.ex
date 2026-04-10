defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint.

  Starts shared infrastructure (PubSub, Jido, ProjectRegistry, Dashboard),
  then the ProjectManager which loads per-project supervision trees.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = SymphonyElixir.AgentEventStore.init()

    children = [
      # Shared infrastructure
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      SymphonyElixir.ProjectRegistry,
      SymphonyElixir.Jido,

      # Project management (loads per-project supervisors from config)
      SymphonyElixir.ProjectManager,

      # Web + observability (shared across all projects)
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    opts = [strategy: :one_for_one, name: SymphonyElixir.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Start configured projects after supervision tree is up
        SymphonyElixir.ProjectManager.start_configured_projects()
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
