# Configuration Reference

CCEM APM is configured via `apm_config.json`, located at `/Users/jeremiah/Developer/ccem/apm/apm_config.json`.

## File Location

```
/Users/jeremiah/Developer/ccem/apm/apm_config.json
```

If the file doesn't exist, CCEM APM creates a default one on first startup.

## Configuration Structure

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

## Top-Level Fields

### project_name
**Type**: `string`
**Default**: `"ccem"`
**Description**: Human-readable name of the currently active project.

```json
"project_name": "my-project"
```

### project_root
**Type**: `string`
**Default**: Current working directory
**Description**: Absolute filesystem path to the active project root.

```json
"project_root": "/Users/jeremiah/Developer/my-project"
```

Must be an absolute path. Relative paths are not supported.

### active_project
**Type**: `string`
**Default**: `"ccem"`
**Description**: Project ID matching an entry in the `projects` array.

```json
"active_project": "ccem"
```

Used for routing API requests and filtering data by project.

### port
**Type**: `integer`
**Default**: `3031`
**Description**: HTTP server listen port.

```json
"port": 3031
```

Valid range: 1024-65535. Ports < 1024 require root/sudo.

### projects
**Type**: `array of objects`
**Description**: Array of configured projects.

```json
"projects": [
  {
    "name": "ccem",
    "root": "/Users/jeremiah/Developer/ccem"
  },
  {
    "name": "lcc",
    "root": "/Users/jeremiah/Developer/lcc"
  }
]
```

Each project object:

| Field | Type | Description |
|-------|------|-------------|
| **name** | string | Unique project identifier (lowercase, hyphens ok) |
| **root** | string | Absolute path to project directory |

### sessions
**Type**: `object`
**Description**: Map of active session metadata.

```json
"sessions": {
  "session-abc123": {
    "project": "ccem",
    "started_at": "2026-02-19T10:00:00Z",
    "last_heartbeat": "2026-02-19T12:34:56Z",
    "agent_count": 5
  }
}
```

Managed automatically by APM. Manual editing not recommended.

Session object fields:

| Field | Type | Description |
|-------|------|-------------|
| **project** | string | Project the session belongs to |
| **started_at** | ISO 8601 string | Session creation timestamp |
| **last_heartbeat** | ISO 8601 string | Most recent session heartbeat |
| **agent_count** | integer | Number of agents in session |

## Optional Fields

### apm_server_url
**Type**: `string`
**Default**: Auto-detected
**Description**: Full URL of APM server (for remote setups).

```json
"apm_server_url": "http://localhost:3031"
```

Used by CCEMAgent and external clients. Auto-set to `http://localhost:{port}`.

### max_agents
**Type**: `integer`
**Default**: `1000`
**Description**: Maximum agents before performance optimizations kick in.

```json
"max_agents": 500
```

At this threshold, agent indexes become more aggressive about cleanup.

### max_sessions
**Type**: `integer`
**Default**: `100`
**Description**: Maximum concurrent sessions before cleanup.

```json
"max_sessions": 50
```

Oldest inactive sessions are archived when exceeded.

### token_budget
**Type**: `integer`
**Default**: `100000`
**Description**: Default token budget per agent.

```json
"token_budget": 100000
```

Used for notifications and budget tracking.

### polling_interval_seconds
**Type**: `integer`
**Default**: `5`
**Description**: CCEMAgent polling interval.

```json
"polling_interval_seconds": 10
```

Adjust for different resource usage profiles.

### enable_docs_server
**Type**: `boolean`
**Default**: `true`
**Description**: Serve documentation wiki from `/docs`.

```json
"enable_docs_server": true
```

### docs_path
**Type**: `string`
**Default**: `"priv/docs"`
**Description**: Relative path to documentation directory.

```json
"docs_path": "priv/docs"
```

### enable_agent_discovery
**Type**: `boolean`
**Default**: `false`
**Description**: Auto-discover agents from environment.

```json
"enable_agent_discovery": true
```

When enabled, agents can be discovered and registered automatically.

### log_level
**Type**: `string`
**Default**: `"info"`
**Description**: Logging verbosity.

```json
"log_level": "debug"
```

Valid values: `debug`, `info`, `warn`, `error`

## Environment Variables

Configuration can be overridden by environment variables:

| Variable | Overrides | Example |
|----------|-----------|---------|
| `APM_PORT` | `port` | `export APM_PORT=3032` |
| `APM_PROJECT` | `active_project` | `export APM_PROJECT=lcc` |
| `APM_CONFIG_PATH` | File location | `export APM_CONFIG_PATH=/path/to/config.json` |
| `APM_LOG_LEVEL` | `log_level` | `export APM_LOG_LEVEL=debug` |

Environment variables take precedence over file config.

```bash
APM_PORT=3032 APM_LOG_LEVEL=debug mix phx.server
```

## Adding a New Project

### Step 1: Edit Configuration

Add to `projects` array:

```json
{
  "name": "new-project",
  "root": "/Users/jeremiah/Developer/new-project"
}
```

### Step 2: Reload Configuration

Restart server or POST to reload endpoint:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

### Step 3: Verify

Check project appears in dashboard selector:

```bash
curl http://localhost:3031/api/projects
```

Response:

```json
{
  "projects": [
    {"name": "ccem", "root": "/Users/jeremiah/Developer/ccem"},
    {"name": "new-project", "root": "/Users/jeremiah/Developer/new-project"}
  ],
  "active": "ccem"
}
```

## Switching Active Project

### Via Configuration File

Edit `active_project`:

```json
{
  "active_project": "lcc"
}
```

Then reload:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

### Via Environment Variable

```bash
export APM_PROJECT=lcc
mix phx.server
```

### Via Dashboard

Click project selector dropdown in web UI and choose project.

## Multi-Project Configuration

Example with multiple projects:

```json
{
  "project_name": "lcc",
  "project_root": "/Users/jeremiah/Developer/lcc",
  "active_project": "lcc",
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
  "sessions": {}
}
```

Each project is isolated:
- Agents registered with different projects don't interact
- Dashboard filters by active project
- Metrics and skills tracked per-project
- Session lifecycle independent per project

## Port Configuration

### Default Port

```json
{
  "port": 3031
}
```

### Custom Port

```json
{
  "port": 3032
}
```

Access at `http://localhost:3032`

### Port Conflicts

If port is already in use:

```bash
# Find process using port
lsof -ti:3031

# Kill the process
kill -9 <pid>

# Or change port in config
```

## Logging Configuration

### Log Level

```json
{
  "log_level": "debug"
}
```

Levels:
- `debug` - Verbose logging for development
- `info` - Standard logging (default)
- `warn` - Only warnings and errors
- `error` - Only errors

### Log Output

Logs print to stdout:

```bash
mix phx.server
# [info] Running ApmV4Web.Endpoint with cowboy ...
# [debug] Received agent registration ...
```

Redirect to file:

```bash
mix phx.server > apm.log 2>&1 &
```

## Configuration Validation

CCEM APM validates config on startup:

- All project roots must exist and be absolute paths
- Port must be in valid range (1024-65535)
- All string fields must be non-empty
- Arrays must be properly formed

Invalid config prints error:

```
[error] Invalid configuration: "project_root" is not an absolute path
```

## Reloading Configuration

Configuration reloaded in three scenarios:

1. **Server restart**: Explicitly kill and restart
2. **API endpoint**: POST `/api/config/reload`
3. **File watch**: Auto-reload if file modified (if enabled)

Reload notification broadcast to all clients:

```
[info] Configuration reloaded
```

Dashboard updates automatically via WebSocket.

## Backup and Recovery

### Backup Configuration

```bash
cp /Users/jeremiah/Developer/ccem/apm/apm_config.json \
   /Users/jeremiah/Developer/ccem/apm/apm_config.json.backup
```

### Restore from Backup

```bash
cp /Users/jeremiah/Developer/ccem/apm/apm_config.json.backup \
   /Users/jeremiah/Developer/ccem/apm/apm_config.json
curl -X POST http://localhost:3031/api/config/reload
```

### Version Control

Track `apm_config.json` in git (with sensitive data redacted):

```bash
git add /Users/jeremiah/Developer/ccem/apm/apm_config.json
git commit -m "Update APM configuration"
```

## Default Configuration

If `apm_config.json` doesn't exist, CCEM APM creates:

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
    }
  ],
  "sessions": {},
  "log_level": "info",
  "token_budget": 100000,
  "polling_interval_seconds": 5
}
```

## Troubleshooting

**Configuration not loading?**
- Verify file path: `/Users/jeremiah/Developer/ccem/apm/apm_config.json`
- Check file permissions: `ls -la apm_config.json`
- Verify valid JSON: `jq empty apm_config.json`

**Port already in use?**
- Find process: `lsof -ti:3031`
- Kill it: `kill -9 <pid>`
- Or change port in config

**Project not appearing?**
- Verify entry in `projects` array
- Check path is absolute: `/Users/...` not `./relative/path`
- Reload config: `curl -X POST http://localhost:3031/api/config/reload`

**Changes not taking effect?**
- Restart server or POST to `/api/config/reload`
- Check environment variables aren't overriding

See [Deployment](deployment.md) for production setup.
