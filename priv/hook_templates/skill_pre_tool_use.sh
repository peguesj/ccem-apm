#!/bin/bash
# Skill PreToolUse hook — tracks skill invocations in CCEM APM (fire-and-forget)
SKILL_NAME="${CLAUDE_SKILL_NAME:-unknown}"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROJECT="${CLAUDE_PROJECT:-unknown}"

(curl -s -X POST http://localhost:3032/api/skills/track \
  -H "Content-Type: application/json" \
  -d "{\"skill\":\"${SKILL_NAME}\",\"session_id\":\"${SESSION_ID}\",\"project\":\"${PROJECT}\"}" \
  >/dev/null 2>&1) &
