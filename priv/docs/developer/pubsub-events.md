# PubSub Events Reference

CCEM APM uses Phoenix PubSub for real-time event broadcasting. This document describes all topics and events.

## Topic Architecture

PubSub topics are hierarchical strings for organizing events:

```
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

In LiveView or GenServer:

```elixir
Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:notifications")
```

## apm:agents Topic

Agent lifecycle and status events.

### {:agent_registered, agent}
Fired when new agent registers.

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

**Broadcast from**: `ApmV4.AgentRegistry` in `handle_cast(:register_agent, ...)`

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

**Broadcast from**: `ApmV4.AgentRegistry` in `handle_cast(:update_status, ...)` and `handle_cast(:update_agent, ...)`

### {:agent_discovered, agent_id, project}
Fired when agent auto-discovered from environment.

```elixir
{
  :agent_discovered,
  "discovered-xyz789",
  "ccem"
}
```

**Broadcast from**: `ApmV4.AgentDiscovery`

## apm:notifications Topic

Alert and notification events.

### {:notification_added, notification}
Fired when new notification created.

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

**Broadcast from**: `ApmV4.AgentRegistry.add_notification/1`

### :notifications_read
Fired when all notifications marked as read.

```elixir
:notifications_read
```

**Broadcast from**: `ApmV4.AgentRegistry.mark_all_read/0`

## apm:config Topic

Configuration and environment changes.

### {:config_reloaded, config}
Fired when config file reloaded or project updated.

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

**Broadcast from**: `ApmV4.ConfigLoader.reload/0` and `ApmV4Web.ApiController.update_project/2`

## apm:tasks Topic

Task execution and lifecycle events.

### {:tasks_synced, project, tasks}
Fired when tasks synced via the API.

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

**Broadcast from**: `ApmV4.ProjectStore.sync_tasks/2`

## apm:commands Topic

Slash command registration events.

### {:commands_updated, project}
Fired when command list updated for project.

```elixir
{
  :commands_updated,
  "ccem"
}
```

**Broadcast from**: `ApmV4.ProjectStore.register_commands/2`

## apm:upm Topic

UPM (Unified Project Management) execution tracking.

### {:upm_session_registered, session}
Fired when UPM session created.

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

**Broadcast from**: `ApmV4.UpmStore.register_session/1`

### {:upm_agent_registered, params}
Fired when agent assigned to UPM story.

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

**Broadcast from**: `ApmV4.UpmStore.register_agent/1`

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

Event types:
- `story_started` - Work on story begins
- `progress_update` - Periodic progress with tokens
- `subtask_completed` - Milestone reached
- `story_completed` - All acceptance criteria met
- `story_blocked` - Waiting for dependency
- `agent_error` - Agent paused with error
- `agent_transition` - New agent takes over
- `milestone_reached` - Wave milestone
- `wave_completed` - All stories in wave done

**Broadcast from**: `ApmV4.UpmStore.record_event/1`

### {:formation_registered, formation}
Fired when a new formation is registered.

**Broadcast from**: `ApmV4.UpmStore`

### {:formation_updated, formation}
Fired when a formation is updated.

**Broadcast from**: `ApmV4.UpmStore`

## apm:skills Topic

Skill tracking and analytics.

### {:skill_tracked, session_id, skill_name}
Fired when skill usage logged.

```elixir
{
  :skill_tracked,
  "session-abc123",
  "test-writing"
}
```

**Broadcast from**: `ApmV4.SkillTracker.track_skill/4`

## apm:audit Topic

Audit logging for compliance and debugging.

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

**Broadcast from**: `ApmV4.AuditLog`

## apm:alerts Topic

Alert rule engine events.

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

**Broadcast from**: `ApmV4.AlertRulesEngine`

## apm:environments Topic

Environment scanning events.

### {:environments_updated, count}
Fired when environment scan completes.

```elixir
{:environments_updated, 12}
```

**Broadcast from**: `ApmV4.EnvironmentScanner`

## apm:input Topic

User input request and response events.

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

**Broadcast from**: `ApmV4.ProjectStore.add_input_request/1`

### {:input_responded, input}
Fired when user responds to an input request.

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

**Broadcast from**: `ApmV4.ProjectStore.respond_to_input/2`

## apm:plane Topic

Plane PM integration events.

### {:plane_updated, project_name}
Fired when Plane PM data is updated for a project.

```elixir
{:plane_updated, "ccem"}
```

**Broadcast from**: `ApmV4.ProjectStore.update_plane/2`

## apm:metrics Topic

Fleet metrics events.

### {:fleet_metrics_updated, metrics}
Fired when fleet-wide metrics are recalculated.

```elixir
{:fleet_metrics_updated, %{total_agents: 12, active: 5, ...}}
```

**Broadcast from**: `ApmV4.MetricsCollector`

## apm:slos Topic

SLO status transition events.

### {:slo_transition, sli_name, old_status, new_status}
Fired when an SLO transitions between statuses.

```elixir
{:slo_transition, "agent_uptime", :healthy, :degraded}
```

**Broadcast from**: `ApmV4.SloEngine`

## apm:ag_ui Topic

AG-UI Server-Sent Events for real-time streaming.

### {:ag_ui_event, event}
Fired for AG-UI compatible events.

**Broadcast from**: `ApmV4.EventStream`

## Broadcast Example

Broadcasting from a GenServer:

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

## Event Handling in LiveView

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

## Event Ordering

- Events are delivered in order per client connection
- No guarantee of global ordering across multiple clients
- For critical ordering, use timestamps

## Performance Considerations

- High-frequency events (heartbeats) may be throttled
- Subscribe only to needed topics
- Filter events early (in handle_info) to avoid re-rendering
- Batch related events when possible

## Testing Events

In tests, broadcast directly:

```elixir
Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:agents", {:agent_registered, agent})

# In LiveView test
send(view.pid, {:agent_registered, agent})
```

See [Architecture](architecture.md) for system design details.
