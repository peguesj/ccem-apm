# CCEM APM — Environment contextual policy (auth-v10.1-s2 / CP-292)
#
# Restricts destructive operations in production environments.
# The "environment" field is injected into the OPA input by the calling agent
# from the CCEM_ENV environment variable or application config.
#
# Input shape:
#   {
#     "tool_name": "Bash",
#     "environment": "production",   # production | staging | development | test
#     "params": {"command": "rm -rf /tmp/cache"},
#     "role": "agent"
#   }
#
# Usage with OpaClient:
#   ApmV5.Auth.OpaClient.evaluate("apm/agentlock/environment", "allow", %{
#     tool_name: "Bash",
#     environment: "production",
#     role: "agent"
#   })

package apm.agentlock.environment

import future.keywords.if
import future.keywords.in

# Destructive tools that require elevated trust in production
destructive_tools := {"Bash", "Write", "Edit", "NotebookEdit"}

# Production-trusted roles
production_trusted_roles := {"admin", "orchestrator", "squadron_lead"}

default allow = false

# All tools allowed in non-production environments
allow if {
  input.environment != "production"
}

# In production: only destructive tools are restricted
allow if {
  input.environment == "production"
  not input.tool_name in destructive_tools
}

# In production: destructive tools require trusted role
allow if {
  input.environment == "production"
  input.tool_name in destructive_tools
  input.role in production_trusted_roles
}

# Unknown environment treated as most restrictive (production semantics)
allow if {
  not input.environment
  not input.tool_name in destructive_tools
}

deny_reason := "destructive tool blocked in production for non-privileged role" if {
  input.environment == "production"
  input.tool_name in destructive_tools
  not input.role in production_trusted_roles
}
