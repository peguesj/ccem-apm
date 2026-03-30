# REST API Reference

Complete API endpoint documentation for CCEM APM v8.11.0. The API uses JSON for request/response bodies and supports both HTTP/REST and WebSocket connections.

> **v8.11.0 additions**: Plugin Repository API (`/api/v2/plugins/repositories`) for managing plugin sources. Claude Code Plugin Bridge (`/api/v2/plugins/cc/*`) for discovering CC ecosystem plugins. Library API (`/api/v2/library/*`) for the 7-tab resource catalog.
>
> **v8.10.1 additions**: Usage Limits API (`GET /api/usage/limits`) with model capability data and utilization. API Key Management (`/api/v2/auth/api-keys`) CRUD. Claude Code Discovery plugin at `/plugins/claude-code`. LVM Status integration at `/integrations/lvm`.
>
> **v8.10.0 additions**: Auto-Approval Policies API (`/api/v2/auth/auto-approval-policies`) with 6 endpoints for hierarchical scope matching policy CRUD + test-match dry-run. `CommandContextExtractor` enriches all pending approvals with `action_type`, `action_detail`, and `approval_reasoning`.
>
> **v8.9.0 additions**: Plane-PM Align API (`/api/v2/plane/sync-status`, `/api/v2/plane/sync`) for persistent Plane sync status and on-demand sync trigger.
>
> **v7.0.0 additions**: AgentLock Authorization API (`/api/v2/auth/*`) with 19 endpoints for token management, policy CRUD, session control, rate limiting, context inspection, and redaction preview.
>
> **v6.4.0 additions**: Claude Usage API (`/api/usage/*`) with per-project effort tracking and Ports API (`/api/ports/register`, `/api/ports/conflicts`) for service-name registration and conflict checking.

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
| POST | `/api/ports/register` | Register a named service on a port (v6.4.0) |
| GET | `/api/ports/conflicts` | Check for port conflicts across all namespaces (v6.4.0) |

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

### POST /api/ports/register (v6.4.0)

Register a named service on a specific port. Associates a human-readable `service_name` and optional `namespace` with a port entry. If the port is already registered to a different project the server returns 409.

Example request:

```bash
curl -X POST http://localhost:3032/api/ports/register \
  -H "Content-Type: application/json" \
  -d '{
    "port": 4000,
    "project": "ccem",
    "service_name": "apm-server",
    "namespace": "web"
  }'
```

Request body fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `port` | integer | yes | Port number to register |
| `project` | string | yes | Owning project name |
| `service_name` | string | yes | Human-readable service identifier |
| `namespace` | string | no | Port namespace (e.g. `"web"`, `"api"`, `"db"`) |

Success response (201):

```json
{
  "ok": true,
  "port": 4000,
  "project": "ccem",
  "service_name": "apm-server",
  "namespace": "web"
}
```

Conflict response (409):

```json
{
  "ok": false,
  "error": "port 4000 already registered to project lcc"
}
```

### GET /api/ports/conflicts (v6.4.0)

Check for port conflicts across all registered namespaces. Returns every port that is claimed by more than one project, grouped by severity.

Example request:

```bash
curl http://localhost:3032/api/ports/conflicts
```

Example response:

```json
{
  "ok": true,
  "conflicts": [
    {
      "port": 3000,
      "severity": "high",
      "projects": ["lcc", "egpt"],
      "namespaces": ["web", "web"]
    }
  ],
  "total": 1
}
```

Severity levels:

| Level | Meaning |
|-------|---------|
| `high` | Two or more projects claim exclusive ownership |
| `medium` | Shared + exclusive conflict |
| `low` | Two shared claims on the same port |

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

## AG-UI Protocol Endpoints (v2)

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/v2/ag-ui/emit` | Emit an AG-UI typed event |
| GET | `/api/v2/ag-ui/events` | Stream all AG-UI events (SSE) |
| GET | `/api/v2/ag-ui/events/:agent_id` | Stream agent-specific events (SSE) |
| GET | `/api/v2/ag-ui/state/:agent_id` | Get agent state snapshot |
| PUT | `/api/v2/ag-ui/state/:agent_id` | Replace agent state |
| PATCH | `/api/v2/ag-ui/state/:agent_id` | Apply JSON Patch delta to agent state |
| GET | `/api/v2/ag-ui/router/stats` | Get EventRouter statistics |

### POST /api/v2/ag-ui/emit

Emit a typed AG-UI event into the event bus.

```bash
curl -X POST http://localhost:3032/api/v2/ag-ui/emit \
  -H "Content-Type: application/json" \
  -d '{
    "type": "CUSTOM",
    "agent_id": "agent-abc123",
    "data": {"message": "Build complete", "status": "success"}
  }'
```

Supported event types: `RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`, `STEP_STARTED`, `STEP_FINISHED`, `TOOL_CALL_START`, `TOOL_CALL_END`, `STATE_SNAPSHOT`, `STATE_DELTA`, `TEXT_MESSAGE_START`, `TEXT_MESSAGE_CONTENT`, `TEXT_MESSAGE_END`, `MESSAGES_SNAPSHOT`, `CUSTOM`.

### GET /api/v2/ag-ui/events

Subscribe to all AG-UI events via Server-Sent Events.

```bash
curl http://localhost:3032/api/v2/ag-ui/events
```

### GET /api/v2/ag-ui/state/:agent_id

Get the current state snapshot for an agent.

```bash
curl http://localhost:3032/api/v2/ag-ui/state/agent-abc123
```

### PATCH /api/v2/ag-ui/state/:agent_id

Apply a JSON Patch (RFC 6902) delta to agent state.

```bash
curl -X PATCH http://localhost:3032/api/v2/ag-ui/state/agent-abc123 \
  -H "Content-Type: application/json" \
  -d '{"delta": [{"op": "replace", "path": "/status", "value": "complete"}]}'
```

## UI Component Endpoints

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/a2ui/components` | List available A2UI components |

### GET /api/a2ui/components

List available A2UI components (accepts JSON and JSONL).

```bash
curl http://localhost:3032/api/a2ui/components
```

## Agent Activity Log Endpoints (v6.1.0)

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/agents/activity-log` | Get recent agent activity events (ring buffer, up to 200) |

### GET /api/agents/activity-log

Returns recent agent activity events from the `AgentActivityLog` ring buffer. Events are ordered chronologically (oldest first). Use the `limit` query parameter to request fewer events.

```bash
curl 'http://localhost:3032/api/agents/activity-log?limit=30'
```

Query params:
- `limit` — Number of events to return (1–200, default: 200)

Example response:

```json
{
  "events": [
    {
      "id": "evt-abc123",
      "type": "lifecycle",
      "agent_id": "agent-xyz",
      "timestamp": "2026-03-18T10:00:00.000Z",
      "payload": {
        "event": "registered",
        "status": "active",
        "project": "ccem"
      }
    },
    {
      "id": "evt-def456",
      "type": "tool",
      "agent_id": "agent-xyz",
      "timestamp": "2026-03-18T10:00:01.500Z",
      "payload": {
        "tool_name": "Read",
        "phase": "start",
        "path": "/path/to/file"
      }
    }
  ],
  "total": 2,
  "capacity": 200
}
```

Event types:
- `lifecycle` — agent register / update / disconnect
- `tool` — tool call start and finish (includes `tool_name`, `phase`)
- `thinking` — thinking token events (includes `token_count`)
- `text` — text output events (includes `char_count`)

## UPM API Controller (v6.2.0)

`UpmApiController` is a dedicated domain controller for UPM execution tracking endpoints, extracted from the monolithic `ApiController` in v6.2.0. All `/api/upm/*` routes are now handled by this controller.

| Method | Path | Controller | Description |
|:-------|:-----|:-----------|:------------|
| POST | `/api/upm/register` | `UpmApiController` | Register UPM execution session |
| POST | `/api/upm/agent` | `UpmApiController` | Register agent with work-item binding |
| POST | `/api/upm/event` | `UpmApiController` | Log UPM lifecycle event |
| GET | `/api/upm/status` | `UpmApiController` | Get current UPM execution state |

The request/response contract for each endpoint is unchanged — see [UPM Integration Endpoints](#upm-integration-endpoints) for full details.

## Formation API Controller (v6.2.0)

`FormationApiController` is a dedicated domain controller for formation CRUD operations, extracted from `ApiController` in v6.2.0.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/formations` | List all formations |
| GET | `/api/v2/formations/:id` | Get a single formation by ID |
| POST | `/api/v2/formations` | Create a new formation |
| PUT | `/api/v2/formations/:id` | Update a formation |
| GET | `/api/v2/formations/:id/agents` | List agents belonging to a formation |

### GET /api/v2/formations

List all registered formations.

```bash
curl http://localhost:3032/api/v2/formations
```

Example response:

```json
{
  "formations": [
    {
      "id": "fmt-abc123",
      "name": "ccem-v6-20260318",
      "status": "active",
      "agent_count": 5,
      "created_at": "2026-03-18T09:00:00Z"
    }
  ]
}
```

### GET /api/v2/formations/:id/agents

List all agents registered under a formation.

```bash
curl http://localhost:3032/api/v2/formations/fmt-abc123/agents
```

Example response:

```json
{
  "formation_id": "fmt-abc123",
  "agents": [
    {
      "id": "agent-001",
      "name": "orchestrator",
      "formation_role": "orchestrator",
      "status": "active"
    }
  ]
}
```

## Showcase API Controller (v6.2.0)

`ShowcaseApiController` is a dedicated domain controller for showcase data REST endpoints, extracted from `ApiController` in v6.2.0.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/showcase` | List all projects that have showcase data |
| GET | `/api/showcase/:project` | Get showcase data for a named project |
| POST | `/api/showcase/:project/reload` | Hot-reload showcase data from disk |

### GET /api/showcase/:project

Fetch showcase data for a project.

```bash
curl http://localhost:3032/api/showcase/ccem
```

Example response:

```json
{
  "project": "ccem",
  "features": [
    {
      "id": "US-031",
      "wave": 6,
      "title": "AgentActivityLog",
      "status": "done"
    }
  ],
  "feature_count": 1
}
```

### POST /api/showcase/:project/reload

Hot-reload showcase data from disk without restarting the server. Broadcasts `{:showcase_data_reloaded, project, data}` on `apm:showcase`.

```bash
curl -X POST http://localhost:3032/api/showcase/ccem/reload
```

Response:

```json
{"ok": true, "project": "ccem"}
```

## Claude Usage API (v6.3.0+)

Track Claude model and token usage at user and project scope. Data is persisted in ETS by `ApmV5.ClaudeUsageStore` and broadcast on the `"apm:usage"` PubSub topic.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/usage` | All usage data keyed by project → model |
| GET | `/api/usage/summary` | Aggregated totals with model breakdown and per-project effort levels |
| GET | `/api/usage/project/:name` | Usage data for a single project |
| POST | `/api/usage/record` | Record a usage event |
| DELETE | `/api/usage/project/:name` | Reset all counters for a project |

### GET /api/usage

Return all usage data keyed by project, then model.

```bash
curl http://localhost:3032/api/usage
```

Example response:

```json
{
  "ok": true,
  "usage": {
    "ccem": {
      "claude-sonnet-4-6": {
        "input_tokens": 45000,
        "output_tokens": 12000,
        "cache_tokens": 3000,
        "tool_calls": 350,
        "sessions": 12,
        "last_seen": "2026-03-18T10:00:00Z"
      }
    }
  }
}
```

### GET /api/usage/summary

Return aggregated totals across all projects with model breakdown and per-project effort levels.

```bash
curl http://localhost:3032/api/usage/summary
```

Example response:

```json
{
  "ok": true,
  "summary": {
    "total_input_tokens": 45000,
    "total_output_tokens": 12000,
    "total_cache_tokens": 3000,
    "total_tool_calls": 350,
    "total_sessions": 12,
    "top_model": "claude-sonnet-4-6",
    "model_breakdown": {
      "claude-sonnet-4-6": {
        "input_tokens": 45000,
        "output_tokens": 12000,
        "cache_tokens": 3000,
        "tool_calls": 350,
        "sessions": 12,
        "last_seen": "2026-03-18T10:00:00Z"
      }
    },
    "projects": {
      "ccem": {
        "input_tokens": 45000,
        "output_tokens": 12000,
        "cache_tokens": 3000,
        "tool_calls": 350,
        "sessions": 12,
        "effort_level": "high",
        "model_breakdown": {
          "claude-sonnet-4-6": { "..." : "..." }
        }
      }
    }
  }
}
```

### GET /api/usage/project/:name

Return usage data for a single project with its current effort level.

```bash
curl http://localhost:3032/api/usage/project/ccem
```

Example response:

```json
{
  "ok": true,
  "project": "ccem",
  "effort_level": "high",
  "usage": {
    "claude-sonnet-4-6": {
      "input_tokens": 45000,
      "output_tokens": 12000,
      "cache_tokens": 3000,
      "tool_calls": 350,
      "sessions": 12,
      "last_seen": "2026-03-18T10:00:00Z"
    }
  }
}
```

### POST /api/usage/record

Record a Claude API usage event. Increments counters for the `{project, model}` pair and increments `sessions` by 1. Returns 201 on success.

```bash
curl -X POST http://localhost:3032/api/usage/record \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem",
    "model": "claude-sonnet-4-6",
    "input_tokens": 1000,
    "output_tokens": 250,
    "cache_tokens": 0,
    "tool_calls": 1
  }'
```

Request body fields:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `project` | string | no | `"unknown"` | Project name |
| `model` | string | no | `"claude-sonnet-4-6"` | Claude model identifier |
| `input_tokens` | integer | no | `0` | Number of input tokens consumed |
| `output_tokens` | integer | no | `0` | Number of output tokens generated |
| `cache_tokens` | integer | no | `0` | Number of cache-read tokens |
| `tool_calls` | integer | no | `0` | Number of tool calls made |

Response (201):

```json
{
  "ok": true,
  "project": "ccem",
  "model": "claude-sonnet-4-6",
  "effort_level": "high",
  "usage": {
    "claude-sonnet-4-6": {
      "input_tokens": 46000,
      "output_tokens": 12250,
      "cache_tokens": 3000,
      "tool_calls": 351,
      "sessions": 13,
      "last_seen": "2026-03-18T10:05:00Z"
    }
  }
}
```

### DELETE /api/usage/project/:name

Reset all usage counters for a project. Removes all ETS entries for the named project.

```bash
curl -X DELETE http://localhost:3032/api/usage/project/ccem
```

Example response:

```json
{
  "ok": true,
  "project": "ccem",
  "message": "Usage data reset"
}
```

### Effort Levels

Inferred from `tool_calls / sessions` ratio per project:

| Level | Threshold | Behavior |
|-------|-----------|----------|
| `low` | <10 calls/session | None |
| `medium` | 10–50 calls/session | None |
| `high` | 50–100 calls/session | None |
| `intensive` | >100 calls/session | PreToolUse hook emits warning |

> **PubSub**: Every `POST /api/usage/record` and `DELETE /api/usage/project/:name` broadcasts `{:usage_updated, all_usage}` on `"apm:usage"` so `UsageLive` updates in real time.

---

## AgentLock Authorization Endpoints (v7.0.0)

19 endpoints for the AgentLock authorization protocol. All under `/api/v2/auth/*`.

### Token Management

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/v2/auth/tokens` | Issue a new authorization token |
| GET | `/api/v2/auth/tokens` | List all active tokens |
| GET | `/api/v2/auth/tokens/:token_id` | Get token details |
| DELETE | `/api/v2/auth/tokens/:token_id` | Revoke a token |
| POST | `/api/v2/auth/tokens/:token_id/refresh` | Refresh a token's TTL |

#### POST /api/v2/auth/tokens

Issue a new authorization token for an agent.

```bash
curl -X POST http://localhost:3032/api/v2/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "scope": ["read", "write"],
    "ttl_seconds": 3600,
    "metadata": {"project": "ccem"}
  }'
```

Response (201):

```json
{
  "ok": true,
  "token": {
    "id": "tok-xyz789",
    "agent_id": "agent-abc123",
    "scope": ["read", "write"],
    "issued_at": "2026-03-21T10:00:00Z",
    "expires_at": "2026-03-21T11:00:00Z",
    "status": "active"
  }
}
```

#### GET /api/v2/auth/tokens

List all active tokens. Supports optional `agent_id` filter.

```bash
curl 'http://localhost:3032/api/v2/auth/tokens?agent_id=agent-abc123'
```

Response:

```json
{
  "ok": true,
  "tokens": [
    {
      "id": "tok-xyz789",
      "agent_id": "agent-abc123",
      "scope": ["read", "write"],
      "issued_at": "2026-03-21T10:00:00Z",
      "expires_at": "2026-03-21T11:00:00Z",
      "status": "active"
    }
  ],
  "total": 1
}
```

#### DELETE /api/v2/auth/tokens/:token_id

Revoke an active token immediately.

```bash
curl -X DELETE http://localhost:3032/api/v2/auth/tokens/tok-xyz789
```

Response:

```json
{"ok": true, "token_id": "tok-xyz789", "status": "revoked"}
```

### Policy Management

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/auth/policies` | List all policies |
| POST | `/api/v2/auth/policies` | Create a new policy |
| GET | `/api/v2/auth/policies/:policy_id` | Get policy details |
| PUT | `/api/v2/auth/policies/:policy_id` | Update a policy |
| DELETE | `/api/v2/auth/policies/:policy_id` | Delete a policy |

#### POST /api/v2/auth/policies

Create a new authorization policy.

```bash
curl -X POST http://localhost:3032/api/v2/auth/policies \
  -H "Content-Type: application/json" \
  -d '{
    "name": "read-only-agents",
    "description": "Restricts agents to read-only operations",
    "rules": [
      {"action": "allow", "scope": "read", "resource": "*"},
      {"action": "deny", "scope": "write", "resource": "*"}
    ],
    "priority": 10
  }'
```

Response (201):

```json
{
  "ok": true,
  "policy": {
    "id": "pol-abc123",
    "name": "read-only-agents",
    "rules": [...],
    "priority": 10,
    "created_at": "2026-03-21T10:00:00Z"
  }
}
```

#### GET /api/v2/auth/policies

List all policies, ordered by priority.

```bash
curl http://localhost:3032/api/v2/auth/policies
```

Response:

```json
{
  "ok": true,
  "policies": [...],
  "total": 3
}
```

### Session Control

| Method | Path | Description |
|:-------|:-----|:------------|
| POST | `/api/v2/auth/sessions` | Create an authorization session |
| GET | `/api/v2/auth/sessions/:session_id` | Get session details |
| DELETE | `/api/v2/auth/sessions/:session_id` | Terminate a session |

#### POST /api/v2/auth/sessions

Create a new authorization session binding an agent to a set of policies.

```bash
curl -X POST http://localhost:3032/api/v2/auth/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "token_id": "tok-xyz789",
    "policy_ids": ["pol-abc123"],
    "context": {"project": "ccem", "environment": "dev"}
  }'
```

Response (201):

```json
{
  "ok": true,
  "session": {
    "id": "auth-sess-001",
    "agent_id": "agent-abc123",
    "token_id": "tok-xyz789",
    "status": "active",
    "created_at": "2026-03-21T10:00:00Z"
  }
}
```

### Rate Limiting

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/auth/rate-limits` | Get current rate limit status for all agents |
| GET | `/api/v2/auth/rate-limits/:agent_id` | Get rate limit status for a specific agent |

#### GET /api/v2/auth/rate-limits/:agent_id

Get rate limit counters and remaining quota for an agent.

```bash
curl http://localhost:3032/api/v2/auth/rate-limits/agent-abc123
```

Response:

```json
{
  "ok": true,
  "agent_id": "agent-abc123",
  "limits": {
    "requests_per_minute": {"limit": 60, "remaining": 45, "resets_at": "2026-03-21T10:01:00Z"},
    "tokens_per_hour": {"limit": 100000, "remaining": 78000, "resets_at": "2026-03-21T11:00:00Z"}
  }
}
```

### Context and Redaction

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/auth/contexts/:agent_id` | Get execution context for an agent |
| POST | `/api/v2/auth/redact/preview` | Preview content redaction without applying |
| POST | `/api/v2/auth/authorize` | Evaluate authorization for an action |

#### POST /api/v2/auth/authorize

Evaluate whether an agent is authorized to perform an action. Combines policy evaluation, rate limit checks, and context validation.

```bash
curl -X POST http://localhost:3032/api/v2/auth/authorize \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "token_id": "tok-xyz789",
    "action": "write",
    "resource": "config/apm_config.json",
    "context": {"project": "ccem"}
  }'
```

Authorized response:

```json
{
  "ok": true,
  "authorized": true,
  "agent_id": "agent-abc123",
  "action": "write",
  "resource": "config/apm_config.json",
  "evaluated_policies": ["pol-abc123"],
  "decision": "allow"
}
```

Denied response (403):

```json
{
  "ok": false,
  "authorized": false,
  "agent_id": "agent-abc123",
  "action": "write",
  "resource": "config/apm_config.json",
  "decision": "deny",
  "reason": "Policy 'read-only-agents' denies write access to resource"
}
```

#### POST /api/v2/auth/redact/preview

Preview what content redaction would produce for a given input and scope.

```bash
curl -X POST http://localhost:3032/api/v2/auth/redact/preview \
  -H "Content-Type: application/json" \
  -d '{
    "content": "API key: sk-abc123-secret",
    "scope": "external",
    "rules": ["api_keys", "credentials"]
  }'
```

Response:

```json
{
  "ok": true,
  "original_length": 26,
  "redacted": "API key: [REDACTED]",
  "redactions_applied": 1,
  "rules_matched": ["api_keys"]
}
```

#### GET /api/v2/auth/contexts/:agent_id

Get the current execution context for an agent, including scope inheritance chain and active permissions.

```bash
curl http://localhost:3032/api/v2/auth/contexts/agent-abc123
```

Response:

```json
{
  "ok": true,
  "agent_id": "agent-abc123",
  "context": {
    "scope": "project:ccem",
    "inherited_scopes": ["global", "project:ccem"],
    "active_permissions": ["read", "write"],
    "memory_access": {"read": true, "write": true, "execute": false},
    "created_at": "2026-03-21T10:00:00Z"
  }
}
```

---

## Plane-PM Align Endpoints (v8.9.0)

The `PlanePmAlign` GenServer maintains a persistent sync with Plane PM, polling every 5 minutes and broadcasting on `"plane:sync"` PubSub.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/plane/sync-status` | Current Plane sync status and last sync metadata |
| POST | `/api/v2/plane/sync` | Trigger an immediate Plane sync |

### GET /api/v2/plane/sync-status

Returns the current sync state, last sync timestamp, and project counts.

```bash
curl http://localhost:3032/api/v2/plane/sync-status
```

Response:

```json
{
  "ok": true,
  "status": "synced",
  "last_sync_at": "2026-03-30T10:00:00Z",
  "next_sync_in_seconds": 240,
  "projects_synced": 3,
  "issues_synced": 42,
  "agent_id": "plane-pm-align-persistent"
}
```

### POST /api/v2/plane/sync

Triggers an immediate Plane sync outside the 5-minute polling interval. Returns the sync result.

```bash
curl -X POST http://localhost:3032/api/v2/plane/sync
```

Response:

```json
{
  "ok": true,
  "synced_at": "2026-03-30T10:02:15Z",
  "projects_synced": 3,
  "issues_synced": 42,
  "duration_ms": 312
}
```

---

## Claude Code Plugin Bridge Endpoints (v8.11.0)

Discover plugins from the Claude Code ecosystem via `ClaudeCodePluginBridge`.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/plugins/cc/plugins` | List all discovered Claude Code plugins |
| GET | `/api/v2/plugins/cc/summary` | Summary of Claude Code plugin ecosystem |

### GET /api/v2/plugins/cc/plugins

Returns all plugins discovered from the Claude Code ecosystem (MCP servers, hooks, skills).

```bash
curl http://localhost:3032/api/v2/plugins/cc/plugins
```

Response:

```json
{
  "ok": true,
  "plugins": [
    {
      "name": "agent-browser",
      "type": "mcp_server",
      "source": "claude_code",
      "status": "active"
    }
  ],
  "total": 12
}
```

### GET /api/v2/plugins/cc/summary

Returns a summary with counts by type and scope.

```bash
curl http://localhost:3032/api/v2/plugins/cc/summary
```

Response:

```json
{
  "ok": true,
  "total": 12,
  "by_type": {"mcp_server": 5, "hook": 4, "skill": 3},
  "by_scope": {"user": 8, "project": 4}
}
```

---

## Plugin Repository Endpoints (v8.11.0)

Manage plugin repository sources via `PluginRepositoryStore`.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/plugins/repositories` | List all plugin repositories |
| POST | `/api/v2/plugins/repositories` | Register a new plugin repository |
| GET | `/api/v2/plugins/repositories/:id` | Get repository details |
| PATCH | `/api/v2/plugins/repositories/:id` | Update repository metadata |
| DELETE | `/api/v2/plugins/repositories/:id` | Remove a repository |

### GET /api/v2/plugins/repositories

List all registered plugin repositories.

```bash
curl http://localhost:3032/api/v2/plugins/repositories
```

Response:

```json
{
  "ok": true,
  "repositories": [
    {
      "id": "repo-abc123",
      "name": "ccem-core",
      "url": "https://github.com/peguesj/ccem-plugins",
      "scope": "apm",
      "plugin_count": 8,
      "last_synced_at": "2026-03-30T10:00:00Z"
    }
  ],
  "total": 1
}
```

### POST /api/v2/plugins/repositories

Register a new plugin repository.

```bash
curl -X POST http://localhost:3032/api/v2/plugins/repositories \
  -H "Content-Type: application/json" \
  -d '{
    "name": "custom-plugins",
    "url": "https://github.com/org/plugins",
    "scope": "ccem"
  }'
```

Response (201):

```json
{
  "ok": true,
  "repository": {
    "id": "repo-xyz789",
    "name": "custom-plugins",
    "url": "https://github.com/org/plugins",
    "scope": "ccem"
  }
}
```

### PATCH /api/v2/plugins/repositories/:id

Update repository metadata.

```bash
curl -X PATCH http://localhost:3032/api/v2/plugins/repositories/repo-xyz789 \
  -H "Content-Type: application/json" \
  -d '{"name": "updated-name"}'
```

### DELETE /api/v2/plugins/repositories/:id

Remove a registered repository.

```bash
curl -X DELETE http://localhost:3032/api/v2/plugins/repositories/repo-xyz789
```

Response:

```json
{"ok": true, "id": "repo-xyz789", "status": "deleted"}
```

---

## Library Endpoints (v8.11.0)

The Library dashboard provides a 7-tab resource catalog backed by `LibraryStore` GenServer.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/library/agents` | List all registered agents |
| GET | `/api/v2/library/skills` | List all tracked skills |
| GET | `/api/v2/library/mcp` | List all MCP server configurations |
| GET | `/api/v2/library/tools` | List all available tools |
| GET | `/api/v2/library/commands` | List all slash commands |
| GET | `/api/v2/library/patterns` | List all discovered patterns |
| GET | `/api/v2/library/learnings` | List all captured learnings |

### GET /api/v2/library/agents

Returns all agents from the library catalog.

```bash
curl http://localhost:3032/api/v2/library/agents
```

Response:

```json
{
  "ok": true,
  "agents": [
    {
      "id": "orchestrator-agent",
      "name": "Master Orchestrator",
      "type": "orchestrator",
      "source": "manifest",
      "description": "Master compound request decomposition"
    }
  ],
  "total": 67
}
```

### GET /api/v2/library/skills

Returns all skills with health scores and metadata.

```bash
curl http://localhost:3032/api/v2/library/skills
```

Response:

```json
{
  "ok": true,
  "skills": [
    {
      "name": "upm",
      "health_score": 92,
      "tier": "healthy",
      "triggers": ["upm", "/upm"],
      "last_invoked": "2026-03-30T10:00:00Z"
    }
  ],
  "total": 45
}
```

### GET /api/v2/library/mcp

Returns all MCP server configurations.

```bash
curl http://localhost:3032/api/v2/library/mcp
```

### GET /api/v2/library/tools

Returns all available tools across agents and MCP servers.

```bash
curl http://localhost:3032/api/v2/library/tools
```

### GET /api/v2/library/commands

Returns all registered slash commands.

```bash
curl http://localhost:3032/api/v2/library/commands
```

### GET /api/v2/library/patterns

Returns discovered patterns from agent execution history.

```bash
curl http://localhost:3032/api/v2/library/patterns
```

### GET /api/v2/library/learnings

Returns captured learnings from agent sessions.

```bash
curl http://localhost:3032/api/v2/library/learnings
```

---

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
