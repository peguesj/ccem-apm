# Configuration Reference

CCEM APM is configured via `apm_config.json`, located at `~/Developer/ccem/apm/apm_config.json`.

## File Location

```text
~/Developer/ccem/apm/apm_config.json
```

If the file doesn't exist, the `ConfigLoader` GenServer creates a default in memory. The session init hook creates the file on disk when a Claude Code session starts.

## Configuration Structure (v4 Schema)

```json
{
  "$schema": "./apm_config_v4.schema.json",
  "version": "4.0.0",
  "port": 3031,
  "active_project": "my-project",
  "projects": [
    {
      "name": "my-project",
      "root": "/Users/jeremiah/Developer/my-project",
      "tasks_dir": "/private/tmp/claude-503/-Users-jeremiah-Developer-my-project/tasks",
      "prd_json": "/Users/jeremiah/Developer/my-project/.claude/ralph/prd.json",
      "todo_md": "",
      "status": "active",
      "primary_port": 4000,
      "port_ownership": "exclusive",
      "registered_at": "2026-02-19T00:00:00Z",
      "sessions": [
        {
          "session_id": "afb88ff8-7315-4887-b0df-73ff794bd6d3",
          "session_jsonl": "/Users/jeremiah/.claude/projects/-Users-jeremiah-Developer-my-project/afb88ff8-7315-4887-b0df-73ff794bd6d3.jsonl",
          "start_time": "2026-02-19T22:55:29Z",
          "status": "active"
        }
      ]
    }
  ]
}
```

## Top-Level Fields

### version

**Type**: `string`
**Required**: Yes
**Value**: `"4.0.0"`

Identifies the config schema version. The session init hook checks this value and will re-initialize the config if it does not equal `"4.0.0"`.

```json
"version": "4.0.0"
```

### port

**Type**: `integer`
**Default**: `3031`

HTTP server listen port for the Phoenix application. Configured in `config/dev.exs` via the `PORT` environment variable.

```json
"port": 3031
```

### active_project

**Type**: `string`
**Default**: `null`

Name of the currently active project. Must match a `name` field in the `projects` array. Updated automatically by the session init hook each time a new Claude Code session starts.

```json
"active_project": "my-project"
```

The `ConfigLoader.get_active_project/0` function looks up this name in the `projects` array and returns the matching project map.

### projects

**Type**: `array of objects`
**Default**: `[]`

Array of all registered projects. Projects are added automatically by the session init hook via jq UPSERT logic -- they are never overwritten, only appended or updated.

## Project Object Fields

Each object in the `projects` array has the following fields:

| Field | Type | Description |
|-------|------|-------------|
| **name** | string | Unique project identifier, derived from `basename` of the working directory |
| **root** | string | Absolute path to the project directory |
| **tasks_dir** | string | Path to Claude Code tasks directory (usually under `/private/tmp/claude-503/`) |
| **prd_json** | string | Path to Ralph PRD file if found at `{root}/.claude/ralph/prd.json`, otherwise `""` |
| **todo_md** | string | Path to TODO file if found under `{root}/.claude/plans/`, otherwise `""` |
| **status** | string | Project status: `"active"` |
| **primary_port** | integer | Primary dev server port for this project (optional, set via `/api/ports/set-primary`) |
| **port_ownership** | string | Port ownership mode: `"exclusive"` or `"shared"` (optional) |
| **registered_at** | ISO 8601 string | Timestamp when the project was first registered |
| **sessions** | array | Array of session objects associated with this project |

## Session Object Fields

Each object in a project's `sessions` array:

| Field | Type | Description |
|-------|------|-------------|
| **session_id** | string | UUID of the Claude Code session |
| **session_jsonl** | string | Path to the session's JSONL transcript file |
| **start_time** | ISO 8601 string | When the session was registered |
| **status** | string | Session status: `"active"` |

## ConfigLoader GenServer API

The `ApmV4.ConfigLoader` module provides the runtime interface to the config:

| Function | Return | Description |
|----------|--------|-------------|
| `get_config()` | `map()` | Returns the full parsed config map |
| `get_project(name)` | `map() \| nil` | Finds a project by name in the projects array |
| `get_active_project()` | `map() \| nil` | Returns the project matching `active_project` |
| `reload()` | `:ok` | Re-reads config from disk, broadcasts via PubSub |
| `update_project(params)` | `{:ok, map()} \| {:error, String.t()}` | Updates a project's fields and persists to disk |

On startup, `ConfigLoader` also syncs all sessions from the config into the `AgentRegistry` so the dashboard shows accurate session counts immediately.

## Default Configuration

If `apm_config.json` does not exist or fails to parse, `ConfigLoader` uses this default:

```json
{
  "version": "4.0.0",
  "port": 3031,
  "active_project": null,
  "projects": []
}
```

## Environment Variables

| Variable | Overrides | Example |
|----------|-----------|---------|
| `PORT` | Phoenix HTTP listen port | `PORT=3032 mix phx.server` |

The Phoenix endpoint reads `PORT` from the environment in `config/dev.exs` and `config/runtime.exs`. The config file's `port` field is informational for the hook and dashboard.

## Adding a New Project

Projects are added automatically when a Claude Code session starts in a new directory. The session init hook runs `basename` on the working directory to derive the project name and uses jq to UPSERT the project into the `projects` array.

To add a project manually:

```bash
jq --arg name "new-project" --arg root "/path/to/project" \
  '.projects += [{"name": $name, "root": $root, "tasks_dir": "", "prd_json": "", "todo_md": "", "status": "active", "registered_at": (now | todate), "sessions": []}]' \
  ~/Developer/ccem/apm/apm_config.json > /tmp/config.tmp && \
  mv /tmp/config.tmp ~/Developer/ccem/apm/apm_config.json
```

Then reload:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

## Switching Active Project

The `active_project` field is updated automatically by the session init hook whenever a new Claude Code session starts. It can also be changed manually:

```bash
jq '.active_project = "other-project"' ~/Developer/ccem/apm/apm_config.json > /tmp/config.tmp && \
  mv /tmp/config.tmp ~/Developer/ccem/apm/apm_config.json
curl -X POST http://localhost:3031/api/config/reload
```

## Reloading Configuration

Configuration can be reloaded at runtime via the API:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

This calls `ConfigLoader.reload/0`, which re-reads the file from disk, syncs sessions into the `AgentRegistry`, and broadcasts a `{:config_reloaded, config}` event on the `apm:config` PubSub topic. All connected LiveView dashboards update automatically via WebSocket.

## Port Configuration

The APM server listens on port 3031 by default. To use a different port:

```bash
PORT=3032 mix phx.server
```

If the port is already in use:

```bash
# Find process using port
lsof -ti:3031

# Kill the process
kill -9 $(lsof -ti:3031)
```

## Backup and Recovery

```bash
# Backup
cp ~/Developer/ccem/apm/apm_config.json ~/Developer/ccem/apm/apm_config.json.backup

# Restore
cp ~/Developer/ccem/apm/apm_config.json.backup ~/Developer/ccem/apm/apm_config.json
curl -X POST http://localhost:3031/api/config/reload
```

## Troubleshooting

**Configuration not loading?**
- Verify file exists: `ls -la ~/Developer/ccem/apm/apm_config.json`
- Check valid JSON: `jq empty ~/Developer/ccem/apm/apm_config.json`
- Check version field equals `"4.0.0"`

**Project not appearing?**
- Verify entry in `projects` array: `jq '.projects[].name' ~/Developer/ccem/apm/apm_config.json`
- Reload config: `curl -X POST http://localhost:3031/api/config/reload`

**Changes not taking effect?**
- POST to `/api/config/reload` or `/api/reload`
- Both endpoints call the same `ConfigLoader.reload/0` function

See [Deployment](deployment.md) for production setup.
