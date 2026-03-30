# API Architecture — Core vs Extensions

CCEM APM uses a **microkernel + extensions** design. The core API surface covers
fundamental monitoring primitives. All domain-specific capabilities are organized
as named extensions, each clearly delimited in the router.

---

## Core API

The core contains everything needed to monitor and track agentic sessions without
any additional features enabled:

| Concern | Routes | Example |
|---------|--------|---------|
| Agent lifecycle | register, heartbeat, activity log | `POST /api/register` |
| Sessions & data | sessions list, master data | `GET /api/v2/sessions` |
| Notifications | CRUD + read-all | `GET /api/notifications` |
| Health & telemetry | status, telemetry buckets, metrics | `GET /api/status` |
| Ports | registry, scan, clash detection | `GET /api/ports` |
| Background tasks | CRUD + logs + stop | `GET /api/bg-tasks` |
| Project scanner | scan, results, status | `POST /api/scanner/scan` |
| Actions | catalog, run, runs | `POST /api/actions/run` |
| Projects & config | list, update, reload | `GET /api/projects` |
| Export / import | JSON/CSV export, import | `GET /api/v2/export` |
| Alerts, SLOs, Audit | v2 monitoring primitives | `GET /api/v2/slos` |
| Workflows | schema store CRUD | `GET /api/v2/workflows` |
| Verification | double-verify gate | `POST /api/v2/verify/double` |
| A2A messaging | agent-to-agent relay | `POST /api/v2/a2a/send` |
| Chat | scoped message store | `GET /api/v2/chat/:scope` |
| Tool calls | invocation tracking | `GET /api/v2/tool-calls` |
| Approvals | request/approve/reject | `POST /api/v2/approvals/request` |

---

## Extensions

Each extension is delimited with a section comment in `router.ex`. Extensions are
identified in the OpenAPI spec by the `x-extension: true` field on their tag
definitions, and by the `[extension:name]` prefix in tag descriptions.

### Discovering Extensions at Runtime

```
GET /api/v2/manifest
```

Returns a machine-readable summary of all extensions, their route counts, and
enabled status. Example response:

```json
{
  "core_version": "8.9.0",
  "architecture": "microkernel+extensions",
  "extensions": [
    {
      "name": "agentlock",
      "version": "8.9.0",
      "enabled": true,
      "routes": 26,
      "description": "AgentLock authorization — session, token, policy, context, memory, rate-limit management",
      "path_prefix": "/api/v2/auth/*"
    },
    ...
  ],
  "core_routes": 62,
  "total_routes": 178
}
```

### Extension Classification Table

| Extension | Tag in OpenAPI | Path Prefix | Route Count |
|-----------|---------------|-------------|-------------|
| `agentlock` | `AgentLock Authorization` | `/api/v2/auth/*` | 26 |
| `upm` | `UPM`, `UPM Decision Gate` | `/api/upm/*`, `/api/v2/upm/*` | 30 |
| `coalesce` | `Coalesce` | `/api/v2/coalesce/*` | 8 |
| `skills` | `Skills` | `/api/skills/*` | 6 |
| `showcase` | `CCEM Management` | `/api/showcase/*` | 3 |
| `ag_ui` | `AG-UI`, `Agent Context` | `/api/ag-ui/*`, `/api/v2/ag-ui/*` | 14 |
| `plugins` | `Plugins`, `Integrations` | `/api/v2/plugins/*`, `/api/v2/integrations/*` | 11 |
| `usage` | `Usage` | `/api/usage/*` | 5 |
| `formations` | `Formations` | `/api/formations/*`, `/api/v2/formations/*` | 10 |
| `plane` | `Plane` | `/api/v2/plane/*` | 2 |

---

## OpenAPI Spec — Identifying Extensions

All extension tags in the OpenAPI spec carry `"x-extension": true`:

```json
{
  "tags": [
    { "name": "Health", "description": "..." },
    { "name": "AgentLock Authorization",
      "description": "[extension:agentlock] ...",
      "x-extension": true }
  ]
}
```

Operations tagged with an extension tag inherit `x-extension: true` semantics.
Tools parsing the spec can filter to core-only by excluding operations whose tags
have `x-extension: true` in the tags array.

---

## Router Organization

`lib/apm_v5_web/router.ex` uses section comments to delimit core vs extension routes:

```elixir
# ── CORE APM — REST API (v1) ─────────────────────────────────
scope "/api", ApmV5Web do
  pipe_through :api
  # agent lifecycle, ports, tasks, telemetry, ...

  # ── EXTENSION: skills (v1) ──────────────────────────────────
  # ...

  # ── EXTENSION: upm (v1) ─────────────────────────────────────
  # ...
end

# ── CORE APM — REST API (v2) ─────────────────────────────────
scope "/api/v2", ApmV5Web.V2 do
  pipe_through :api
  # v2 monitoring primitives: agents, sessions, metrics, slos, ...

  # ── EXTENSION: ag_ui (v2) ───────────────────────────────────
  # ...

  # ── EXTENSION: agentlock ────────────────────────────────────
  # ...
end
```

This is a **non-breaking, commentary-only reorganization** — all URLs are unchanged.
The separation is purely for navigability, auditability, and code review clarity.
