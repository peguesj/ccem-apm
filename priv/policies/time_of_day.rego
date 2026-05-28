# CCEM APM — Time-of-Day contextual policy (auth-v10.1-s2 / CP-292)
#
# Restricts tool access based on the hour of day (UTC) embedded in the input.
# Useful for limiting destructive operations to business hours.
#
# Input shape:
#   {
#     "tool_name": "Bash",
#     "hour": 14,        # UTC hour (0-23)
#     "role": "agent"
#   }
#
# Usage with OpaClient:
#   ApmV5.Auth.OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{
#     tool_name: "Bash",
#     hour: 14,
#     role: "agent"
#   })

package apm.agentlock.time_of_day

import future.keywords.if
import future.keywords.in

# Business hours window (UTC): 08:00–22:00
business_hours_start := 8
business_hours_end := 22

# High-risk tools restricted to business hours
high_risk_tools := {"Bash", "Write", "Edit", "NotebookEdit"}

default allow = false

# Non-high-risk tools are always allowed regardless of time
allow if {
  not input.tool_name in high_risk_tools
}

# High-risk tools allowed during business hours
allow if {
  input.tool_name in high_risk_tools
  input.hour >= business_hours_start
  input.hour < business_hours_end
}

# Admin role bypasses time restriction
allow if {
  input.role == "admin"
}

# Deny reason for UI display
deny_reason := "tool restricted outside business hours (08:00-22:00 UTC)" if {
  input.tool_name in high_risk_tools
  not (input.hour >= business_hours_start)
  not (input.hour < business_hours_end)
}
