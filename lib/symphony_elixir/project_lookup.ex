defmodule SymphonyElixir.ProjectLookup do
  @moduledoc """
  Shared helpers for resolving per-project processes.

  Used by dashboard, API, and terminal UI to find the right
  orchestrator for a given project (or the first active project).
  """

  alias SymphonyElixir.{ProjectManager, ProjectRegistry}

  @doc "Returns the orchestrator pid for a project, or the first active project, or nil."
  @spec orchestrator(String.t() | nil) :: pid() | atom() | nil
  def orchestrator(nil), do: orchestrator(default_project_id())
  def orchestrator(project_id) when is_binary(project_id) do
    ProjectRegistry.whereis(project_id, :orchestrator)
  end

  @doc "Returns the first active project ID, or nil."
  @spec default_project_id() :: String.t() | nil
  def default_project_id do
    case ProjectManager.list_projects() do
      [first | _] -> first
      [] -> nil
    end
  end

  @doc "Returns all active project IDs."
  @spec project_ids() :: [String.t()]
  def project_ids do
    ProjectManager.list_projects()
  end
end
