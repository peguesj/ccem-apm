# PubSub Events Reference

CCEM APM uses Phoenix PubSub for real-time event broadcasting. This document describes all topics and events.

## Topic Architecture

PubSub topics are hierarchical strings for organizing events.

All available topics:

```text
apm:agents          - Agent lifecycle and updates
apm:notifications   - Alerts and notifications
apm:config          - Configuration changes
apm:tasks           - Task execution
apm:commands        - Slash command registration
apm:upm             - UPM execution tracking
apm:skills          - Skill tracking
apm:audit           - Audit logging
apm:alerts          - Alert rule engine
apm:environments    - Environment scanning
apm:input           - User input requests/responses
apm:plane           - Plane PM integration
apm:metrics         - Fleet metrics
apm:slos            - SLO status transitions
apm:ag_ui           - AG-UI Server-Sent Events
apm:ports           - Port assignment events
```

## Subscribing to Topics

Subscribe in a LiveView mount or GenServer init.

```elixir
Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:notifications")
```

> **Pattern:** Use `Phoenix.PubSub.subscribe/2` in `mount/3` guarded by `connected?(socket)` to receive real-time updates without double-subscribing during static render.

## apm:agents Topic

Agent lifecycle and status events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:agent_registered, agent}` | Agent map | `AgentRegistry.handle_cast(:register_agent)` |
| `{:agent_updated, agent}` | Agent map | `AgentRegistry.handle_cast(:update_status / :update_agent)` |
| `{:agent_discovered, agent_id, project}` | Agent ID string, project string | `AgentDiscovery` |

### {:agent_registered, agent}

Fired when a new agent registers.

```elixir
{
  :agent_registered,
  %{
    id: "agent-abc123",
    name: "test-generator",
    status: "idle",
    tier: 2,
    deps: [],
    metadata: %{},
    registered_at: ~U[2026-02-19 12:00:00Z]
  }
}
```

### {:agent_updated, agent}

Fired when agent status or properties change.

```elixir
{
  :agent_updated,
  %{
    id: "agent-abc123",
    status: "active",
    last_heartbeat: ~U[2026-02-19 12:34:56Z]
  }
}
```

### {:agent_discovered, agent_id, project}

Fired when an agent is auto-discovered from the environment.

```elixir
{
  :agent_discovered,
  "discovered-xyz789",
  "ccem"
}
```

## apm:notifications Topic

Alert and notification events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:notification_added, notification}` | Notification map | `AgentRegistry.add_notification/1` |
| `:notifications_read` | (none) | `AgentRegistry.mark_all_read/0` |

### {:notification_added, notification}

Fired when a new notification is created.

```elixir
{
  :notification_added,
  %{
    id: 1,
    level: "success",
    title: "Story Completed",
    message: "Create project selector - 3200 tokens",
    created_at: ~U[2026-02-19 12:34:56Z]
  }
}
```

### :notifications_read

Fired when all notifications are marked as read.

```elixir
:notifications_read
```

## apm:config Topic

Configuration and environment changes.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:config_reloaded, config}` | Config map | `ConfigLoader.reload/0`, `ApiController.update_project/2` |

### {:config_reloaded, config}

Fired when the config file is reloaded or a project is updated.

```elixir
{
  :config_reloaded,
  %{
    "project_name" => "ccem",
    "project_root" => "/Users/jeremiah/Developer/ccem",
    "active_project" => "ccem",
    "projects" => [...]
  }
}
```

## apm:tasks Topic

Task execution and lifecycle events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:tasks_synced, project, tasks}` | Project string, task list | `ProjectStore.sync_tasks/2` |

### {:tasks_synced, project, tasks}

Fired when tasks are synced via the API.

```elixir
{
  :tasks_synced,
  "ccem",
  [
    %{
      "id" => "CCEM-123",
      "title" => "Add project selector",
      "status" => "in_progress"
    }
  ]
}
```

## apm:commands Topic

Slash command registration events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:commands_updated, project}` | Project string | `ProjectStore.register_commands/2` |

### {:commands_updated, project}

Fired when the command list is updated for a project.

```elixir
{
  :commands_updated,
  "ccem"
}
```

## apm:upm Topic

UPM (Unified Project Management) execution tracking.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:upm_session_registered, session}` | Session map | `UpmStore.register_session/1` |
| `{:upm_agent_registered, params}` | Params map | `UpmStore.register_agent/1` |
| `{:upm_event, event}` | Event map | `UpmStore.record_event/1` |
| `{:formation_registered, formation}` | Formation map | `UpmStore` |
| `{:formation_updated, formation}` | Formation map | `UpmStore` |

### {:upm_session_registered, session}

Fired when a UPM session is created.

```elixir
{
  :upm_session_registered,
  %{
    id: "upm-abc123",
    project: "ccem",
    title: "Multi-project dashboard",
    created_at: ~U[2026-02-19 12:00:00Z],
    waves: [...]
  }
}
```

### {:upm_agent_registered, params}

Fired when an agent is assigned to a UPM story.

```elixir
{
  :upm_agent_registered,
  %{
    "upm_session_id" => "upm-abc123",
    "agent_id" => "agent-xyz789",
    "story_id" => "story-1-1"
  }
}
```

### {:upm_event, event}

Fired for UPM execution events.

```elixir
{
  :upm_event,
  %{
    upm_session_id: "upm-abc123",
    story_id: "story-1-1",
    event_type: "progress_update",
    data: %{"progress_percent" => 75},
    timestamp: ~U[2026-02-19 12:34:56Z]
  }
}
```

Supported event types:
- `story_started` -- Work on story begins
- `progress_update` -- Periodic progress with tokens
- `subtask_completed` -- Milestone reached
- `story_completed` -- All acceptance criteria met
- `story_blocked` -- Waiting for dependency
- `agent_error` -- Agent paused with error
- `agent_transition` -- New agent takes over
- `milestone_reached` -- Wave milestone
- `wave_completed` -- All stories in wave done

### {:formation_registered, formation}

Fired when a new formation is registered.

### {:formation_updated, formation}

Fired when a formation is updated.

## apm:skills Topic

Skill tracking and analytics.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:skill_tracked, session_id, skill_name}` | Session ID string, skill name string | `SkillTracker.track_skill/4` |

### {:skill_tracked, session_id, skill_name}

Fired when skill usage is logged.

```elixir
{
  :skill_tracked,
  "session-abc123",
  "test-writing"
}
```

## apm:audit Topic

Audit logging for compliance and debugging.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:audit_event, event}` | Event map | `AuditLog` |

### {:audit_event, event}

Fired for all auditable events.

```elixir
{
  :audit_event,
  %{
    entity_type: "agent",
    entity_id: "agent-xyz789",
    action: "registered",
    actor: "system",
    details: %{type: "individual", tier: 2},
    timestamp: ~U[2026-02-19 12:00:00Z]
  }
}
```

## apm:alerts Topic

Alert rule engine events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:alert_fired, alert}` | Alert map | `AlertRulesEngine` |

### {:alert_fired, alert}

Fired when an alert rule condition is met.

```elixir
{
  :alert_fired,
  %{
    rule_name: "high_token_usage",
    severity: "warning",
    message: "Token usage exceeded threshold",
    timestamp: ~U[2026-02-19 12:34:56Z]
  }
}
```

## apm:environments Topic

Environment scanning events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:environments_updated, count}` | Integer count | `EnvironmentScanner` |

### {:environments_updated, count}

Fired when an environment scan completes.

```elixir
{:environments_updated, 12}
```

## apm:input Topic

User input request and response events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:input_requested, input}` | Input map | `ProjectStore.add_input_request/1` |
| `{:input_responded, input}` | Input map | `ProjectStore.respond_to_input/2` |

### {:input_requested, input}

Fired when an agent requests user input.

```elixir
{
  :input_requested,
  %{
    id: 1,
    agent_id: "agent-abc123",
    prompt: "Confirm deployment?",
    input_type: "confirmation"
  }
}
```

### {:input_responded, input}

Fired when the user responds to an input request.

```elixir
{
  :input_responded,
  %{
    id: 1,
    choice: "yes",
    responded_at: ~U[2026-02-19 12:35:00Z]
  }
}
```

## apm:plane Topic

Plane PM integration events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:plane_updated, project_name}` | Project name string | `ProjectStore.update_plane/2` |

### {:plane_updated, project_name}

Fired when Plane PM data is updated for a project.

```elixir
{:plane_updated, "ccem"}
```

## apm:metrics Topic

Fleet metrics events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:fleet_metrics_updated, metrics}` | Metrics map | `MetricsCollector` |

### {:fleet_metrics_updated, metrics}

Fired when fleet-wide metrics are recalculated.

```elixir
{:fleet_metrics_updated, %{total_agents: 12, active: 5, ...}}
```

## apm:slos Topic

SLO status transition events.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:slo_transition, sli_name, old_status, new_status}` | SLI name atom, old status atom, new status atom | `SloEngine` |

### {:slo_transition, sli_name, old_status, new_status}

Fired when an SLO transitions between statuses.

```elixir
{:slo_transition, "agent_uptime", :healthy, :degraded}
```

## apm:ag_ui Topic

AG-UI Server-Sent Events for real-time streaming.

| Event | Payload | Source |
|:------|:--------|:-------|
| `{:ag_ui_event, event}` | Event map | `EventStream` |

### {:ag_ui_event, event}

Fired for AG-UI compatible events streamed via SSE.

## Broadcasting Events

Example of broadcasting from a GenServer:

```elixir
defmodule ApmV4.AgentRegistry do
  def register_agent(agent_id, metadata, project_name) do
    GenServer.cast(__MODULE__, {:register_agent, agent_id, metadata, project_name})
  end

  def handle_cast({:register_agent, agent_id, metadata, project_name}, state) do
    agent = build_agent(agent_id, metadata, project_name)

    # Store in ETS
    :ets.insert(:agents, {agent.id, agent})

    # Broadcast event
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:agents", {:agent_registered, agent})

    {:noreply, state}
  end
end
```

## Handling Events in LiveView

Example of subscribing and handling events in a LiveView page:

```elixir
defmodule ApmV4Web.DashboardLive do
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:notifications")
    end

    {:ok, socket}
  end

  def handle_info({:agent_registered, agent}, socket) do
    # Handle new agent
    agents = [agent | socket.assigns.agents]
    {:noreply, assign(socket, :agents, agents)}
  end

  def handle_info({:notification_added, notif}, socket) do
    # Handle notification
    {:noreply, assign(socket, :latest_notification, notif)}
  end
end
```

> **Warning:** Never call GenServer directly from LiveView render -- use assigns. Store data in socket assigns via `handle_info` and reference assigns in templates.

## Event Ordering

- Events are delivered in order per client connection
- No guarantee of global ordering across multiple clients
- For critical ordering, use timestamps

## Performance Considerations

- High-frequency events (heartbeats) may be throttled
- Subscribe only to needed topics
- Filter events early (in handle_info) to avoid re-rendering
- Batch related events when possible

## Testing PubSub Events

Broadcast directly in tests to simulate events:

```elixir
Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:agents", {:agent_registered, agent})
```

In LiveView tests, send messages directly to the view process:

```elixir
send(view.pid, {:agent_registered, agent})
```

See [Architecture](architecture.md) for system design details.
