# System Architecture

CCEM APM v4 is built on Phoenix/Elixir with a supervisor-based OTP architecture. The system uses GenServers for state management, PubSub for real-time events, and ETS for fast data access.

## High-Level Architecture

```
┌─────────────────────────────────────────────────┐
│  Phoenix Endpoint & Router                      │
│  - HTTP routes                                  │
│  - WebSocket upgrade                            │
│  - Static assets (HTML, CSS, JS)                │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│  LiveView Pages & Controllers                   │
│  - DashboardLive, ProjectsLive, SkillsLive      │
│  - REST controllers for API routes              │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│  PubSub Broker (Event Bus)                      │
│  - Topics: apm:agents, apm:notifications, etc.  │
│  - Broadcasts real-time updates to clients      │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│  GenServer Stores (OTP Supervision)             │
│  - ConfigLoader, AgentRegistry                  │
│  - ProjectStore, UpmStore, SkillTracker         │
│  - MetricsCollector, AlertRulesEngine           │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│  Data Layer                                     │
│  - ETS tables for fast lookups                  │
│  - JSON files (apm_config.json, sessions)       │
│  - File-based persistence                       │
└─────────────────────────────────────────────────┘
```

## Application Supervision Tree

```
ApmV4.Supervisor (root)
├── ApmV4Web.Endpoint
├── ApmV4.PubSub (Phoenix.PubSub)
├── ApmV4.Repo (if using Ecto)
└── ApmV4.Supervisors.GeneralSupervisor
    ├── ConfigLoader
    ├── DashboardStore
    ├── ApiKeyStore
    ├── AuditLog
    ├── ProjectStore
    ├── AgentRegistry
    ├── UpmStore
    ├── SkillTracker
    ├── AlertRulesEngine
    ├── MetricsCollector
    ├── SloEngine
    ├── EventStream
    ├── AgentDiscovery
    ├── EnvironmentScanner
    ├── CommandRunner
    └── DocsStore
```

## GenServer Modules

### ConfigLoader
Loads and manages `apm_config.json`.

```elixir
GenServer: ApmV4.Stores.ConfigLoader
State:
  - config: %{project_name, project_root, active_project, projects, sessions}
  - file_path: /path/to/apm_config.json

API:
  - get_config/0
  - get_project/1
  - set_active_project/1
  - reload_config/0

Broadcasts:
  - {:config_reloaded, config} to "apm:config"
```

### DashboardStore
Maintains aggregated dashboard metrics and state.

```elixir
GenServer: ApmV4.Stores.DashboardStore
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

```elixir
GenServer: ApmV4.Stores.AgentRegistry
State:
  - agents: %{agent_id => agent_data}
  - by_project: index agents by project
  - by_type: index agents by type
  - by_status: index agents by status
  - timestamps: last_update per agent

API:
  - register_agent/1
  - heartbeat/2
  - get_agent/1
  - get_agents/1 (with filters)
  - update_agent_status/2
  - discover_agents/1

Broadcasts:
  - {:agent_registered, agent}
  - {:agent_updated, agent}
  - {:agent_discovered, id, project}
  to "apm:agents"
```

### ProjectStore
Manages multi-project configuration and isolation.

```elixir
GenServer: ApmV4.Stores.ProjectStore
State:
  - projects: %{project_name => project_data}
  - active: current active project
  - config: cached config

API:
  - get_projects/0
  - set_active/1
  - get_active/0
  - get_project_agents/1

Subscribes to:
  - "apm:config" for config changes
```

### UpmStore
Tracks UPM sessions, waves, and stories.

```elixir
GenServer: ApmV4.Stores.UpmStore
State:
  - sessions: %{session_id => session_data}
  - waves: %{wave_id => wave_data}
  - stories: %{story_id => story_data}
  - events: timeline of events

API:
  - register_session/1
  - register_agent/2
  - log_event/1
  - get_status/1
  - update_story_status/2

Broadcasts:
  - {:upm_session_registered, session}
  - {:upm_agent_registered, params}
  - {:upm_event, event}
  to "apm:upm"
```

### SkillTracker
Tracks skill usage, co-occurrence, and patterns.

```elixir
GenServer: ApmV4.Stores.SkillTracker
State:
  - skills: %{skill_name => usage_data}
  - co_occurrence: matrix of skill pairs
  - methodologies: detected patterns
  - anomalies: flagged behaviors

API:
  - track_skill/2
  - get_skills/0
  - get_cooccurrence_matrix/0
  - detect_methodologies/0
  - flag_anomaly/2

Broadcasts:
  - {:skill_tracked, skill} to "apm:skills"
```

### MetricsCollector
Collects and aggregates metrics from all sources.

```elixir
GenServer: ApmV4.Stores.MetricsCollector
State:
  - metrics: %{metric_name => values}
  - timeseries: metric history

API:
  - collect/2
  - get_metrics/1
  - get_timeseries/2

Subscribes to:
  - "apm:agents" for agent metrics
  - "apm:upm" for execution metrics
  - "apm:skills" for skill metrics
```

### AlertRulesEngine
Manages alert rules and evaluates conditions.

```elixir
GenServer: ApmV4.Stores.AlertRulesEngine
State:
  - rules: alert rule definitions
  - alerts: active alerts
  - escalation_rules: tier escalation rules

API:
  - add_rule/1
  - evaluate_condition/1
  - escalate_agent/2
  - get_active_alerts/0
```

### AuditLog
Maintains immutable audit trail.

```elixir
GenServer: ApmV4.Stores.AuditLog
State:
  - entries: list of audit entries
  - index: by entity_id for fast lookup

API:
  - log/1
  - get_entries/1
  - get_by_agent/1
  - export/1

Broadcasts:
  - {:audit_entry, entry} to "apm:audit"
```

### EventStream
Manages event queue and streaming.

```elixir
GenServer: ApmV4.Stores.EventStream
State:
  - queue: FIFO event queue
  - subscribers: listening connections
  - history: recent events

API:
  - push_event/1
  - subscribe/0
  - get_history/0
```

### Additional GenServers

**ApiKeyStore** - API authentication and key management
**AgentDiscovery** - Auto-discovery of agents from environment
**EnvironmentScanner** - Monitors system environment
**CommandRunner** - Executes slash commands
**DocsStore** - Caches and serves documentation
**SloEngine** - Evaluates SLO rules and targets

## ETS Tables

Fast in-memory storage for frequently accessed data:

| Table | Keys | Purpose |
|-------|------|---------|
| `:agents` | agent_id | Agent registry |
| `:projects` | project_name | Project catalog |
| `:skills` | skill_name | Skill catalog |
| `:metrics` | {entity_type, entity_id} | Metric cache |
| `:sessions` | session_id | Session metadata |
| `:notifications` | notification_id | Recent notifications |
| `:agent_index_by_project` | project_name | Project → agent mapping |
| `:agent_index_by_status` | status | Status → agent mapping |

Created in ConfigLoader init, cleared on reload.

## PubSub Topics

Real-time event broadcasting:

### apm:agents
Agent lifecycle events.

```elixir
{:agent_registered, %Agent{}}
{:agent_updated, %Agent{}}
{:agent_discovered, agent_id, project}
{:agent_heartbeat, agent_id, metrics}
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
{:project_switched, project_name}
```

### apm:tasks
Task execution events.

```elixir
{:tasks_synced, project, tasks}
{:task_started, task_id}
{:task_completed, task_id}
```

### apm:commands
Slash command execution.

```elixir
{:commands_updated, project}
{:command_executed, command, agent_id}
```

### apm:upm
UPM execution tracking.

```elixir
{:upm_session_registered, session}
{:upm_agent_registered, params}
{:upm_event, event}
```

### apm:skills
Skill tracking.

```elixir
{:skill_tracked, %Skill{}}
{:methodology_detected, methodology}
```

### apm:audit
Audit logging.

```elixir
{:audit_entry, %AuditEntry{}}
```

## Error Handling

GenServers use standard Elixir error handling:

- **Init errors**: Logged, supervisor restarts
- **Cast/call errors**: Logged, GenServer continues
- **Subscription errors**: Logged, reconnection attempted
- **File I/O errors**: Logged, operation retried

Errors broadcast to `"apm:notifications"` for UI alert.

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

1. Start with `lib/apm_v4/application.ex` - see supervision tree
2. Explore `lib/apm_v4/stores/` - understand GenServer modules
3. Check `lib/apm_v4_web/` - Phoenix routes and controllers
4. Review `lib/apm_v4_web/live/` - LiveView pages

See [Extending CCEM](extending.md) for adding new features.
