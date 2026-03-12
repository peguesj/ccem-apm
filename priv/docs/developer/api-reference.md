# REST API Reference

Complete API endpoint documentation for CCEM APM v4. The API uses JSON for request/response bodies and supports both HTTP/REST and WebSocket connections.

## Health and Status Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/health` | Server health check (v3-compatible) |
| GET | `/api/status` | Detailed server status |

### GET /health

Server health check endpoint (v3-compatible, outside `/api` scope).

Example request:

```bash
curl http://localhost:3032/health
```

Example response:

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

Detailed server status with session information.

Example request:

```bash
curl http://localhost:3032/api/status
```

Example response:

```json
{
  "status": "ok",
  "uptime": 3600,
  "agent_count": 12,
  "session_id": "session-abc123",
  "server_version": "4.0.0"
}
```

## Agent Management Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/agents` | List all agents (optional project filter) |
| POST | `/api/register` | Register a new agent |
| POST | `/api/heartbeat` | Send agent heartbeat / keep-alive |
| POST | `/api/notify` | Send notification |
| POST | `/api/agents/update` | Full agent update (v3-compatible) |
| GET | `/api/agents/discover` | Trigger agent discovery scan |

### GET /api/agents

List all agents, with optional project filter.

Example request:

```bash
curl 'http://localhost:3032/api/agents?project=ccem'
```

Query params:
- `project` -- Filter by project name

Example response:

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

Example request:

```bash
curl -X POST http://localhost:3032/api/register \
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

Example request:

```bash
curl -X POST http://localhost:3032/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active"
  }'
```

Success response:

```json
{"ok": true, "agent_id": "agent-abc123"}
```

Error response (404 if agent not found):

```json
{"error": "Agent not found", "agent_id": "agent-abc123"}
```

### POST /api/notify

Send a notification to the dashboard.

Example request:

```bash
curl -X POST http://localhost:3032/api/notify \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Build Complete",
    "message": "All tests passed",
    "level": "success"
  }'
```

Example response:

```json
{"ok": true, "id": 1}
```

### POST /api/agents/update

Full agent update (v3-compatible).

Example request:

```bash
curl -X POST http://localhost:3032/api/agents/update \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active",
    "name": "updated-name"
  }'
```

Example response:

```json
{"ok": true, "agent_id": "agent-abc123"}
```

### GET /api/agents/discover

Trigger agent discovery scan across environments.

Example request:

```bash
curl http://localhost:3032/api/agents/discover
```

Example response:

```json
{
  "discovered": [...],
  "count": 3
}
```

## Data Retrieval Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/data` | Master data aggregation (v3-compatible) |

### GET /api/data

Master data aggregation endpoint (v3-compatible). Returns agents, tasks, notifications, ralph data, commands, and input requests for a project.

Example request:

```bash
curl 'http://localhost:3032/api/data?project=ccem'
```

Query params:
- `project` -- Project name (defaults to active project)

Example response:

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

## Notification Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/notifications` | Get recent notifications |
| POST | `/api/notifications/add` | Create a notification (v3-compatible) |
| POST | `/api/notifications/read-all` | Mark all notifications as read |

### GET /api/notifications

Get recent notifications.

Example request:

```bash
curl http://localhost:3032/api/notifications
```

Response: array of notification objects.

### POST /api/notifications/add

Create a new notification (v3-compatible).

Example request:

```bash
curl -X POST http://localhost:3032/api/notifications/add \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Low Token Budget",
    "body": "Agent analyzer has 5000 tokens remaining",
    "category": "warning"
  }'
```

Example response:

```json
{"ok": true, "id": 1}
```

### POST /api/notifications/read-all

Mark all notifications as read.

Example request:

```bash
curl -X POST http://localhost:3032/api/notifications/read-all
```

Example response:

```json
{"ok": true}
```

## Ralph Integration Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/ralph` | Get Ralph methodology data |
| GET | `/api/ralph/flowchart` | Get D3.js-compatible flowchart data |

### GET /api/ralph

Get Ralph methodology data for the active project.

Example request:

```bash
curl 'http://localhost:3032/api/ralph?project=ccem'
```

Query params:
- `project` -- Project name (defaults to active project)

Response: Ralph PRD data object (stories, waves, objectives) or empty object if no PRD found.

### GET /api/ralph/flowchart

Get D3.js-compatible flowchart data for Ralph visualization.

Example request:

```bash
curl 'http://localhost:3032/api/ralph/flowchart?project=ccem'
```

Example response:

```json
{
  "nodes": [...],
  "edges": [...]
}
```

## Command Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/commands` | Get registered slash commands |
| POST | `/api/commands` | Register slash commands |

### GET /api/commands

Get registered slash commands for a project.

Example request:

```bash
curl 'http://localhost:3032/api/commands?project=ccem'
```

Response: array of command objects.

### POST /api/commands

Register slash commands for a project.

Example request:

```bash
curl -X POST http://localhost:3032/api/commands \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "commands": [
      {"name": "/spawn", "description": "Create new agent"}
    ]
  }'
```

Example response:

```json
{"ok": true, "count": 1}
```

## Input and Interaction Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/input/pending` | Get pending user input requests |
| POST | `/api/input/request` | Request user input from agent |
| POST | `/api/input/respond` | Provide user input response |

### GET /api/input/pending

Get pending user input requests.

Example request:

```bash
curl http://localhost:3032/api/input/pending
```

Response: array of pending input request objects.

### POST /api/input/request

Request user input from an agent.

Example request:

```bash
curl -X POST http://localhost:3032/api/input/request \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "prompt": "Confirm test generation?",
    "input_type": "confirmation"
  }'
```

Example response:

```json
{"ok": true, "id": 1}
```

### POST /api/input/respond

Provide user input response.

Example request:

```bash
curl -X POST http://localhost:3032/api/input/respond \
  -H "Content-Type: application/json" \
  -d '{
    "id": 1,
    "choice": "yes"
  }'
```

Example response:

```json
{"ok": true, "id": 1}
```

## Task Sync Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/tasks/sync` | Replace a project's task list |

### POST /api/tasks/sync

Replace a project's task list with the provided array.

Example request:

```bash
curl -X POST http://localhost:3032/api/tasks/sync \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "tasks": [
      {"id": "CCEM-1", "title": "Add feature", "status": "in_progress"}
    ]
  }'
```

Example response:

```json
{"ok": true, "count": 1}
```

## Configuration Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/config/reload` | Reload configuration from file |
| POST | `/api/reload` | Alias for config reload |
| POST | `/api/plane/update` | Update Plane PM context |

### POST /api/config/reload

Reload configuration from the `apm_config.json` file.

Example request:

```bash
curl -X POST http://localhost:3032/api/config/reload
```

Example response:

```json
{"ok": true}
```

### POST /api/reload

Alias for `/api/config/reload`.

Example request:

```bash
curl -X POST http://localhost:3032/api/reload
```

Example response:

```json
{"ok": true}
```

### POST /api/plane/update

Update Plane PM context for a project.

Example request:

```bash
curl -X POST http://localhost:3032/api/plane/update \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "workspace_slug": "ccem",
    "issues": [...]
  }'
```

Example response:

```json
{"ok": true}
```

## Skill Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/skills` | Get skill catalog and analytics |
| POST | `/api/skills/track` | Track a skill usage event |

### GET /api/skills

Get skill catalog and analytics. Supports filtering by session or project.

Full catalog request:

```bash
curl http://localhost:3032/api/skills
```

Filter by session:

```bash
curl 'http://localhost:3032/api/skills?session_id=sess-123'
```

Filter by project:

```bash
curl 'http://localhost:3032/api/skills?project=ccem'
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

Track a skill usage event. Requires `session_id` and `skill`.

Example request:

```bash
curl -X POST http://localhost:3032/api/skills/track \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "sess-abc123",
    "skill": "test-writing",
    "project": "ccem",
    "args": "--coverage"
  }'
```

Example response:

```json
{"ok": true, "session_id": "sess-abc123", "skill": "test-writing"}
```

## Project Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/projects` | Get all configured projects |
| PATCH | `/api/projects` | Update project fields |

### GET /api/projects

Get all configured projects with agent and session counts.

Example request:

```bash
curl http://localhost:3032/api/projects
```

Example response:

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

Example request:

```bash
curl -X PATCH http://localhost:3032/api/projects \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ccem",
    "status": "active",
    "prd_json": "/new/path/prd.json"
  }'
```

Success response:

```json
{"status": "ok"}
```

Error response (422):

```json
{"status": "error", "reason": "Project not found"}
```

## Port Management Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/ports` | Get port assignments and ranges |
| POST | `/api/ports/scan` | Scan for active ports |
| POST | `/api/ports/assign` | Assign an available port |
| GET | `/api/ports/clashes` | Detect port clashes |
| POST | `/api/ports/set-primary` | Set primary port for project |

### GET /api/ports

Get port assignments, ranges, and clash information.

Example request:

```bash
curl http://localhost:3032/api/ports
```

Example response:

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

Example request:

```bash
curl -X POST http://localhost:3032/api/ports/scan
```

Example response:

```json
{
  "ok": true,
  "active_ports": [...]
}
```

### POST /api/ports/assign

Assign an available port to a project or namespace.

Assign by namespace:

```bash
curl -X POST http://localhost:3032/api/ports/assign \
  -H "Content-Type: application/json" \
  -d '{"namespace": "web"}'
```

Assign by project:

```bash
curl -X POST http://localhost:3032/api/ports/assign \
  -H "Content-Type: application/json" \
  -d '{"project": "my-project"}'
```

Success response:

```json
{"ok": true, "port": 3005}
```

Error response (422):

```json
{"ok": false, "error": "no available port"}
```

### GET /api/ports/clashes

Detect port clashes across projects.

Example request:

```bash
curl http://localhost:3032/api/ports/clashes
```

Example response:

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

Example request:

```bash
curl -X POST http://localhost:3032/api/ports/set-primary \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "port": 3031,
    "ownership": "exclusive"
  }'
```

Ownership values: `exclusive`, `shared`, `reserved`.

Example response:

```json
{
  "ok": true,
  "project": "ccem",
  "primary_port": 3031,
  "port_ownership": "exclusive"
}
```

## UPM Integration Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/upm/register` | Register UPM execution session |
| POST | `/api/upm/agent` | Register agent with work-item binding |
| POST | `/api/upm/event` | Log UPM lifecycle event |
| GET | `/api/upm/status` | Get current UPM execution state |

### POST /api/upm/register

Register a new UPM execution session.

Example request:

```bash
curl -X POST http://localhost:3032/api/upm/register \
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

Register an agent with work-item binding.

Example request:

```bash
curl -X POST http://localhost:3032/api/upm/agent \
  -H "Content-Type: application/json" \
  -d '{
    "upm_session_id": "upm-abc123",
    "agent_id": "agent-xyz789",
    "story_id": "story-1-1"
  }'
```

Success response:

```json
{"ok": true}
```

Error response (404 if session not found):

```json
{"error": "UPM session not found", "upm_session_id": "upm-abc123"}
```

### POST /api/upm/event

Log a UPM lifecycle event.

Example request:

```bash
curl -X POST http://localhost:3032/api/upm/event \
  -H "Content-Type: application/json" \
  -d '{
    "upm_session_id": "upm-abc123",
    "story_id": "story-1-1",
    "event_type": "progress_update",
    "data": {"progress_percent": 75}
  }'
```

Example response:

```json
{"ok": true}
```

### GET /api/upm/status

Get the current UPM execution state.

Example request:

```bash
curl http://localhost:3032/api/upm/status
```

Example response:

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

## Environment Management Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/environments` | List all Claude Code environments |
| GET | `/api/environments/:name` | Get environment detail |
| POST | `/api/environments/:name/exec` | Execute command in environment |
| POST | `/api/environments/:name/session/start` | Launch Claude Code session |
| POST | `/api/environments/:name/session/stop` | Kill Claude Code session |

### GET /api/environments

List all Claude Code environments.

Example request:

```bash
curl http://localhost:3032/api/environments
```

Example response:

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

Get full detail for a specific environment.

Example request:

```bash
curl http://localhost:3032/api/environments/ccem
```

### POST /api/environments/:name/exec

Execute a command in an environment. Timeout capped at 120 seconds.

Example request:

```bash
curl -X POST http://localhost:3032/api/environments/ccem/exec \
  -H "Content-Type: application/json" \
  -d '{"command": "mix test", "timeout": 30}'
```

Success response:

```json
{
  "exit_code": 0,
  "output": "..."
}
```

Error response (403 for dangerous commands):

```json
{"error": "Command rejected as dangerous"}
```

> **Warning:** The `exec` endpoint rejects commands considered dangerous (e.g., `rm -rf`, `sudo`). The timeout is capped at 120 seconds regardless of the value provided.

### POST /api/environments/:name/session/start

Launch a Claude Code session in an environment.

Example request:

```bash
curl -X POST http://localhost:3032/api/environments/ccem/session/start \
  -H "Content-Type: application/json" \
  -d '{"with_ccem": true}'
```

Example response:

```json
{"ok": true, "environment": "ccem", "with_ccem": true}
```

### POST /api/environments/:name/session/stop

Kill a Claude Code session in an environment.

Example request:

```bash
curl -X POST http://localhost:3032/api/environments/ccem/session/stop
```

Example response:

```json
{"ok": true, "environment": "ccem", "killed": 1}
```

## V2 API Endpoints (Advanced)

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/agents` | List agents with extended data |
| GET | `/api/v2/agents/:id` | Get agent details with metrics |
| GET | `/api/v2/sessions` | List all sessions |
| GET | `/api/v2/metrics` | Get fleet metrics |
| GET | `/api/v2/metrics/:agent_id` | Get agent-specific metrics |
| GET | `/api/v2/slos` | List configured SLOs |
| GET | `/api/v2/slos/:name` | Get specific SLO details |
| GET | `/api/v2/alerts` | List active alerts |
| GET | `/api/v2/alerts/rules` | Get alert rules |
| POST | `/api/v2/alerts/rules` | Create alert rule |
| GET | `/api/v2/audit` | Get audit log entries |
| GET | `/api/v2/openapi.json` | Get OpenAPI specification |

### GET /api/v2/agents

List agents with extended data including metrics.

```bash
curl http://localhost:3032/api/v2/agents
```

### GET /api/v2/agents/:id

Get detailed agent information with associated metrics.

```bash
curl http://localhost:3032/api/v2/agents/agent-abc123
```

### GET /api/v2/sessions

List all tracked sessions.

```bash
curl http://localhost:3032/api/v2/sessions
```

### GET /api/v2/metrics

Get fleet-wide aggregated metrics.

```bash
curl http://localhost:3032/api/v2/metrics
```

### GET /api/v2/metrics/:agent_id

Get metrics for a specific agent.

```bash
curl http://localhost:3032/api/v2/metrics/agent-abc123
```

### GET /api/v2/slos

List all configured SLOs (Service Level Objectives).

```bash
curl http://localhost:3032/api/v2/slos
```

### GET /api/v2/slos/:name

Get details for a specific SLO.

```bash
curl http://localhost:3032/api/v2/slos/uptime
```

### GET /api/v2/alerts

List currently active alerts.

```bash
curl http://localhost:3032/api/v2/alerts
```

### GET /api/v2/alerts/rules

Get all configured alert rules.

```bash
curl http://localhost:3032/api/v2/alerts/rules
```

### POST /api/v2/alerts/rules

Create a new alert rule.

Example request:

```bash
curl -X POST http://localhost:3032/api/v2/alerts/rules \
  -H "Content-Type: application/json" \
  -d '{"condition": "token_usage > 80000", "action": "escalate"}'
```

### GET /api/v2/audit

Get audit log entries.

```bash
curl http://localhost:3032/api/v2/audit
```

### GET /api/v2/openapi.json

Get the OpenAPI specification for the full API.

```bash
curl http://localhost:3032/api/v2/openapi.json
```

## Data Export and Import Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/export` | Export APM data as JSON or CSV |
| POST | `/api/v2/import` | Import data from JSON |

### GET /api/v2/export

Export APM data as JSON or CSV.

JSON export (default):

```bash
curl http://localhost:3032/api/v2/export > export.json
```

CSV export for a specific section:

```bash
curl 'http://localhost:3032/api/v2/export?format=csv&section=agents' > agents.csv
```

Filtered JSON export:

```bash
curl 'http://localhost:3032/api/v2/export?sections[]=agents&sections[]=sessions&since=2026-02-01T00:00:00Z'
```

Query params:
- `format` -- `json` (default) or `csv`
- `section` -- Section for CSV export (e.g., `agents`)
- `sections[]` -- Array of sections for JSON export
- `since` -- ISO8601 datetime filter
- `agent_ids[]` -- Filter by agent IDs

### POST /api/v2/import

Import data from a JSON export file.

Example request:

```bash
curl -X POST http://localhost:3032/api/v2/import \
  -H "Content-Type: application/json" \
  -d @export.json
```

Example response:

```json
{"status": "ok", "summary": {...}}
```

## Server-Sent Events Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/ag-ui/events` | Subscribe to real-time AG-UI events (SSE) |

### GET /api/ag-ui/events

Subscribe to real-time AG-UI events via Server-Sent Events.

Example request:

```bash
curl http://localhost:3032/api/ag-ui/events
```

Streams events as they occur:

```text
data: {"type":"agent_registered","agent":"test-gen"}
data: {"type":"agent_updated","agent":"test-gen"}
```

> **Pattern:** Use `EventSource` in JavaScript or `curl` for testing. The connection stays open and delivers events in real time.

## UI Component Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/a2ui/components` | List available A2UI components |

### GET /api/a2ui/components

List available A2UI components (accepts JSON and JSONL).

```bash
curl http://localhost:3032/api/a2ui/components
```

## Error Responses

All endpoints return structured error information on failure.

Standard error format:

```json
{"error": "Agent not found", "agent_id": "unknown"}
```

Status codes:
- **200**: Success
- **201**: Created (agent registration, UPM session registration)
- **400**: Bad request (missing required fields)
- **403**: Forbidden (dangerous command rejected)
- **404**: Not found
- **422**: Unprocessable entity (validation error)
- **500**: Server error

## Authentication

API endpoints are protected by the `ApiAuth` plug. API keys are configured via `ApmV5.ApiKeyStore`.

Include the API key in the Authorization header:

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
  http://localhost:3032/api/status
```
