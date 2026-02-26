#!/bin/bash
# deploy:agents-v2 SessionStart hook — notifies CCEM APM on agent deployment (fire-and-forget)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
PROJECT="${CLAUDE_PROJECT:-unknown}"

(curl -s -X POST http://localhost:3031/api/notify \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"info\",\"title\":\"Agent Deployment Started\",\"message\":\"deploy:agents-v2 session ${SESSION_ID}\",\"category\":\"deploy_agents\",\"project\":\"${PROJECT}\"}" \
  >/dev/null 2>&1) &
