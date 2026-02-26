# UPM - Unified Project Management

> **Prerequisite:** Understand [Ralph Methodology](/docs/user/ralph) and [Agent Fleet](/docs/user/agents) before using UPM, as it integrates with both systems.

UPM (Unified Project Management) is CCEM APM's integration layer for tracking multi-agent project execution across Claude Code sessions. It captures waves of work, individual stories, and detailed execution events.

## Overview

UPM provides:

- **Wave-Based Organization**: Group stories into logical work phases
- **Story Tracking**: Individual task tracking with metadata
- **Event Logging**: Detailed execution timeline
- **Integration with Ralph**: Seamless handoff to Ralph methodology
- **Status Reporting**: Real-time progress visibility

## Core Concepts

### Waves

Waves are logical groupings of stories, typically representing phases:

- Wave 1: Foundation / Setup
- Wave 2: Core Features
- Wave 3: Polish / Testing
- Wave 4: Deployment

### Stories

Individual work items within a wave:

- Title and description
- Assigned tier and agent
- Token estimates
- Status and progress

### Events

Execution timeline entries tracking:

- Status changes (started, completed, error)
- Agent transitions
- Token consumption
- Milestone achievements

## UPM Session Registration

### POST /api/upm/register

Register a new UPM session to begin tracking work:

```bash
curl -X POST http://localhost:3031/api/upm/register \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "title": "Multi-project dashboard refactor",
    "description": "Redesign dashboard for multi-project support",
    "waves": [
      {
        "id": "wave-1",
        "title": "Foundation",
        "stories": [
          {
            "id": "story-1-1",
            "title": "Create project selector",
            "estimate_tokens": 3000
          }
        ]
      }
    ]
  }'
```

Response:

```json
{
  "session_id": "upm-session-abc123",
  "created_at": "2026-02-19T12:00:00Z",
  "project": "ccem",
  "status": "active"
}
```

## Wave Structure

Each wave contains an ID, title, status, and its stories:

```json
{
  "id": "wave-1",
  "title": "Foundation",
  "description": "Initial project setup",
  "status": "not_started",
  "start_time": "2026-02-19T12:00:00Z",
  "end_time": null,
  "stories": [
    {
      "id": "story-1-1",
      "title": "Create project selector",
      "description": "Add dropdown to select projects",
      "estimate_tokens": 3000,
      "assigned_tier": 2,
      "status": "not_started"
    }
  ],
  "progress_percent": 0
}
```

## Story Structure

Each story tracks title, criteria, tokens, and assignment:

```json
{
  "id": "story-1-1",
  "title": "Create project selector",
  "description": "Add dropdown to select active project",
  "acceptance_criteria": [
    "Appears in top navigation",
    "Shows all projects from config",
    "Updates on selection"
  ],
  "estimate_tokens": 3000,
  "actual_tokens": 0,
  "assigned_tier": 2,
  "assigned_agent": null,
  "status": "not_started",
  "progress_percent": 0,
  "subtasks": []
}
```

> **Tip:** Keep 3-5 stories per wave. Larger waves become difficult to track and increase the risk of blocked dependencies.

## Assigning Agents to UPM Stories

### POST /api/upm/agent

Register an agent to work on a specific UPM story:

```bash
curl -X POST http://localhost:3031/api/upm/agent \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "upm-session-abc123",
    "agent_id": "agent-xyz789",
    "agent_name": "code-generator",
    "assigned_story": "story-1-1",
    "capabilities": ["code-writing", "testing"]
  }'
```

The agent begins work on the assigned story. Progress updates are tracked automatically.

## Event Logging

### POST /api/upm/event

Log execution events to build the timeline:

```bash
curl -X POST http://localhost:3031/api/upm/event \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "upm-session-abc123",
    "story_id": "story-1-1",
    "agent_id": "agent-xyz789",
    "event_type": "progress_update",
    "data": {
      "progress_percent": 75,
      "tokens_consumed": 1500,
      "current_task": "Implementing dropdown component"
    }
  }'
```

### Event Types Reference

| Type | Description |
| :--- | :--- |
| **story_started** | Agent begins work on story |
| **progress_update** | Periodic status update with tokens/progress |
| **subtask_completed** | Sub-task milestone completed |
| **story_completed** | Story finished, all criteria met |
| **story_blocked** | Story blocked, waiting for dependency |
| **agent_error** | Error encountered, agent paused |
| **agent_transition** | New agent takes over story |
| **milestone_reached** | Wave milestone achieved |
| **wave_completed** | All stories in wave finished |

## Querying UPM Status

### GET /api/upm/status

Get current UPM session status:

```bash
curl http://localhost:3031/api/upm/status?session_id=upm-session-abc123
```

Response:

```json
{
  "session_id": "upm-session-abc123",
  "project": "ccem",
  "status": "in_progress",
  "created_at": "2026-02-19T12:00:00Z",
  "waves": [
    {
      "id": "wave-1",
      "title": "Foundation",
      "status": "in_progress",
      "progress_percent": 50,
      "stories": [
        {
          "id": "story-1-1",
          "title": "Create project selector",
          "status": "completed",
          "progress_percent": 100,
          "tokens_used": 3200
        }
      ]
    }
  ],
  "total_progress_percent": 35,
  "total_tokens_used": 5600,
  "estimated_tokens_remaining": 15000
}
```

## UPM Dashboard Panel

In the right sidebar of the main dashboard:

### Wave Summary

- Wave name and status
- Progress bar
- Story count (completed/total)

### Current Story View

- Story title and description
- Assigned agent
- Progress percentage
- Tokens used / estimated
- Acceptance criteria checklist

### Event Timeline

Recent events in reverse chronological order:

```text
2 mins ago  - story-1 completed (3200 tokens)
5 mins ago  - Agent generator assigned to story-1
8 mins ago  - Wave 1 started
```

## Integration with Ralph

UPM data flows into Ralph:

1. **UPM Registration**: Creates Ralph objectives and stories
2. **Event Logging**: Updates Ralph story status
3. **Agent Assignment**: Links UPM agents to Ralph agents
4. **Progress Tracking**: Synchronizes progress metrics

> **Important:** For seamless integration, ensure the UPM session project matches the Ralph `prd.json` project, wave IDs align with the Ralph objective structure, and agent tiers match the story `assigned_tier`.

## Best Practices

1. **Wave Granularity**: 3-5 stories per wave
2. **Realistic Estimates**: Use historical data to inform token estimates
3. **Regular Events**: Log events at least every 5 minutes
4. **Clear Descriptions**: Write detailed story descriptions
5. **Acceptance Criteria**: Make criteria specific and measurable
6. **Agent Assignment**: Assign agents by tier, not individual preference
7. **Milestone Tracking**: Log wave completions as milestones

## Troubleshooting

### UPM Session Not Starting

- Verify project is in apm_config.json
- Check POST /api/upm/register request format
- Review server logs

### Stories Not Appearing in Dashboard

- Refresh page (Cmd+R)
- Verify session_id in UPM panel matches current session
- Check WebSocket connection

### Agent Not Assigned to Story

- POST /api/upm/agent with correct session_id and story_id
- Verify agent exists and is active
- Check response for error messages

### Progress Not Updating

- Send progress_update events regularly
- Include story_id and agent_id
- Verify tokens_consumed is increasing

See [API Reference](/docs/developer/api-reference) for complete UPM endpoints.

---

## See Also

- [Ralph Methodology](/docs/user/ralph) - Autonomous workflow execution
- [Agent Fleet](/docs/user/agents) - Understanding agent types and statuses
- [Skills Analytics](/docs/user/skills) - Skill usage and co-occurrence
