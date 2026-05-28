# DRTW Report: AI Governance & Compliance Frameworks
**Domain**: NIST AI RMF, SOC 2, ISO 27001, EU AI Act, OPA, Casbin
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (minor bump)

## CCEM Already Has (Strong Foundation)
1. `PolicyEngine` + `PolicyRulesStore` → NIST AI RMF GOVERN + SOC 2 CC6.1
2. `AuditLog` with SHA-256 hash chain → ISO 27001 A.8.15 + SOC 2 CC7 **SATISFIED**
3. `ApprovalAuditLog` + approval gates → EU AI Act Article 14 human oversight **SATISFIED**
4. `RedactionEngine` (7 PII patterns) → partial CIS 3 data protection
5. `SloEngine` (5 SLIs + error budgets) → partial NIST CSF DETECT
6. `SecurityGuidancePlugin` + hook blocking → partial NIST AI RMF MAP
7. `sobelow` + `credo` already in deps → NIST SP 800-218 **SATISFIED**
8. MCP ToolAnnotations risk scoring → AI-native governance, unique to CCEM

## Packages to IMPORT
```elixir
{:logger_json, "~> 7.0"},              # 11.9M DL — structured JSON for SIEM (SOC 2 CC7.1) — 1sp
{:open_api_spex, "~> 3.22"},           # 10.6M DL — API contract governance middleware — 2sp
{:ex_json_schema, "~> 0.11"},          # 34.3M DL — hook payload schema validation — 3sp
{:norm, "~> 0.13"},                    # 2.6M DL — PolicyEngine.evaluate/3 input contracts — 2sp
{:cloak, "~> 1.1"},                    # 7.3M DL — field-level AES-256-GCM encryption at rest — 3sp
```

## Packages to SKIP
- `casbin`/`ex_casbin`: 1.3K total downloads (44/wk) — immature. PolicyEngine already covers this.
- `bodyguard`: Designed for user-facing apps, not agent governance
- `paper_trail`/`ex_audit`: Ecto-based; CCEM uses ETS
- OPA Elixir clients: All abandoned (opalix: 5 stars 2020, opa_suite: 1 star)

## OPA Verdict: ADAPT not REPLACE
CCEM's PolicyEngine is already a pure-function Elixir pipeline doing what Rego would express. OPA sidecar makes sense if multi-tenant policy federation is needed. For now: BUILD `GET /api/v2/auth/policy/rego` export endpoint so external OPA deployments can consume CCEM policy as a bundle.

## Critical Gaps (Must Build)
1. **Composite risk score** — risk is per-tool-call only; no session/formation-level aggregate
2. **ControlRegistry** — controls exist but not tagged with framework identifiers (NIST/SOC2/ISO codes)
3. **ComplianceReportEngine** — no automated posture report; `ActionEngine` has raw denial counts only
4. **IncidentResponseEngine** — manual `always_deny` only; no automated circuit breaker on threshold breach
5. **ASL tier / EU AI Act disclosure fields** — agent registrations lack capability ceiling declaration

## Implementation Stories (NIST AI RMF organized)

### GOVERN (Policy Infrastructure)
- **GOV-1** `logger_json` structured logging backend — 1sp — IMPORT
- **GOV-2** PolicyRulesStore versioning + attestation (version, created_by, approved_by, expires_at) — 3sp — ADAPT
- **GOV-3** `open_api_spex` request validation middleware — 2sp — IMPORT
- **GOV-4** `ControlRegistry` module — framework control mapping — 2sp — BUILD

### MAP (Risk Categorization)
- **MAP-1** ASL tier + EU AI Act risk class on AgentIdentity — 3sp — ADAPT
- **MAP-2** `RiskScoreAggregator` GenServer — composite session/formation risk — 4sp — BUILD
- **MAP-3** Hook payload schema validation with `ex_json_schema` — 3sp — IMPORT+ADAPT

### MEASURE (KRIs & Metrics)
- **MS-1** Compliance KRI telemetry (6 new events + Prometheus export) — 3sp — BUILD+IMPORT
- **MS-2** `ComplianceReportEngine` — automated posture report — 5sp — BUILD

### MANAGE (Response & Recovery)
- **MG-1** `IncidentResponseEngine` circuit breaker (auto deny on threshold) — 5sp — BUILD
- **MG-2** `cloak` field encryption for audit log PII — 3sp — IMPORT
- **MG-3** `GovernanceLive` at `/governance` — 5sp — BUILD

## NIST AI RMF Coverage After Implementation
| Function | Before | After |
|---|---|---|
| GOVERN | PARTIAL | GOOD |
| MAP | PARTIAL | GOOD |
| MEASURE | PARTIAL | GOOD |
| MANAGE | WEAK | PARTIAL (MG-1 adds circuit breaker; recovery still absent) |

## EU AI Act Status
- Article 13 (Transparency): PARTIAL → GOOD after MAP-1
- Article 14 (Human Oversight): SATISFIED (approval gates)
- Article 52 (Disclosure): ABSENT → add disclosure_text field in MAP-1
