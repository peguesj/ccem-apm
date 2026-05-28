# DRTW Report: Rate Limiting & Circuit Breaking
**Domain**: Hammer, Fuse, PlugAttack, FormationRateLimiter, Adaptive Backpressure
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (minor, 8 stories)

## Current State (Critical Gap)
Two hand-rolled sliding-window ETS rate limiters for `{agent_id, tool_name}` only.
- **125 POST endpoints completely unprotected at the HTTP pipeline level**
- A 20-agent formation at 10 Hz = 200 req/s to /api/register with zero protection
- No circuit breaker anywhere in the codebase
- No HTTP rate limit response headers (no `Retry-After`, no `X-RateLimit-*`)
- No per-formation aggregate limits (20 agents each get full bucket = O(n) amplification)

## Packages to IMPORT
```elixir
{:hammer, "~> 7.0"},       # 45.8K DL/wk, May 2026 — drop-in replacement for both RateLimiters
{:fuse, "~> 2.5"},         # 25.5K DL/wk, stable Erlang — circuit breaker for agent storms
{:plug_attack, "~> 0.4"},  # 8.5K DL/wk — HTTP pipeline IP-level throttling
```

**Defer**: `hammer_backend_redis` / `hammer_backend_mnesia` — only when multi-node needed

## Packages Rejected
- `ex_rated` v2.1.0 — last updated Dec 2021; hammer is a full superset
- `regulator` v0.6.0 — 120 DL/wk, effectively unmaintained
- `rate_limiter` v0.4.0 — updated 2019

## Key Integration Notes
- **Hammer**: `hit/3` is atomic check+record (replaces separate `check/2` + `record/2`)
- **Fuse**: install in `Application.start/2`; wrap hot paths with `:fuse.run/3`; returns `:blown` in ~0.5μs
- **PlugAttack**: add to `:api` pipeline in router.ex after `ApiAuth`

## Standards to Implement
- **RFC 6585 §4**: 429 with `Retry-After` header (not 503) on rate limit
- **IETF draft-ietf-httpapi-ratelimit-headers**: `RateLimit` + `RateLimit-Policy` structured headers
- **Legacy compatibility**: `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`

## Gaps → Stories (8 total)
1. **story-rl-1**: Add hammer + fuse + plug_attack to mix.exs — XS (30min)
2. **story-rl-2**: Replace both RateLimiters with Hammer — S (2h)
3. **story-rl-3**: Install fuse circuit breakers on /api/register, /heartbeat, /notify — M (3h)
   - Thresholds: register 500/10s, heartbeat 1000/10s, notify 300/10s (generous to avoid false trips)
4. **story-rl-4**: PlugAttack in :api pipeline — M (3h)
5. **story-rl-5**: BUILD `RateLimitHeaders` Plug (~25 LOC) — S (1.5h)
6. **story-rl-6**: BUILD `FormationRateLimiter` — formation budget = `per_agent × sqrt(agent_count)` — M (3h)
7. **story-rl-7**: BUILD `AdaptiveRateLimiter` GenServer — scales buckets based on GenServer mailbox depth — L (5h)
8. **story-rl-8**: Dashboard widget — fuse states, formation utilization heatmap, adaptive factor — M (3h)

## DRTW Summary
| Capability | Decision | Package/Approach |
|---|---|---|
| Rate limiting per {agent, tool} | IMPORT | `hammer` v7.0 replaces both custom RateLimiters |
| HTTP pipeline rate limiting | IMPORT | `plug_attack` v0.4.3 |
| Circuit breaker for agent storms | IMPORT | `fuse` v2.5.0 (Erlang, 0.5μs per ask) |
| Rate limit HTTP headers | BUILD | `RateLimitHeaders` Plug ~25 LOC |
| Per-formation aggregate limits | BUILD | `FormationRateLimiter` (CCEM-specific key logic) |
| Adaptive load-based scaling | BUILD | `AdaptiveRateLimiter` GenServer |
| Distributed rate limiting | DEFER | `hammer_backend_mnesia` when multi-node needed |
