# DRTW Report: Authorization & Policy Engines
**Domain**: OPA, Casbin, Bodyguard, JWT, OAuth 2.0, NIST SP 800-63B-4
**Research date**: 2026-05-26
**Version targets**: v9.3.0 through v10.3.0

## CCEM Already Has (Strong Foundation)
- `PolicyEngine` — 5 risk levels, MCP annotation derivation, role/data-boundary checks
- `PolicyRulesStore` — ETS always_allow/always_deny, `"*"` wildcard, durable
- `AuthorizationGate` — 7-step pipeline with audit + PubSub
- `TokenStore` — single-use SHA-256 bound execution tokens, 60s TTL
- `RateLimiter` — sliding window per `{user_id, tool_name}`, 5 risk-level defaults
- `ContextTracker` — monotonically decreasing trust ceiling, 200-entry ring buffer
- `AutoApprovalStore` — specificity-scored (4+3+2+1) scope-matched auto-approval
- `SkillPermissiveStore` — per-skill bypass list, persisted to disk

## Packages to IMPORT
```elixir
{:joken, "~> 2.6"},       # 116K DL/wk — RFC 7523 JWT Bearer Assertions for agent identity
{:bodyguard, "~> 2.4"},   # 9.2K DL/wk — Phoenix LiveView/controller authorize/3 DSL
{:hammer, "~> 7.4"},      # 45.8K DL/wk — drop-in RateLimiter replacement for multi-node
{:assent, "~> 0.3"},      # 2K DL/wk — only mature OIDC/OAuth client for external IdP
{:ex_audit, "~> 0.10"},   # 3.2K DL/wk — queryable audit records with revert capability
```

## Packages to SKIP
- `casbin`/`casbin-ex`: 87 stars, 44 DL/wk — PolicyEngine already covers ACL/RBAC
- `opa_suite` v0.0.1: 125 all-time DL, proof-of-concept — build thin Req wrapper instead
- `authorizir`: 17 DL/wk, last updated 2022 — extract design pattern, don't import
- `rbac` v1.0.3: GPL-2.0 license (viral), unmaintained
- `bodyguard` as PolicyEngine replacement: complementary wrapper only, not a replacement

## OPA Verdict: Sidecar + Thin Req Wrapper
No production-ready Elixir OPA client exists. Build `ApmV5.Auth.OpaClient` as ~30-line Req HTTP client against OPA `/v1/data/{package}/{rule}`. Keep PolicyEngine for hot-path (0.1ms), offload complex contextual/temporal/delegation rules to OPA sidecar. Ship Rego policies in `priv/policies/`.

## Gaps → Version Roadmap

### v9.3.0 — Compliance audit + bodyguard
- **GAP 5**: `PolicyDecisionStore` — queryable ETS ring buffer + async Postgres flush for authorization decisions; NIST AI RMF evidence
- IMPORT `bodyguard` for Phoenix controller/LV `authorize/3` DSL

### v9.4.0 — Policy versioning + contextual predicates
- **GOV-2**: PolicyRulesStore versioning (version, created_by, approved_by, expires_at)
- **GAP 4**: `PolicyPredicate` DSL — struct-based AST for time-based, env-based, path-glob conditions evaluated before risk classification

### v10.0.0 — Agent identity tokens (BREAKING: session auth changes)
- **GAP 1**: RFC 7523 JWT Bearer Assertions — `joken` signs agent assertions; AuthorizationGate verifies signature; agent_id becomes cryptographically bound
- **GAP 2**: `DelegationToken` system — `{parent_agent_id, child_agent_id, max_risk_ceiling, allowed_tools, expires_at, signature}`; scope-narrowing on sub-agent spawn (OWASP MCP02)

### v10.1.0 — OPA contextual policies
- **GAP 3**: Temporal/environment policies via OPA sidecar; `ApmV5.Auth.OpaClient`
- Bundle Rego policies for: time-of-day, environment, path-pattern, formation-role

### v10.2.0 — Multi-node + external IdP
- **GAP 6**: Swap `RateLimiter` ETS → `hammer` Redis backend for BEAM cluster deployments
- **GAP 7**: `assent` OIDC integration in `SessionStore.create/2` for enterprise SSO agent identity

### v10.3.0 — Verifiable Credentials + Human approver attestation
- **SHIPPED (CP-300)**: `ApmV5.Governance.VerifiableCredential` — W3C VC 2.0 JWT-VC issuance.
  Issues EdDSA-signed VCs documenting agent capabilities (WHAT authorized) alongside
  v10.0.0 JWT identity tokens (WHO the agent is). Zero new deps — pure OTP `:crypto`.
  Closes EU AI Act Article 13 + 52 disclosure gap. See `docs/migrations/v10.3.0-vc-issuance.md`.
- **GAP 8**: `wax_` WebAuthn attestation on approval endpoint; prevents API-based approval bypass

## Key Non-Obvious Findings
1. **Delegation chain is the biggest security gap** — OWASP MCP02 explicitly identifies scope creep via unchecked delegation as the #2 risk in multi-agent systems. No existing Elixir package solves this; must build `DelegationToken`.
2. **`agent_id` is advisory not enforced** — entire auth pipeline trusts a string from hooks with zero cryptographic verification. This is fine for dev but untenable for enterprise. `joken` + RFC 7523 is the fix.
3. **Hammer Redis backend is the multi-node migration path** — current ETS `RateLimiter` works for single-node; `hammer` is a drop-in swap when clustering is needed.
4. **prom_ex has no Bandit plugin** — same finding as observability report, confirmed here too.
