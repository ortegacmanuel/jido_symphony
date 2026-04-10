defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  Registry for project-scoped infrastructure process lookup.

  Each project's non-agent processes register under composite keys:

      {project_id, :orchestrator}
      {project_id, :workflow_store}
      {project_id, :proophboard_bridge}
      {project_id, :task_supervisor}

  Agent processes (CoordinatorAgent, etc.) are managed by `SymphonyElixir.Jido`
  via Jido's built-in registry.

  ## Example

      SymphonyElixir.ProjectRegistry.whereis("partner-middleware", :orchestrator)
      #=> pid | nil
  """

  @registry_name __MODULE__

  @type project_id :: String.t()
  @type role ::
          :project_supervisor
          | :orchestrator
          | :workflow_store
          | :proophboard_bridge
          | :task_supervisor
          | :coordinator_starter

  @doc "Child spec for the supervision tree."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Registry, :start_link, [[keys: :unique, name: @registry_name]]},
      type: :supervisor
    }
  end

  @doc "Returns the via-tuple for registering a project-scoped process."
  @spec via(project_id(), role()) :: {:via, Registry, {atom(), {project_id(), role()}}}
  def via(project_id, role) do
    {:via, Registry, {@registry_name, {project_id, role}}}
  end

  @doc "Looks up the pid for a project-scoped process. Returns nil if not found."
  @spec whereis(project_id(), role()) :: pid() | nil
  def whereis(project_id, role) do
    case Registry.lookup(@registry_name, {project_id, role}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Returns all registered project IDs."
  @spec list_project_ids() :: [project_id()]
  def list_project_ids do
    Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
    |> Enum.map(fn {project_id, _role} -> project_id end)
    |> Enum.uniq()
  end
end
