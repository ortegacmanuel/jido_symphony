defmodule SymphonyElixir.ProjectSupervisor do
  @moduledoc """
  Supervisor for a single project's infrastructure processes.

  Each project gets its own isolated supervision tree:

      ProjectSupervisor ("partner-middleware")
      ├── Task.Supervisor (agent pool)
      ├── WorkflowStore (watches this project's WORKFLOW.md)
      ├── Orchestrator (polls this project's tracker)
      └── ProophboardBridge (optional, if configured)

  All processes register via `SymphonyElixir.ProjectRegistry` under
  `{project_id, :role}` keys. If one project's orchestrator crashes,
  only that project is affected — other projects continue running.
  """

  use Supervisor
  require Logger

  alias SymphonyElixir.{Project, ProjectRegistry}

  @doc "Starts a ProjectSupervisor for the given project."
  @spec start_link(Project.t()) :: Supervisor.on_start()
  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project,
      name: ProjectRegistry.via(project.id, :project_supervisor)
    )
  end

  @impl true
  def init(%Project{id: project_id, workflow_path: workflow_path}) do
    Logger.info("ProjectSupervisor starting: project=#{project_id} workflow=#{workflow_path}")

    children = [
      {Task.Supervisor, name: ProjectRegistry.via(project_id, :task_supervisor)},
      {SymphonyElixir.WorkflowStore,
       project_id: project_id, workflow_path: workflow_path},
      {SymphonyElixir.Orchestrator, project_id: project_id},
      {SymphonyElixir.ProophboardBridge, project_id: project_id},
      {SymphonyElixir.Coordinator.Starter, project_id: project_id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
