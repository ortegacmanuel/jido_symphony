# Claude Streaming Adapter

## Current State

The Claude adapter (`lib/symphony_elixir/agent_adapters/claude.ex`) uses `claude --print` which is a **batch mode** — `System.cmd` blocks until Claude finishes all work and returns the full output at once. Symphony has zero visibility into what's happening during execution.

**Consequence:** The stall detector (`codex_stall_timeout_ms`) always fires because there's no intermediate output to detect activity. ConectaZen's WORKFLOW.md disables it with `stall_timeout_ms: 0`, relying on the turn timeout (1h) as the safety net.

## Proposed: Streaming Adapter

Replace `System.cmd` (batch) with a port-based streaming approach that reads Claude's JSON output line by line as it works.

**Current flow:**
```
Symphony → claude --print "prompt" → [silence 5-10 min] → full JSON output
```

**Streaming flow:**
```
Symphony → claude (streaming) → tool_use: "Read file X" → tool_use: "Write file Y" → tool_use: "Run mix test" → done
```

### Benefits

- **Stall detection works again** — each tool use is a heartbeat
- **Dashboard shows progress** — "Reading file...", "Writing tests...", "Running mix test..."
- **Loop detection** — if agent reads the same file 10 times, Symphony can intervene
- **Cost tracking in real-time** — token usage visible as it accumulates

### Implementation Approach

1. Use Elixir `Port.open` instead of `System.cmd` to get streaming stdout
2. Parse each JSON line as Claude emits it (tool_use events, text events)
3. Forward events to Symphony's `on_message` callback for dashboard/stall detector
4. Accumulate final result for the turn completion

### Claude CLI Modes

- `claude --print -p "prompt"` — current batch mode, returns JSON with result
- `claude -p "prompt" --output-format stream-json` — streams JSON events to stdout (tool uses, text, errors)
- Claude Agent SDK — programmatic API for full control over the conversation loop

### Priority

Medium. The `stall_timeout_ms: 0` workaround is adequate for now. This becomes important when:
- Multiple agents run concurrently and dashboard visibility matters
- Complex tasks take 15+ minutes and we need to distinguish "working" from "stuck"
- We want to implement cost-based circuit breakers (stop agent if approaching budget)

## Related: Stop Turns When Issue is Closed

**Bug:** Symphony continues dispatching turns even after the agent closes the GitHub issue. The orchestrator should check issue state before each turn and stop if the issue is no longer in "In Progress" state.

**Location:** `lib/symphony_elixir/orchestrator.ex` — the `Continuing agent run` path should call the tracker to verify issue state before dispatching the next turn.

**Priority:** High — wastes tokens on completed work.
