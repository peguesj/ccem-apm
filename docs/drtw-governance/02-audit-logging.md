# DRTW Report: Audit Logging Standards
**Domain**: WORM, hash chains, EventStore, SIEM, OWASP/NIST/PCI DSS/ISO 27001
**Research date**: 2026-05-26
**Version target**: v9.2.1 (security patch) → v9.3.0 (minor, full upgrade)

## Critical Current-State Findings
1. **Hash chain stored but not verifiable** — `prev_hash` is in events, but the current event's `self_hash` is only kept in GenServer state (not ETS, not JSONL file). No `verify_chain/0` API exists.
2. **ETS is `:public`** — any process in the VM can `:ets.delete/2` audit entries, bypassing the GenServer. Tamper surface.
3. **Dual GenServer divergence** — `AuditLog` (hash chain, disk) and `ApprovalAuditLog` (no chain, no disk, lost on restart) for essentially the same purpose
4. **No retention policy** — JSONL files rotate daily but are never deleted; no purge timer
5. **No agent attribution** — `actor` is free-text; no typed `agent_id`/`session_id`/`formation_id`/`wave` fields
6. **No cursor pagination** — `/api/v2/audit` does full `tab2list` scan

## Packages to IMPORT
```elixir
{:logger_json, "~> 7.0"},      # 11.9M DL — ECS/Datadog/GCP JSON formatter, 3-line config switch
# OPTIONAL (deferred to v9.4):
{:eventstore, "~> 1.4"},       # 1.8M DL — SQL-level WORM via PostgreSQL RULE blocks UPDATE/DELETE
```

**SQL-level immutability finding**: EventStore's migration creates PostgreSQL `RULE` directives that make the events table physically immutable — even a superuser DELETE silently does nothing. This is **the only Elixir package providing true WORM guarantees**. Requires PostgreSQL (CCEM uses ETS+JSONL+optional exqlite today).

## Packages to SKIP
- `ex_audit`, `paper_trail` — Ecto-only, designed for DB row diffs, not agent action auditing
- `commanded` — full CQRS/ES framework, too heavy for audit-only use
- `timber` (timberio) — abandoned since 2019
- `spear`/`extreme` — require external EventStoreDB server process

## Unified Event Schema (synthesized from OWASP/NIST/PCI/AS2)
```elixir
%{
  # Identity
  id: integer, event_id: uuid_string,
  # Temporal
  timestamp: iso8601_string,
  # Classification (W3C AS2)
  event_type: atom, severity: atom, result: atom,  # success|failure|denied
  # Actor (PCI Req 10)
  actor: string, agent_id: nil|string, session_id: nil|string,
  formation_id: nil|string, wave: nil|integer, project_name: nil|string,
  # Object
  resource: string, tool_name: nil|string,   # W3C `instrument`
  # Causality (eventstore pattern)
  correlation_id: nil|uuid, causation_id: nil|uuid,
  # Payload
  details: map,
  # Integrity
  prev_hash: string, self_hash: string,  # NEW — enables forward verification
}
```

## Gaps → 9 Stories

### v9.2.1 patch (security)
- **S1** `self_hash` field + `verify_chain!/1` API — S (4h)
- **S2** ETS `:public` → `:protected` + test-gated `clear_all/0` — XS (1h)

### v9.3.0 minor
- **S3** Unified schema: agent_id/session_id/formation_id/wave/event_id — M (1 day)
- **S4** Merge `ApprovalAuditLog` into `AuditLog` as `:approval_decision` event type — M (1 day)
- **S5** IMPORT `logger_json` for structured Logger output — S (2h)
- **S6** Retention policy + JSONL `chmod 0444` after rotation — S (3h)
- **S7** HTTP audit sink behaviour (fire-and-forget Task) — M (1 day)
- **S8** Cursor pagination on `/api/v2/audit` (ETS select with match spec) — S (2h)

### v9.4.0 (deferred, opt-in)
- **S9** `eventstore` PostgreSQL backend gated by `config :apm_v5, :audit_backend, :eventstore` — L (2-3 days)
