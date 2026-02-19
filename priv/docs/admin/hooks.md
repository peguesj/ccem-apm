# Session Initialization Hooks

CCEM APM uses shell hooks to automatically initialize sessions, register with the APM server, and maintain configuration state.

## Overview

Session hooks are shell scripts that:

1. Detect current working directory and project
2. Start APM server if not running
3. Register current session with APM
4. Update `apm_config.json` with active project
5. Initialize environment for Claude Code session

## Hook Location

```
~/Developer/ccem/apm/hooks/session_init.sh
```

## Hook Initialization

Source the hook at the start of your Claude Code session:

```bash
source ~/Developer/ccem/apm/hooks/session_init.sh
```

Or add to shell profile for auto-invocation:

### Bash (~/.bashrc or ~/.bash_profile)

```bash
# At the end of file
if [[ -f ~/Developer/ccem/apm/hooks/session_init.sh ]]; then
  source ~/Developer/ccem/apm/hooks/session_init.sh
fi
```

### Zsh (~/.zshrc)

```bash
# At the end of file
if [[ -f ~/Developer/ccem/apm/hooks/session_init.sh ]]; then
  source ~/Developer/ccem/apm/hooks/session_init.sh
fi
```

## Hook Behavior

### 1. Project Detection

Detects current project from working directory:

```bash
# If in /Users/jeremiah/Developer/ccem, detects project "ccem"
# If in /Users/jeremiah/Developer/lcc, detects project "lcc"
# etc.
```

Mapping based on `apm_config.json` projects array.

### 2. Server Check

Checks if APM server is running on port 3031:

```bash
curl -s http://localhost:3031/health
```

- **If running**: Proceeds to registration
- **If not running**: Starts server automatically

### 3. Server Start (if needed)

Starts APM server in background:

```bash
cd /Users/jeremiah/Developer/ccem/apm-v4
mix phx.server &
echo $! > .apm.pid
```

Waits for server to be ready (max 30 seconds).

### 4. Session Registration

Registers current session with APM:

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "claude-code-session",
    "type": "orchestrator",
    "project": "ccem",
    "tier": 3,
    "capabilities": ["session-orchestration", "agent-dispatch"]
  }'
```

Session ID generated and stored.

### 5. Configuration Update

Updates `apm_config.json` to set active project:

```json
{
  "project_name": "ccem",
  "project_root": "/Users/jeremiah/Developer/ccem",
  "active_project": "ccem",
  "sessions": {
    "session-abc123": {
      "project": "ccem",
      "started_at": "2026-02-19T10:00:00Z",
      "last_heartbeat": "2026-02-19T10:00:00Z",
      "agent_count": 0
    }
  }
}
```

### 6. Environment Setup

Sets shell environment variables:

```bash
export CCEM_APM_URL="http://localhost:3031"
export CCEM_APM_PROJECT="ccem"
export CCEM_SESSION_ID="session-abc123"
```

## Hook Script

Standard hook implementation:

```bash
#!/bin/bash

# CCEM APM Session Initialization Hook
# Source this script to initialize a Claude Code session

set -e

APM_HOME="${APM_HOME:-${HOME}/Developer/ccem/apm}"
APM_V4_HOME="${APM_V4_HOME:-${HOME}/Developer/ccem/apm-v4}"
CONFIG_FILE="${APM_HOME}/apm_config.json"
APM_URL="http://localhost:3031"
APM_PORT="3031"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}[CCEM APM]${NC} Initializing session..."

# Detect project from current directory
detect_project() {
  local cwd="$PWD"

  # Map directory to project
  case "$cwd" in
    *"Developer/ccem"*) echo "ccem" ;;
    *"Developer/lcc"*) echo "lcc" ;;
    *"Developer/strategic-thinking"*) echo "strategic-thinking" ;;
    *"Developer/lgtm"*) echo "lgtm" ;;
    *) echo "unknown" ;;
  esac
}

# Check if APM server is running
is_apm_running() {
  curl -s "${APM_URL}/health" > /dev/null 2>&1
  return $?
}

# Start APM server
start_apm_server() {
  echo -e "${YELLOW}[CCEM APM]${NC} APM not running, starting server..."

  cd "$APM_V4_HOME"
  nohup mix phx.server > /tmp/ccem-apm.log 2>&1 &
  local pid=$!
  echo $pid > "$APM_V4_HOME/.apm.pid"

  # Wait for server to be ready
  local count=0
  while ! is_apm_running && [ $count -lt 30 ]; do
    sleep 1
    count=$((count + 1))
  done

  if is_apm_running; then
    echo -e "${GREEN}[CCEM APM]${NC} Server started successfully (PID: $pid)"
  else
    echo -e "${RED}[CCEM APM]${NC} Failed to start server"
    return 1
  fi
}

# Get or create session ID
get_session_id() {
  # Check if we already have a session ID
  if [[ -n "$CCEM_SESSION_ID" ]]; then
    echo "$CCEM_SESSION_ID"
  else
    # Generate new UUID-like session ID
    python3 -c "import uuid; print('session-' + str(uuid.uuid4())[:8])"
  fi
}

# Register session with APM
register_session() {
  local project=$1
  local session_id=$2

  echo -e "${GREEN}[CCEM APM]${NC} Registering session in project '$project'..."

  curl -s -X POST "${APM_URL}/api/register" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"claude-code-$project\",
      \"type\": \"orchestrator\",
      \"project\": \"$project\",
      \"tier\": 3,
      \"capabilities\": [\"session-orchestration\", \"agent-dispatch\"]
    }" > /dev/null

  echo -e "${GREEN}[CCEM APM]${NC} Session registered (ID: $session_id)"
}

# Update configuration
update_config() {
  local project=$1
  local project_root="$PWD"
  local session_id=$2

  # Update with jq if available
  if command -v jq &> /dev/null; then
    jq --arg proj "$project" \
       --arg root "$project_root" \
       --arg sid "$session_id" \
       '.project_name = $proj |
        .active_project = $proj |
        .project_root = $root |
        .sessions[$sid] = {
          "project": $proj,
          "started_at": now | todate,
          "last_heartbeat": now | todate,
          "agent_count": 0
        }' \
       "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && \
      mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  fi
}

# Main logic
main() {
  local project=$(detect_project)

  if [[ "$project" == "unknown" ]]; then
    echo -e "${YELLOW}[CCEM APM]${NC} Could not detect project from current directory"
    return 1
  fi

  # Check APM server
  if ! is_apm_running; then
    start_apm_server || return 1
  else
    echo -e "${GREEN}[CCEM APM]${NC} APM server is running"
  fi

  # Get session ID
  local session_id=$(get_session_id)

  # Register session
  register_session "$project" "$session_id"

  # Update configuration
  update_config "$project" "$session_id"

  # Set environment
  export CCEM_APM_URL="$APM_URL"
  export CCEM_APM_PROJECT="$project"
  export CCEM_SESSION_ID="$session_id"

  echo -e "${GREEN}[CCEM APM]${NC} Session initialized!"
  echo -e "  Project: ${YELLOW}$project${NC}"
  echo -e "  Session: ${YELLOW}$session_id${NC}"
  echo -e "  URL: ${YELLOW}${APM_URL}${NC}"
}

# Run main logic
main
```

## Switching Projects

To switch projects in the same shell session:

```bash
# Change to new project directory
cd /Users/jeremiah/Developer/lcc

# Re-source the hook to switch active project
source ~/Developer/ccem/apm/hooks/session_init.sh

# Dashboard now shows lcc agents
```

This:
1. Detects new project (lcc)
2. Updates `active_project` in config
3. Sets new environment variables
4. Dashboard filters to new project

## Environment Variables Set

After sourcing the hook:

```bash
echo $CCEM_APM_URL          # http://localhost:3031
echo $CCEM_APM_PROJECT      # ccem (or current project)
echo $CCEM_SESSION_ID       # session-abc123
```

Available in shell and child processes (including Claude Code agents).

## Accessing in Claude Code

Agents can read session info:

```bash
# Get APM URL
curl $CCEM_APM_URL/health

# Register as agent
curl -X POST $CCEM_APM_URL/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-agent",
    "type": "individual",
    "project": "'$CCEM_APM_PROJECT'",
    "tier": 2
  }'
```

## Hook Customization

### Custom Project Mapping

Edit `session_init.sh` to detect more projects:

```bash
detect_project() {
  case "$PWD" in
    *"Developer/ccem"*) echo "ccem" ;;
    *"Developer/lcc"*) echo "lcc" ;;
    *"Developer/my-new-project"*) echo "my-new-project" ;;
    *) echo "unknown" ;;
  esac
}
```

### Custom Server Path

Override APM server location:

```bash
export APM_V4_HOME="/custom/path/to/apm-v4"
source ~/Developer/ccem/apm/hooks/session_init.sh
```

### Custom Port

```bash
export APM_PORT=3032
source ~/Developer/ccem/apm/hooks/session_init.sh
```

### Disable Auto-Start

Prevent hook from starting server:

```bash
export CCEM_NO_AUTO_START=1
source ~/Developer/ccem/apm/hooks/session_init.sh
```

## Troubleshooting

### Hook not initializing?

```bash
# Check if hook file exists
ls -la ~/Developer/ccem/apm/hooks/session_init.sh

# Try sourcing explicitly
bash ~/Developer/ccem/apm/hooks/session_init.sh
```

### APM server not starting

```bash
# Check APM v4 path
ls -la ~/Developer/ccem/apm-v4

# Try starting manually
cd ~/Developer/ccem/apm-v4
mix phx.server
```

### Wrong project detected

```bash
# Check current directory
pwd

# Verify project mapping in hook script
# Edit session_init.sh to add your directory pattern
```

### Configuration not updating

```bash
# Check config file permissions
ls -la ~/Developer/ccem/apm/apm_config.json

# Verify jq is installed (optional but useful)
which jq

# Check config is valid JSON
jq empty ~/Developer/ccem/apm/apm_config.json
```

## Manual Session Registration

If hook doesn't work, register manually:

```bash
# Start APM server
cd /Users/jeremiah/Developer/ccem/apm-v4
mix phx.server &

# Register session
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-session",
    "type": "orchestrator",
    "project": "ccem",
    "tier": 3,
    "capabilities": ["session-orchestration"]
  }'

# Set environment
export CCEM_APM_URL="http://localhost:3031"
export CCEM_APM_PROJECT="ccem"
export CCEM_SESSION_ID="session-manual"
```

## See Also

- [Getting Started](../user/getting-started.md) - Session initialization
- [Configuration](configuration.md) - apm_config.json setup
- [Deployment](deployment.md) - Production server setup
