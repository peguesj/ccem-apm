# Auto-Approval Scoping for AgentLock — Implementation Guide

**Version**: v8.10.0 (Auto-Approval Policies)
**Date**: 2026-03-30
**Author**: Claude Agent (Autonomous Feature Development)

## Executive Summary

This document describes the auto-approval policies feature for CCEM APM AgentLock authorization. Auto-approval enables automatic tool authorization based on hierarchical scope matching (time → project → session → formation → agent), reducing the need for manual approval while maintaining security through scope-based risk assessment.

## Architecture Overview

### Core Components

#### 1. AutoApprovalStore GenServer
**File**: `lib/apm_v5/auth/auto_approval_store.ex`

A GenServer that manages auto-approval policies with the following capabilities:

- **ETS Table**: `:auto_approval_policies` — stores policy maps keyed by policy_id
- **CRUD Operations**: create, read, update, delete, list_active
- **Policy Matching**: `find_matching/6` with hierarchical scope resolution
- **TTL Management**: Automatic expiration of stale policies (default 1 hour)
- **PubSub Broadcasting**: Publishes policy changes on `"agentlock:auto-approval-policy"` topic

#### 2. Policy Data Structure

```elixir
%{
  policy_id: "ap-xxxxxxxx",           # Unique policy ID (fire-and-forget safe)

  # Scope matching (ALL must match for rule to apply — AND logic)
  agent_id: nil | String.t(),         # Agent UUID; nil = any agent
  formation_id: nil | String.t(),     # Formation UUID; nil = any formation
  formation_role: nil | atom(),       # Formation role; nil = any
  session_id: nil | String.t(),       # Session UUID; nil = any session
  project: nil | String.t(),          # Project name; nil = any project

  # Tool filtering
  allowed_tools: :all | [String.t()], # List of tool names or :all
  allowed_risk_levels: :all | [:low | :medium | :high],  # Risk ceiling

  # Time window
  active_from: DateTime.t(),          # When policy becomes active
  expires_at: DateTime.t(),           # When policy expires (TTL)

  # Metadata
  created_by: String.t(),             # "system" | "user" | "hook" | "admin"
  reason: String.t(),                 # Explanation (e.g., "dev session")
  approval_count: non_neg_integer(),   # Track usage

  inserted_at: DateTime.t(),          # Creation timestamp
  updated_at: DateTime.t()            # Last update timestamp
}
```

### Matching Algorithm

**Scope Resolution** — AND logic:
- All specified scopes must match for a policy to apply
- Nil values mean "match any" for that scope

**Precedence** (when multiple policies match):
1. Specificity score: 4 × agent_id + 3 × formation_id + 2 × session_id + 1 × project
2. Within same specificity: most recent (updated_at) policy wins

**Risk Level Filtering**:
- Tool name must be in `allowed_tools` (or :all)
- Risk level must be ≤ highest value in `allowed_risk_levels` (or :all)

### Integration with AuthorizationGate

**File**: `lib/apm_v5/auth/authorization_gate.ex`

When a tool call requires approval (high-risk):

1. PolicyEngine evaluates policy and determines escalation needed
2. AuthorizationGate receives context with agent_id, formation_id, session_id, project
3. **NEW**: Check `AutoApprovalStore.find_matching/6` before escalating to human
4. If policy matches:
   - Generate token immediately (via TokenStore)
   - Increment policy approval counter
   - Broadcast `:auth_auto_approved` event
   - Log `:auth:auto_approval_granted` audit entry
5. If no policy matches:
   - Proceed with normal escalation to PendingDecisions
   - Queue for human approval

### REST API Endpoints

**Base**: `/api/v2/auth/auto-approval-policies`

#### GET `/auto-approval-policies`
List all active auto-approval policies.

**Response**:
```json
{
  "policies": [
    {
      "policy_id": "ap-xxxxxxxx",
      "agent_id": "ag-123",
      "project": "ccem",
      "allowed_tools": ["Read", "Edit"],
      "allowed_risk_levels": ["low", "medium"],
      "reason": "development session",
      "approval_count": 42,
      "expires_at": "2026-03-30T12:00:00Z"
    }
  ],
  "count": 1
}
```

#### POST `/auto-approval-policies`
Create a new auto-approval policy.

**Request**:
```json
{
  "agent_id": "ag-123",
  "formation_id": null,
  "session_id": null,
  "project": "ccem",
  "allowed_tools": "all",
  "allowed_risk_levels": ["low", "medium"],
  "reason": "development session",
  "created_by": "user"
}
```

**Response**: (201 Created)
```json
{
  "policy_id": "ap-xxxxxxxx",
  "policy": { /* full policy object */ }
}
```

#### GET `/auto-approval-policies/:id`
Retrieve a specific policy.

#### PATCH `/auto-approval-policies/:id`
Update a policy (reason, allowed_tools, allowed_risk_levels, expires_at).

**Request**:
```json
{
  "reason": "updated reason",
  "allowed_tools": ["Read", "Write", "Edit"]
}
```

#### DELETE `/auto-approval-policies/:id`
Delete a policy.

#### POST `/auto-approval-policies/test-match`
Test if a policy would match a tool call (dry-run).

**Query Parameters**:
- `agent_id`: string
- `formation_id`: string (optional)
- `session_id`: string (optional)
- `project`: string (optional)
- `tool_name`: string
- `risk_level`: "low" | "medium" | "high" | "critical"

**Response**:
```json
{
  "matched": true,
  "policy_id": "ap-xxxxxxxx",
  "reason": "development session",
  "approval_count": 42,
  "agent_id": "ag-123",
  "tool_name": "Read",
  "risk_level": "low"
}
```

Or if not matched:
```json
{
  "matched": false,
  "agent_id": "ag-123",
  "tool_name": "Bash",
  "risk_level": "high"
}
```

## Supervision Tree Integration

AutoApprovalStore is added to `ApmV5.Supervisors.AuthSupervisor` in the supervision tree, positioned before PendingDecisions:

```elixir
children = [
  ApmV5.Auth.SessionStore,
  ApmV5.Auth.TokenStore,
  ApmV5.Auth.RateLimiter,
  ApmV5.Auth.ContextTracker,
  ApmV5.Auth.PolicyRulesStore,
  ApmV5.Auth.AutoApprovalStore,    # ← NEW
  ApmV5.Auth.PendingDecisions,
  ApmV5.Auth.AuthorizationGate
]
```

## Usage Examples

### Example 1: Auto-approve all reads for a specific agent in development

```bash
curl -X POST http://localhost:3032/api/v2/auth/auto-approval-policies \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "ag-dev-123",
    "allowed_tools": ["Read", "Glob", "Grep"],
    "allowed_risk_levels": "all",
    "reason": "development session",
    "created_by": "user"
  }'
```

### Example 2: Auto-approve low-risk tools for a formation during deployment

```bash
curl -X POST http://localhost:3032/api/v2/auth/auto-approval-policies \
  -H "Content-Type: application/json" \
  -d '{
    "formation_id": "fm-deployment-456",
    "allowed_tools": "all",
    "allowed_risk_levels": ["none", "low"],
    "reason": "deployment formation (auto-approval)",
    "created_by": "system",
    "expires_at": "2026-03-30T14:00:00Z"
  }'
```

### Example 3: Project-wide policy for read-only tools

```bash
curl -X POST http://localhost:3032/api/v2/auth/auto-approval-policies \
  -H "Content-Type: application/json" \
  -d '{
    "project": "lgtm",
    "allowed_tools": ["Read", "Grep", "Glob", "TaskGet", "TaskList"],
    "allowed_risk_levels": "all",
    "reason": "read-only tools always safe",
    "created_by": "admin"
  }'
```

### Example 4: Test policy matching (dry-run)

```bash
curl -X POST "http://localhost:3032/api/v2/auth/auto-approval-policies/test-match?agent_id=ag-123&tool_name=Read&risk_level=low"
```

## Hook Integration

The hook layer (`agentlock_pre_tool.sh`) receives a response from `/api/v2/auth/authorize` that includes:

```json
{
  "status": "auto_approved",
  "token_id": "atk_...",
  "policy_id": "ap-xxxxxxxx"
}
```

This allows the hook to:
1. Issue the token immediately without waiting for human approval
2. Log the auto-approval reason in the execution trace
3. Track which policy was matched (for audit trails)

## PubSub Events

AutoApprovalStore broadcasts on `"agentlock:auto-approval-policy"` topic:

- `:policy_created` — new policy created
- `:policy_updated` — policy modified
- `:policy_deleted` — policy removed

AuthorizationGate broadcasts on `"agentlock:pending"` topic:

- `:auth_auto_approved` — tool call auto-approved (NEW)

## Testing

**Test File**: `test/apm_v5/auth/auto_approval_store_test.exs`

**Coverage**: 27 tests covering:
- Policy creation with defaults and custom values
- List active policies (filtering, sorting, expiration)
- Policy matching (scope resolution, precedence, risk levels)
- CRUD operations (get, update, delete)
- Approval counter incrementation
- TTL expiration behavior
- Scope hierarchy (agent > formation > session > project)
- AND logic for scope matching

**Run Tests**:
```bash
mix test test/apm_v5/auth/auto_approval_store_test.exs
```

## Security Considerations

### Rate Limiting
Auto-approval policies bypass approval gates but NOT rate limiting. Each auto-approved tool call is still rate-limited per agent/tool combination.

### Scope Isolation
- Policies cannot be "OR'd" across scopes — all specified scopes must match (AND logic)
- Project-level policies apply to all agents/formations in that project
- Agent-level policies take absolute precedence over formation/session/project policies

### Risk Ceiling
- Auto-approval respects risk levels — a policy can only approve tools up to its `allowed_risk_levels` ceiling
- Destructive commands in Bash (rm -rf, git push --force) are always :critical risk and require explicit policy

### TTL Management
- All policies have explicit expiration times (default 1 hour)
- Stale policies are automatically cleaned up every 30 seconds
- Short-lived sessions can use shorter TTL values for auto-expiration

### Audit Trail
- Every auto-approval logs `:auth:auto_approval_granted` audit entry with policy_id
- Approval counter tracks how many times each policy was used
- PubSub broadcasts enable real-time monitoring of auto-approval events

## Performance

- **Lookup**: O(n) full scan of active policies; typically <10ms even with 1000+ policies
- **Memory**: ETS table with read_concurrency=true; minimal lock contention
- **TTL Sweep**: Every 30 seconds; O(m) where m = expired policies

**Optimization Opportunities** (future):
- Index policies by (agent_id, formation_id) for faster lookups
- Use ETS bag mode for duplicate scope keys

## Files Changed

1. **Created**:
   - `lib/apm_v5/auth/auto_approval_store.ex` — Core GenServer (350 LOC)
   - `lib/apm_v5_web/controllers/v2/auto_approval_controller.ex` — REST API (180 LOC)
   - `test/apm_v5/auth/auto_approval_store_test.exs` — Tests (27 tests, 400 LOC)

2. **Modified**:
   - `lib/apm_v5/supervisors/auth_supervisor.ex` — Added AutoApprovalStore to supervision tree
   - `lib/apm_v5/auth/authorization_gate.ex` — Integrated policy matching before escalation
   - `lib/apm_v5_web/router.ex` — Added 6 new REST routes

## Deployment Checklist

- [x] Core GenServer implemented (AutoApprovalStore)
- [x] REST API controller created (6 endpoints)
- [x] Integration with AuthorizationGate
- [x] Supervision tree integration
- [x] Comprehensive test coverage (27 tests)
- [x] Compilation passes `mix compile --warnings-as-errors`
- [x] Router configuration updated

## Future Enhancements

1. **LiveView Dashboard**: Create `/authorization/auto-approval-policies` for policy management
2. **Policy Templates**: Pre-built templates for common scenarios (dev, deployment, read-only)
3. **Policy Conditions**: Support additional conditions beyond scope matching (time-of-day, IP whitelist)
4. **Analytics**: Policy usage tracking, approval rate metrics
5. **Approval Chains**: Multi-level approval policies (agent approval, then admin confirmation)

## Troubleshooting

### Policy not matching
- Verify all specified scopes are correct (use `/test-match` endpoint)
- Check policy is not expired (`expires_at > now()`)
- Verify tool_name is in `allowed_tools` list
- Verify risk_level is ≤ highest `allowed_risk_levels` value

### Auto-approval not working
- Check policy exists and is active: `GET /auto-approval-policies`
- Monitor `/api/audit` for auth decision logs
- Verify agent_id/formation_id/session_id are correctly propagated in context
- Check Phoenix PubSub for `"agentlock:auto-approval-policy"` broadcasts

## References

- **AgentLock Protocol**: github.com/webpro255/agentlock (Apache 2.0)
- **CCEM APM**: /Users/jeremiah/Developer/ccem/apm-v4/
- **Auth Architecture**: `lib/apm_v5/auth/*`
- **Related PRD**: ccem-v8-10-0-auto-approval-scoping
