# AG-UI Protocol

The AG-UI (Agent-User Interaction) protocol provides a standardized, event-based communication layer between AI agents and the CCEM APM dashboard. It enables real-time streaming of agent lifecycle events, state management, and bidirectional control.

## Canonical SDK

As of v5.3.0, CCEM APM uses the [`ag_ui_ex`](https://hex.pm/packages/ag_ui_ex) Hex package as the canonical Elixir SDK for the AG-UI protocol. All event type constants are sourced from `AgUi.Core.Events.EventType` — no hardcoded strings.

```elixir
# In mix.exs
{:ag_ui_ex, "~> 0.1.0"}

# Usage
alias AgUi.Core.Events.EventType
EventType.run_started()      # => "RUN_STARTED"
EventType.valid?("CUSTOM")   # => true
EventType.all()              # => ["RUN_STARTED", "RUN_FINISHED", ...]
```

## Overview

AG-UI is an open protocol that defines 33+ typed event categories for agent-user interaction. CCEM APM implements the protocol via:

- **ag_ui_ex** — Hex package providing typed event structs, SSE encoder, middleware, and state management ([GitHub](https://github.com/peguesj/ag_ui_ex))
- **EventRouter** — GenServer that routes typed events to subscribers
- **HookBridge** — Translates legacy hook payloads (register, heartbeat, notify) into AG-UI events
- **StateManager** — ETS-backed per-agent state with snapshot/delta (RFC 6902 JSON Patch)
- **EventStream** — Ordered event buffer with agent-scoped filtering

## Event Types

| Event Type | Category | Description |
|:-----------|:---------|:------------|
| `RUN_STARTED` | Lifecycle | Agent run begins |
| `RUN_FINISHED` | Lifecycle | Agent run completes successfully |
| `RUN_ERROR` | Lifecycle | Agent run fails with error |
| `STEP_STARTED` | Progress | Processing step begins |
| `STEP_FINISHED` | Progress | Processing step completes |
| `TOOL_CALL_START` | Tools | Tool invocation begins |
| `TOOL_CALL_END` | Tools | Tool invocation completes |
| `STATE_SNAPSHOT` | State | Full agent state snapshot |
| `STATE_DELTA` | State | Incremental state update (JSON Patch) |
| `TEXT_MESSAGE_START` | Messages | Text message stream begins |
| `TEXT_MESSAGE_CONTENT` | Messages | Text message content chunk |
| `TEXT_MESSAGE_END` | Messages | Text message stream ends |
| `MESSAGES_SNAPSHOT` | Messages | Full message history snapshot |
| `CUSTOM` | Custom | Application-defined event |

## Architecture

```
Hook Payloads (register/heartbeat/notify)
    |
    v
HookBridge ──> AG-UI Typed Events ──> EventRouter
                                         |
                                    ┌────┴─────┐
                                    |          |
                              PubSub         EventStream
                           (real-time)       (buffered)
                                    |          |
                              LiveView       REST API
                             (ag_ui:events)  (/api/v2/ag-ui/*)
```

### GenServers

| GenServer | Module | Purpose |
|:----------|:-------|:--------|
| EventRouter | `ApmV5.AgUi.EventRouter` | Routes events to registered handlers |
| HookBridge | `ApmV5.AgUi.HookBridge` | Translates legacy hooks to AG-UI events |
| StateManager | `ApmV5.AgUi.StateManager` | Per-agent state snapshots and deltas |
| EventStream | `ApmV5.EventStream` | Ordered event buffer with filtering |

## REST API Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/v2/ag-ui/emit` | Emit a typed event |
| GET | `/api/v2/ag-ui/events` | SSE stream (all events) |
| GET | `/api/v2/ag-ui/events/:agent_id` | SSE stream (agent-scoped) |
| GET | `/api/v2/ag-ui/state/:agent_id` | Get state snapshot |
| PUT | `/api/v2/ag-ui/state/:agent_id` | Replace state |
| PATCH | `/api/v2/ag-ui/state/:agent_id` | Apply JSON Patch delta |
| GET | `/api/v2/ag-ui/router/stats` | Router statistics |

## LiveView Integration

The `/ag-ui` page provides a real-time event feed with:

- **Event type filter toggles** — Enable/disable display of specific event types
- **Pause/Resume** — Temporarily halt event stream updates
- **Router stats panel** — Total routed count, per-type breakdown
- **Agent state viewer** — Select an agent to view its current state snapshot
- **Color-coded badges** — Each event type has a distinct badge color for quick scanning

## HookBridge Translation

Legacy hooks automatically produce AG-UI events:

| Hook Endpoint | AG-UI Event |
|:-------------|:------------|
| `POST /api/register` | `RUN_STARTED` |
| `POST /api/heartbeat` | `STEP_STARTED` / `STEP_FINISHED` |
| `POST /api/notify` | `CUSTOM` |
| PreToolUse hook | `TOOL_CALL_START` |
| PostToolUse hook | `TOOL_CALL_END` |

## Emitting Events

```bash
# Emit a custom event
curl -X POST http://localhost:3032/api/v2/ag-ui/emit \
  -H "Content-Type: application/json" \
  -d '{
    "type": "CUSTOM",
    "agent_id": "my-agent",
    "data": {
      "message": "Processing complete",
      "files_changed": 5
    }
  }'
```

## State Management

Agent state is managed via snapshot/delta pattern:

```bash
# Set full state
curl -X PUT http://localhost:3032/api/v2/ag-ui/state/my-agent \
  -H "Content-Type: application/json" \
  -d '{"status": "running", "progress": 0}'

# Apply delta (RFC 6902 JSON Patch)
curl -X PATCH http://localhost:3032/api/v2/ag-ui/state/my-agent \
  -H "Content-Type: application/json" \
  -d '{"delta": [{"op": "replace", "path": "/progress", "value": 75}]}'

# Get current state
curl http://localhost:3032/api/v2/ag-ui/state/my-agent
```

## PubSub Topics

| Topic | Events |
|:------|:-------|
| `ag_ui:events` | All AG-UI events (broadcasted by EventRouter) |
| `apm:agents` | Agent registration and update events |

## Configuration

AG-UI is enabled by default. No additional configuration is required. The EventRouter, HookBridge, StateManager, and EventStream GenServers start automatically under the OTP supervision tree.
