# SMARTFIX: AgentLock Authorization Granularity Enhancement

**Status**: COMPLETE
**Version**: v8.9.1 (queued)
**Date**: 2026-03-30

## Executive Summary

Implemented command context enrichment layer for AgentLock approval requests, transforming opaque "Bash: high risk" approvals into actionable "DELETE RECURSIVE (/tmp/*): destructive" requests. Users now see exactly what they're approving before granting tool access.

## Problem Solved

**Before**: Users approved tool calls with minimal context:
- Approval request: "Bash · high risk"
- User didn't know if this was `cat /file` (safe) or `rm -rf /` (catastrophic)
- Blind approval leads to security incidents

**After**: Users see rich command context:
- Approval request: "🚨 DESTRUCTIVE · critical risk · delete recursive (/tmp/*)"
- Action detail clearly describes what will happen
- Risk rationale explains the category of risk
- Approval reasoning lists what the tool is allowed to do
- Auto-approval policies can restrict to read-only operations only

## Implementation

### Files Created

#### 1. `/lib/apm_v5/auth/command_context_extractor.ex` (260 LOC)
**Purpose**: Extract actionable context from tool parameters.

**Key Features**:
- Analyzes Bash commands with 40+ pattern matches
  - **Destructive**: `rm -rf`, `drop table`, `git push --force`, `pkill -9`
  - **Read**: `cat`, `find`, `grep`, `ls`, `stat`
  - **Write**: `cp`, `mv`, `sed`, `awk`, `tee`
- Analyzes file tools (Write, Edit, MultiEdit, Read, Grep, Glob)
- Returns structured context: `action_type`, `action_detail`, `risk_rationale`, `approval_reasoning`
- Truncates long paths/commands for readability

**Example Output**:
```elixir
CommandContextExtractor.analyze("Bash", %{"command" => "rm -rf /tmp/*"})
# → {:ok, %{
#     action_type: :destructive,
#     action_detail: "delete recursive (/tmp/*)",
#     risk_rationale: "Destructive shell operation — deletes, kills, or modifies system state",
#     approval_reasoning: "This approval allows: executing shell commands that DELETE FILES, DIRECTORIES, PROCESSES, or modify the system. Use with extreme caution. This operation cannot be undone."
#   }}
```

#### 2. `test/apm_v5/auth/command_context_extractor_test.exs` (260 LOC)
**Coverage**: 28 tests, 100% pass rate
- Destructive pattern detection (9 tests)
- Read-only pattern detection (4 tests)
- Write pattern detection (4 tests)
- File tool handling (4 tests)
- Error cases (3 tests)
- String truncation (2 tests)
- Case insensitivity (2 tests)

### Files Modified

#### 1. `lib/apm_v5/auth/pending_decisions.ex` (+65 lines)
**Changes**:
- Import `CommandContextExtractor`
- Call analyzer in `handle_call({:add, ...})`
- Store 4 new fields in pending decision entry:
  - `action_type` — `:destructive | :write | :read | :unknown`
  - `action_detail` — human-readable action (e.g., "delete recursive (/tmp/*)")
  - `risk_rationale` — why this is risky (e.g., "Destructive operation")
  - `approval_reasoning` — what the user is enabling (e.g., "This allows deleting files...")
- Enhanced notification message with action badge emoji and context lines
- Added metadata fields to APM notification payload
- Use `Map.merge()` instead of map update syntax for robustness

**Before Notification**:
```
Title: agent is requesting Bash
Message:
  high risk · 19s remaining
  Params: command: find /app -name...
```

**After Notification**:
```
Title: agent is requesting Bash
Message:
  📖 READ · high risk · 19s remaining
  find files (see command details)
  Read-only shell operation — no modifications
  Params: command: find /app -name...
```

#### 2. `lib/apm_v5/auth/auto_approval_store.ex` (+40 lines)
**Changes**:
- Added `allowed_action_types` field to policy schema
  - Allows policies to restrict auto-approval to specific action categories
  - Example: auto-approve only `:read` actions, require manual approval for `:write` or `:destructive`
- Added optional `action_patterns` field for glob-based command matching (future enhancement)
- Updated `find_matching/7` signature to accept optional `action_type` parameter
- Added `matches_action_type?/2` private helper to check action type in policy
- Updated docstrings with new fields and examples

**Example Policy**:
```elixir
# Auto-approve only read operations for a specific agent
ApmV5.Auth.AutoApprovalStore.create(%{
  agent_id: "ag-123",
  allowed_tools: ["Bash", "Read", "Grep"],
  allowed_risk_levels: [:low],
  allowed_action_types: [:read],  # NEW: restrict to read-only
  reason: "development session read-only"
})
```

## Data Flow

```
User tool call (e.g., Bash with "rm -rf /tmp/*")
  ↓
Hook: agentlock_pre_tool.sh calls POST /api/v2/auth/authorize
  ↓
PolicyEngine.evaluate() returns risk=:critical (destructive pattern detected)
  ↓
AuthorizationGate.escalate() creates PendingDecision entry
  ↓
PendingDecisions.add() calls CommandContextExtractor.analyze()
  ↓
Extractor returns: action_type=:destructive, action_detail="delete recursive (/tmp/*)"
  ↓
Entry stored with enriched context in ETS table
  ↓
Notification fired with emoji badge + action detail + approval reasoning
  ↓
CCEMHelper macOS banner shows: "🚨 DESTRUCTIVE · delete recursive (/tmp/*) · critical risk"
  ↓
Web UI (AuthorizationLive) displays in-browser approval modal with details
  ↓
User sees: "DELETE RECURSIVE (/tmp/*)... This approval allows: executing shell commands that DELETE FILES..."
  ↓
User clicks Approve or Deny (with full context)
```

## Test Results

```
$ mix test test/apm_v5/auth/
  160 tests, 0 failures
  ✓ CommandContextExtractor: 28 tests
  ✓ PendingDecisions: 8 tests (all passing with new context)
  ✓ Auto-approval: existing tests (backward compatible)
  ✓ Authorization: all existing tests pass
```

## Backward Compatibility

✅ **Fully backward compatible**:
- New fields are optional in PendingDecisions (added by handle_call)
- Auto-approval matching with `action_type=nil` defaults to `:all` (any action)
- Existing approval policies continue to work (action_type defaults to `:all`)
- REST API payload expands but doesn't remove fields
- Notifications still contain all original fields + enriched context

## Example Scenarios

### Scenario 1: Destructive Bash Command
```
Tool: Bash
Command: rm -rf /
Risk: :critical
Action Type: :destructive
Action Detail: "delete recursive (/)"
Approval: Requires human, shows: "🚨 DESTRUCTIVE · Delete recursive (/) · critical risk"
Approval Text: "This approval allows: executing shell commands that DELETE FILES OR DIRECTORIES recursively. Use with extreme caution. This operation cannot be undone."
```

### Scenario 2: Read-Only Bash Command
```
Tool: Bash
Command: cat /app/config.exs
Risk: :high (Bash default, before pattern matching)
Action Type: :read
Action Detail: "read file (/app/config.exs)"
Approval: Can auto-approve if policy allows `:read` actions
Approval Text: "This approval allows: executing shell commands that READ file contents or query the system. No files or processes are modified."
```

### Scenario 3: File Write
```
Tool: Write
File: /app/lib/module.ex
Risk: :medium
Action Type: :write
Action Detail: "write to file (/app/lib/module.ex)"
Approval: Requires manual or explicit policy match
Approval Text: "This approval allows: writing to or creating the file at '/app/lib/module.ex'. This will permanently modify that file."
```

### Scenario 4: Restricted Auto-Approval Policy
```
Policy: Agent A2 can auto-approve only read operations
Config: allowed_action_types: [:read]

Tool: Bash, Command: cat file.txt → :read → AUTO-APPROVED
Tool: Bash, Command: rm file.txt → :destructive → REQUIRES MANUAL APPROVAL
Tool: Write, File: /app/main.ex → :write → REQUIRES MANUAL APPROVAL
```

## Future Enhancements

1. **Action Pattern Matching** (Phase 2)
   - Use glob patterns to match specific commands
   - Example: `["cat /app/**", "grep /var/**"]` auto-approve only those patterns
   - Uses `fnmatch` or similar pattern library

2. **Risk Override** (Phase 3)
   - Allow action_type context to override base tool risk
   - Example: Bash defaults to `:high` but `cat /file` could be `:low`
   - Reduces unnecessary approvals for safe read operations

3. **Approval Reasoning in Web UI** (Phase 4)
   - Display `approval_reasoning` prominently in AuthorizationLive
   - Add checkbox: "I understand this allows: [approval_reasoning]"
   - Requires explicit acknowledgment before approval

4. **Analytics** (Phase 5)
   - Track approval patterns by action_type
   - Dashboard: "90% of Bash approvals are destructive" → suggest restricting
   - Report: "Most denied operations: write to /app" → adjust policy

## Metrics

| Metric | Value |
|--------|-------|
| Lines of Code (implementation) | 325 |
| Lines of Code (tests) | 260 |
| Test Coverage | 28 tests, 0 failures |
| Compilation Warnings | 0 |
| Backward Compatibility | 100% |
| Files Created | 2 |
| Files Modified | 2 |
| New GenServer fields | 0 |
| New API endpoints | 0 |
| Breaking Changes | 0 |

## Compliance

✅ OTP supervision: No new GenServers (stateless extraction)
✅ Phoenix LiveView: No changes to LiveView patterns
✅ ETS: Map-based storage (compatible with existing patterns)
✅ PubSub: Uses existing channels (agentlock:pending, agentlock:authorization)
✅ Type Safety: All public functions have @spec annotations
✅ Error Handling: Tagged tuples, safe pattern matching
✅ Logging: DEBUG level for extraction results (low noise)

## Deployment Notes

1. **Zero Downtime**: New fields are optional; old approvals continue to work
2. **Rollback Safe**: If new code is removed, approvals revert to base risk only
3. **APM Dashboard**: Notifications now show enriched context automatically
4. **CCEMHelper**: Emoji badges display in macOS banners (no update needed)
5. **Hook Compatibility**: `agentlock_pre_tool.sh` unchanged; works with enriched metadata

## References

- **Related Issue**: AgentLock authorization granularity gap
- **Related Code**: `PolicyEngine.evaluate()`, `CommandContextExtractor` (new), `PendingDecisions.add()`
- **Related Tests**: `test/apm_v5/auth/*_test.exs`
- **Documentation**: This file + inline docstrings

---

**Implementation Date**: 2026-03-30
**Status**: Ready for merge to main
**Tested**: ✅ All auth tests passing (160/160)
**Compiled**: ✅ No warnings, no errors
