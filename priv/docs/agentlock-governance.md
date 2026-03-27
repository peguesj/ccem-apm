# AgentLock Governance: Agentic Authorization Design Decisions

**Version**: 1.0.0
**Applies to**: CCEM APM v7.x+
**Audience**: New contributors, platform engineers, security reviewers

---

## Problem: Why Agentic Authorization Is a Distinct Discipline

Traditional IAM systems were designed for human users: a principal authenticates once, receives a scoped token, and uses it until expiry. AI agents break every assumption in that model.

An AI agent does not hold a stable intent. Its behavior shifts as it accumulates context — reading files, fetching web content, receiving tool output from peer agents. A session that begins with authoritative context (a human-authored system prompt) can degrade in real time as the agent ingests derived or untrusted content. The agent that entered the session with `:authoritative` trust is not the same agent three tool calls later when it has processed web content.

Second, agents invoke tools at machine speed. A human can read an authorization prompt and reason about it. An agent will fire 200 tool calls in 90 seconds without any reflective pause. Rate limiting and risk-level gating are not optional — they are the primary throttle mechanism.

Third, multi-agent formations create trust delegation chains that have no equivalent in traditional access control. When an orchestrator spawns a swarm agent, the spawned agent's permissions should be a strict subset of the orchestrator's permissions. Nothing in standard OAuth or RBAC enforces this; it must be built explicitly.

Finally, the stakes of a single bad tool call are asymmetric. A `git push --force` to main, a `DROP DATABASE`, or a file write that persists a leaked API key are not recoverable from a log. The cost of false positives (blocking a legitimate tool call) is a delayed task; the cost of a false negative (permitting a destructive command) can be permanent data loss.

OWASP's 2026 Agentic Top 10 identifies Excessive Agency (Risk 1) as the primary threat: granting an agent more permissions or autonomy than its designated function requires. The principle of Least Agency — autonomy is earned, not granted by default — is the foundational design axiom.

---

## Decision: CCEM's 3-Layer AgentLock Authorization Model

CCEM APM implements a three-layer enforcement architecture:

```
Layer 0 (Hook):    PreToolUse shell hook — fires before every tool call
Layer 1 (Policy):  PolicyEngine — stateless risk evaluation + rule override check
Layer 2 (Gate):    AuthorizationGate GenServer — token issuance, escalation, audit
```

**Layer 0: Hook Integration**

`agentlock_pre_tool.sh` intercepts every tool call via Claude Code's PreToolUse hook. It POSTs to `/api/v2/auth/authorize` with a 3-second timeout. On APM unavailability it exits 0 (fail-open). On explicit deny it exits 2, which causes Claude Code to cancel the tool call and surface the reason to the model. On approval it receives an `atk_`-prefixed token, writes it to `~/.claude/state/<tool_use_id>.atk`, and exits 0.

`agentlock_post_tool.sh` fires after execution, reads the stored token file, and POSTs to `/api/v2/auth/execute` as a fire-and-forget background curl. This closes the token lifecycle and writes to the audit log.

**Layer 1: PolicyEngine**

PolicyEngine is intentionally stateless — no GenServer, no ETS writes. It applies a 5-step pipeline:

1. Permanent rule override check (`:always_allow` / `:always_deny` short-circuit everything)
2. Role check against `allowed_roles` list on the registered `AuthTool`
3. Data boundary check (request boundary must not exceed tool boundary)
4. Bulk operation escalation (bulk + medium risk → approval required)
5. Trust ceiling check (`:untrusted` blocks medium+; `:derived` escalates high+)

Risk levels: `none` (auto-permit) → `low` → `medium` → `high` → `critical`. Destructive bash patterns (rm -rf, force push, DROP TABLE) escalate any `Bash` call to `:critical`.

**Layer 2: AuthorizationGate**

AuthorizationGate coordinates all stores and handles the three outcomes of a PolicyDecision:

- `allowed: true, needs_approval: false` → generate token, record rate limit event, increment session counter
- `allowed: false, needs_approval: true` → queue in PendingDecisions (120s TTL), escalate to ApprovalGate, return `:approval_required` to hook
- `allowed: false, needs_approval: false` → deny, increment denied counter, broadcast

All decisions emit on PubSub (`agentlock:authorization`), broadcast an AG-UI `CUSTOM` event, and write an audit log entry.

---

## Key Trade-offs

### Fail-Open vs. Fail-Closed

The hook implements **fail-open**: if APM is unreachable, the tool call proceeds. This is a deliberate productivity trade-off. CCEM APM is a developer monitoring tool — blocking all tool execution when the APM server is down would halt all agent work with no recoverability. Fail-open is appropriate here.

For production security contexts (financial workflows, infrastructure automation), fail-closed should be adopted: if the authorization endpoint is unreachable, deny the tool call. The hook can be made fail-closed by changing `exit 0` on timeout to `exit 2`.

### Ephemeral Tokens vs. Persistent Sessions

**Tokens** (`atk_` prefix, 60s TTL, single-use, SHA-256 param-bound) are designed to prevent replay attacks. A token is bound to the exact parameter hash of the tool call that requested it. Consuming it with different parameters is rejected with `:params_mismatch`. Tokens are deliberately not reusable and deliberately short-lived — they model a single authorization decision for a single tool invocation.

**Sessions** (15-minute TTL, dual-ETS indexed) bind a user identity and role across multiple tool calls. Sessions carry a `trust_ceiling` that degrades monotonically as the agent accumulates context from lower-trust sources. Sessions cannot recover trust; once `:untrusted`, they remain `:untrusted` for their lifetime. This monotonic property prevents prompt injection from leveraging a single high-trust action to temporarily elevate a degraded session.

### Human-in-the-Loop Escalation vs. Automated Denial

Rather than auto-denying all high-risk operations, AgentLock offers human escalation via PendingDecisions. Requests are queued with a 120-second TTL and a long-poll endpoint (`GET /api/v2/auth/pending/:id?wait=30`) that the hook could use to block and await a decision. Currently the hook is fire-and-continue (it does not block on escalation); the APM dashboard and CCEMHelper menu bar surface pending decisions to the human operator who approves or denies asynchronously.

The asymmetry: blocking the hook on human approval (synchronous HITL) would make high-risk operations safe but would freeze agent execution for up to 120 seconds while waiting. The current asynchronous model keeps execution moving but means a high-risk tool call proceeds if the human doesn't intervene before the agent retries.

### Tool-Level vs. Command-Level Granularity

PolicyEngine operates at the tool name level (e.g., "Bash" → :high). Destructive command patterns inside Bash escalate to :critical, but the detection is regex-based on the raw command string. This is imperfect: a malicious command could evade the patterns. True sandboxing (e.g., evaluating Bash in a restricted execution environment, or using an LLM-based command analyzer) would provide better guarantees but at significantly higher latency and cost.

---

## Implementation Guidance for New Developers

**Adding a new tool to the risk map**: Edit `@default_risk_map` in `policy_engine.ex`. If the tool needs role restrictions or a data boundary, call `AuthorizationGate.register_tool/3` from `application.ex` initialization.

**Adding a prohibited bash pattern**: Add to `@destructive_patterns` in `policy_engine.ex`. All entries are compiled at module load time — no runtime cost.

**Adding a prohibited memory pattern**: Add to `@prohibited_patterns` in `memory_gate.ex`. Patterns are applied on every `MemoryGate.authorize_write/4` call.

**Adding a redaction pattern**: Add to `@patterns` in `redaction_engine.ex`. Patterns are stateless and apply on every `RedactionEngine.redact/2` call.

**Changing token TTL**: Modify `@default_ttl_seconds` in `token_store.ex`.

**Changing session TTL**: Modify `@default_ttl_seconds` in `session_store.ex`.

**Adding a new PubSub topic**: All auth broadcasts use topics `agentlock:authorization`, `agentlock:sessions`, `agentlock:trust`, and `agentlock:pending`. Subscribe in any LiveView's `mount/3` via `Phoenix.PubSub.subscribe(ApmV5.PubSub, topic)`.

**Making the hook fail-closed**: In `agentlock_pre_tool.sh`, on curl timeout or empty response, change `exit 0` to `exit 2` with an appropriate stderr message.

---

## Verification Checklist

Before shipping auth-related changes:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test` — all 13+ auth tests pass
- [ ] Start APM (`mix phx.server`), run `agentlock_pre_tool.sh` with a synthetic Bash input and verify token is stored to `~/.claude/state/`
- [ ] Confirm `GET /api/v2/auth/summary` returns correct registered tool count
- [ ] Confirm `GET /api/v2/auth/tools` lists all expected tools with correct risk levels
- [ ] Test destructive command detection: submit `rm -rf /tmp/test` via Bash tool and verify `:critical` risk in response
- [ ] Test escalation flow: submit a `:high` risk tool call with `:derived` trust ceiling and verify pending request appears at `/authorization` (Pending tab) and in CCEMHelper menu bar
- [ ] Test permanent rule override: add `:always_allow` rule for `Bash` via Policies tab, verify subsequent Bash calls return `allowed: true` immediately
- [ ] Verify PubSub broadcasts: subscribe to `agentlock:authorization` in iex and confirm events flow on authorization decisions
- [ ] Rate limiter verification: call `RateLimiter.check/2` 21 times for a high-risk tool and confirm 21st returns `{:error, :rate_limited, _}`
- [ ] Context trust degradation: call `ContextTracker.record_write/4` with `:web_content` source and verify `get_trust_ceiling/1` returns `:untrusted`
- [ ] Memory gate prohibition: call `MemoryGate.authorize_write/4` with content containing an AWS key and verify `:memory_prohibited_content` error
