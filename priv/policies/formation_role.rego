# CCEM APM — Formation-role contextual policy (auth-v10.1-s2 / CP-292)
#
# Controls which tools are accessible based on an agent's formation role
# within a CCEM formation (orchestrator / squadron_lead / swarm_agent /
# cluster_agent / individual).
#
# Formation hierarchy (most privileged first):
#   orchestrator > squadron_lead > cluster_agent > swarm_agent > individual
#
# Input shape:
#   {
#     "tool_name": "Bash",
#     "formation_role": "swarm_agent",
#     "formation_id": "fmt-20260514-v920",
#     "agent_id": "v10x-opa-cluster-lead",
#     "wave": 1
#   }
#
# Usage with OpaClient:
#   ApmV5.Auth.OpaClient.evaluate("apm/agentlock/formation_role", "allow", %{
#     tool_name: "Bash",
#     formation_role: "swarm_agent",
#     formation_id: "fmt-abc"
#   })

package apm.agentlock.formation_role

import future.keywords.if
import future.keywords.in

# Tools allowed for ALL formation roles (read-only)
read_only_tools := {"Read", "Grep", "Glob", "LS", "TaskGet", "TaskList", "WebSearch", "WebFetch"}

# Tools allowed for swarm_agent and above
swarm_tools := {"Edit", "Write", "NotebookEdit", "Skill"}

# Tools allowed for squadron_lead and above
lead_tools := {"TaskCreate", "TaskUpdate", "Agent"}

# Tools restricted to orchestrator only
orchestrator_tools := {"Bash"}

# Formation role hierarchy (role → minimum numeric level required)
role_level := {
  "individual":    0,
  "swarm_agent":   1,
  "cluster_agent": 2,
  "squadron_lead": 3,
  "orchestrator":  4
}

default allow = false

# Read-only tools available to all formation roles
allow if {
  input.tool_name in read_only_tools
}

# Swarm tools — swarm_agent level and above
allow if {
  input.tool_name in swarm_tools
  role_level[input.formation_role] >= role_level["swarm_agent"]
}

# Lead tools — squadron_lead level and above
allow if {
  input.tool_name in lead_tools
  role_level[input.formation_role] >= role_level["squadron_lead"]
}

# Orchestrator-only tools
allow if {
  input.tool_name in orchestrator_tools
  input.formation_role == "orchestrator"
}

# Individual agents outside a formation: read-only
allow if {
  input.formation_role == "individual"
  input.tool_name in read_only_tools
}

# Unknown formation_role — deny all non-read-only
allow if {
  not role_level[input.formation_role]
  input.tool_name in read_only_tools
}

deny_reason := "formation_role insufficient for tool" if {
  not input.tool_name in read_only_tools
  role_level[input.formation_role] < role_level["swarm_agent"]
}

deny_reason := "tool restricted to orchestrator role" if {
  input.tool_name in orchestrator_tools
  input.formation_role != "orchestrator"
}
