# DRTW Report: API & Schema Governance
**Domain**: OpenAPI 3.1, AsyncAPI 3.0, Zod, Spectral, oasdiff, schemathesis
**Research date**: 2026-05-26
**Version target**: v9.2.1 (CI gates) → v9.3.0 (annotation migration) → v9.4.0 (kill `build_spec/0`)

## Critical Structural Finding
`/Users/jeremiah/Developer/ccem/apm-v4/lib/apm_v5_web/controllers/v2/api_v2_controller.ex` is **1,879 lines, ~1,600 of which are hand-written `build_spec/0`/`build_paths/0`/`build_schemas/0`**. The spec silently diverges from controller behavior. Every other governance gap derives from this root issue.

## Packages to IMPORT

### Elixir
```elixir
{:open_api_spex, "~> 3.22"},   # 10.6M DL, ControllerSpecs macro, CastAndValidate plug
{:norm, "~> 0.13"},            # 2.6M DL, internal data spec (not immediate)
```

### Node.js (in `@ccem/apm`)
```json
"@asteasolutions/zod-to-openapi": "^8.5.0",  // Zod → OpenAPI 3.0/3.1 (SSOT for TS types)
"openapi-typescript": "^7.13.0",             // OpenAPI → TS types (`tsc --noEmit` = contract test)
"openapi-fetch": "^1.x",                     // type-safe fetch client
"@stoplight/spectral-cli": "^6.16.0",        // OAS+AsyncAPI+Arazzo+OWASP linter
"@stoplight/spectral-owasp-ruleset": "^2.0.1" // OWASP API Top 10 2023
```

### CLI tools (Homebrew/pip)
- `brew install oasdiff` — Go CLI for breaking change detection, `--fail-on-incompatible` flag
- `pip install schemathesis` — property-based API fuzz testing from OpenAPI spec

## SKIP
- GraphQL — agent telemetry benefits from cursor pagination, not GraphQL
- `pact_elixir` — last updated 2020; `openapi-typescript` + `tsc --noEmit` is equivalent
- OpenAPI 3.1.0 migration — deferred until `open_api_spex` confirms full 3.1 support

## AsyncAPI 3.0 — BUILD (No Elixir Generator Exists)
CCEM has **28+ PubSub topics completely undocumented**. Organize into 4 channel groups:
1. **Core Agent Lifecycle** — `apm:agents`, `apm:sessions`, `apm:hooks`, `apm:notifications`, `apm:activity_log`, `hooks:health`
2. **Formation & Orchestration** — `apm:formations`, `orchestration:runs`, `apm:tool_calls`
3. **Intelligence & Memory** — `apm:memory`, `apm:conversations`, `apm:library`
4. **Platform & Infrastructure** — `apm:metrics`, `apm:slo`, `apm:alerts`, `apm:audit`, `upm:*`, `harness:state`, `apm:worktrees`, `builder:sessions`, `ag_ui:events`, `dashboard:updates`, `composio:triggers`, `open_design:state`, `apm:plugin_config`

Hand-author `priv/static/asyncapi.yaml`, serve at `GET /api/v2/asyncapi.yaml`, validate with `spectral:asyncapi`.

## Implementation Roadmap (10 stories)

### v9.2.1 patch (CI Safety Net — DO IMMEDIATELY)
- **S1** Snapshot `priv/static/openapi.base.json` + `oasdiff breaking` CI gate — XS (30 min, immediate priority)
- **S2** Spectral OpenAPI linting (.spectral.yaml + OWASP ruleset) — XS (half-day)

### v9.3.0 minor — TypeScript SSOT shift
- **S3** `@asteasolutions/zod-to-openapi` registry in `@ccem/apm` — S (2 days)
- **S4** `openapi-typescript` codegen — replace manual TS types with `components["schemas"]["X"]` — M (3 days)
- **S5** `open_api_spex` annotation Wave 1 (4 core controllers) + `CastAndValidate` plug — M (4 days)
- **S6** `OpenApiSpex.TestAssertions` response contract tests — M (3 days)

### v9.3.x patches
- **S8** `DeprecationPlug` — HTTP `Deprecation`/`Sunset` headers for `/api/*` (non-v2) — XS (half-day)
- **S9** AsyncAPI 3.0 doc + `GET /api/v2/asyncapi.yaml` — M (3 days)
- **S10** Schemathesis nightly fuzz CI job — S (2 days)

### v9.4.0 minor — Spec-as-truth
- **S7** `open_api_spex` Wave 2 — annotate all remaining 20+ controllers, **delete `build_spec/0`** — L (8 days)

## Story 1 Is Immediate Priority
The 30-minute oasdiff snapshot + CI gate provides a safety net **right now**. Every other governance tool operates on a spec that may not reflect actual controller behavior until S7 ships. Lock in v9.2.0 spec as baseline immediately.

## SSOT Architecture (Target)
```
   Phoenix Controllers (annotated)                    Zod (TS source)
            │                                              │
   open_api_spex.spec/0                       zod-to-openapi.register
            ↓                                              ↓
         GET /api/v2/openapi.json   ←──reconcile──→  openapi-components.json
                    │                                       │
                    ├──→ oasdiff breaking (CI gate)        │
                    ├──→ spectral lint (CI gate)           │
                    ├──→ schemathesis fuzz (nightly)       │
                    └──→ openapi-typescript codegen ───────┘
                                  ↓
                          @ccem/apm src/schema.d.ts
                                  ↓
                          tsc --noEmit (contract test)
```
