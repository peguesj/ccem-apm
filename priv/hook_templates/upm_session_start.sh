#!/bin/bash
# UPM SessionStart hook — registers session with CCEM APM (fire-and-forget)
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROJECT_NAME="$(basename "${PROJECT_ROOT}")"

(curl -s -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"session-${SESSION_ID}\",\"project\":\"${PROJECT_NAME}\",\"role\":\"session\",\"status\":\"active\"}" \
  >/dev/null 2>&1) &
