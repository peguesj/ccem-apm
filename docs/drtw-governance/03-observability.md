# DRTW Report: Observability & Telemetry
**Domain**: OpenTelemetry, Prometheus, Distributed Tracing
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (minor bump)

## Current State
- `telemetry`, `telemetry_metrics`, `telemetry_poller` ALREADY installed
- Custom PubSub telemetry — nothing exits the process (no export layer)
- No OTel SDK, no Prometheus endpoint, no trace context in hooks

## Packages to IMPORT (Tier 1 — Core OTel)
```elixir
{:opentelemetry_api, "~> 1.5"},        # 138K DL/wk — API-only for libs
{:opentelemetry, "~> 1.7"},             # 127K DL/wk — SDK
{:opentelemetry_exporter, "~> 1.10"},   # 106K DL/wk — OTLP HTTP/gRPC
{:opentelemetry_semantic_conventions, "~> 1.27"}, # 95K DL/wk — GenAI attrs
{:opentelemetry_bandit, "~> 0.3"},      # 26K DL/wk — CCEM uses Bandit not Cowboy
{:opentelemetry_phoenix, "~> 2.0"},     # 78K DL/wk — router/controller spans
{:opentelemetry_process_propagator, "~> 0.3"}, # 83K DL/wk — cross-process W3C
{:peep, "~> 5.0"},                      # 30K DL/wk — Prometheus /metrics (updated April 2026)
```

**Do NOT install:**
- `prom_ex` — no Bandit plugin (CCEM uses Bandit); steal their Grafana JSON from GitHub instead
- `agent_obs` v0.1.4 — 68 DL/week, immature; BUILD thin `ApmV5.Tracing` wrapper instead
- `opentelemetry_liveview` — stuck in RC since 2022

## Key Gaps
1. **No traceparent in hook payloads** — hooks fire without W3C trace context; no cross-agent span linking
2. **No Prometheus `/metrics`** — `/api/v2/metrics` returns JSON, not scrapeable
3. **No OTel SDK** — spans never exported outside the process
4. **No GenAI attrs on ClaudeUsageStore** — cache_read_tokens etc. tracked but not on spans
5. **No formation-level span linking** — parent_agent_id in AgentRegistry but no trace context

## Implementation Stories (5 stories, 3 waves)

### Wave 1 (independent)
- **S1** `observability_otel_sdk` — Install 8 packages, configure runtime.exs, `setup()` calls in Application.start/2 — Effort: S
- **S2** `observability_prometheus_endpoint` — `ApmV5.Metrics` module + peep reporter + `/metrics` route — Effort: M

### Wave 2 (depends on Wave 1)
- **S3** `observability_hook_traceparent` — Add OTEL_TRACEPARENT to session_init.sh + pre/post hooks; store trace_context in AgentRegistry — Effort: M
- **S4** `observability_genai_spans` — `ApmV5.Tracing` module with `with_agent_span/3`, `with_tool_span/3`, `with_llm_span/4`, `with_formation_span/3`; adapt ClaudeUsageStore — Effort: M

### Wave 3 (depends on Wave 2)
- **S5** `observability_grafana_dashboards` — Import prom_ex Grafana JSONs from GitHub; custom CCEM dashboard; Prometheus alert YAML — Effort: S

## Critical Insight
> The most impactful single change is hook traceparent propagation. Without `OTEL_TRACEPARENT` flowing through session_init.sh → pre_tool_use.sh → APM, all OTel SDK work produces only server-side spans with no linkage to Claude Code activity. Story 3 is the linchpin.

## GenAI Semantic Conventions Available
`opentelemetry_semantic_conventions` v1.27.0 incubating module includes:
- `gen_ai.usage.cache_read.input_tokens` — CCEM already tracks this
- `gen_ai.usage.cache_creation.input_tokens` — CCEM already tracks this
- `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.conversation.id`

---

## v9.4.0 Wave 3 S8 Update — AgentRegistry gen_ai.agent.* span emission (prov-w3-s8 / CP-282)

**Shipped**: 2026-05-28 on `ralph/v9.4.0-prov-w3`

### What changed
- `ApmV5.Tracing.with_agent_span/4` (was `/3`): added optional `opts` keyword parameter.
  - `provider_name:` keyword overrides the default `"anthropic"` provider name.
  - `agent_name:`, `agent_description:`, `agent_version:` keywords set the corresponding
    `gen_ai.agent.*` span attributes from `opentelemetry_semantic_conventions` incubating GenAI.
- `ApmV5.AgentRegistry.handle_call({:register_agent, ...})`: wraps the entire registration
  body in `ApmV5.Tracing.with_agent_span(agent_id, formation_id, fn, provider_name: "ccem")`.
  Attributes on the span: `gen_ai.agent.id`, `gen_ai.provider.name = "ccem"`,
  `ccem.formation.id`, `openinference.span.kind = "AGENT"`, plus optional
  `gen_ai.agent.name`, `gen_ai.agent.description`, `gen_ai.agent.version` when provided.
- `ApmV5.AgentRegistry.handle_call({:update_status, ...})`: wraps status update body in
  `with_agent_span` so status transition OTel events are emitted.

### DRTW decision
No new packages. `opentelemetry_semantic_conventions ~> 1.27` is already installed
(obs-s1 / CP-216).  `ApmV5.Tracing.with_agent_span/3` was already present (obs-s4 / CP-219).
The story required only a 4-argument overload + two `handle_call` wrappings — ~50 LOC.

### TDD
9 behavioral tests in `test/apm_v5/agent_registry_otel_test.exs` verify:
- Registration returns `:ok` with no span errors (no-op OTel in test env)
- Agent record fields that feed span attributes are correctly stored
- Concurrent registration does not leak span context
- Status updates return `:ok` and persist correctly
