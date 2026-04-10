# Analysis: Multi-Project Support + Coordinator Agent

**Branch:** `refactor/multi-project-coordinator`
**Date:** 2026-04-10
**Status:** Draft — awaiting team review

---

## 1. Problem Statement

Jido Symphony has three architectural limitations that block its evolution from a single-developer tool into a production orchestration platform:

### 1.1 Single-Project-Per-Instance

Symphony currently manages exactly one project per running BEAM process. All configuration is global: one `WORKFLOW_PATH`, one tracker, one orchestrator, one workspace root. Running multiple projects requires multiple OS processes on different ports (`start-all.sh`).

**Impact:** Juan's team wants to connect a Sentry clone that creates GitHub Issues across multiple project repos. Each project needs its own orchestrator. Running N separate processes is operationally fragile — no unified dashboard, no shared resource management, no centralized monitoring.

### 1.2 ProophboardBridge is Monolithic and ES-Only

The ProophboardBridge does too much (classify patterns + generate implementation notes + create issues + update slice status) and is hardcoded for event sourcing artifacts (FactEvent, StateChange behaviour, apply_event). Partner Middleware uses CRUD + Domain Events — a fundamentally different persistence strategy that produces different code artifacts.

**Impact:** The bridge can't be used for Partner Middleware's event model slices without rewriting the classification and artifact generation. It also can't handle non-event-model work (bugs, refactors, manual features) at all.

### 1.3 No Delivery Unit Grouping or Dependency-Aware Dispatch

The bridge creates one GitHub Issue per slice. But in CRUD architectures, slices have hard compile-time dependencies (Slice B imports Slice A's query handler). A slice dispatched alone may produce a PR that can't be QA'd independently because its dependencies haven't merged yet.

**Impact:** Agent-created PRs may fail at QA even when the code is correct, because the dependency chain isn't resolved. This wastes agent compute and reviewer time.

### 1.4 Pipeline Ends at PR Creation

The current lifecycle: Issue → Agent → PR → dead end. When a human reviewer requests changes, nobody picks them up. When a reviewer identifies a recurring pattern issue, nobody updates the guidance to prevent it next time.

**Impact (from Juan Macias's feedback):** The system doesn't learn. The same mistakes repeat because `CLAUDE.md`, `ai_docs/`, and `/deep-review` rules aren't updated from review feedback. This is the biggest quality gap.

---

## 2. Vision: The Complete Development Lifecycle

```
DESIGN          PLAN              BUILD           REVIEW          LEARN
─────────       ──────────        ──────          ──────          ─────
Prooph Board    CoordinatorAgent  CodingAgent     ReviewAgent     FeedbackAgent
Manual Issue    (group/split/     (Claude CLI     (address PR     (extract lessons,
Sentry alert    schedule DAG)     Phase 1)        review          update CLAUDE.md /
                                                  comments)       ai_docs / skills)
      │               │                │               │               │
      ▼               ▼                ▼               ▼               ▼
 GitHub Issue → Delivery Unit → Implementation → PR Review → Guidance Update
                    DAG              + Tests        Fixes         (meta-PR)
                                       │               │               │
                                       └───── PR ──────┘               │
                                              │                        │
                                              ▼                        ▼
                                           Merged              Next agent does
                                                               better
```

**Five agent roles, one CoordinatorAgent orchestrating them all.**

This analysis covers **Phase 0 (multi-project)** and **Phase 1a (coordinator + simplified bridge)**.
Phases 1b (ReviewAgent) and 1c (FeedbackAgent) will have separate analysis documents.

---

## 3. Solution: Phase 0 — Multi-Project Support

### 3.1 Architecture: DynamicSupervisor with Per-Project Isolation

```
Single BEAM node
├── Shared infrastructure
│   ├── Phoenix.PubSub (SymphonyElixir.PubSub)
│   ├── HttpServer (single dashboard, project tabs)
│   ├── ProjectRegistry (Registry for named process lookup)
│   └── StatusDashboard (aggregated + per-project views)
│
└── DynamicSupervisor: ProjectManager
    │
    ├── ProjectSupervisor: "partner-middleware"
    │   ├── WorkflowStore (partner-middleware/WORKFLOW.md)
    │   ├── Orchestrator (polls zenchef/partner-hub issues)
    │   ├── ProophboardBridge (partner-middleware workspace)
    │   ├── Task.Supervisor (agent pool, max 10)
    │   └── AgentEventStore (ETS, project-scoped)
    │
    ├── ProjectSupervisor: "sentry-clone-project-a"
    │   ├── WorkflowStore (project-a/WORKFLOW.md)
    │   ├── Orchestrator (polls juan/project-a issues)
    │   ├── Task.Supervisor (agent pool, max 5)
    │   └── AgentEventStore (ETS, project-scoped)
    │
    └── (more projects added at runtime)
```

### 3.2 Key Changes

**Config becomes project-scoped:**
```elixir
# Before (global):
Config.tracker_kind()          # → :github
Config.workspace_root()        # → "/tmp/symphony_workspaces"

# After (project-scoped):
Config.tracker_kind(project_id)      # → :github
Config.workspace_root(project_id)    # → "/tmp/symphony_workspaces/partner-middleware"
```

**Process registration via Registry:**
```elixir
# Each project's processes registered under composite keys:
{:via, Registry, {ProjectRegistry, {project_id, :orchestrator}}}
{:via, Registry, {ProjectRegistry, {project_id, :workflow_store}}}
{:via, Registry, {ProjectRegistry, {project_id, :proophboard_bridge}}}
```

**Project lifecycle:**
```elixir
# Add project at runtime (via dashboard or config):
ProjectManager.add_project("partner-middleware", %{
  workflow_path: "/path/to/partner-middleware/WORKFLOW.md",
  # All other config comes from WORKFLOW.md itself
})

# Remove project:
ProjectManager.remove_project("partner-middleware")

# List active projects:
ProjectManager.list_projects()
```

**Dashboard gets project context:**
```
Dashboard: [partner-middleware ▾]  [sentry-clone]  [+ New Project]

Orchestrator: running | 3 agents active | 2 issues queued
Delivery units: DU1 ✅ merged | DU2 🔄 in progress | DU3 ⏳ blocked
```

### 3.3 External System Integration (Path 1: GitHub Issues)

Juan's Sentry clone creates GitHub Issues directly on target repos:

```
Sentry clone detects bug in project-A
  → gh issue create --repo juan/project-a --title "..." --label "Todo"
  → Symphony polls juan/project-a (already registered as a project)
  → Picks up the issue on next poll cycle
  → Coordinator classifies and dispatches
```

No API needed between Sentry and Symphony. GitHub Issues is the universal interface. If a richer integration is needed later (priority hints, structured metadata), a Symphony API can be added as a future phase.

### 3.4 Project Configuration

Each project is defined by its WORKFLOW.md (same as today, just multiple):

```yaml
# partner-middleware/WORKFLOW.md
tracker:
  kind: github
  github_repo: zenchef/partner-hub

workspace:
  root: /data/symphony/workspaces/partner-middleware

agent:
  kind: claude
  max_concurrent_agents: 5

proophboard:
  workspace_id: abc123
  our_system_lanes: ["Partner Hub", "Hub API"]
```

```yaml
# project-a/WORKFLOW.md
tracker:
  kind: github
  github_repo: juan/project-a

workspace:
  root: /data/symphony/workspaces/project-a

agent:
  kind: claude
  max_concurrent_agents: 3

# No proophboard section — not every project uses event modeling
```

### 3.5 Startup Configuration

Projects can be registered at startup via a config file:

```elixir
# config/runtime.exs
config :symphony_elixir, :projects, [
  %{
    id: "partner-middleware",
    workflow_path: "/path/to/partner-middleware/WORKFLOW.md"
  },
  %{
    id: "sentry-project-a",
    workflow_path: "/path/to/project-a/WORKFLOW.md"
  }
]
```

Or added dynamically at runtime via the dashboard.

---

## 4. Solution: Phase 1a — Coordinator Agent + Simplified Bridge

### 4.1 Simplified ProophboardBridge

**Before:** Bridge does classification, artifact generation, issue creation, status updates.

**After:** Bridge is a dumb translator with rich metadata:

```elixir
# Simplified bridge responsibility:
# 1. Poll prooph board for "planned" slices
# 2. For each: create GitHub Issue with structured metadata
# 3. Update slice status to "in-progress"
# That's it. No classification. No artifact generation. No grouping.
```

The issue body includes machine-readable JSON:

```markdown
## Event Model Slice: avail_sync_to_hub

**Chapter:** Availability  
**Pattern:** STATE_CHANGE  

## Elements

- **Command:** SyncAvailabilityToHub _(Partner Hub lane)_
- **Event:** AvailabilitySyncedToHub _(Partner Hub lane)_
- **Automation:** AvailabilityChangedListener _(Partner Hub lane)_

## Structured Metadata
​```json
{
  "source": "proophboard",
  "workspace_id": "abc123",
  "chapter_id": "ch_456",
  "slice_id": "sl_789",
  "slice_type": "STATE_CHANGE",
  "elements": [
    {"type": "command", "name": "SyncAvailabilityToHub", "lane": "Partner Hub", "lane_id": "ln_1"},
    {"type": "event", "name": "AvailabilitySyncedToHub", "lane": "Partner Hub", "lane_id": "ln_1"},
    {"type": "automation", "name": "AvailabilityChangedListener", "lane": "Partner Hub", "lane_id": "ln_1"}
  ],
  "chapter_timeline": {
    "position": 3,
    "total": 19,
    "before": ["avail_changed_in_tenant", "avail_tenant_availability"],
    "after": ["avail_hub_availability"]
  }
}
​```
```

Labels: `event-model-slice`, `STATE_CHANGE`, `flow:availability`

### 4.2 CoordinatorAgent (Jido Agent)

The coordinator is a Jido Agent with an FSM strategy that monitors GitHub Issues and orchestrates the full lifecycle.

**Agent Definition:**
```elixir
defmodule Symphony.CoordinatorAgent do
  use Jido.Agent,
    name: "coordinator",
    strategy: {Jido.Agent.Strategy.FSM,
      initial_state: "polling",
      transitions: %{
        "polling"      => ["analyzing"],
        "analyzing"    => ["dispatching", "polling"],
        "dispatching"  => ["monitoring"],
        "monitoring"   => ["dispatching", "polling", "completed"],
        "completed"    => ["polling"]
      }
    },
    schema: Zoi.object(%{
      project_id: Zoi.string(),
      delivery_units: Zoi.map() |> Zoi.default(%{}),
      issue_cache: Zoi.map() |> Zoi.default(%{}),
      dag: Zoi.any() |> Zoi.optional()
    })
end
```

**FSM Flow:**

```
polling: Fetch open GitHub Issues for this project
    │
    ▼
analyzing: For each new/changed issue:
    ├── Has structured proophboard metadata?
    │   → Deterministic: read produces/consumes, build dependency graph
    │   → Group into delivery units
    │
    ├── Manual feature issue (no metadata)?
    │   → LLM-assisted: decompose into subtasks
    │
    └── Bug report?
        → LLM-assisted: plan investigation + fix
    │
    ▼
dispatching: For each ready delivery unit / task:
    ├── Check dependencies satisfied (all blocking DUs merged)
    ├── Assign to available agent slot
    └── Signal orchestrator to spawn coding agent
    │
    ▼
monitoring: Track active agents:
    ├── Agent completed → mark DU complete, unblock dependents
    ├── Agent failed → retry with backoff
    ├── PR merged → update prooph board slice status
    ├── PR review requested → (Phase 1b: dispatch ReviewAgent)
    └── Pattern issue detected → (Phase 1c: dispatch FeedbackAgent)
    │
    ▼
    Back to polling (continuous loop)
```

### 4.3 Coordinator Actions

```elixir
# Issue discovery
FetchOpenIssues          # gh issue list --label "Todo" --json ...

# Classification (for proophboard slices)
ClassifySlicePattern     # Read structured JSON → SC→Internal, SV→External, etc.
                         # Pluggable: project provides its own pattern → artifact mapping

# Delivery unit grouping
IdentifyDeliveryUnits    # Dependency analysis → group hard-coupled slices
                         # Algorithm from partner-middleware docs (produces/consumes graph)

# For non-slice issues (LLM-assisted)
DecomposeComplexIssue    # LLM call → subtask breakdown (open-multi-agent coordinator pattern)

# DAG management
BuildTaskDAG             # Topological sort of delivery units
UnblockDependents        # When DU completes → promote blocked DUs to ready
CascadeFailure           # When DU fails → mark transitive dependents as blocked

# Dispatch
DispatchReadyUnit        # Signal orchestrator to spawn coding agent for a DU

# Prooph board integration (MCP tools)
FetchChapterDetails      # mcp__proophboard__get_chapter — for additional context
SearchElements           # mcp__proophboard__search_elements — cross-chapter lookup
UpdateSliceStatus        # mcp__proophboard__update_slice_status — mark completed
```

### 4.4 Delivery Unit Identification Algorithm

For projects using event modeling (prooph board slices with structured metadata):

```
Input: Set of GitHub Issues with "event-model-slice" label

1. Parse structured metadata JSON from each issue body
2. For each slice, extract:
   - produces: what commands/queries/entities this slice defines
   - consumes: what commands/queries/entities this slice uses (from other slices)

3. Build dependency graph:
   - If Slice B consumes a command/query that Slice A produces → hard edge B→A
   - If Slice B writes to an entity that Slice A creates → hard edge B→A
   - If Slice B listens to an event from Slice A → soft edge (no grouping)

4. Check what already exists in main branch:
   - If a consumed handler/entity already exists → dependency satisfied, no edge

5. Group by hard edges:
   - Connected components in the hard-dependency graph = delivery units
   - Each DU gets a synthetic parent issue linking its slice issues

6. Order DUs topologically:
   - DU with no unsatisfied dependencies → ready
   - DU depending on another DU → blocked until dependency DU merges

Output: Ordered list of delivery units with:
  - Slice issues in each DU
  - Dependencies between DUs
  - Ready/blocked status
```

For non-event-model issues (bugs, features, refactors):

```
Input: GitHub Issue without "event-model-slice" label

1. Read issue title + body
2. Call LLM (DecomposeComplexIssue action):
   - "Given this issue and this project's architecture, break into ordered subtasks"
   - Context: project's CLAUDE.md + ai_docs (loaded from workspace)
3. If issue is small enough for one agent turn → pass through as-is
4. If complex → create sub-issues as checklist items in the parent issue
5. Build DAG from subtask ordering

Output: Single delivery unit with ordered subtasks
  OR: pass-through (issue dispatched directly to coding agent)
```

### 4.5 Pattern Classification (Pluggable Per Project)

The coordinator doesn't hardcode patterns. Each project's WORKFLOW.md can specify a classification scheme:

```yaml
# partner-middleware/WORKFLOW.md
coordinator:
  slice_classification: crud_domain_events  # built-in scheme
  # OR
  slice_classification_skill: .claude/skills/event-modeling/  # custom skill path
```

Built-in schemes:

**`event_sourcing`** (current ConectaZen patterns):
- SIMPLE_STATE_CHANGE, WEBHOOK_STATE_CHANGE, AUTOMATION_STATE_CHANGE
- INTERNAL_STATE_VIEW, TODO_STATE_VIEW
- EXTERNAL_STATE_VIEW (skip), TRANSLATION_EXTERNAL (skip)

**`crud_domain_events`** (Partner Middleware patterns):
- SC→Internal (Command → Entity → Event → Repository)
- SC→External (ProcessManager → HTTP API call)
- SV→Internal (Query → Entity → DTO)
- SV→External (Query → ReadModel via RemoteRepository)
- Compound (SV→External + SC→Internal translation)

The classification drives the implementation notes injected into the agent's prompt, not the coordination logic. The coordinator groups by dependencies regardless of classification scheme.

### 4.6 Prooph Board as Coordinator Tool

The coordinator doesn't just read flat issue text. It has MCP access to prooph board for additional context:

```
Coordinator reads issue → finds proophboard metadata
  → Needs element relationship details?
    → FetchChapterDetails action (mcp__proophboard__get_chapter)
  → Needs to find related elements in other chapters?
    → SearchElements action (mcp__proophboard__search_elements)
  → DU completed and merged?
    → UpdateSliceStatus action (marks slices as "done" in prooph board)
```

This is optional — projects without prooph board (Juan's projects) skip these tools. The coordinator adapts based on available metadata.

---

## 5. What Doesn't Change

- **WORKFLOW.md format** — Same YAML frontmatter + Liquid template body. Just read by a project-scoped WorkflowStore instead of a global one.
- **Claude Code CLI** — Still the coding engine in Phase 1. The coordinator dispatches work; Claude does it.
- **CLAUDE.md / ai_docs / skills** — Per-project coding guidance. Loaded by Claude Code automatically. Not touched by this refactor.
- **Interactive mode** — Developers running Claude Code in their terminal are unaffected. This refactor is about the autonomous pipeline.
- **Hook system** — after_create, before_run, after_run hooks still work the same way, just scoped to a project's workspace.

---

## 6. Impact Assessment

### 6.1 Multi-Project (Phase 0)

| Area | Impact |
|------|--------|
| `Config` module | Refactor all accessors to take `project_id` parameter |
| `Workflow` / `WorkflowStore` | Instance per project, registered via Registry |
| `Orchestrator` | Instance per project, scoped state |
| `ProophboardBridge` | Instance per project (optional, only if configured) |
| `Application` supervision tree | Add ProjectManager (DynamicSupervisor) + ProjectRegistry |
| `AgentEventStore` | Scope ETS entries by project_id |
| Dashboard LiveViews | Add project selector, scope all queries |
| `start-all.sh` | Replaced by single process with config file |
| Tests | Existing tests should pass (single project = default project) |

### 6.2 Coordinator Agent (Phase 1a)

| Area | Impact |
|------|--------|
| `ProophboardBridge` | Simplified — remove classification/implementation notes/grouping logic |
| New: `CoordinatorAgent` | Jido Agent with FSM, delivery unit DAG, issue analysis |
| New: Coordinator Actions | ~10 Jido Actions (classify, group, decompose, dispatch, etc.) |
| `Orchestrator` | Modified to accept dispatch signals from coordinator (not just poll tracker) |
| Issue creation | Bridge creates simple issues; coordinator may create DU parent issues |
| Dependencies | Add `jido` core as dependency (for Agent, Action, Signal, Strategy) |

### 6.3 Risk Assessment

| Risk | Mitigation |
|------|------------|
| Multi-project increases blast radius | OTP per-project supervision — one project's crash doesn't affect others |
| Jido core dependency is new | Start with minimal usage (Agent + FSM Strategy + Actions). Don't over-adopt. |
| Coordinator LLM calls add cost | LLM-assisted decomposition only for non-structured issues. Proophboard issues use deterministic grouping. |
| Delivery unit grouping may be wrong | Human approval gate: coordinator proposes DUs, human confirms before dispatch. Can be made automatic later. |

---

## 7. Relationship to Future Phases

This analysis intentionally scopes to Phase 0 + Phase 1a. The following phases build on this foundation:

**Phase 1b — ReviewAgent:** Coordinator monitors PR review events (GitHub webhooks or polling). When `changes_requested`, dispatches coding agent to existing branch with review comments as context. Requires: coordinator's monitoring loop (built in 1a).

**Phase 1c — FeedbackAgent:** After PR review cycles, analyzes whether rejected patterns are already covered by guidance or represent gaps. Proposes CLAUDE.md / ai_docs / deep-review updates as meta-PRs. Requires: coordinator's PR monitoring (built in 1a/1b).

**Phase 2 — Native Jido Coding Agent:** Replace Claude CLI with a Jido Agent that calls the Anthropic API directly and uses Jido Actions for tools (ReadFile, EditFile, Bash, etc.). Requires: coordinator dispatch (built in 1a).

**Phase 3 — MCP Tool Bridge:** Build a Jido Action that can call any MCP tool, giving the native coding agent access to the same tool ecosystem as Claude Code CLI. Requires: native coding agent (built in Phase 2).

---

## 8. Decisions (resolved 2026-04-10)

1. **Human approval gate for delivery units?** No gate — automatic dispatch from the beginning. Human is present as PR reviewer, which is the quality checkpoint.

2. **Cross-project dependencies?** Each project is independent. No cross-project dependency tracking.

3. **Project-level agent budget?** No LLM spend limit in this phase. Track token/cost spend per project for observability. Add limits in a later phase.

4. **Coordinator as standalone package?** Start in symphony, extract to `jido_coordinator` Hex package if it proves reusable.

5. **How does the coordinator persist state across restarts?** In-memory (ETS) for Phase 1. Add Jido.Storage (ETS/File/Redis) later if long-running DU tracking is needed.
