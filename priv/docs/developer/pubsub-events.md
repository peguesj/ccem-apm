# PubSub Events Reference

CCEM APM uses Phoenix PubSub for real-time event broadcasting. This document describes all topics and events.

## Topic Architecture

PubSub topics are hierarchical strings for organizing events:

```
apm:agents          - Agent lifecycle and updates
apm:notifications   - Alerts and notifications
apm:config          - Configuration changes
apm:tasks           - Task execution
apm:commands        - Slash command execution
apm:upm             - UPM execution tracking
apm:skills          - Skill tracking
apm:audit           - Audit logging
```

## Subscribing to Topics

In LiveView or GenServer:

```elixir
ApmV4.PubSub.subscribe("apm:agents")
ApmV4.PubSub.subscribe("apm:notifications")
```

Unsubscribe:

```elixir
ApmV4.PubSub.unsubscribe("apm:agents")
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
    type: "individual",
    status: "active",
    tier: 2,
    project: "ccem",
    capabilities: ["test-writing", "mock-generation"],
    registered_at: ~U[2026-02-19 12:00:00Z]
  }
}
```

**Broadcast from**: `AgentRegistry.register_agent/1`

### {:agent_updated, agent}
Fired when agent properties change.

```elixir
{
  :agent_updated,
  %{
    id: "agent-abc123",
    status: "active",
    current_task: "Generating tests for UserService",
    progress: 75,
    token_usage: 12500,
    last_heartbeat: ~U[2026-02-19 12:34:56Z]
  }
}
```

**Broadcast from**: `AgentRegistry.heartbeat/2`, `AgentRegistry.update_agent_status/2`

### {:agent_discovered, agent_id, project}
Fired when agent auto-discovered from environment.

```elixir
{
  :agent_discovered,
  "discovered-xyz789",
  "ccem"
}
```

**Broadcast from**: `AgentDiscovery.discover/1`

### {:agent_heartbeat, agent_id, metrics}
Periodic heartbeat with metrics.

```elixir
{
  :agent_heartbeat,
  "agent-abc123",
  %{
    status: "active",
    token_usage: 12500,
    tasks_completed: 5,
    error_rate: 0.02
  }
}
```

**Broadcast from**: `AgentRegistry.heartbeat/2`

## apm:notifications Topic

Alert and notification events.

### {:notification_added, notification}
Fired when new notification created.

```elixir
{
  :notification_added,
  %{
    id: "notif-abc123",
    level: "success",
    title: "Story Completed",
    message: "Create project selector - 3200 tokens",
    created_at: ~U[2026-02-19 12:34:56Z],
    action_url: "/ralph"
  }
}
```

**Broadcast from**: `DashboardStore.add_notification/1`

### :notifications_read
Fired when all notifications marked as read.

```elixir
:notifications_read
```

**Broadcast from**: `DashboardStore.read_all_notifications/0`

## apm:config Topic

Configuration and environment changes.

### {:config_reloaded, config}
Fired when config file reloaded.

```elixir
{
  :config_reloaded,
  %{
    project_name: "ccem",
    project_root: "/Users/jeremiah/Developer/ccem",
    active_project: "ccem",
    port: 3031,
    projects: [...]
  }
}
```

**Broadcast from**: `ConfigLoader.reload_config/0`

### {:project_switched, project_name}
Fired when active project changes.

```elixir
{
  :project_switched,
  "lcc"
}
```

**Broadcast from**: `ConfigLoader.set_active_project/1`

## apm:tasks Topic

Task execution and lifecycle events.

### {:tasks_synced, project, tasks}
Fired when tasks synced from external source (Plane, Linear).

```elixir
{
  :tasks_synced,
  "ccem",
  [
    %{
      id: "CCEM-123",
      title: "Add project selector",
      status: "in_progress",
      assigned_to: "agent-abc123"
    },
    ...
  ]
}
```

**Broadcast from**: `TaskSync.sync_tasks/1`

### {:task_started, task_id}
Fired when task begins.

```elixir
{
  :task_started,
  "CCEM-123"
}
```

**Broadcast from**: `TaskRunner.start_task/1`

### {:task_completed, task_id}
Fired when task completes.

```elixir
{
  :task_completed,
  "CCEM-123"
}
```

**Broadcast from**: `TaskRunner.complete_task/1`

### {:task_failed, task_id, reason}
Fired when task fails.

```elixir
{
  :task_failed,
  "CCEM-123",
  "Compilation error in generated code"
}
```

**Broadcast from**: `TaskRunner.fail_task/2`

## apm:commands Topic

Slash command execution events.

### {:commands_updated, project}
Fired when command list updated for project.

```elixir
{
  :commands_updated,
  "ccem"
}
```

**Broadcast from**: `CommandRegistry.update_commands/1`

### {:command_executed, command, agent_id}
Fired when slash command executed.

```elixir
{
  :command_executed,
  "/spawn",
  "agent-abc123"
}
```

**Broadcast from**: `CommandRunner.execute/2`

## apm:upm Topic

UPM (Unified Project Management) execution tracking.

### {:upm_session_registered, session}
Fired when UPM session created.

```elixir
{
  :upm_session_registered,
  %{
    session_id: "upm-abc123",
    project: "ccem",
    title: "Multi-project dashboard",
    created_at: ~U[2026-02-19 12:00:00Z],
    waves: [...]
  }
}
```

**Broadcast from**: `UpmStore.register_session/1`

### {:upm_agent_registered, params}
Fired when agent assigned to UPM story.

```elixir
{
  :upm_agent_registered,
  %{
    session_id: "upm-abc123",
    agent_id: "agent-xyz789",
    story_id: "story-1-1",
    assigned_at: ~U[2026-02-19 12:30:00Z]
  }
}
```

**Broadcast from**: `UpmStore.register_agent/2`

### {:upm_event, event}
Fired for UPM execution events.

```elixir
{
  :upm_event,
  %{
    session_id: "upm-abc123",
    story_id: "story-1-1",
    agent_id: "agent-xyz789",
    event_type: "progress_update",
    data: %{
      progress_percent: 75,
      tokens_consumed: 1500
    },
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

**Broadcast from**: `UpmStore.log_event/1`

## apm:skills Topic

Skill tracking and analytics.

### {:skill_tracked, skill}
Fired when skill usage logged.

```elixir
{
  :skill_tracked,
  %{
    agent_id: "agent-abc123",
    skill: "test-writing",
    project: "ccem",
    context: %{
      language: "swift",
      test_framework: "XCTest"
    },
    timestamp: ~U[2026-02-19 12:34:56Z]
  }
}
```

**Broadcast from**: `SkillTracker.track_skill/2`

### {:methodology_detected, methodology}
Fired when methodology pattern detected.

```elixir
{
  :methodology_detected,
  %{
    methodology: "tdd",
    confidence: 0.92,
    agents: ["test-gen", "code-writer", "refactorer"],
    active_since: ~U[2026-02-19 10:00:00Z],
    events_count: 45
  }
}
```

Methodologies: `tdd`, `refactor-max`, `fix-loop`

**Broadcast from**: `SkillTracker.detect_methodologies/0`

### {:anomaly_detected, anomaly}
Fired when unusual behavior detected.

```elixir
{
  :anomaly_detected,
  %{
    type: "high_token_spike",
    agent_id: "agent-abc123",
    skill: "analysis",
    normal: 2000,
    observed: 45000,
    timestamp: ~U[2026-02-19 12:34:56Z]
  }
}
```

**Broadcast from**: `SkillTracker.detect_anomalies/0`

## apm:audit Topic

Audit logging for compliance and debugging.

### {:audit_entry, entry}
Fired for all auditable events.

```elixir
{
  :audit_entry,
  %{
    id: "audit-abc123",
    entity_type: "agent",
    entity_id: "agent-xyz789",
    action: "registered",
    actor: "system",
    details: %{type: "individual", tier: 2},
    timestamp: ~U[2026-02-19 12:00:00Z]
  }
}
```

Audited actions:
- Agent registration, update, deletion
- Project switches
- Configuration changes
- Task state changes
- UPM session events

**Broadcast from**: `AuditLog.log/1` (called from various stores)

## Broadcast Example

Broadcasting from GenServer:

```elixir
defmodule ApmV4.Stores.AgentRegistry do
  def register_agent(agent_data) do
    agent = %Agent{...}

    # Store in state...
    :ets.insert(:agents, {agent.id, agent})

    # Broadcast event
    ApmV4.PubSub.broadcast("apm:agents", {:agent_registered, agent})

    {:ok, agent}
  end
end
```

## Event Handling in LiveView

```elixir
defmodule ApmV4Web.DashboardLive do
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ApmV4.PubSub.subscribe("apm:agents")
      ApmV4.PubSub.subscribe("apm:notifications")
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
ApmV4.PubSub.broadcast("apm:agents", {:agent_registered, agent})

# In LiveView test
send(view.pid, {:agent_registered, agent})
```

See [Testing](../developer/architecture.md#testing) for more.
