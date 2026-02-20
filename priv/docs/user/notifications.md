# Notifications System

CCEM APM's notification system alerts users to important events: agent status changes, task completions, errors, and system messages.

## Overview

The notification system provides:

- **Real-time Alerts**: Instant notification of important events
- **Severity Levels**: Info, warning, error, and success classifications
- **Bell Icon**: Quick access to notification history
- **Auto-dismiss**: Temporary notifications disappear after delay
- **Persistent Alerts**: Critical notifications remain until acknowledged

## Notification Levels

### Info
Informational messages about normal operation.

```json
{
  "level": "info",
  "title": "Agent Registered",
  "message": "test-generator (individual, tier 2) joined the fleet",
  "icon": "info-circle"
}
```

Auto-dismisses after 5 seconds.

### Warning
Non-critical issues requiring attention.

```json
{
  "level": "warning",
  "title": "Low Token Budget",
  "message": "Agent analyzer has only 5000 tokens remaining",
  "icon": "alert-triangle",
  "action": "View agent"
}
```

Auto-dismisses after 10 seconds, or click to act.

### Error
Critical issues preventing operation.

```json
{
  "level": "error",
  "title": "Agent Error",
  "message": "Agent refactor-squad encountered compilation error in src/main.swift",
  "icon": "alert-circle",
  "action": "View details"
}
```

Persists until user dismisses or takes action.

### Success
Operation completed successfully.

```json
{
  "level": "success",
  "title": "Story Completed",
  "message": "story-1-1: Create project selector (3200 tokens used)",
  "icon": "check-circle"
}
```

Auto-dismisses after 5 seconds.

## Bell Icon

Located in top navigation, the bell icon shows:

- **Unread count badge**: Number of unread notifications
- **Click to open**: Reveals notification drawer with history
- **Color code**: Matches notification levels
  - Gray: Info
  - Yellow: Warning
  - Red: Error
  - Green: Success

The notification drawer shows:
- Up to 20 most recent notifications
- Timestamp for each
- Original message and action
- "Clear All" button to dismiss all

## Adding Notifications

### POST /api/notifications/add

Create a new notification:

```bash
curl -X POST http://localhost:3031/api/notifications/add \
  -H "Content-Type: application/json" \
  -d '{
    "level": "warning",
    "title": "Low Token Budget",
    "message": "Agent analyzer has 5000 tokens remaining",
    "icon": "alert-triangle",
    "duration_seconds": 10,
    "action_url": "/agents/agent-xyz789"
  }'
```

### Parameters

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| **level** | string | Yes | info, warning, error, or success |
| **title** | string | Yes | Short notification title |
| **message** | string | Yes | Detailed message |
| **icon** | string | No | Icon name (info-circle, alert-triangle, etc.) |
| **duration_seconds** | integer | No | How long to show (default: level-dependent) |
| **action_url** | string | No | URL to navigate when clicked |
| **action_label** | string | No | Button label (default: "View") |

### Default Durations

- **info**: 5 seconds
- **warning**: 10 seconds
- **error**: 30 seconds (or until dismissed)
- **success**: 5 seconds

## Clearing Notifications

### POST /api/notifications/read-all

Mark all notifications as read:

```bash
curl -X POST http://localhost:3031/api/notifications/read-all
```

This clears the unread badge on the bell icon.

## Built-in Notifications

CCEM APM automatically generates notifications for:

### Agent Events
- Agent registered
- Agent status changed (active → idle, etc.)
- Agent encountered error
- Agent completed task
- Agent started new task

### Task Events
- Task started
- Task completed successfully
- Task blocked or failed
- Subtask milestone reached

### Story Events
- Story started
- Story completed
- Story blocked
- Acceptance criteria milestone

### System Events
- Server health issues
- Configuration reloaded
- Port changes
- New project added
- Project switched

### Ralph/UPM Events
- Wave started
- Story assigned to agent
- Escalation triggered
- Methodology detected
- Objective completed

## Example Notifications

### Agent Registration

```text
TITLE: Agent Registered
MESSAGE: test-generator (individual, tier 2) joined the fleet in project ccem
LEVEL: info
DURATION: 5 seconds
```

### Story Completion

```text
TITLE: Story Completed
MESSAGE: Create project selector - 3200 tokens consumed (estimate: 3000)
LEVEL: success
DURATION: 5 seconds
ACTION: View in Ralph
```

### Error Alert

```text
TITLE: Compilation Error
MESSAGE: Agent refactor-squad encountered error in src/views/menu_bar_view.swift:42
LEVEL: error
DURATION: Persist until dismissed
ACTION: View details
```

### Low Token Budget

```text
TITLE: Agent Low on Tokens
MESSAGE: Agent analyzer has 5000 tokens remaining (budget: 100000)
LEVEL: warning
DURATION: 10 seconds
ACTION: Review usage
```

## Notification Drawer

Click the bell icon to open the drawer:

### Recent Notifications

Shows up to 20 notifications in reverse chronological order:

```text
2026-02-19 12:34:56  ✓ Story completed
2026-02-19 12:32:10  ⚠ Low token budget
2026-02-19 12:30:45  → Agent updated
2026-02-19 12:28:33  ✓ Agent registered
```

### Actions

- **Click notification**: Navigate to relevant resource
- **Click X**: Dismiss single notification
- **Clear All**: Dismiss all notifications

## Sound & Visual Cues

Optional (configurable per user):

- **Error level**: Bell sound + red flash
- **Warning level**: Subtle sound + yellow flash
- **Success level**: Chime sound + green flash

Can be disabled in browser preferences.

## Notification Preferences

Users can customize notification behavior:

- **Show alerts**: Toggle on/off
- **Sound**: Enable/disable notification sounds
- **Duration**: Adjust auto-dismiss timing
- **Levels to show**: Filter which levels appear

Preferences stored in browser local storage per user.

## Best Practices

1. **Timely Alerts**: Notify immediately on critical events
2. **Actionable Messages**: Include clear next steps
3. **Avoid Spam**: Batch related notifications when possible
4. **Clear Titles**: Keep titles under 50 characters
5. **Contextual Links**: Include action URLs to relevant pages

## Troubleshooting

**Notifications not appearing?**
- Check browser notifications permission
- Verify WebSocket connection (DevTools Network)
- Refresh page (Cmd+R)

**Sound not playing?**
- Check system volume
- Verify browser notification sounds enabled
- Check browser privacy settings

**Notification drawer empty?**
- Notifications may have auto-dismissed
- Check if clear-all was clicked
- Refresh to reload notification history

**Spam notifications?**
- Check if multiple agents registering
- Review agent heartbeat frequency
- Consider batching events

See [API Reference](../developer/api-reference.md) for complete notification endpoints.

---

## See Also

- [Dashboard Guide](/docs/user/dashboard) - Using the web interface
- [API Reference](/docs/developer/api-reference) - Complete endpoint documentation
