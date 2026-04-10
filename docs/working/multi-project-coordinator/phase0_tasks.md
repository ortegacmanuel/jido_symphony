# Tasks: Phase 0 — Multi-Project Support

**Branch:** `refactor/multi-project-coordinator`

## Implementation Order

### 1. New modules (no existing code changes)
- [ ] `ProjectRegistry` — Registry for `{project_id, role}` process lookup
- [ ] `Project` — Struct holding project config (id, workflow_path, status)
- [ ] `ProjectSupervisor` — Supervisor per project (WorkflowStore, Orchestrator, Bridge, TaskSupervisor)
- [ ] `ProjectManager` — DynamicSupervisor managing ProjectSupervisors

### 2. Refactor WorkflowStore to be project-scoped
- [ ] Accept `project_id` in opts
- [ ] Register via ProjectRegistry instead of global name
- [ ] Keep backward compat: default project if no project_id given

### 3. Refactor Config to support project-scoped access
- [ ] Add `Config.for_project(project_id)` that looks up project's WorkflowStore via Registry
- [ ] Existing global `Config.*` calls continue to work (use default project)

### 4. Refactor Orchestrator to be project-scoped
- [ ] Accept `project_id` in opts
- [ ] Register via ProjectRegistry
- [ ] Use project-scoped Config
- [ ] Pass project_id through to AgentRunner, Workspace, Tracker

### 5. Refactor ProophboardBridge to be project-scoped
- [ ] Accept `project_id` in opts
- [ ] Register via ProjectRegistry
- [ ] Optional (only started if configured in WORKFLOW.md)

### 6. Update Application supervision tree
- [ ] Start ProjectRegistry + ProjectManager as shared infrastructure
- [ ] Load projects from config (runtime.exs or env vars)
- [ ] Start a ProjectSupervisor per configured project

### 7. Update Dashboard for project context
- [ ] Add project selector to DashboardLive
- [ ] Scope issue/agent views to selected project

### 8. Tests
- [ ] ProjectManager add/remove project
- [ ] Multiple projects running simultaneously
- [ ] Project isolation (one project's failure doesn't affect others)
