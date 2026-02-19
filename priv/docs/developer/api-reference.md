# REST API Reference

Complete API endpoint documentation for CCEM APM v4. The API uses JSON for request/response bodies and supports both HTTP/REST and WebSocket connections.

## Health & Status

### GET /health
Server health check endpoint.

```bash
curl http://localhost:3031/health
```

Response:
```json
{
  "status": "ok",
  "timestamp": "2026-02-19T12:00:00Z",
  "version": "4.0.0"
}
```

### GET /api/status
Detailed server status.

```bash
curl http://localhost:3031/api/status
```

Response:
```json
{
  "status": "ok",
  "uptime_seconds": 3600,
  "agents_active": 12,
  "sessions_active": 3,
  "projects_configured": 5
}
```

## Agent Management

### GET /api/agents
List all agents, with optional filters.

```bash
curl 'http://localhost:3031/api/agents?project=ccem&status=active&type=individual'
```

Query params:
- `project` - Filter by project
- `status` - Filter by status (active, idle, error, discovered, completed)
- `type` - Filter by type (individual, squadron, swarm, orchestrator)
- `capability` - Filter by capability
- `tier` - Filter by tier (1, 2, or 3)
- `limit` - Max results (default: 100)

Response:
```json
{
  "agents": [
    {
      "id": "agent-abc123",
      "name": "test-generator",
      "type": "individual",
      "status": "active",
      "tier": 2,
      "project": "ccem",
      "capabilities": ["test-writing", "mock-generation"],
      "registered_at": "2026-02-19T10:00:00Z",
      "last_heartbeat": "2026-02-19T12:34:56Z"
    }
  ],
  "total": 12
}
```

### POST /api/register
Register a new agent.

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-generator",
    "type": "individual",
    "project": "ccem",
    "tier": 2,
    "capabilities": ["test-writing", "mock-generation"],
    "metadata": {"language": "swift"}
  }'
```

Response:
```json
{
  "id": "agent-abc123",
  "name": "test-generator",
  "status": "active",
  "registered_at": "2026-02-19T12:00:00Z"
}
```

### POST /api/heartbeat
Send agent heartbeat (keep-alive).

```bash
curl -X POST http://localhost:3031/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active",
    "token_usage": 12500,
    "current_task": "Generating test for UserService",
    "progress": 75
  }'
```

Response: `{"status": "ok"}`

### POST /api/notify
Send agent notification.

```bash
curl -X POST http://localhost:3031/api/notify \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "level": "warning",
    "message": "Token budget running low"
  }'
```

## Data Retrieval

### GET /api/data
Get aggregated APM data.

```bash
curl http://localhost:3031/api/data?type=metrics
```

Query params:
- `type` - Data type (metrics, agents, sessions, projects)
- `project` - Filter by project
- `timeframe` - Time range (1h, 24h, 7d)

Response:
```json
{
  "timestamp": "2026-02-19T12:00:00Z",
  "data": {...}
}
```

## Notifications

### GET /api/notifications
Get recent notifications.

```bash
curl http://localhost:3031/api/notifications?limit=20
```

Query params:
- `limit` - Max notifications (default: 20, max: 100)
- `level` - Filter by level (info, warning, error, success)

Response:
```json
{
  "notifications": [
    {
      "id": "notif-123",
      "level": "success",
      "title": "Story Completed",
      "message": "Create project selector",
      "created_at": "2026-02-19T12:34:56Z"
    }
  ],
  "total": 45,
  "unread": 3
}
```

### POST /api/notifications/add
Create a new notification.

```bash
curl -X POST http://localhost:3031/api/notifications/add \
  -H "Content-Type: application/json" \
  -d '{
    "level": "warning",
    "title": "Low Token Budget",
    "message": "Agent analyzer has 5000 tokens remaining",
    "duration_seconds": 10
  }'
```

### POST /api/notifications/read-all
Mark all notifications as read.

```bash
curl -X POST http://localhost:3031/api/notifications/read-all
```

## Ralph Integration

### GET /api/ralph
Get Ralph session data.

```bash
curl http://localhost:3031/api/ralph
```

Response:
```json
{
  "project": "ccem",
  "current_objective": "obj-1",
  "progress_percent": 40,
  "active_agents": 3,
  "stories": [...]
}
```

### GET /api/ralph/flowchart
Get flowchart visualization data.

```bash
curl http://localhost:3031/api/ralph/flowchart
```

Response: D3-compatible JSON for rendering.

## Commands

### GET /api/commands
Get available slash commands.

```bash
curl http://localhost:3031/api/commands?project=ccem
```

Response:
```json
{
  "commands": [
    {
      "name": "spawn",
      "description": "Create new agent",
      "syntax": "/spawn [name] [type] [tier]",
      "examples": ["/spawn analyzer individual 2"]
    }
  ]
}
```

### POST /api/commands
Execute a slash command.

```bash
curl -X POST http://localhost:3031/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "command": "/spawn",
    "args": ["analyzer", "individual", "2"],
    "project": "ccem"
  }'
```

## Agent Discovery & Updates

### GET /api/agents/discover
Discover agents from environment.

```bash
curl http://localhost:3031/api/agents/discover?project=ccem
```

### POST /api/agents/register
Register discovered agent formally.

```bash
curl -X POST http://localhost:3031/api/agents/register \
  -H "Content-Type: application/json" \
  -d '{"id": "discovered-123", "name": "analyzer"}'
```

### POST /api/agents/update
Update agent properties.

```bash
curl -X POST http://localhost:3031/api/agents/update \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active",
    "capabilities": ["analysis", "review"]
  }'
```

## Input/Interaction

### GET /api/input/pending
Get pending user input requests.

```bash
curl http://localhost:3031/api/input/pending
```

### POST /api/input/request
Request user input from agent.

```bash
curl -X POST http://localhost:3031/api/input/request \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "prompt": "Confirm test generation?",
    "input_type": "confirmation"
  }'
```

### POST /api/input/respond
Provide user input response.

```bash
curl -X POST http://localhost:3031/api/input/respond \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "input-123",
    "response": "yes"
  }'
```

## Task Sync

### POST /api/tasks/sync
Sync task list with external source (Plane, Linear).

```bash
curl -X POST http://localhost:3031/api/tasks/sync \
  -H "Content-Type: application/json" \
  -d '{"project": "ccem"}'
```

## Configuration

### POST /api/config/reload
Reload configuration from file.

```bash
curl -X POST http://localhost:3031/api/config/reload
```

### POST /api/plane/update
Update Plane PM integration.

```bash
curl -X POST http://localhost:3031/api/plane/update \
  -H "Content-Type: application/json" \
  -d '{"project": "ccem", "workspace_slug": "ccem"}'
```

## Skills

### GET /api/skills
Get skill catalog and analytics.

```bash
curl http://localhost:3031/api/skills
```

Response:
```json
{
  "skills": [
    {
      "skill": "code-review",
      "count": 124,
      "agents": 8,
      "last_used": "2026-02-19T12:34:56Z"
    }
  ],
  "co_occurrence_matrix": {...},
  "detected_methodologies": [...]
}
```

### POST /api/skills/track
Track skill usage event.

```bash
curl -X POST http://localhost:3031/api/skills/track \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "skill": "test-writing",
    "project": "ccem",
    "context": {"language": "swift"}
  }'
```

## Projects

### GET /api/projects
Get all configured projects.

```bash
curl http://localhost:3031/api/projects
```

Response:
```json
{
  "projects": [
    {"name": "ccem", "root": "/path/to/ccem"},
    {"name": "lcc", "root": "/path/to/lcc"}
  ],
  "active": "ccem"
}
```

## UPM Integration

### POST /api/upm/register
Register UPM session.

```bash
curl -X POST http://localhost:3031/api/upm/register \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "title": "Multi-project dashboard",
    "waves": [...]
  }'
```

### POST /api/upm/agent
Assign agent to UPM story.

```bash
curl -X POST http://localhost:3031/api/upm/agent \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "upm-abc123",
    "agent_id": "agent-xyz789",
    "assigned_story": "story-1-1"
  }'
```

### POST /api/upm/event
Log UPM execution event.

```bash
curl -X POST http://localhost:3031/api/upm/event \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "upm-abc123",
    "story_id": "story-1-1",
    "event_type": "progress_update",
    "data": {"progress_percent": 75}
  }'
```

### GET /api/upm/status
Get UPM session status.

```bash
curl http://localhost:3031/api/upm/status?session_id=upm-abc123
```

## Environment Management

### GET /api/environments
List available environments.

```bash
curl http://localhost:3031/api/environments
```

### GET /api/environments/:name
Get environment details.

```bash
curl http://localhost:3031/api/environments/dev
```

### POST /api/environments/:name/exec
Execute command in environment.

```bash
curl -X POST http://localhost:3031/api/environments/dev/exec \
  -H "Content-Type: application/json" \
  -d '{"command": "mix test"}'
```

### POST /api/environments/:name/session/start
Start session in environment.

```bash
curl -X POST http://localhost:3031/api/environments/dev/session/start \
  -H "Content-Type: application/json" \
  -d '{"session_id": "session-123"}'
```

### POST /api/environments/:name/session/stop
Stop session in environment.

```bash
curl -X POST http://localhost:3031/api/environments/dev/session/stop \
  -H "Content-Type: application/json" \
  -d '{"session_id": "session-123"}'
```

## V2 API (Advanced)

### GET /api/v2/agents
List agents with extended data.

```bash
curl http://localhost:3031/api/v2/agents
```

### GET /api/v2/agents/:id
Get agent details with metrics.

```bash
curl http://localhost:3031/api/v2/agents/agent-abc123
```

### GET /api/v2/sessions
List all sessions.

```bash
curl http://localhost:3031/api/v2/sessions
```

### GET /api/v2/metrics
Get system metrics.

```bash
curl http://localhost:3031/api/v2/metrics
```

### GET /api/v2/metrics/:agent_id
Get agent-specific metrics.

```bash
curl http://localhost:3031/api/v2/metrics/agent-abc123
```

### GET /api/v2/slos
List configured SLOs.

```bash
curl http://localhost:3031/api/v2/slos
```

### GET /api/v2/alerts
List active alerts.

```bash
curl http://localhost:3031/api/v2/alerts
```

### GET /api/v2/alerts/rules
Get alert rules.

```bash
curl http://localhost:3031/api/v2/alerts/rules
```

### POST /api/v2/alerts/rules
Create alert rule.

```bash
curl -X POST http://localhost:3031/api/v2/alerts/rules \
  -H "Content-Type: application/json" \
  -d '{"condition": "token_usage > 80000", "action": "escalate"}'
```

### GET /api/v2/audit
Get audit log entries.

```bash
curl http://localhost:3031/api/v2/audit
```

### GET /api/v2/openapi.json
Get OpenAPI specification.

```bash
curl http://localhost:3031/api/v2/openapi.json
```

## Data Export/Import

### GET /api/v2/export
Export all data as JSON.

```bash
curl http://localhost:3031/api/v2/export > export.json
```

### POST /api/v2/import
Import data from JSON.

```bash
curl -X POST http://localhost:3031/api/v2/import \
  -H "Content-Type: application/json" \
  -d @export.json
```

## Server-Sent Events

### GET /api/ag-ui/events
Subscribe to real-time events (SSE).

```bash
curl http://localhost:3031/api/ag-ui/events
```

Streams events as they occur:
```
data: {"type":"agent_registered","agent":"test-gen"}
data: {"type":"agent_updated","agent":"test-gen"}
```

## UI Components

### GET /api/a2ui/components
List available UI components.

```bash
curl http://localhost:3031/api/a2ui/components
```

## Error Responses

All endpoints return standard error format on failure:

```json
{
  "error": "Invalid project",
  "message": "Project 'unknown' not found in configuration",
  "status": 400,
  "timestamp": "2026-02-19T12:00:00Z"
}
```

Status codes:
- 200: Success
- 400: Bad request
- 401: Unauthorized
- 404: Not found
- 429: Rate limited
- 500: Server error

## Rate Limiting

- Heartbeats: 1 per second per agent
- Agent registration: 10 per minute per project
- API calls: 100 per minute per client IP

Returns HTTP 429 when exceeded with `Retry-After` header.

## Authentication

Some endpoints require API key:

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://localhost:3031/api/secure/endpoint
```

API keys configured in `apm_config.json`.
