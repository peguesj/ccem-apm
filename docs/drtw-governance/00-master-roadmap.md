# DRTW Governance Master Roadmap — v9.2.0 → v10.3.0
**Synthesized**: 2026-05-26 from 10 parallel DRTW research agents
**Target**: AI Agent Governance product, grounded in industry standards
**Source reports**: 01-authorization.md, 02-audit-logging.md, 03-observability.md, 04-rate-limiting.md, 05-workflow.md, 06-compliance.md, 07-health-checks.md, 08-provenance.md, 09-multi-agent-coordination.md, 10-api-schema-governance.md

## Cross-Cutting Themes (Critical Findings)

### #1 — `agent_id` Is Cryptographically Unverified (Auth #1 Gap)
The entire 7-step AuthorizationGate trusts a string from hooks with zero proof. **This is the linchpin gap that propagates to provenance, audit, A2A, and compliance**.
- Auth Report: RFC 7523 JWT Bearer Assertions via `joken` (Tier 1 fix, v10.0)
- Provenance Report: same fix unlocks Ed25519-signed artifact attestations
- Compliance Report: same fix enables NIST AI RMF GOVERN evidence

### #2 — Hand-Written OpenAPI Spec Diverges Silently (Governance #1 Gap)
1,879 LOC hand-written in `api_v2_controller.ex`. **Until this is replaced, every other governance tool operates on a spec that may not match reality**.
- API Governance Report: `open_api_spex` annotation migration is highest priority
- Immediate safety net: oasdiff snapshot + CI gate (30 min, ship in v9.2.1)

### #3 — `prom_ex` Has No Bandit Plugin (Repeated Independently)
CCEM uses Bandit; `prom_ex` only ships PlugCowboy. **Use `peep` instead**. Reuse prom_ex's Grafana JSON files from GitHub.

### #4 — Multiple Reports Independently Recommend OpenTelemetry SDK
Observability, Provenance, Compliance, and Authorization all converge on adopting `opentelemetry` + `opentelemetry_semantic_conventions`. **Consolidate as Wave 1 across product**.

### #5 — `{:topic, t}` A2A Addressing Bug (Silent Broadcast Amplification)
Currently resolves to ALL agents instead of topic subscribers. Hotfix priority for v9.2.1.

### #6 — Dual Audit GenServers Diverging
`AuditLog` (hash chain, disk) and `ApprovalAuditLog` (no chain, no disk, lost on restart) cause schema fragmentation. Merge in v9.3.0.

## Consolidated Package Adoption List (All 10 Reports)

### Tier 1 — Critical (Adopt Together in Wave 1)
```elixir
# OpenTelemetry suite (Observability + Provenance + Compliance)
{:opentelemetry_api, "~> 1.5"},
{:opentelemetry, "~> 1.7"},
{:opentelemetry_exporter, "~> 1.10"},
{:opentelemetry_semantic_conventions, "~> 1.27"},
{:opentelemetry_bandit, "~> 0.3"},
{:opentelemetry_phoenix, "~> 2.0"},
{:opentelemetry_process_propagator, "~> 0.3"},

# Metrics export (Observability + Compliance + Rate Limiting)
{:peep, "~> 5.0"},

# Structured logging (Audit + Compliance + Logging)
{:logger_json, "~> 7.0"},

# API governance (API + Compliance + Auth)
{:open_api_spex, "~> 3.22"},
```

### Tier 2 — Wave 2-3 (Auth + Rate Limit + Workflow)
```elixir
{:joken, "~> 2.6"},          # Agent identity JWT (Auth + Provenance)
{:joken_jwks, "~> 1.7"},     # JWKS endpoint
{:bodyguard, "~> 2.4"},      # Phoenix authorize/3 DSL (Auth)
{:hammer, "~> 7.0"},         # Drop-in RateLimiter replacement (Rate Limit)
{:fuse, "~> 2.5"},           # Circuit breaker (Rate Limit)
{:plug_attack, "~> 0.4"},    # HTTP pipeline throttling (Rate Limit)
{:reactor, "~> 1.0"},        # Saga compensation (Workflow)
{:cloak, "~> 1.1"},          # AES-256-GCM at rest (Compliance + Audit)
{:ex_json_schema, "~> 0.11"} # Hook payload validation (Compliance)
```

### Tier 3 — Wave 4-5 (Provenance + DID)
```elixir
{:ex_did, "~> 0.2"},         # DID:key resolution (Provenance)
{:prov, "~> 0.1"},           # W3C PROV-DM (Provenance)
{:rdf, "~> 3.0"},            # Turtle serialization (Provenance)
{:grax, "~> 0.6"},           # prov dep
```

### Tier 4 — v10.x (Multi-Node + IdP + Advanced)
```elixir
{:assent, "~> 0.3"},         # OIDC client for enterprise SSO (Auth v10.2)
{:horde, "~> 0.10"},         # Distributed registry (A2A v10.0)
{:libcluster, "~> 3.5"},     # Node discovery (A2A v10.0)
{:wax_, "~> 0.7"},           # WebAuthn for human approvers (Auth v10.3)
{:eventstore, "~> 1.4"},     # PostgreSQL WORM audit (Audit v9.4 opt-in)
```

### NPM (`@ccem/apm`)
```json
"@asteasolutions/zod-to-openapi": "^8.5.0",
"openapi-typescript": "^7.13.0",
"@stoplight/spectral-cli": "^6.16.0",
"@stoplight/spectral-owasp-ruleset": "^2.0.1"
```

### CLI Tools (devDependencies / brew / pip)
- `oasdiff` — Go CLI breaking change detection
- `schemathesis` — Python OpenAPI property-based fuzzing

## Total New Hex Deps: 23 packages
All MIT/Apache-2.0. No CVEs as of research date. ~10 are stdlib-adjacent (OTel suite). 5 are deferred to v10.x.

---

## Version Sequence: v9.2.0 → v10.3.0

### v9.2.1 — Security Hotfixes (Immediate)
Sprint: ~3 days. Patch-level safety net before any major work.

| Story | Domain | Effort |
|---|---|---|
| `audit-s1` `self_hash` field + verify_chain API | Audit | S (4h) |
| `audit-s2` ETS `:public` → `:protected` | Audit | XS (1h) |
| `api-s1` oasdiff snapshot + CI gate | API Gov | XS (30min) |
| `api-s2` Spectral OpenAPI linting + OWASP | API Gov | XS (half-day) |
| `coord-a1` AgentCard + `/.well-known/agent-card.json` | Coordination | M (1 day) |
| `coord-a2` Fix `{:topic, t}` broadcast bug (hotfix) | Coordination | S (4h) |

### v9.3.0 — Foundation Wave (OTel + JSON Audit + Auth Compliance)
Sprint: ~3 weeks. The biggest minor release. Establishes governance product foundation.

**Track 1: Observability + Audit (parallel)**
- `obs-s1` OTel SDK Bootstrap (8 packages) — S
- `obs-s2` `peep` Prometheus `/metrics` endpoint + `ApmV5.Metrics` module — M
- `obs-s3` Hook traceparent propagation (W3C through hooks → APM) — M
- `obs-s4` `ApmV5.Tracing` module — `with_agent_span/3`, `with_tool_span/3`, `with_llm_span/4` — M
- `obs-s5` Grafana dashboard JSON + Prometheus alert rules — S
- `audit-s3` Unified schema: agent_id/session_id/formation_id/wave fields — M
- `audit-s4` Merge `ApprovalAuditLog` → `AuditLog :approval_decision` — M
- `audit-s5` IMPORT `logger_json` (ECS format) — S
- `audit-s6` Retention policy + JSONL `chmod 0444` after rotation — S
- `audit-s7` HTTP audit sink behaviour (fire-and-forget) — M
- `audit-s8` Cursor pagination on /api/v2/audit — S

**Track 2: Auth Compliance (parallel with Track 1)**
- `auth-s1` `PolicyDecisionStore` GenServer — queryable audit ETS ring buffer — M
- `comp-gov1` IMPORT `logger_json` (joins audit-s5) — done in Track 1
- `comp-gov3` IMPORT `open_api_spex` request validation middleware — M
- `comp-gov4` `ControlRegistry` framework mapping (NIST AI RMF/SOC 2/ISO) — M
- `comp-map1` ASL tier + EU AI Act risk class on AgentIdentity — M
- `comp-map2` `RiskScoreAggregator` GenServer — formation-level composite risk — L
- `comp-ms1` 6 KRI telemetry events + Prometheus export — M
- `comp-ms2` `ComplianceReportEngine` — automated NIST/SOC2/ISO posture report — L
- `comp-mg1` `IncidentResponseEngine` circuit breaker — L
- `comp-mg2` `cloak` field encryption for audit PII — M
- `comp-mg3` `GovernanceLive` at `/governance` — L

**Track 3: Rate Limit + Workflow + Health + Coordination (parallel)**
- `rl-s2` Replace both custom RateLimiters with `hammer` — S
- `rl-s3` Install `fuse` circuit breakers on /api/register, /heartbeat, /notify — M
- `rl-s4` `plug_attack` HTTP pipeline rate limiting — M
- `rl-s5` `RateLimitHeaders` Plug (RFC 6585 + IETF structured headers) — S
- `rl-s6` `FormationRateLimiter` (sqrt scaling) — M
- `rl-s7` `AdaptiveRateLimiter` GenServer — L
- `rl-s8` Dashboard widget for rate limits + fuse states — M
- `wf-s1` Replace custom DFS with `:digraph_utils.is_acyclic/1` — XS
- `wf-s2` `FormationStateMachine` typed atom FSM — M
- `wf-s3` `FormationPersistenceStore` exqlite WAL — L
- `wf-s4` `reactor` saga compensation — L
- `wf-s5` `:approval` step type in OrchestrationManager — M
- `wf-s6` `:gen_statem` step timeout policies — M
- `hc-s1` RFC 8615 `/health` + `application/health+json` — S
- `hc-s2..5` `/healthz`, `/ready`, `/startup`, Erlang VM checks — XS each
- `coord-b1` `ApmV5.A2A.TaskStore` task state machine — M
- `coord-b2` Bridge AG-UI events → A2A task transitions — M
- `coord-c1` FIPA performatives vocabulary on Envelope — S
- `coord-c2` `FileLockRegistry` GenServer (pessimistic, 30s TTL) — M
- `coord-c3` `ArtifactVersionStore` CAS for skill edits — S

**Track 4: API Governance (TypeScript)**
- `api-s3` `zod-to-openapi` registry in @ccem/apm — S
- `api-s4` `openapi-typescript` codegen replaces manual TS types — M
- `api-s5` `open_api_spex` annotation Wave 1 (4 controllers) + CastAndValidate plug — M
- `api-s6` `OpenApiSpex.TestAssertions` contract tests — M

**Total v9.3.0 stories**: ~45 stories across 4 parallel tracks.

### v9.3.1 — Patch Polish
- `audit-s9` cursor pagination + `logger_json` ECS format (deferred from v9.3.0 if needed)
- `comp-mg3` `GovernanceLive` polish + walkthrough
- `hc-s6..9` Per-agent + per-formation health endpoints + score history + threshold config
- `wf-s7` OTel + PROV-DM attribute alignment
- `wf-s8` BPMN XML export endpoint
- `api-s8` `DeprecationPlug` for `/api/*` (non-v2) routes
- `api-s9` AsyncAPI 3.0 doc — `/api/v2/asyncapi.yaml`
- `api-s10` Schemathesis nightly fuzz CI

### v9.4.0 — Provenance + Identity + Audit WORM
**Foundation for v10.0 identity bump**

- `prov-w1-s1` `ApmV5.Identity.KeyStore` Ed25519 keypair — M
- `prov-w1-s2` `DIDProvider` + `/api/v2/identity/did-document` — M
- `prov-w1-s3` `ArtifactAttestation` signer for Write/Edit hooks — M
- `prov-w2-s4` `prov-ex` PROV-DM bundle export `/api/v2/provenance/bundle` — L
- `prov-w2-s5` `AgentRoleIndex` cross-session lineage — S
- `prov-w2-s6` `LineageTracker` `wasDerivedFrom` edges — M
- `prov-w3-s7` HDP delegation chain (Ed25519 signed hops) — M
- `prov-w3-s8` OTel GenAI `gen_ai.agent.*` span emission — M
- `prov-w4-s9` Provenance REST API (6 new endpoints) — M
- `prov-w4-s10` `ProvenanceLive` at `/intelligence/provenance` — L
- `auth-s2` PolicyRulesStore versioning (version, created_by, approved_by, expires_at) — M
- `auth-s3` `PolicyPredicate` DSL (time/env/path-glob conditions) — M
- `audit-s9` `eventstore` PostgreSQL WORM backend (opt-in feature flag) — L
- `api-s7` `open_api_spex` Wave 2 — annotate all remaining 20+ controllers, **delete `build_spec/0`** — L

### v10.0.0 — Cryptographic Agent Identity (BREAKING)
**The major bump. Agent identity becomes verifiable.**

- `auth-v10-s1` RFC 7523 JWT Bearer Assertions — `joken` signs agent assertions, AuthorizationGate verifies — L (BREAKING)
- `auth-v10-s2` `DelegationToken` system — `{parent, child, max_risk, allowed_tools, sig}`, OWASP MCP02 — L
- `coord-d2` Horde + libcluster replaces ETS AgentRegistry with cross-node `Horde.Registry` — L (BREAKING supervision tree)
- API migration guide for hook payloads to include `Authorization: Bearer <jwt>`
- Migration helper: existing string `agent_id` deprecation path with 6-month sunset

### v10.1.0 — Contextual Policies via OPA
- `auth-v10.1-s1` `ApmV5.Auth.OpaClient` thin `Req` HTTP wrapper to OPA sidecar — M
- `auth-v10.1-s2` Rego policies in `priv/policies/` for time/env/path/role conditions — M
- `auth-v10.1-s3` `GET /api/v2/auth/policy/rego` export for external OPA — S
- `auth-v10.1-s4` `PolicyPriorityResolver` for conflict resolution (deny-wins/most-specific) — S

### v10.2.0 — Multi-Node + External IdP
- `auth-v10.2-s1` Swap `RateLimiter` ETS → `hammer` Redis backend (or `hammer_backend_mnesia`) — M
- `auth-v10.2-s2` `assent` OIDC integration in `SessionStore.create/2` — M
- Cross-node testing harness for clustered deployments

### v10.3.0 — Human Approver Attestation + Compliance Polish
- `auth-v10.3-s1` `wax_` WebAuthn FIDO2 attestation on approval endpoint — L
- `comp-v10.3-s1` SLSA Provenance v1.0 attestation for tool calls — M
- `comp-v10.3-s2` Verifiable Credentials issuance via `joken` + custom VC context — L
- EU AI Act Article 13 transparency disclosure surfacing in dashboard
- ISO/IEC 42001 AIMS document generation from ControlRegistry

---

## Dependency Graph

```
v9.2.1 (security patches, no deps)
  ↓
v9.3.0 (OTel + JSON audit + auth compliance — 4 parallel tracks)
  ↓
v9.3.1 (polish — depends on v9.3.0)
  ↓
v9.4.0 (provenance + identity + WORM — depends on OTel + audit foundation from v9.3.0)
  ↓
v10.0.0 [BREAKING] (JWT identity + delegation + Horde — depends on KeyStore from v9.4.0)
  ↓
v10.1.0 (OPA sidecar — depends on PolicyRulesStore versioning from v9.4.0)
  ↓
v10.2.0 (multi-node + OIDC — depends on Horde from v10.0.0)
  ↓
v10.3.0 (WebAuthn + SLSA + VC — depends on KeyStore + delegation from v9.4.0 + v10.0.0)
```

## NIST AI RMF Coverage Trajectory

| Function | v9.2.0 (now) | v9.3.0 | v9.4.0 | v10.0.0 | v10.3.0 |
|---|---|---|---|---|---|
| GOVERN | PARTIAL | GOOD | GOOD | EXCELLENT | EXCELLENT |
| MAP | PARTIAL | GOOD | GOOD | EXCELLENT | EXCELLENT |
| MEASURE | PARTIAL | GOOD | EXCELLENT | EXCELLENT | EXCELLENT |
| MANAGE | WEAK | PARTIAL | GOOD | GOOD | EXCELLENT |

## EU AI Act Article Coverage Trajectory

| Article | v9.2.0 | v9.3.0 | v9.4.0 | v10.3.0 |
|---|---|---|---|---|
| Art. 13 Transparency | PARTIAL | GOOD | GOOD | EXCELLENT |
| Art. 14 Human Oversight | SATISFIED | SATISFIED | SATISFIED | EXCELLENT |
| Art. 52 Disclosure | ABSENT | PARTIAL | GOOD | EXCELLENT |
| Art. 9 Risk Mgmt | ABSENT | PARTIAL | GOOD | EXCELLENT |

## A2A Protocol Conformance Trajectory

| A2A Feature | v9.2.0 | v9.2.1 | v9.3.0 |
|---|---|---|---|
| `/.well-known/agent-card.json` | ❌ | ✓ | ✓ |
| Task state machine | ❌ | ❌ | ✓ |
| AgentCard skills[] | ❌ | partial | ✓ |
| Topic-scoped broadcast | 🐛 BUG | ✓ | ✓ |
| AG-UI ↔ A2A bridge | ❌ | ❌ | ✓ |

---

## Recommended UPM Formation Strategy

This roadmap is too large for sequential implementation. Recommended:

1. **v9.2.1 ships as a hotfix sprint** (1 week, 6 stories, single squadron)
2. **v9.3.0 = "Governance Foundation" major sprint** — 45 stories across 4 parallel tracks, each track = squadron
   - Track 1 squadron: Observability + Audit (11 stories)
   - Track 2 squadron: Auth Compliance + Compliance Reporting (10 stories)
   - Track 3 squadron: Rate Limit + Workflow + Health + Coordination (18 stories)
   - Track 4 squadron: API Governance + TypeScript codegen (6 stories)
3. **v9.4.0 = "Provenance Wave" specialized formation** — 14 stories across 4 waves (parallel within waves)
4. **v10.0.0 = "Identity Major" coordinated breaking change** — 3 stories but each L-effort with migration tooling
5. **v10.1/10.2/10.3 = quarterly minor releases** with smaller specialized formations

Total estimated effort: ~120 stories across 9 versions over ~6 months at sustained velocity.

## Skill Chaining Integration Points

Each existing CCEM skill should chain to coalesce:
- `/coalesce` — refresh all skill SKILL.md files with new endpoints (v9.3.0, v10.0.0, v10.3.0)
- `/showcase` — feature each new LiveView page (`/governance`, `/provenance`, `/intelligence/provenance`)
- `/plane-pm align` — sync UPM stories to Plane project CCEM
- `/upm autopilot` — drive each track via wave-based delivery
- `/apm-api-reference` — auto-regenerate from updated OpenAPI spec at each minor bump
