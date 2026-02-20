# System Architecture

CCEM APM v4 is built on Phoenix/Elixir with a supervisor-based OTP architecture. The system uses GenServers for state management, PubSub for real-time events, and ETS for fast data access.

## High-Level Architecture

The following diagram shows the layered architecture from HTTP entry point down to the data layer.

```text
┌───────────────────────────────────────────────────┐
│  Phoenix Endpoint & Router                        │
│  - HTTP routes                                    │
│  - WebSocket upgrade                              │
│  - Static assets (HTML, CSS, JS)                  │
└─────────────────────┬─────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────┐
│  LiveView Pages & Controllers                     │
│  - DashboardLive, AllProjectsLive, SkillsLive     │
│  - FormationLive, PortsLive, DocsLive             │
│  - REST controllers for API routes                │
└─────────────────────┬─────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────┐
│  PubSub Broker (Event Bus)                        │
│  - Topics: apm:agents, apm:notifications, etc.    │
│  - Broadcasts real-time updates to clients        │
└─────────────────────┬─────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────┐
│  GenServer Stores (OTP Supervision)               │
│  - ConfigLoader, AgentRegistry, ProjectStore      │
│  - UpmStore, SkillTracker, PortManager, DocsStore │
│  - MetricsCollector, AlertRulesEngine             │
└─────────────────────┬─────────────────────────────┘
                      │
┌─────────────────────▼─────────────────────────────┐
│  Data Layer                                       │
│  - ETS tables for fast lookups                    │
│  - JSON files (apm_config.json, sessions)         │
│  - File-based persistence                         │
└───────────────────────────────────────────────────┘
```

## Application Supervision Tree

The application uses a flat `one_for_one` supervision strategy defined in `lib/apm_v4/application.ex`. All children are direct descendants of the root supervisor -- there is no intermediate `GeneralSupervisor`.

The following diagram shows every supervised child process in start order.

```text
ApmV4.Supervisor (root, strategy: :one_for_one)
├── ApmV4Web.Telemetry
├── DNSCluster
├── Phoenix.PubSub (name: ApmV4.PubSub)
├── ApmV4.ConfigLoader
├── ApmV4.DashboardStore
├── ApmV4.ApiKeyStore
├── ApmV4.AuditLog
├── ApmV4.ProjectStore
├── ApmV4.AgentRegistry
├── ApmV4.UpmStore
├── ApmV4.SkillTracker
├── ApmV4.AlertRulesEngine
├── ApmV4.MetricsCollector
├── ApmV4.SloEngine
├── ApmV4.EventStream
├── ApmV4.AgentDiscovery
├── ApmV4.EnvironmentScanner
├── ApmV4.CommandRunner
├── ApmV4.DocsStore
├── ApmV4.PortManager
└── ApmV4Web.Endpoint
```

> **Warning:** The supervision tree uses `one_for_one` strategy. If a child crashes, only that child is restarted. Ensure each GenServer can recover its own state on restart.

## GenServer Modules

### ConfigLoader

Loads and manages `apm_config.json`.

GenServer state and API summary:

```elixir
GenServer: ApmV4.ConfigLoader
State:
  - config: %{project_name, project_root, active_project, projects, sessions}
  - file_path: /path/to/apm_config.json

API:
  - get_config/0
  - get_project/1
  - update_project/1
  - reload/0

Broadcasts:
  - {:config_reloaded, config} to "apm:config"
```

### DashboardStore

Maintains aggregated dashboard metrics and state.

GenServer state and API summary:

```elixir
GenServer: ApmV4.DashboardStore
State:
  - stats: %{agent_count, session_count, project_count, skill_count}
  - agents_cache: list of agents
  - notifications_cache: recent notifications
  - last_update: timestamp

API:
  - get_stats/0
  - get_agents/0
  - update_agent/1

Subscribes to:
  - "apm:agents" for agent changes
  - "apm:notifications" for alerts
```

### AgentRegistry

Central registry for all agents and fleet management.

GenServer state and API summary:

```elixir
GenServer: ApmV4.AgentRegistry
State:
  - agents: %{agent_id => agent_data}
  - by_project: index agents by project
  - by_type: index agents by type
  - by_status: index agents by status
  - timestamps: last_update per agent

API:
  - register_agent/3
  - update_status/2
  - update_agent/2
  - get_agent/1
  - list_agents/0
  - list_agents/1 (by project)
  - list_sessions/0
  - add_notification/1
  - get_notifications/0
  - mark_all_read/0

Broadcasts:
  - {:agent_registered, agent} to "apm:agents"
  - {:agent_updated, agent} to "apm:agents"
  - {:notification_added, notif} to "apm:notifications"
  - :notifications_read to "apm:notifications"
```

### ProjectStore

Manages multi-project tasks, commands, input requests, and Plane PM data.

GenServer state and API summary:

```elixir
GenServer: ApmV4.ProjectStore
State:
  - tasks: %{project_name => task_list}
  - commands: %{project_name => command_list}
  - inputs: pending input requests
  - plane: %{project_name => plane_data}

API:
  - get_tasks/1
  - sync_tasks/2
  - get_commands/1
  - register_commands/2
  - get_pending_inputs/0
  - add_input_request/1
  - respond_to_input/2
  - update_plane/2

Broadcasts:
  - {:tasks_synced, project, tasks} to "apm:tasks"
  - {:commands_updated, project} to "apm:commands"
  - {:plane_updated, project} to "apm:plane"
  - {:input_requested, input} to "apm:input"
  - {:input_responded, input} to "apm:input"
```

### UpmStore

Tracks UPM sessions, formations, agents, and events.

GenServer state and API summary:

```elixir
GenServer: ApmV4.UpmStore
State:
  - sessions: %{session_id => session_data}
  - formations: formation hierarchy data
  - events: timeline of events

API:
  - register_session/1
  - register_agent/1
  - record_event/1
  - get_status/0
  - get_active_formation/0

Broadcasts:
  - {:upm_session_registered, session} to "apm:upm"
  - {:upm_agent_registered, params} to "apm:upm"
  - {:upm_event, event} to "apm:upm"
  - {:formation_registered, formation} to "apm:upm"
  - {:formation_updated, formation} to "apm:upm"
```

### SkillTracker

Tracks skill usage, co-occurrence, and patterns.

GenServer state and API summary:

```elixir
GenServer: ApmV4.SkillTracker
State:
  - skills: %{skill_name => usage_data}
  - co_occurrence: matrix of skill pairs
  - by_session: skills per session
  - by_project: skills per project

API:
  - track_skill/4
  - get_skill_catalog/0
  - get_co_occurrence/0
  - get_session_skills/1
  - get_project_skills/1

Broadcasts:
  - {:skill_tracked, session_id, skill_name} to "apm:skills"
```

### MetricsCollector

Collects and aggregates metrics from all sources.

GenServer state and API summary:

```elixir
GenServer: ApmV4.MetricsCollector
State:
  - metrics: %{metric_name => values}
  - timeseries: metric history

API:
  - collect/2
  - get_metrics/1
  - get_timeseries/2

Broadcasts:
  - {:fleet_metrics_updated, metrics} to "apm:metrics"

Subscribes to:
  - "apm:agents" for agent metrics
  - "apm:upm" for execution metrics
  - "apm:skills" for skill metrics
```

### AlertRulesEngine

Manages alert rules and evaluates conditions.

GenServer state and API summary:

```elixir
GenServer: ApmV4.AlertRulesEngine
State:
  - rules: alert rule definitions
  - alerts: active alerts
  - escalation_rules: tier escalation rules

API:
  - add_rule/1
  - evaluate_condition/1
  - get_active_alerts/0

Broadcasts:
  - {:alert_fired, alert} to "apm:alerts"
```

### AuditLog

Maintains immutable audit trail.

GenServer state and API summary:

```elixir
GenServer: ApmV4.AuditLog
State:
  - entries: list of audit entries
  - index: by entity_id for fast lookup

API:
  - log/1
  - get_entries/1
  - get_by_agent/1
  - export/1

Broadcasts:
  - {:audit_event, event} to "apm:audit"
```

### EventStream

Manages event queue and AG-UI SSE streaming.

GenServer state and API summary:

```elixir
GenServer: ApmV4.EventStream
State:
  - queue: FIFO event queue
  - subscribers: listening connections
  - history: recent events

API:
  - push_event/1
  - subscribe/0
  - get_history/0

Broadcasts:
  - {:ag_ui_event, event} to "apm:ag_ui"
```

### SloEngine

Evaluates SLO (Service Level Objective) rules and targets.

GenServer state and API summary:

```elixir
GenServer: ApmV4.SloEngine
State:
  - slos: %{sli_name => slo_definition}
  - statuses: current SLO statuses

Broadcasts:
  - {:slo_transition, sli_name, old_status, new_status} to "apm:slos"
```

### PortManager

Manages port assignments across CCEM projects.

GenServer state and API summary:

```elixir
GenServer: ApmV4.PortManager
State:
  - port_map: %{port => %{project, namespace, active, ownership}}
  - port_ranges: %{namespace => Range}

API:
  - get_port_map/0
  - get_port_ranges/0
  - detect_clashes/0
  - scan_active_ports/0
  - assign_port/1
  - set_primary_port/3
```

### DocsStore

Caches and serves documentation from `priv/docs/`.

GenServer state and API summary:

```elixir
GenServer: ApmV4.DocsStore
State:
  - pages: %{path => %{title, html, raw, meta}}
  - toc: table of contents tree

API:
  - get_toc/0
  - get_page/1
  - search/1
```

### Additional GenServers

- **ApiKeyStore** -- API authentication and key management
- **AgentDiscovery** -- Auto-discovery of agents from environment
- **EnvironmentScanner** -- Scans and tracks Claude Code environments
- **CommandRunner** -- Executes commands in environments

## ETS Tables

Fast in-memory storage for frequently accessed data.

| Table | Keys | Purpose |
|:------|:-----|:--------|
| `:agents` | agent_id | Agent registry |
| `:projects` | project_name | Project catalog |
| `:skills` | skill_name | Skill catalog |
| `:metrics` | {entity_type, entity_id} | Metric cache |
| `:sessions` | session_id | Session metadata |
| `:notifications` | notification_id | Recent notifications |
| `:agent_index_by_project` | project_name | Project -> agent mapping |
| `:agent_index_by_status` | status | Status -> agent mapping |

> **Pattern:** ETS tables are created in `ConfigLoader.init/1` and cleared on reload. Use `:ets.lookup/2` for O(1) reads and `:ets.insert/2` for writes.

## PubSub Topics

Real-time event broadcasting. See [PubSub Events](pubsub-events.md) for full payload documentation.

### apm:agents

Agent lifecycle events.

```elixir
{:agent_registered, %Agent{}}
{:agent_updated, %Agent{}}
{:agent_discovered, agent_id, project}
```

### apm:notifications

Alert and notification events.

```elixir
{:notification_added, %Notification{}}
:notifications_read
```

### apm:config

Configuration changes.

```elixir
{:config_reloaded, config}
```

### apm:tasks

Task execution events.

```elixir
{:tasks_synced, project, tasks}
```

### apm:commands

Slash command registration.

```elixir
{:commands_updated, project}
```

### apm:upm

UPM execution tracking.

```elixir
{:upm_session_registered, session}
{:upm_agent_registered, params}
{:upm_event, event}
{:formation_registered, formation}
{:formation_updated, formation}
```

### apm:skills

Skill tracking.

```elixir
{:skill_tracked, session_id, skill_name}
```

### apm:audit

Audit logging.

```elixir
{:audit_event, event}
```

### apm:alerts

Alert rule engine.

```elixir
{:alert_fired, alert}
```

### apm:environments

Environment scanning.

```elixir
{:environments_updated, count}
```

### apm:input

User input requests and responses.

```elixir
{:input_requested, input}
{:input_responded, input}
```

### apm:plane

Plane PM integration.

```elixir
{:plane_updated, project_name}
```

### apm:metrics

Fleet metrics.

```elixir
{:fleet_metrics_updated, metrics}
```

### apm:slos

SLO status transitions.

```elixir
{:slo_transition, sli_name, old_status, new_status}
```

### apm:ag_ui

AG-UI Server-Sent Events.

```elixir
{:ag_ui_event, event}
```

## Error Handling

GenServers use standard Elixir error handling:

- **Init errors**: Logged, supervisor restarts the child
- **Cast/call errors**: Logged, GenServer continues operating
- **Subscription errors**: Logged, reconnection attempted
- **File I/O errors**: Logged, operation retried

> **Pattern:** Errors are broadcast to `"apm:notifications"` so the UI can display alerts to the user.

## Scalability

- **Agents**: Tested to 1000+ agents per instance
- **Sessions**: 100+ concurrent sessions
- **ETS lookups**: O(1) for registered agents
- **PubSub topics**: Broadcast to 100+ listeners
- **Memory**: ~500MB baseline, grows with agent count

For larger deployments, consider:

- Splitting GenServers across multiple nodes (Erlang clustering)
- Using external store (PostgreSQL) with ETS cache layer
- Implementing request queuing for high-volume periods

## Development

To understand the codebase:

1. Start with `lib/apm_v4/application.ex` -- see the supervision tree
2. Explore `lib/apm_v4/` -- understand GenServer modules
3. Check `lib/apm_v4_web/` -- Phoenix routes and controllers
4. Review `lib/apm_v4_web/live/` -- LiveView pages

See [Extending CCEM](extending.md) for adding new features.
