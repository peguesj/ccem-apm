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

## Hook Inventory

The following table lists all active CCEM APM hooks registered in `~/.claude/settings.json` as of v6.4.0:

| Hook Script | Event | Matcher | Purpose |
|---|---|---|---|
| `~/Developer/ccem/apm/hooks/session_init.sh` | `SessionStart` | `*` | Start APM server, register session, UPSERT config |
| `~/Developer/ccem/apm/hooks/pre_tool_use.sh` | `PreToolUse` | `*` | APM heartbeat / span start before each tool |
| `~/Developer/ccem/apm/hooks/post_tool_use.sh` | `PostToolUse` | `*` | APM span close / event emission after each tool |
| `~/Developer/ccem/apm/hooks/claude_usage_check.sh` | `PreToolUse` | `*` | Read current usage summary; warn on intensive projects |
| `~/Developer/ccem/apm/hooks/claude_usage_record.sh` | `PostToolUse` | `*` | Record tool execution to ClaudeUsageStore via `/api/usage/record` |
| `~/Developer/ccem/apm/hooks/subagent_start.sh` | `SubagentStart` | `*` | Register subagent spawn with APM |
| `~/Developer/ccem/apm/hooks/subagent_stop.sh` | `SubagentStop` | `*` | Mark subagent complete in APM |
| `~/Developer/ccem/apm/hooks/session_end.sh` | `SessionEnd` | `*` | Flush session state to APM on session close |
| `~/.claude/hooks/doc_progress_tracker.sh` | `PostToolUse` | `Write\|Edit\|MultiEdit` | Fire APM event + toast when `priv/docs/**/*.md` files are written |
| `~/.claude/hooks/pre_tool_use.sh` | `PreToolUse` | `*` | User-scope pre-tool hook (disk space, general checks) |
| `~/.claude/hooks/disk_space_check.sh` | `PreToolUse` | `*` | Abort if disk space is critically low |
| `~/.claude/hooks/port_availability_check.sh` | `PreToolUse` | `Bash` | Validate port availability before Bash commands |
| `~/.claude/hooks/drtw_discovery.sh` | `PreToolUse` | `Write\|Edit\|MultiEdit` | Surface DRTW recommendations before file writes |

## Key Variables

```bash
APM_DIR="$HOME/Developer/ccem/apm"           # APM shared directory (config, sessions, hooks)
APM_V4_DIR="$HOME/Developer/ccem/apm-v5"     # Phoenix project root
APM_PORT=3032                                 # HTTP listen port
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
  "apm_port": 3032
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
  "apm_port": 3032,
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
2026-02-19 22:55:29 [APM-HOOK-v4] APM server already running on port 3032
2026-02-19 22:55:29 [APM-HOOK-v4] Session registered: /Users/jeremiah/Developer/ccem/apm/sessions/afb88ff8-....json
2026-02-19 22:55:29 [APM-HOOK-v4] Added session afb88ff8-... to existing project sfa
2026-02-19 22:55:29 [APM-HOOK-v4] APM v4 config updated (active_project: sfa, total projects: 12)
2026-02-19 22:55:29 [APM-HOOK-v4] Sent config reload to APM server
```

---

## Claude Usage Tracking Hooks

Introduced in v6.4.0, the Claude usage tracking hooks instrument every tool call to record model usage, token consumption, and tool call frequency. Data is aggregated in the `ClaudeUsageStore` GenServer and surfaced in the `/usage` LiveView dashboard.

### claude_usage_check.sh

**Location:** `~/Developer/ccem/apm/hooks/claude_usage_check.sh`
**Event:** `PreToolUse`
**Matcher:** `*` (all tools)

This hook fires before every tool execution. It reads the current usage summary from APM and writes a warning to stderr when the active project has reached an "intensive" effort level (more than 100 tool calls in the current session). It never blocks execution -- the hook always exits 0 regardless of APM availability.

```bash
APM_URL="http://localhost:3032"
PROJECT=$(basename "$PWD")

# Attempt to fetch summary; skip silently if APM is not running
SUMMARY=$(curl -s --max-time 2 "$APM_URL/api/usage/summary" 2>/dev/null)

if [ "$PROJECT_EFFORT" = "intensive" ]; then
  echo "CCEM APM: Intensive usage detected for project '$PROJECT' \
(>100 tool calls/session). Consider using a lighter model for simple tasks." >&2
fi

exit 0
```

**Data read:**

- `GET /api/usage/summary` -- returns a JSON object with per-project effort levels
- Field path: `.summary.projects.<project_name>.effort_level` -- one of `"low"`, `"moderate"`, `"intensive"`

**Behavior:**

- If APM is unreachable or the request times out (2s), the hook exits silently.
- If the project is at `"intensive"` effort, a warning is printed to stderr (visible in Claude Code output).
- Never blocks or modifies tool execution.

### claude_usage_record.sh

**Location:** `~/Developer/ccem/apm/hooks/claude_usage_record.sh`
**Event:** `PostToolUse`
**Matcher:** `*` (all tools)

This hook fires after every tool execution. It reads token counters from Claude Code environment variables and submits a fire-and-forget POST to the APM usage recording endpoint. The request runs in the background so it never adds latency to tool execution.

```bash
APM_URL="http://localhost:3032"
PROJECT=$(basename "$PWD")
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
INPUT="${CLAUDE_INPUT_TOKENS:-0}"
OUTPUT="${CLAUDE_OUTPUT_TOKENS:-0}"
CACHE="${CLAUDE_CACHE_TOKENS:-0}"

curl -s -X POST "$APM_URL/api/usage/record" \
  -H "Content-Type: application/json" \
  -d "{\"project\":\"$PROJECT\",\"model\":\"$MODEL\",\"input_tokens\":$INPUT,\"output_tokens\":$OUTPUT,\"cache_tokens\":$CACHE,\"tool_calls\":1}" \
  >/dev/null 2>&1 &

exit 0
```

**Data captured per tool call:**

| Field | Source | Description |
|---|---|---|
| `project` | `basename "$PWD"` | Active project name |
| `model` | `$CLAUDE_MODEL` env var | Model identifier (e.g. `claude-sonnet-4-6`) |
| `input_tokens` | `$CLAUDE_INPUT_TOKENS` env var | Input tokens consumed by the tool call |
| `output_tokens` | `$CLAUDE_OUTPUT_TOKENS` env var | Output tokens produced |
| `cache_tokens` | `$CLAUDE_CACHE_TOKENS` env var | Cache read tokens consumed |
| `tool_calls` | Hardcoded `1` | Increments the tool call counter by 1 per invocation |

**APM endpoint:** `POST /api/usage/record`

**ClaudeUsageStore pipeline:**

1. The hook POSTs a record to `/api/usage/record`.
2. `ClaudeUsageStore` (GenServer) receives the record and accumulates totals per project and model.
3. Effort level is computed: `< 50` tool calls = `"low"`, `50–100` = `"moderate"`, `> 100` = `"intensive"`.
4. The `/usage` LiveView dashboard queries `ClaudeUsageStore` on a 5-second refresh interval and renders per-project usage, token totals, model breakdown, and effort level badges.
5. The usage summary (used by `claude_usage_check.sh`) is served from `GET /api/usage/summary`.

---

## Documentation Progress Tracker Hook

Introduced in v6.4.0, this hook provides real-time visibility into documentation update progress during formations that write to `priv/docs/**/*.md`.

### doc_progress_tracker.sh

**Location:** `~/.claude/hooks/doc_progress_tracker.sh`
**Event:** `PostToolUse`
**Matcher:** `Write|Edit|MultiEdit`

This hook fires after any file write, edit, or multi-edit operation. It inspects the target file path and acts only when the path contains `priv/docs` and ends with `.md`. For matching writes it emits two fire-and-forget APM calls in parallel:

1. **UPM event** -- `POST /api/upm/event` with `event_type: "task_complete"`, tagging the formation, wave, and file name.
2. **Toast notification** -- `POST /api/notify` with a `"success"` toast visible in the APM dashboard notification panel.

```bash
# Only fire for priv/docs/**/*.md files
if [[ "$FILE_PATH" != *"priv/docs"* ]] || [[ "$FILE_PATH" != *.md ]]; then
  exit 0
fi

# UPM event (fire-and-forget)
curl -s -X POST "${APM_URL}/api/upm/event" \
  -H "Content-Type: application/json" \
  -d "{
    \"event_type\": \"task_complete\",
    \"agent_id\": \"fmt-docs-wiki-hook\",
    \"formation_id\": \"${FORMATION_ID}\",
    \"formation_role\": \"individual\",
    \"wave\": 1,
    \"task_subject\": \"docs: ${DOC_NAME}\",
    \"project\": \"ccem/apm-v4\",
    ...
  }" >/dev/null 2>&1 &

# Toast notification (fire-and-forget)
curl -s -X POST "${APM_URL}/api/notify" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"success\",
    \"title\": \"Docs Updated\",
    \"message\": \"${DOC_NAME} written by ${TOOL_NAME}\",
    \"category\": \"formation\",
    \"formation_id\": \"${FORMATION_ID}\"
  }" >/dev/null 2>&1 &
```

**APM endpoints used:**

| Endpoint | Purpose |
|---|---|
| `POST /api/upm/event` | Emit a structured formation event (task_complete) for the Formation Live dashboard |
| `POST /api/notify` | Push a success toast to the APM notification panel |

**Event payload fields:**

| Field | Value | Description |
|---|---|---|
| `event_type` | `"task_complete"` | Maps to the UPM task completion event type |
| `agent_id` | `"fmt-docs-wiki-hook"` | Logical agent identity for this hook |
| `formation_id` | Set at hook authoring time | Identifies the formation this hook was deployed for |
| `formation_role` | `"individual"` | Leaf-level formation role |
| `wave` | `1` | Wave number within the formation |
| `task_subject` | `"docs: <relative-doc-path>"` | Human-readable description of the written file |
| `project` | `"ccem/apm-v4"` | Project namespace |

**Using this hook in formations:**

When deploying a formation that updates documentation:

1. Ensure `~/.claude/hooks/doc_progress_tracker.sh` exists and is executable.
2. The hook is automatically active because `~/.claude/settings.json` registers it for `Write|Edit|MultiEdit` events (PostToolUse).
3. Each time an agent in the formation writes a `priv/docs/**/*.md` file, a toast appears in the APM dashboard and a `task_complete` UPM event is recorded.
4. Formation progress is therefore visible in real time on the APM Formation Live page at `http://localhost:3032/formations`.

**No additional configuration is required.** The `FORMATION_ID` embedded in the script identifies which formation the hook was generated for. For different formations, generate a new hook instance with the appropriate `FORMATION_ID` value set at the top of the file.

---

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
ls -la ~/Developer/ccem/apm-v5/mix.exs

# Check server log for errors
tail -20 ~/Developer/ccem/apm/hooks/apm_server.log

# Try starting manually
cd ~/Developer/ccem/apm-v5 && mix phx.server
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

### Issue: Usage Not Appearing in /usage Dashboard

**Symptoms:** Tool calls are executing but the `/usage` LiveView shows no data.

**Cause:** `claude_usage_record.sh` hook is not registered, APM is not running, or `ClaudeUsageStore` lost state on restart.

**Fix:**

```bash
# Verify the hook is registered
grep -A3 "claude_usage_record" ~/.claude/settings.json

# Test the endpoint manually
curl -s -X POST http://localhost:3032/api/usage/record \
  -H "Content-Type: application/json" \
  -d '{"project":"test","model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50,"cache_tokens":0,"tool_calls":1}'

# Check APM is running
curl -s http://localhost:3032/api/status | jq '.status'
```

### Issue: doc_progress_tracker Toast Not Appearing

**Symptoms:** Writing a `priv/docs/**/*.md` file does not produce a toast notification.

**Cause:** Hook script is not executable, APM is not running, or the file path does not match the `priv/docs` pattern.

**Fix:**

```bash
# Verify script is executable
ls -la ~/.claude/hooks/doc_progress_tracker.sh

# Make executable if needed
chmod +x ~/.claude/hooks/doc_progress_tracker.sh

# Verify APM is running
curl -s http://localhost:3032/api/status | jq '.status'

# Test notify endpoint manually
curl -s -X POST http://localhost:3032/api/notify \
  -H "Content-Type: application/json" \
  -d '{"type":"success","title":"Test","message":"Hook test","category":"formation"}'
```

## See Also

- [Configuration](configuration.md) -- Full config schema reference
- [Deployment](deployment.md) -- Server setup and management
- [Troubleshooting](troubleshooting.md) -- Common issues

---

*CCEM APM v6.4.0 — Author: Jeremiah Pegues*
