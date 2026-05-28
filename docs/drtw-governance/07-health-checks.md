# DRTW Report: Health Check & Liveness Probe Standards
**Domain**: IETF RFC, Kubernetes probes, Erlang VM health, CCEM probe infrastructure
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (S1-S5), v9.3.1 (S6-S9)

## Verdict: No New Packages Needed
CCEM APM already has substantial health infrastructure. Every candidate Hex package is stale, non-RFC-compliant, or duplicates existing infrastructure:
- `HealthCheckRunner` GenServer — 5 checks, 30s interval, parallel Task.async_stream
- `StatusCache` — ETS, 1s TTL, 500ms proactive refresh
- `MetricsCollector.compute_health_score/1` — 4-factor weighted score
- `SloEngine` — hourly ETS snapshots for 5 SLIs
- `AppVersion.current/0` — runtime-safe for RFC `releaseId` field

**Only potential add**: `recon v2.5.6` for deep production diagnostics — deferred until a deep diagnostics LiveView is scoped.

## Standards to Implement (Zero New Deps)

### IETF draft-inadarei-api-health-check-06
```json
GET /health → Content-Type: application/health+json
{
  "status": "pass",   // "pass" | "warn" | "fail" (not "ok"!)
  "version": "9.2.0",
  "releaseId": "9.2.0",
  "checks": {
    "ets:size": [{"componentType": "datastore", "observedValue": 42, "status": "pass"}],
    "beam:memory": [{"componentType": "system", "observedValue": 512, "observedUnit": "MB", "status": "pass"}]
  }
}
```

### Kubernetes Probes (universally expected)
```
GET /healthz  → liveness: BEAM up + Phoenix responding → 200/503
GET /ready    → readiness: StatusCache warm + critical GenServers registered → 200/503
GET /startup  → startup: supervision tree children initialized → 200/503
```

### RFC 8615 Well-Known URI
```
GET /.well-known/health → alias to RFC health endpoint
```

### Erlang VM health (OTP stdlib, zero new deps)
- `:erlang.memory()` — total/processes/ETS memory
- `:erlang.system_info(:process_count/:process_limit)` — process saturation %
- `:erlang.statistics(:run_queue)` — scheduler backpressure
- `:ets.info(table, :size/:memory)` — per-table health

## Critical Content-Type Gap
`/health` currently uses `json/2` → `Content-Type: application/json`.
RFC-compliant tools (AWS ALB, Consul, uptime-kuma) check for `application/health+json`.
**Also note**: RFC uses `"pass"` not `"ok"` — document breaking change in release notes.

## Gaps → Stories (9 total)
1. **S1** RFC 8615 `/health` + `application/health+json` + `/.well-known/health` alias — S
2. **S2** `GET /healthz` liveness probe — XS
3. **S3** `GET /ready` readiness probe — XS
4. **S4** `GET /startup` startup probe — S
5. **S5** Erlang VM health in RFC checks object (memory/processes/run_queue/ETS) — S
6. **S6** `GET /api/v2/agents/:id/health` dedicated endpoint — S
7. **S7** `GET /api/v2/formations/:id/health` rollup (% healthy agents) — M
8. **S8** Health score history via SloEngine extension — M
9. **S9** Configurable alert thresholds + PubSub breach events — M
