# Multi-Project Support

CCEM APM supports managing multiple projects within a single server instance. Projects are isolated by namespace, allowing Claude Code sessions across different codebases to report independently.

## Configuration Structure

Multi-project configuration is stored in `/Users/jeremiah/Developer/ccem/apm/apm_config.json`:

```json
{
  "project_name": "ccem",
  "project_root": "/Users/jeremiah/Developer/ccem",
  "active_project": "ccem",
  "port": 3031,
  "projects": [
    {
      "name": "ccem",
      "root": "/Users/jeremiah/Developer/ccem"
    },
    {
      "name": "lcc",
      "root": "/Users/jeremiah/Developer/lcc"
    },
    {
      "name": "strategic-thinking",
      "root": "/Users/jeremiah/Developer/strategic-thinking"
    }
  ],
  "sessions": {
    "session-abc123": {
      "project": "ccem",
      "started_at": "2026-02-19T10:00:00Z",
      "last_heartbeat": "2026-02-19T12:34:56Z",
      "agent_count": 5
    }
  }
}
```

## Configuration Fields

| Field | Type | Description |
|-------|------|-------------|
| **project_name** | string | Currently active project (human-readable) |
| **project_root** | string | Filesystem path to active project |
| **active_project** | string | Project ID/name for routing |
| **port** | integer | Server port (default 3031) |
| **projects** | array | List of configured projects |
| **sessions** | object | Active session metadata |

## Projects Array

Each project object contains:

```json
{
  "name": "project-id",
  "root": "/absolute/path/to/project"
}
```

- **name**: Unique identifier, used in agent registration and routing
- **root**: Absolute filesystem path to project root

## Adding a New Project

### Step 1: Update Configuration

Edit `/Users/jeremiah/Developer/ccem/apm/apm_config.json` and add to `projects` array:

```json
{
  "name": "new-project",
  "root": "/Users/jeremiah/Developer/new-project"
}
```

### Step 2: Reload Configuration

Send a reload request to the server:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

Or restart the server:

```bash
mix phx.server
```

### Step 3: Verify in Dashboard

Open `http://localhost:3031` and check the **Project Selector** dropdown. The new project should appear.

## Switching Projects

### Via Dashboard

1. Click the **Project Selector** dropdown at the top of the page
2. Select the target project
3. The dashboard filters to show agents and data for that project only

### Via API

```bash
curl -X POST http://localhost:3031/api/config/reload \
  -H "Content-Type: application/json" \
  -d '{"active_project": "lcc"}'
```

### Via Session Hooks

The session initialization hook updates the active project:

```bash
source ~/Developer/ccem/apm/hooks/session_init.sh
```

This script detects your current working directory and sets the active project automatically.

## Project Namespacing

Agents, sessions, and data are isolated by project namespace:

- **Agent Registration**: Agents must include `"project": "project-name"` in registration payload
- **Session Isolation**: Each session belongs to exactly one project
- **Data Filtering**: Dashboard automatically filters all data by active project
- **Metrics**: Project-specific metrics in stats cards

Example agent registration:

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "analyzer",
    "type": "individual",
    "project": "ccem",
    "tier": 2,
    "capabilities": ["analysis", "review"]
  }'
```

The `"project"` field determines which namespace the agent belongs to.

## Project Selector Dropdown

Located in the top navigation bar:

- Shows all configured projects
- Current project is highlighted
- Click to switch instantly
- Updates dashboard filter in real-time
- Persists selection in browser local storage

## Sessions Per Project

Sessions are tracked per project in the `sessions` object:

```json
"sessions": {
  "session-1": {
    "project": "ccem",
    "started_at": "2026-02-19T10:00:00Z",
    "last_heartbeat": "2026-02-19T12:34:56Z",
    "agent_count": 5
  },
  "session-2": {
    "project": "lcc",
    "started_at": "2026-02-19T10:15:00Z",
    "last_heartbeat": "2026-02-19T12:30:00Z",
    "agent_count": 3
  }
}
```

Only sessions for the active project are displayed in the dashboard.

## Switching Directories

When working in different project directories, the session hook automatically updates the config:

```bash
# Working on CCEM
cd /Users/jeremiah/Developer/ccem
source ~/Developer/ccem/apm/hooks/session_init.sh
# Config updates: active_project = "ccem", project_root = "/Users/jeremiah/Developer/ccem"

# Switch to LCC
cd /Users/jeremiah/Developer/lcc
source ~/Developer/ccem/apm/hooks/session_init.sh
# Config updates: active_project = "lcc", project_root = "/Users/jeremiah/Developer/lcc"
```

## API Endpoints

### Get All Projects

```bash
curl http://localhost:3031/api/projects
```

Response:

```json
{
  "projects": [
    {"name": "ccem", "root": "/Users/jeremiah/Developer/ccem"},
    {"name": "lcc", "root": "/Users/jeremiah/Developer/lcc"}
  ],
  "active": "ccem"
}
```

### Get Project Agents

```bash
curl http://localhost:3031/api/agents?project=ccem
```

Returns agents filtered by project.

## Best Practices

1. **Consistent Naming**: Use lowercase project names with hyphens (e.g., `project-name`, not `Project Name`)
2. **Absolute Paths**: Always use absolute filesystem paths in project root
3. **Session Registration**: Always include project name in agent registration
4. **Documentation**: Add project names to team documentation and wikis
5. **Cleanup**: Remove unused projects from apm_config.json periodically

## Troubleshooting

**Project not appearing in dropdown?**
- Verify it's in `apm_config.json` projects array
- Run `/api/config/reload` to reload config
- Restart server: `mix phx.server`

**Switching projects shows wrong agents?**
- Refresh page (Cmd+R)
- Check WebSocket connection in DevTools
- Verify agents have correct project name in registration

**New session in wrong project?**
- Check your current working directory
- Run session hook again: `source ~/Developer/ccem/apm/hooks/session_init.sh`
- Verify apm_config.json updated correctly: `cat ~/Developer/ccem/apm/apm_config.json | jq .active_project`

See [Configuration](../admin/configuration.md) for advanced multi-project setup.

---

## See Also

- [Configuration](/docs/admin/configuration) - apm_config.json setup
- [Agent Fleet](/docs/user/agents) - Understanding agent types and statuses
