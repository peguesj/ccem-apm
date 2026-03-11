# Session Initialization Hooks

CCEM APM uses a shell hook invoked by Claude Code's `SessionStart` event to automatically start the APM server, register sessions, and maintain the multi-project config.

## Overview

The hook script is called by Claude Code on every session start. It receives a JSON payload on stdin containing the `session_id` and `cwd`, then performs a series of operations to ensure the APM server is running and the session is registered.

### Session Start Flow

When a new Claude Code session begins, the following steps execute in order:

1. **Parse input** -- Read JSON from stdin to extract `session_id` and `cwd`
2. **Detect project** -- Derive project name from `basename` of the working directory
3. **Check APM server** -- Test if the Phoenix server is running via PID file or port check
4. **Start server (if needed)** -- Launch `mix phx.server` in the background with `nohup`
5. **Wait for readiness** -- Pause 3 seconds, then confirm the port is listening via `lsof`
6. **Create session file** -- Write per-session JSON to `~/Developer/ccem/apm/sessions/{session_id}.json`
7. **Discover project files** -- Locate `tasks_dir`, `prd_json`, and `todo_md` for the project
8. **UPSERT config** -- Add or update the project and session in `apm_config.json` using jq
9. **Reload server config** -- POST to `/api/config/reload` so the dashboard picks up changes
10. **Output result** -- Print JSON success payload to stdout for the Claude Code hook system

> **Important:** The hook is invoked as a subprocess by Claude Code, not sourced into the shell. It must complete quickly and write valid JSON to stdout.

## Hook Location

```text
~/Developer/ccem/apm/hooks/session_init.sh
```

This is invoked as a Claude Code `SessionStart` hook, not sourced into the shell. The hook configuration lives in `~/.claude/hooks/` or the project's `.claude/hooks/` directory.

## Key Variables

```bash
APM_DIR="$HOME/Developer/ccem/apm"           # APM shared directory (config, sessions, hooks)
APM_V4_DIR="$HOME/Developer/ccem/apm-v4"     # Phoenix project root
APM_PORT=3031                                 # HTTP listen port
SESSIONS_DIR="$APM_DIR/sessions"             # Per-session JSON files
LOG_FILE="$APM_DIR/hooks/apm_hook.log"       # Hook activity log
PID_FILE="$APM_V4_DIR/.apm.pid"             # Server PID file
CONFIG_FILE="$APM_DIR/apm_config.json"       # Multi-project config
```

## How It Works

### 1. Input Parsing

The hook reads JSON from stdin (the Claude Code hook payload):

```bash
INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"' 2>/dev/null || pwd)
```

### 2. Project Detection

The project name is derived from the basename of the working directory -- there is no hardcoded mapping:

```bash
PROJECT_NAME=$(basename "$CWD" 2>/dev/null || echo "unknown")
```

For example, `/Users/jeremiah/Developer/sfa` becomes `sfa`, and `/Users/jeremiah/tools/@yj/lfg` becomes `lfg`.

### 3. APM Server Check and Start

The hook checks whether the APM server is running by examining the PID file and falling back to a port check:

```bash
is_apm_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Fallback: check if port is in use
    if lsof -ti:"$APM_PORT" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}
```

If the server is not running, it starts `mix phx.server` in the background with nohup:

```bash
(cd "$APM_V4_DIR" && nohup mix phx.server > "$APM_DIR/hooks/apm_server.log" 2>&1) &
local pid=$!
echo "$pid" > "$PID_FILE"
```

It waits 3 seconds then confirms the port is listening via `lsof`.

> **Warning:** Never run multiple APM instances on the same port. The hook checks for an existing process before starting a new one to prevent conflicts.

### 4. Per-Session File Creation

A JSON file is created at `~/Developer/ccem/apm/sessions/{session_id}.json` with session metadata:

```json
{
  "session_id": "<uuid>",
  "project_name": "<basename of cwd>",
  "project_root": "<cwd>",
  "start_time": "2026-02-19T22:55:29Z",
  "status": "active",
  "session_jsonl": "<path to .jsonl transcript>",
  "tasks_dir": "<path to tasks dir>",
  "prd_json": "<path to prd.json if found>",
  "todo_md": "<path to TODO if found>",
  "apm_port": 3031
}
```

### 5. Discovery of tasks_dir, prd_json, todo_md

The hook looks for project-specific files:

- **tasks_dir**: Constructed from the encoded CWD path under `/private/tmp/claude-503/`
- **prd_json**: Checks for `${CWD}/.claude/ralph/prd.json`
- **todo_md**: Scans `${CWD}/.claude/plans/*TODO*.md` for the first match

### 6. Config UPSERT (v4 Schema)

The `update_apm_config` function is the core of the multi-project logic. It uses jq to perform an UPSERT that never overwrites other projects.

**V4 schema check**: If the config file does not exist or its `version` field is not `"4.0.0"`, a fresh v4 config is created:

```bash
if [ ! -f "$CONFIG_FILE" ] || ! jq -e '.version == "4.0.0"' "$CONFIG_FILE" >/dev/null 2>&1; then
    # Creates fresh v4 config with empty projects array
fi
```

**Project exists -- upsert session**:

```bash
# Check if project already exists
project_exists=$(jq --arg name "$PROJECT_NAME" \
    '[.projects[] | select(.name == $name)] | length' "$CONFIG_FILE")

if [ "$project_exists" -gt "0" ]; then
    # Check if session already exists within that project
    session_exists=$(jq --arg name "$PROJECT_NAME" --arg sid "$SESSION_ID" \
        '[.projects[] | select(.name == $name) | .sessions[]? | select(.session_id == $sid)] | length' \
        "$CONFIG_FILE")

    if [ "$session_exists" -eq "0" ]; then
        # Append new session to existing project's sessions array
        jq --arg name "$PROJECT_NAME" --arg sid "$SESSION_ID" --arg jsonl "$jsonl_path" --arg now "$now" \
            '(.projects[] | select(.name == $name) | .sessions) += [{
                "session_id": $sid,
                "session_jsonl": $jsonl,
                "start_time": $now,
                "status": "active"
            }] | .active_project = $name' \
            "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        # Session already registered, just update active_project
        jq --arg name "$PROJECT_NAME" '.active_project = $name' \
            "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
```

**New project -- append**:

```bash
else
    # Append entire new project object with first session
    jq --arg name "$PROJECT_NAME" --arg root "$CWD" --arg tasks "$tasks_dir" \
       --arg prd "$prd_json" --arg sid "$SESSION_ID" --arg jsonl "$jsonl_path" --arg now "$now" \
        '.projects += [{
            "name": $name,
            "root": $root,
            "tasks_dir": $tasks,
            "prd_json": $prd,
            "todo_md": "",
            "status": "active",
            "registered_at": $now,
            "sessions": [{
                "session_id": $sid,
                "session_jsonl": $jsonl,
                "start_time": $now,
                "status": "active"
            }]
        }] | .active_project = $name' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi
```

In both cases, `active_project` is set to the current project name.

### 7. Config Reload Notification

After updating the config file, the hook notifies the running APM server to reload:

```bash
curl -s -X POST "http://localhost:${APM_PORT}/api/config/reload" >/dev/null 2>&1 || true
```

### 8. Hook Output

The hook outputs a JSON success payload to stdout for the Claude Code hook system:

```json
{
  "success": true,
  "apm_running": true,
  "apm_port": 3031,
  "session_id": "<uuid>",
  "project_name": "<basename>",
  "apm_url": "http://localhost:3032"
}
```

## Logging

All hook activity is logged to:

```text
~/Developer/ccem/apm/hooks/apm_hook.log
```

Log entries are prefixed with timestamps and `[APM-HOOK-v4]`:

```text
2026-02-19 22:55:29 [APM-HOOK-v4] Session init: afb88ff8-... (cwd: /Users/jeremiah/Developer/sfa)
2026-02-19 22:55:29 [APM-HOOK-v4] APM server already running on port 3031
2026-02-19 22:55:29 [APM-HOOK-v4] Session registered: /Users/jeremiah/Developer/ccem/apm/sessions/afb88ff8-....json
2026-02-19 22:55:29 [APM-HOOK-v4] Added session afb88ff8-... to existing project sfa
2026-02-19 22:55:29 [APM-HOOK-v4] APM v4 config updated (active_project: sfa, total projects: 12)
2026-02-19 22:55:29 [APM-HOOK-v4] Sent config reload to APM server
```

## Troubleshooting

### Issue: Hook Not Running

**Symptoms:** No log entries in `apm_hook.log` when starting a new Claude Code session.

**Cause:** Claude Code hook configuration does not point to the correct script path.

**Fix:** Verify the `SessionStart` hook in `~/.claude/hooks/` or `.claude/hooks/` references the correct path to `session_init.sh`.

### Issue: APM Server Not Starting

**Symptoms:** Hook runs but dashboard is unreachable.

**Cause:** Missing dependencies, compilation errors, or the APM v4 directory does not exist.

**Fix:**

```bash
# Check if APM v4 directory exists
ls -la ~/Developer/ccem/apm-v4/mix.exs

# Check server log for errors
tail -20 ~/Developer/ccem/apm/hooks/apm_server.log

# Try starting manually
cd ~/Developer/ccem/apm-v4 && mix phx.server
```

### Issue: Config Not Updating

**Symptoms:** New sessions or projects do not appear in `apm_config.json` after hook runs.

**Cause:** `jq` not installed, config file not writable, or invalid JSON in existing config.

**Fix:**

```bash
# Verify jq is installed
which jq

# Check config is valid JSON
jq empty ~/Developer/ccem/apm/apm_config.json

# Check version is v4
jq '.version' ~/Developer/ccem/apm/apm_config.json
```

### Issue: Session Not Appearing in Dashboard

**Symptoms:** Session file created but dashboard does not show the session.

**Cause:** Config reload request failed (server not ready or network error).

**Fix:**

```bash
# Check per-session file was created
ls ~/Developer/ccem/apm/sessions/

# Force a config reload
curl -X POST http://localhost:3032/api/config/reload

# Check hook log for errors
tail -20 ~/Developer/ccem/apm/hooks/apm_hook.log
```

## See Also

- [Configuration](configuration.md) -- Full config schema reference
- [Deployment](deployment.md) -- Server setup and management
- [Troubleshooting](troubleshooting.md) -- Common issues
