# DRTW Report: Agent Provenance & Identity Standards
**Domain**: W3C PROV-DM, DID:key, JWT/joken, SLSA, OTel GenAI Agent Spans
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (minor, 10 stories across 4 waves)

## Packages to IMPORT
```elixir
{:joken, "~> 2.6"},                           # 55.4M DL, 109 dependents — JWT agent tokens
{:joken_jwks, "~> 1.7"},                      # JWKS endpoint for public key distribution
{:ex_did, "~> 0.2"},                          # 499 DL — DID:key resolution (ADAPT needed)
{:prov, "~> 0.1"},                            # 372 DL, March 2026 — W3C PROV-DM (ADAPT)
{:rdf, "~> 3.0"},                             # 7.9K DL/wk — RDF/Turtle serialization (prov dep)
{:grax, "~> 0.6"},                            # prov dep
# opentelemetry_api + opentelemetry + opentelemetry_semantic_conventions — see observability report
```

**Note**: OTP `:crypto` (native, zero new dep) provides Ed25519 keypair generation and signing — no `ex_crypto` needed.

## Key Architecture: Additive, Not Replacing
- `agent_id` string remains the ETS primary key
- JWT identity token is ADDITIVE to registration response
- `did:key` identifier derived from `agent_id` deterministic seed (UUID v5) — no per-agent keypair overhead
- `AuditLog` hash chain is the existing artifact provenance; extend with Ed25519 signatures

## What Must Be Built (No Package Covers It)
1. **`ApmV5.Provenance.ArtifactAttestation`** — SLSA-like `{subject, agent_id, tool_name, sha256, sig}` for Write/Edit hooks
2. **`ApmV5.Identity.AgentRoleIndex`** GenServer — cross-session stable `agent_role_id` via UUID v5
3. **`ApmV5.Provenance.LineageTracker`** GenServer — `wasDerivedFrom` edges when tool B consumes tool A output
4. **`ApmV5.Provenance.DelegationChain`** — HDP-style append-only Ed25519 signed hop chain (human → orchestrator → swarm)

## Gaps → Waves

### Wave 1 (independent, parallel)
- **S1** `ApmV5.Identity.KeyStore` + `TokenIssuer` — Ed25519 keypair + JWT agent tokens — M (2 days)
- **S2** `DIDProvider` + `GET /api/v2/identity/did-document` — M (2 days)
- **S3** `ArtifactAttestation` struct + signer + `:apm_artifact_attestations` ETS — M (2 days)

### Wave 2 (depends on Wave 1)
- **S4** `ProvExporter` using `prov ~> 0.1` + `GET /api/v2/provenance/bundle` — L (3 days)
- **S5** `AgentRoleIndex` GenServer + `GET /api/v2/agents/:id/lineage` — S (1 day)
- **S6** `LineageTracker` GenServer + lineage DAG API — M (2 days)

### Wave 3 (depends on Wave 1, parallel)
- [x] **S7** `DelegationChain` module — pure functional, `:crypto` only — M (prov-w3-s7 / CP-281 / SHIPPED)
- [x] **S8** OTel GenAI `gen_ai.agent.*` span emission in `AgentRegistry` — M (prov-w3-s8 / CP-282 / SHIPPED)

### Wave 4 (depends on Waves 1-3) — SHIPPED prov-w4 / CP-283 + CP-284
- [x] **S9** Provenance REST API — 3 new endpoints (agents/:id, artifacts, verify) — SHIPPED
  - `GET /api/v2/provenance/agents/:id` — full provenance record
  - `GET /api/v2/provenance/artifacts` — paginated ETS attestations with sig verify
  - `POST /api/v2/provenance/verify` — sign+verify roundtrip
  - OpenApiSpex annotations, no new deps, 12 TDD tests green
- [x] **S10** `ProvenanceLive` at `/intelligence/provenance` — SHIPPED
  - 3 tabs: Artifact Attestations, Lineage Graph (D3.js), PROV Bundle
  - PubSub `"apm:artifacts"` live updates + 30s tick refresh
  - `ProvenanceLineageGraph` JS hook (D3 lazy CDN, force DAG)
  - Sidebar nav item under Intelligence section
  - 11 TDD tests green

### Wave 4 DRTW Decisions

**ProvenanceLive D3 graph**: Reused existing CDN lazy-load pattern from
`FormationGraph` hook rather than introducing a new bundled dependency.
`ProvenanceLineageGraph` is a new 120-LOC hook, not a new npm package.

**Verify endpoint**: `:crypto.verify(:eddsa, :none, ...)` (OTP native) used for
Ed25519 signature verification — no jose/joken dep required.  All provenance
signing uses `ApmV5.Identity.KeyStore` (already in the supervision tree).

## New Deps Summary
5 new packages (originally planned): `joken`, `joken_jwks`, `ex_did`, `prov`/`rdf`/`grax`, plus OTel already coming from observability report. All MIT/Apache-2.0, no CVEs.

### Wave 3 S7 DRTW Decision — DelegationChain JWT encoding
**Decision**: No `joken` dep for `DelegationChain.to_jwt/1`.
**Rationale**: `DelegationChain.to_jwt/1` is a transport-envelope function producing a
`delegation_chain` JWT claim for downstream validators.  Full EdDSA JWT (`alg: EdDSA`)
requires JOSE/JWKS infrastructure.  The JWT payload's trust anchor is the Ed25519 hop
signatures already embedded in the chain; the JWT wrapper uses HS256 with the APM's
private key bytes as a shared secret, which is adequate for intra-CCEM wire transport.
**Stack used**: `:crypto` (OTP native) + `Base.url_encode64/2` (stdlib) + `Jason.encode!/1`
(existing dep, `~> 1.2`).  Zero new dependencies.  Joken will be evaluated when JWKS
distribution (`GET /api/v2/identity/jwks`) is implemented in Wave 4.

## EU AI Act Note
Enforcement begins August 2, 2026. `AuditLog` hash chain satisfies lightweight Article 13 transparency for internal tooling. C2PA has no Elixir implementation — defer. `Co-Authored-By` git trailer already partially satisfies Article 52 disclosure.
