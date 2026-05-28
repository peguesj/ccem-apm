# DRTW Report: Workflow & Orchestration Standards
**Domain**: BPMN, Temporal, Reactor, Saga, State Machines, OTP
**Research date**: 2026-05-26
**Version target**: v9.2.0 → v9.3.0 (minor, 8 stories)

## Summary: CCEM Already Has Right Instincts
3 of 6 orchestration subsystems are well-reasoned custom code that should stay custom:
- `AgentLifecycle` `@valid_transitions` pattern — gold standard, promote to all state-bearing modules
- `JobQueue` exponential backoff retry — better than most packages offer
- PubSub event bus (138 broadcast sites) — correct for Phoenix; no event broker library needed

## Only New Production Dependency: `reactor`
```elixir
{:reactor, "~> 1.0.2"},  # 16.9K DL/wk, MIT, GA Jan 2026, Ash-backed
```
- Provides saga compensation via `compensate/4` callback
- Ash project uses it in production at scale — not experimental
- Resolves cleanly: `jason 1.4.4` + `telemetry ~> 1.2` already in lock file

## OTP Stdlib Wins (Zero New Deps)
- `:digraph_utils.is_acyclic/1` — replaces CCEM's 34-line custom DFS cycle detection
- `:digraph_utils.topsort/1` — topological sort for parallel step scheduling
- `:gen_statem` `state_timeout` events — per-step timeout policies (no package needed)

## Packages to SKIP
- `oban`: requires PostgreSQL/SQLite3 — adds DB coupling CCEM avoids
- `commanded`: full CQRS/ES framework — too heavy for APM observability
- `gen_state_machine`: thin OTP wrapper, last updated 2020; use `:gen_statem` directly
- `bpe`/`rodar`: BPMN engines — 386/2 DL/wk, not production-grade; BPMN export only
- `machinery`/`fsmx`: maintenance-mode or Ecto-coupled
- Temporal.io: requires external Go/Java cluster; overkill for single-node APM

## `exqlite` Already in mix.exs — Use for WAL
`exqlite` is already an optional dep. Make it required in `:prod`. Build `FormationPersistenceStore` as append-only event log for durable execution on restart.

## Gaps → Stories

### Critical Gaps
- **G3** Saga/compensation — no rollback when squadron N fails mid-formation; orphaned worktrees/Plane tickets/git branches — IMPORT `reactor`
- **G4** Durable execution — 97 ETS tables lost on APM restart; in-flight formations vanish — BUILD WAL via `exqlite`

### Medium Gaps
- **G1** State type safety — formation status strings with no transition guards → `FormationStateMachine` module
- **G5** Step timeouts — runaway agents block formations indefinitely → `:gen_statem` `state_timeout`
- **G6** Human-in-the-loop step — no `:approval` step type in `OrchestrationManager`

### Low Gaps
- **G2** Cycle detection — custom DFS has O(n²) worst case → `:digraph_utils`
- **G7** OTel workflow spans — add `gen_ai.operation.type: "workflow"` + PROV-DM attrs
- **G8** BPMN export — `GET /api/v2/workflows/:id/bpmn` XML endpoint for dashboard interop

## Implementation Stories (8 total, ordered by priority)
1. **story-orch-1**: Replace custom DFS with `:digraph_utils.is_acyclic/1` — 2h
2. **story-orch-2**: `FormationStateMachine` typed atom FSM — 1 day
3. **story-orch-3**: `FormationPersistenceStore` exqlite WAL — 2 days
4. **story-orch-4**: `reactor` saga compensation (`FormationReactor`) — 3 days
5. **story-orch-5**: `:approval` step type in `OrchestrationManager` — 2 days
6. **story-orch-6**: Per-step timeout policies via `:gen_statem` — 1 day
7. **story-orch-7**: OTel + PROV-DM attribute alignment — 4h
8. **story-orch-8**: BPMN 2.0 XML export endpoint — 1 day (optional)

## Standards Vocabulary to Adopt
Amazon States Language (ASL) step types as CCEM's canonical vocabulary:
- `Task` → `:action`, `Choice` → `:decision`, `Wait` → `:approval`, `Parallel` → wave concurrency
- `Map` → formation over a list (currently missing), `Pass` → `:gate`, `Succeed`/`Fail` → `:terminal`
