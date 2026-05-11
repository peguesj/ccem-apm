# UPM Story Groups — CCEM APM Design System + Wireframes v1.0
# Generated: 2026-05-04 via /claude-design
# Source: CCEM APM (1).zip
# Run `/upm` to convert these into Plane issues.
# ──────────────────────────────────────────────

## Observe
- [ ] US-TBD: Observe — Dashboard (live fleet overview, 6-up metrics, dependency graph, fleet table, AI anomaly rail)
- [ ] US-TBD: Observe — Fleet (agent grid/list with card view, status pills, sparklines, filter rail)
- [ ] US-TBD: Observe — Formations (tree + 4 layout modes: tree/matrix/list/dot, scope selector)
- [ ] US-TBD: Observe — Timeline (swim-lane, 15m→24h window, per-agent tracks)
- [ ] US-TBD: Observe — Session Detail (JSONL viewer, tool call trace, token breakdown)
- [ ] US-TBD: Observe — Conversations (live transcript, CoWork split, streaming text)
- [ ] US-TBD: Observe — Tool Calls (stream view, per-agent stats, call graph)
- [ ] US-TBD: Observe — A2A (router table, broadcast log, fan-out graph)
- [ ] US-TBD: Observe — Architecture (supervision tree diagram, GenServer list)

## Measure
- [ ] US-TBD: Measure — Analytics (tokens, models, tools charts, 7d/30d windows)
- [ ] US-TBD: Measure — Usage (Claude cost, LVM limits, per-project utilization)
- [ ] US-TBD: Measure — Health (BootReporter telemetry, system vitals)
- [ ] US-TBD: Measure — Ports (lsof scan, conflict detection, service map)
- [ ] US-TBD: Measure — Background Tasks (long-running jobs, progress bars, cancellation)
- [ ] US-TBD: Measure — Actions (ActionEngine catalog, last-run stats, trigger UI)
- [ ] US-TBD: Measure — Scanner (project discovery, file tree, pattern matches)
- [ ] US-TBD: Measure — UAT (acceptance test runs, pass/fail grid, session replay)
- [ ] US-TBD: Measure — DRTW (reuse registry, semantic match %, duplicate candidates, register form)

## Intelligence
- [ ] US-TBD: Intelligence — Skills (registry, 3-tier health grid: system/user/project)
- [ ] US-TBD: Intelligence — Skill Drift (drift detector, fix wizard, before/after diff)
- [ ] US-TBD: Intelligence — Library (agents, skills, MCP servers, hooks catalog)
- [ ] US-TBD: Intelligence — Memory (observations, timeline, correlation graph)
- [ ] US-TBD: Intelligence — Orchestration (DAG view, run history, replay)
- [ ] US-TBD: Intelligence — Intake (request queue, watchers, intake form)
- [ ] US-TBD: Intelligence — Alignment (Plane-PM alignment agent, drift summary)

## Govern
- [ ] US-TBD: Govern — Approvals (AgentLock history, audit log, decision timeline)
- [ ] US-TBD: Govern — Authorization v9 (20s TTL countdown, policy rules table, scope test panel)
- [ ] US-TBD: Govern — Routing (model + tool routing rules, latency matrix)
- [ ] US-TBD: Govern — Coalesce (merge runs, gate decisions, branch comparison)
- [ ] US-TBD: Govern — UPM (projects, work items, drift indicators)

## Extend
- [ ] US-TBD: Extend — Plugins (10 bundled, PluginBehaviour registry, health status)
- [ ] US-TBD: Extend — Integrations (IntegrationBehaviour registry, connection status)
- [ ] US-TBD: Extend — AG-UI (generative UI events, SSE stream viewer, event types)
- [ ] US-TBD: Extend — Notifications (2K buffer, grouped by channel, filter by level)
- [ ] US-TBD: Extend — Showcase (CCEM environments, live preview)
- [ ] US-TBD: Extend — Docs (API reference, guides, OpenAPI viewer)

## Platform (System + Workflow)
- [ ] US-TBD: Platform — Architecture (supervision tree, ETS tables, PubSub topics, LiveViews)
- [ ] US-TBD: Platform — UAT (acceptance test matrix, run history)
- [ ] US-TBD: Platform — DRTW (reuse registry: components, hooks, skills, patterns, utilities, prompts)
- [ ] US-TBD: Platform — Intake (request queue + watchers)
- [ ] US-TBD: Platform — Alignment (Plane-PM sync agent)

## AI Platform + Plugins
- [ ] US-TBD: AI Platform — LVM Integration (Claude model cards: opus/sonnet/haiku, tokens/hr, cache hit rate, per-project utilization)
- [ ] US-TBD: AI Platform — Claude Code Discovery (MCP, hooks, skills registry viewer)
- [ ] US-TBD: AI Platform — Ralph Plugin (methodology view, loop status, backpressure graph)
- [ ] US-TBD: AI Platform — AG-UI Plugin (event types, SSE stream, KPIs: events/subscribers/routes)
- [ ] US-TBD: AI Platform — Authorization v9 (20s TTL override, policy rules, scope test, token_id filter)

## Design System (Infrastructure — implement first)
- [ ] US-TBD: DS — tokens.css → Phoenix CSS layer (import in app.css, verify oklch support)
- [ ] US-TBD: DS — Primitives: Button (5 variants × 4 sizes, lime primary, keyboard focus ring)
- [ ] US-TBD: DS — Primitives: Badge + Dot (7 tones, animated presence dot)
- [ ] US-TBD: DS — Primitives: Input (text/number/search, ⌘K affordance)
- [ ] US-TBD: DS — Primitives: Card + Stat tile (1px line, no drop shadow, tabular numerics)
- [ ] US-TBD: DS — Primitives: Table (dense 36px rows, monospaced numerics, keyboard j/k nav)
- [ ] US-TBD: DS — Primitives: Segmented control + Toggle + Kbd chip
- [ ] US-TBD: DS — AI: Sparkline (60-point live window, animated trailing dot)
- [ ] US-TBD: DS — AI: StreamingText + Skeleton shimmer (60fps caret, token-by-token)
- [ ] US-TBD: DS — AI: Waveform (processing indicator, tool-call running state)
- [ ] US-TBD: DS — AI: Gauge (radial 0–100%, needle, AccentGlow)
- [ ] US-TBD: DS — AI: AgentCard (identicon avatar, live sparkline, skill badges)
- [ ] US-TBD: DS — AI: CommandBar ⌘K (global, groups, AI Suggestions streaming, focus trap, Esc)
- [ ] US-TBD: DS — AI: GraphNode + Edge (dependency viz, animated live edges, PubSub 3s TTL)
- [ ] US-TBD: DS — AI: Presence stack (avatar cluster, pulse dot, count overflow)
- [ ] US-TBD: DS — Scaffolding: Sidebar nav (10 groups, collapsible, keyboard nav)
- [ ] US-TBD: DS — Scaffolding: Top bar (logo, project switcher, ⌘K, presence, account)
- [ ] US-TBD: DS — Scaffolding: Right inspector (contextual: selection / copilot / filters)
- [ ] US-TBD: DS — Motion: ease curve, 120/200/320ms durations, scanline animation, pulse keyframe

---
Total: 57 stories across 7 sections + Design System layer

Implementation order (per handoff README):
1. DS stories (tokens → primitives → AI components → scaffolding)
2. Observe — Dashboard, Fleet, Session Detail (highest traffic)
3. Govern — Authorization v9 (operational criticality)
4. Observe — Formations, Timeline, Conversations, Tool Calls, A2A
5. Measure section
6. Intelligence section
7. Extend + Platform sections
8. AI Platform + Plugins
