# CCEM APM v4

**Agentic Performance Monitor** -- real-time monitoring dashboard for Claude Code agent sessions, with AG-UI protocol support.

Built with Phoenix LiveView, daisyUI, D3.js, the AG-UI Elixir SDK, and a companion SwiftUI menubar agent.

## Quick Start

```bash
cd apm-v5
mix deps.get
mix phx.server
```

Open [http://localhost:3032](http://localhost:3032).

## Features

- **Multi-project dashboard** with D3.js dependency graph
- **Agent fleet management** -- register, track, and inspect AI agents
- **Ralph methodology** integration with flowchart visualization
- **UPM execution tracking** -- waves, stories, verification gates
- **Skills tracking** with UEBA analytics and co-occurrence matrix
- **Session timeline** with Gantt-style D3 visualization
- **60+ REST API endpoints** with v2 OpenAPI spec
- **AG-UI v2 protocol integration** -- EventRouter, HookBridge, StateManager
- **AG-UI SSE streams** -- global and per-agent event streams
- **AG-UI state sync** -- snapshot + JSON Patch (RFC 6902) delta
- **SwiftUI menubar agent** (CCEMAgent) for macOS
- **Built-in documentation wiki** at `/docs`

## Architecture

Phoenix/OTP application with 30+ GenServers managing state via ETS tables. PubSub-driven real-time updates across 6+ LiveView pages. No database -- all state is in-memory with config file persistence.

### Core GenServers

- `AgentRegistry` -- agent lifecycle and fleet management
- `ProjectStore` -- multi-project tasks and commands
- `ConfigLoader` -- watches and reloads `apm_config.json`
- `SkillTracker` -- skill catalog and usage analytics
- `UpmStore` -- UPM execution session tracking
- `DocsStore` -- markdown documentation wiki
- `BackgroundTasksStore` -- background task/process tracking
- `ProjectScanner` -- developer directory scanning
- `ActionEngine` -- action catalog with async execution

### AG-UI GenServers (v5)

Three GenServers under `lib/apm_v5/ag_ui/`:

- `ApmV5.AgUi.EventRouter` -- routes AG-UI events to AgentRegistry, FormationStore, Dashboard, MetricsCollector
- `ApmV5.AgUi.HookBridge` -- translates legacy hook payloads (register, heartbeat, notify, tool-use) to typed AG-UI events for backward compatibility
- `ApmV5.AgUi.StateManager` -- ETS-backed per-agent state with snapshot/delta pattern using RFC 6902 JSON Patch

### AG-UI v2 API Endpoints

Served by `ApmV5Web.V2.AgUiV2Controller`:

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v2/ag-ui/emit` | Emit AG-UI events into the router |
| GET | `/api/v2/ag-ui/events` | SSE stream of all AG-UI events |
| GET | `/api/v2/ag-ui/events/:agent_id` | SSE stream filtered to a single agent |
| GET | `/api/v2/ag-ui/state/:agent_id` | Get current agent state snapshot |
| PUT | `/api/v2/ag-ui/state/:agent_id` | Replace agent state (full snapshot) |
| PATCH | `/api/v2/ag-ui/state/:agent_id` | Apply JSON Patch delta to agent state |
| GET | `/api/v2/ag-ui/router/stats` | Routing statistics |

Pre-existing v1 endpoints (`GET /api/ag-ui/events`, `GET /api/a2ui/components`) remain unchanged.

### AG-UI Elixir SDK

The AG-UI protocol types and transports are provided by the standalone `ag_ui` Elixir library at `~/Developer/ag-ui-elixir/ag_ui/`. The SDK provides 15 core type structs, 30 event structs (7 categories: lifecycle, text, tool call, state, activity, reasoning, special), SSE/JSON encoding, Phoenix Channel transport, middleware pipeline, and RFC 6902 state management.

## Plane Projects

- **CCEM**: `a20e1d2e` -- main CCEM project
- **CCEM5**: `a898419a` -- APM v5 AG-UI integration work
- **AGUI**: `3e16b3ea` -- AG-UI Elixir SDK

## Documentation

Full documentation available at [http://localhost:3032/docs](http://localhost:3032/docs) when the server is running.

## License

Private -- CCEM project.
