defmodule SymphonyElixir.ProjectManager do
  @moduledoc """
  DynamicSupervisor that manages project supervision trees.

  Each project gets its own `ProjectSupervisor` with isolated processes.
  Projects can be added and removed at runtime.

  ## Startup

  On init, loads projects from application config:

      config :symphony_elixir, :projects, [
        %{id: "partner-middleware", workflow_path: "/path/to/WORKFLOW.md"},
        %{id: "sentry-project", workflow_path: "/path/to/WORKFLOW.md"}
      ]

  Or from environment (single project, backward compatible):

      WORKFLOW_PATH=/path/to/WORKFLOW.md

  ## Runtime management

      ProjectManager.add_project("new-project", "/path/to/WORKFLOW.md")
      ProjectManager.remove_project("new-project")
      ProjectManager.list_projects()
  """

  use DynamicSupervisor
  require Logger

  alias SymphonyElixir.{Project, ProjectSupervisor, ProjectRegistry}

  @doc "Starts the ProjectManager."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts all projects from application config.

  Called after the supervision tree is up. Reads from:
  1. `:projects` config key (list of %{id, workflow_path})
  2. Falls back to single project from WORKFLOW_PATH env var
  """
  @spec start_configured_projects() :: :ok
  def start_configured_projects do
    projects = resolve_configured_projects()

    Enum.each(projects, fn %{id: id, workflow_path: path} ->
      case add_project(id, path) do
        {:ok, _pid} ->
          Logger.info("ProjectManager: started project=#{id}")

        {:error, reason} ->
          Logger.error("ProjectManager: failed to start project=#{id} reason=#{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc "Adds a project and starts its supervision tree."
  @spec add_project(String.t(), Path.t()) :: DynamicSupervisor.on_start_child()
  def add_project(id, workflow_path) when is_binary(id) and is_binary(workflow_path) do
    project = Project.new(id, workflow_path)

    DynamicSupervisor.start_child(__MODULE__, {ProjectSupervisor, project})
  end

  @doc "Removes a project and stops its supervision tree."
  @spec remove_project(String.t()) :: :ok | {:error, :not_found}
  def remove_project(id) when is_binary(id) do
    case ProjectRegistry.whereis(id, :project_supervisor) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "Lists all active project IDs."
  @spec list_projects() :: [String.t()]
  def list_projects do
    ProjectRegistry.list_project_ids()
  end

  # -- Private --

  defp resolve_configured_projects do
    case Application.get_env(:symphony_elixir, :projects) do
      projects when is_list(projects) and projects != [] ->
        Enum.map(projects, &normalize_project_config/1)

      _ ->
        resolve_single_project_fallback()
    end
  end

  defp resolve_single_project_fallback do
    workflow_path =
      Application.get_env(:symphony_elixir, :workflow_file_path) ||
        System.get_env("WORKFLOW_PATH")

    case workflow_path do
      nil ->
        Logger.warning("ProjectManager: no projects configured and no WORKFLOW_PATH set")
        []

      path ->
        id = derive_project_id(path)
        [%{id: id, workflow_path: path}]
    end
  end

  defp normalize_project_config(%{id: id, workflow_path: path}), do: %{id: id, workflow_path: path}

  defp normalize_project_config(config) when is_map(config) do
    %{
      id: Map.get(config, :id) || Map.get(config, "id"),
      workflow_path: Map.get(config, :workflow_path) || Map.get(config, "workflow_path")
    }
  end

  defp derive_project_id(workflow_path) do
    workflow_path
    |> Path.dirname()
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
  end
end
