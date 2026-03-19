#!/bin/bash
# deploy:agents-v2 SessionStart hook — notifies CCEM APM on agent deployment (fire-and-forget)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROJECT="${CLAUDE_PROJECT:-unknown}"

# Read upm_context from environment if available
UPM_SESSION_ID="${CLAUDE_UPM_SESSION_ID:-}"
STORY_ID="${CLAUDE_UPM_STORY_ID:-}"
PLANE_ISSUE_ID="${CLAUDE_UPM_PLANE_ISSUE_ID:-}"
FORMATION_ID="${CLAUDE_UPM_FORMATION_ID:-}"
FEATURE_NAME="${CLAUDE_UPM_FEATURE_NAME:-}"
WAVE="${CLAUDE_UPM_WAVE:-}"
ROLE="${CLAUDE_UPM_ROLE:-individual}"
PARENT_ID="${CLAUDE_UPM_PARENT_ID:-}"
START_TIME="${CLAUDE_UPM_START_TIME:-}"

# Build upm_context JSON if any UPM fields are set
if [ -n "$UPM_SESSION_ID" ] || [ -n "$STORY_ID" ] || [ -n "$PLANE_ISSUE_ID" ]; then
  UPM_CONTEXT_JSON="{\"upm_session_id\":\"${UPM_SESSION_ID}\",\"story_id\":\"${STORY_ID}\",\"plane_issue_id\":\"${PLANE_ISSUE_ID}\",\"formation_id\":\"${FORMATION_ID}\",\"feature_name\":\"${FEATURE_NAME}\",\"wave\":\"${WAVE}\",\"role\":\"${ROLE}\",\"parent_id\":\"${PARENT_ID}\",\"start_time\":\"${START_TIME}\"}"
  PAYLOAD="{\"type\":\"info\",\"title\":\"Agent Deployment Started\",\"message\":\"deploy:agents-v2 session ${SESSION_ID}\",\"category\":\"deploy_agents\",\"project\":\"${PROJECT}\",\"session_id\":\"${SESSION_ID}\",\"formation_id\":\"${FORMATION_ID}\",\"story_id\":\"${STORY_ID}\",\"upm_session_id\":\"${UPM_SESSION_ID}\",\"upm_context\":${UPM_CONTEXT_JSON}}"
else
  PAYLOAD="{\"type\":\"info\",\"title\":\"Agent Deployment Started\",\"message\":\"deploy:agents-v2 session ${SESSION_ID}\",\"category\":\"deploy_agents\",\"project\":\"${PROJECT}\",\"session_id\":\"${SESSION_ID}\"}"
fi

(curl -s -X POST http://localhost:3032/api/notify \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  >/dev/null 2>&1) &
