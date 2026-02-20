# REST API Reference

Complete API endpoint documentation for CCEM APM v4. The API uses JSON for request/response bodies and supports both HTTP/REST and WebSocket connections.

## Health & Status

### GET /health
Server health check endpoint (v3-compatible, outside `/api` scope).

```bash
curl http://localhost:3031/health
```

Response:
```json
{
  "status": "ok",
  "uptime": 3600,
  "server_version": "4.0.0",
  "total_projects": 5,
  "active_project": "ccem",
  "projects": [
    {
      "name": "ccem",
      "status": "active",
      "agent_count": 3,
      "session_count": 1
    }
  ]
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
  "uptime": 3600,
  "agent_count": 12,
  "session_id": "session-abc123",
  "server_version": "4.0.0"
}
```

## Agent Management

### GET /api/agents
List all agents, with optional project filter.

```bash
curl 'http://localhost:3031/api/agents?project=ccem'
```

Query params:
- `project` - Filter by project name

Response:
```json
{
  "agents": [
    {
      "id": "agent-abc123",
      "name": "test-generator",
      "status": "active",
      "tier": 2,
      "deps": [],
      "metadata": {},
      "registered_at": "2026-02-19T10:00:00Z",
      "last_heartbeat": "2026-02-19T12:34:56Z"
    }
  ]
}
```

### POST /api/register
Register a new agent (also available at POST /api/agents/register).

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "name": "test-generator",
    "project_name": "ccem",
    "tier": 2,
    "status": "idle",
    "deps": [],
    "metadata": {"language": "swift"},
    "agent_type": "individual",
    "namespace": "testing",
    "story_id": "story-1-1",
    "wave": 1,
    "upm_session_id": "upm-xyz"
  }'
```

Response (201):
```json
{
  "ok": true,
  "agent_id": "agent-abc123"
}
```

### POST /api/heartbeat
Send agent heartbeat (keep-alive / status update).

```bash
curl -X POST http://localhost:3031/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active"
  }'
```

Response:
```json
{"ok": true, "agent_id": "agent-abc123"}
```

Error (404 if agent not found):
```json
{"error": "Agent not found", "agent_id": "agent-abc123"}
```

### POST /api/notify
Send notification.

```bash
curl -X POST http://localhost:3031/api/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Build Complete",
    "message": "All tests passed",
    "level": "success"
  }'
```

Response:
```json
{"ok": true, "id": 1}
```

### POST /api/agents/update
Full agent update (v3-compatible).

```bash
curl -X POST http://localhost:3031/api/agents/update \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active",
    "name": "updated-name"
  }'
```

Response:
```json
{"ok": true, "agent_id": "agent-abc123"}
```

### GET /api/agents/discover
Trigger agent discovery scan.

```bash
curl http://localhost:3031/api/agents/discover
```

Response:
```json
{
  "discovered": [...],
  "count": 3
}
```

## Data Retrieval

### GET /api/data
Master data aggregation endpoint (v3-compatible). Returns agents, tasks, notifications, ralph data, commands, and input requests for a project.

```bash
curl 'http://localhost:3031/api/data?project=ccem'
```

Query params:
- `project` - Project name (defaults to active project)

Response:
```json
{
  "agents": [...],
  "summary": {
    "total": 12,
    "active": 5,
    "idle": 3,
    "error": 1,
    "completed": 2,
    "discovered": 1
  },
  "edges": [{"source": "dep-id", "target": "agent-id"}],
  "tasks": [...],
  "notifications": [...],
  "ralph": {...},
  "commands": [...],
  "input_requests": [...]
}
```

## Notifications

### GET /api/notifications
Get recent notifications.

```bash
curl http://localhost:3031/api/notifications
```

Response: array of notification objects.

### POST /api/notifications/add
Create a new notification (v3-compatible).

```bash
curl -X POST http://localhost:3031/api/notifications/add \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Low Token Budget",
    "body": "Agent analyzer has 5000 tokens remaining",
    "category": "warning"
  }'
```

Response:
```json
{"ok": true, "id": 1}
```

### POST /api/notifications/read-all
Mark all notifications as read.

```bash
curl -X POST http://localhost:3031/api/notifications/read-all
```

Response:
```json
{"ok": true}
```

## Ralph Integration

### GET /api/ralph
Get Ralph methodology data for active project.

```bash
curl 'http://localhost:3031/api/ralph?project=ccem'
```

Query params:
- `project` - Project name (defaults to active project)

Response: Ralph PRD data object (stories, waves, objectives) or empty object if no PRD found.

### GET /api/ralph/flowchart
Get D3.js-compatible flowchart data.

```bash
curl 'http://localhost:3031/api/ralph/flowchart?project=ccem'
```

Response:
```json
{
  "nodes": [...],
  "edges": [...]
}
```

## Commands

### GET /api/commands
Get registered slash commands for a project.

```bash
curl 'http://localhost:3031/api/commands?project=ccem'
```

Response: array of command objects.

### POST /api/commands
Register slash commands for a project.

```bash
curl -X POST http://localhost:3031/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "commands": [
      {"name": "/spawn", "description": "Create new agent"}
    ]
  }'
```

Response:
```json
{"ok": true, "count": 1}
```

## Input/Interaction

### GET /api/input/pending
Get pending user input requests.

```bash
curl http://localhost:3031/api/input/pending
```

Response: array of pending input request objects.

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

Response:
```json
{"ok": true, "id": 1}
```

### POST /api/input/respond
Provide user input response.

```bash
curl -X POST http://localhost:3031/api/input/respond \
  -H "Content-Type: application/json" \
  -d '{
    "id": 1,
    "choice": "yes"
  }'
```

Response:
```json
{"ok": true, "id": 1}
```

## Task Sync

### POST /api/tasks/sync
Replace a project's task list.

```bash
curl -X POST http://localhost:3031/api/tasks/sync \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "tasks": [
      {"id": "CCEM-1", "title": "Add feature", "status": "in_progress"}
    ]
  }'
```

Response:
```json
{"ok": true, "count": 1}
```

## Configuration

### POST /api/config/reload
Reload configuration from file.

```bash
curl -X POST http://localhost:3031/api/config/reload
```

Response:
```json
{"ok": true}
```

### POST /api/reload
Alias for `/api/config/reload`.

```bash
curl -X POST http://localhost:3031/api/reload
```

Response:
```json
{"ok": true}
```

### POST /api/plane/update
Update Plane PM context for a project.

```bash
curl -X POST http://localhost:3031/api/plane/update \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "workspace_slug": "ccem",
    "issues": [...]
  }'
```

Response:
```json
{"ok": true}
```

## Skills

### GET /api/skills
Get skill catalog and analytics. Supports filtering by session or project.

```bash
# Full catalog with co-occurrence
curl http://localhost:3031/api/skills

# Filter by session
curl 'http://localhost:3031/api/skills?session_id=sess-123'

# Filter by project
curl 'http://localhost:3031/api/skills?project=ccem'
```

Response (no filter):
```json
{
  "catalog": {"skill-name": {...}},
  "co_occurrence": [
    {"skill_a": "tdd", "skill_b": "fix-loop", "count": 5}
  ]
}
```

Response (with session_id or project filter):
```json
{
  "skills": [...]
}
```

### POST /api/skills/track
Track skill usage event. Requires `session_id` and `skill`.

```bash
curl -X POST http://localhost:3031/api/skills/track \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "sess-abc123",
    "skill": "test-writing",
    "project": "ccem",
    "args": "--coverage"
  }'
```

Response:
```json
{"ok": true, "session_id": "sess-abc123", "skill": "test-writing"}
```

## Projects

### GET /api/projects
Get all configured projects with agent and session counts.

```bash
curl http://localhost:3031/api/projects
```

Response:
```json
{
  "active_project": "ccem",
  "projects": [
    {
      "name": "ccem",
      "root": "/Users/jeremiah/Developer/ccem",
      "status": "active",
      "tasks_dir": null,
      "prd_json": "/path/to/prd.json",
      "agent_count": 3,
      "session_count": 1
    }
  ]
}
```

### PATCH /api/projects
Update project fields in config.

```bash
curl -X PATCH http://localhost:3031/api/projects \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ccem",
    "status": "active",
    "prd_json": "/new/path/prd.json"
  }'
```

Response:
```json
{"status": "ok"}
```

Error (422):
```json
{"status": "error", "reason": "Project not found"}
```

## Port Management

### GET /api/ports
Get port assignments, ranges, and clash information.

```bash
curl http://localhost:3031/api/ports
```

Response:
```json
{
  "ok": true,
  "ports": {
    "3000": {"project": "lcc", "namespace": "web", "active": true}
  },
  "ranges": {
    "web": {"first": 3000, "last": 3099},
    "api": {"first": 3100, "last": 3199}
  },
  "clashes": []
}
```

### POST /api/ports/scan
Scan for active ports on the system.

```bash
curl -X POST http://localhost:3031/api/ports/scan
```

Response:
```json
{
  "ok": true,
  "active_ports": [...]
}
```

### POST /api/ports/assign
Assign an available port to a project or namespace.

```bash
# By namespace
curl -X POST http://localhost:3031/api/ports/assign \
  -H "Content-Type: application/json" \
  -d '{"namespace": "web"}'

# By project
curl -X POST http://localhost:3031/api/ports/assign \
  -H "Content-Type: application/json" \
  -d '{"project": "my-project"}'
```

Response:
```json
{"ok": true, "port": 3005}
```

Error (422):
```json
{"ok": false, "error": "no available port"}
```

### GET /api/ports/clashes
Detect port clashes across projects.

```bash
curl http://localhost:3031/api/ports/clashes
```

Response:
```json
{
  "ok": true,
  "clashes": [
    {"port": 3000, "projects": ["lcc", "egpt"]}
  ]
}
```

### POST /api/ports/set-primary
Set the primary port for a project with ownership level.

```bash
curl -X POST http://localhost:3031/api/ports/set-primary \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "port": 3031,
    "ownership": "exclusive"
  }'
```

Ownership values: `exclusive`, `shared`, `reserved`.

Response:
```json
{
  "ok": true,
  "project": "ccem",
  "primary_port": 3031,
  "port_ownership": "exclusive"
}
```

## UPM Integration

### POST /api/upm/register
Register UPM execution session.

```bash
curl -X POST http://localhost:3031/api/upm/register \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "title": "Multi-project dashboard",
    "waves": [...]
  }'
```

Response (201):
```json
{"ok": true, "upm_session_id": "upm-abc123"}
```

### POST /api/upm/agent
Register agent with work-item binding.

```bash
curl -X POST http://localhost:3031/api/upm/agent \
  -H "Content-Type: application/json" \
  -d '{
    "upm_session_id": "upm-abc123",
    "agent_id": "agent-xyz789",
    "story_id": "story-1-1"
  }'
```

Response:
```json
{"ok": true}
```

Error (404 if session not found):
```json
{"error": "UPM session not found", "upm_session_id": "upm-abc123"}
```

### POST /api/upm/event
Log UPM lifecycle event.

```bash
curl -X POST http://localhost:3031/api/upm/event \
  -H "Content-Type: application/json" \
  -d '{
    "upm_session_id": "upm-abc123",
    "story_id": "story-1-1",
    "event_type": "progress_update",
    "data": {"progress_percent": 75}
  }'
```

Response:
```json
{"ok": true}
```

### GET /api/upm/status
Get current UPM execution state.

```bash
curl http://localhost:3031/api/upm/status
```

Response:
```json
{
  "active": true,
  "session": {
    "id": "upm-abc123",
    "status": "running",
    "current_wave": 2,
    "total_waves": 4,
    "stories": [...]
  },
  "events": [...]
}
```

## Environment Management

### GET /api/environments
List all Claude Code environments.

```bash
curl http://localhost:3031/api/environments
```

Response:
```json
{
  "environments": [
    {
      "name": "ccem",
      "path": "/Users/jeremiah/Developer/ccem",
      "stack": "elixir",
      "has_claude_md": true,
      "has_git": true,
      "session_count": 1,
      "last_session_date": "2026-02-19",
      "last_modified": "2026-02-19T12:00:00Z"
    }
  ],
  "count": 5
}
```

### GET /api/environments/:name
Get full environment detail.

```bash
curl http://localhost:3031/api/environments/ccem
```

### POST /api/environments/:name/exec
Execute command in environment. Timeout capped at 120 seconds.

```bash
curl -X POST http://localhost:3031/api/environments/ccem/exec \
  -H "Content-Type: application/json" \
  -d '{"command": "mix test", "timeout": 30}'
```

Response:
```json
{
  "exit_code": 0,
  "output": "..."
}
```

Error (403 for dangerous commands):
```json
{"error": "Command rejected as dangerous"}
```

### POST /api/environments/:name/session/start
Launch Claude Code session in environment.

```bash
curl -X POST http://localhost:3031/api/environments/ccem/session/start \
  -H "Content-Type: application/json" \
  -d '{"with_ccem": true}'
```

Response:
```json
{"ok": true, "environment": "ccem", "with_ccem": true}
```

### POST /api/environments/:name/session/stop
Kill Claude Code session in environment.

```bash
curl -X POST http://localhost:3031/api/environments/ccem/session/stop
```

Response:
```json
{"ok": true, "environment": "ccem", "killed": 1}
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
Get fleet metrics.

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

### GET /api/v2/slos/:name
Get specific SLO details.

```bash
curl http://localhost:3031/api/v2/slos/uptime
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
Export APM data as JSON or CSV.

```bash
# JSON export (default)
curl http://localhost:3031/api/v2/export > export.json

# CSV export for specific section
curl 'http://localhost:3031/api/v2/export?format=csv&section=agents' > agents.csv

# Filtered JSON export
curl 'http://localhost:3031/api/v2/export?sections[]=agents&sections[]=sessions&since=2026-02-01T00:00:00Z'
```

Query params:
- `format` - `json` (default) or `csv`
- `section` - Section for CSV export (e.g., `agents`)
- `sections[]` - Array of sections for JSON export
- `since` - ISO8601 datetime filter
- `agent_ids[]` - Filter by agent IDs

### POST /api/v2/import
Import data from JSON.

```bash
curl -X POST http://localhost:3031/api/v2/import \
  -H "Content-Type: application/json" \
  -d @export.json
```

Response:
```json
{"status": "ok", "summary": {...}}
```

## Server-Sent Events

### GET /api/ag-ui/events
Subscribe to real-time AG-UI events (SSE).

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
List available A2UI components (accepts JSON and JSONL).

```bash
curl http://localhost:3031/api/a2ui/components
```

## Error Responses

Endpoints return error information on failure:

```json
{"error": "Agent not found", "agent_id": "unknown"}
```

Status codes:
- 200: Success
- 201: Created (agent registration, UPM session registration)
- 400: Bad request (missing required fields)
- 403: Forbidden (dangerous command rejected)
- 404: Not found
- 422: Unprocessable entity (validation error)
- 500: Server error

## Authentication

API endpoints are protected by the `ApiAuth` plug. API keys are configured via `ApmV4.ApiKeyStore`.

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://localhost:3031/api/status
```
