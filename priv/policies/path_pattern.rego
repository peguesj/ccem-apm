# CCEM APM — Path-pattern contextual policy (auth-v10.1-s2 / CP-292)
#
# Restricts file operations based on path patterns.
# Blocks writes to sensitive paths (secrets, credentials, system dirs).
# Allows configurable project-scoped allowed prefixes.
#
# Input shape:
#   {
#     "tool_name": "Write",
#     "params": {
#       "file_path": "/Users/jeremiah/Developer/myproject/src/main.ex",
#       "command": "cat /etc/passwd"
#     },
#     "role": "agent",
#     "allowed_path_prefixes": ["/Users/jeremiah/Developer/myproject"]
#   }
#
# Usage with OpaClient:
#   ApmV5.Auth.OpaClient.evaluate("apm/agentlock/path_pattern", "allow", %{
#     tool_name: "Write",
#     params: %{file_path: "/path/to/file.ex"},
#     role: "agent",
#     allowed_path_prefixes: ["/Users/jeremiah/Developer/myproject"]
#   })

package apm.agentlock.path_pattern

import future.keywords.if
import future.keywords.in

# Sensitive path fragments — writes/reads blocked for non-admin
sensitive_fragments := {
  ".env",
  "credentials",
  "secrets",
  "/etc/passwd",
  "/etc/shadow",
  "id_rsa",
  ".ssh/",
  "keychain",
  "api_key",
  ".apm.pid"
}

# Tools that operate on file paths
file_tools := {"Write", "Edit", "NotebookEdit", "Read", "Bash"}

default allow = false

# Non-file tools always pass through
allow if {
  not input.tool_name in file_tools
}

# Admin bypasses path restrictions
allow if {
  input.role == "admin"
}

# Read operations on non-sensitive paths are allowed
allow if {
  input.tool_name == "Read"
  not sensitive_path(get_path(input))
}

# Write/Edit on non-sensitive, project-allowed paths
allow if {
  input.tool_name in {"Write", "Edit", "NotebookEdit"}
  not sensitive_path(get_path(input))
  allowed_project_path(get_path(input), input.allowed_path_prefixes)
}

# Bash — not explicitly path-checked (path_pattern focuses on file tools)
allow if {
  input.tool_name == "Bash"
  not bash_touches_sensitive(input)
}

# ── Helpers ──────────────────────────────────────────────────────────────────

get_path(inp) := inp.params.file_path if inp.params.file_path
get_path(inp) := "" if not inp.params.file_path

sensitive_path(path) if {
  some fragment in sensitive_fragments
  contains(path, fragment)
}

allowed_project_path(_, prefixes) if {
  prefixes == null
}

allowed_project_path(path, prefixes) if {
  some prefix in prefixes
  startswith(path, prefix)
}

bash_touches_sensitive(inp) if {
  cmd := inp.params.command
  some fragment in sensitive_fragments
  contains(cmd, fragment)
}

deny_reason := "path contains sensitive fragment" if {
  sensitive_path(get_path(input))
  input.role != "admin"
}
