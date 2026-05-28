# DRTW Report: Multi-Agent Coordination & A2A Protocol
**Domain**: Google A2A v0.3.0, AG-UI, FIPA, Horde/libcluster, file locks, AgentCard
**Research date**: 2026-05-26
**Version target**: v9.2.1 → v9.3.0 (Waves A-C), v10.0.0 (Wave D)

## CCEM Already Has Extensive A2A Infrastructure
- `ApmV5.AgUi.A2A.Envelope` + Router (ETS, EventBus delivery, TTL expiry)
- `ApmV5.AgUi.A2A.Patterns` (request/reply, broadcast, fan_out)
- `ag_ui_ex v0.1.0` first-party package — ALL 33 AG-UI events implemented
- `ApmV5.AgentIdentity` already OTel `gen_ai.agent.*` aligned
- AG-UI EP-01 EventBus, EP-02 Lifecycle, EP-03 Tool Tracking, EP-05 Streaming, EP-07 ApprovalGate all complete

## Critical A2A v0.3.0 Gaps (Just Hit RC1, Jan 2026)
1. **No `/.well-known/agent-card.json`** — no industry-standard discovery endpoint
2. **No task lifecycle state machine** — `submitted → working → input-required → completed/failed/cancelled`
3. **No `skills[]` declaration** per agent in AgentIdentity
4. **`{:topic, t}` broken** — currently resolves to ALL agents, not topic subscribers (silent bug)

## What CCEM Has That A2A Doesn't (KEEP)
- Formation hierarchy (orchestrator/squadron/swarm/cluster)
- Trust degradation model (AUTHORITATIVE/DERIVED/UNTRUSTED)
- UPM linkage, AgentLock authorization gates
- ETS-based queue with TTL, fan-out, correlation_id request/reply

## Packages to IMPORT (Wave D only — deferred to v10.0)
```elixir
{:horde, "~> 0.10"},        # distributed DynamicSupervisor + Registry across nodes
{:libcluster, "~> 3.5"},    # automatic BEAM node discovery
{:delta_crdt, "~> 0.6"},    # transitive via Horde, also useful directly
```

**Do NOT import**:
- `ra` (RabbitMQ Raft) — overkill at current scale
- Python frameworks (CrewAI, LangGraph, AutoGen) — wrong runtime
- FIPA JADE — 2002 Java platform, use vocabulary only

## Implementation Roadmap

### Wave A: Discovery + Capability (v9.2.1 patch, independent, parallel)
- **A-1** `AgentCard` schema + `/.well-known/agent-card.json` endpoint — M
- **A-2** Fix `{:topic, t}` — `TopicRegistry` GenServer with `subscribe/unsubscribe` — S

### Wave B: Task Lifecycle (v9.3.0, depends on Wave A)
- **B-1** `ApmV5.A2A.TaskStore` GenServer — task state machine — M
- **B-2** Bridge AG-UI `RUN_STARTED/FINISHED/ERROR` → A2A task transitions — M

### Wave C: FIPA + Conflict Resolution (v9.3.0, independent of B)
- **C-1** Formalize FIPA performatives vocabulary (cfp, propose, accept, inform, failure) — S
- **C-2** `FileLockRegistry` GenServer (pessimistic lock, 30s TTL, PubSub) — M
- **C-3** `ArtifactVersionStore` (optimistic CAS for skill edits during coalesce) — S

### Wave D: OTel Alignment + Distributed Clustering (v10.0.0, BREAKING)
- **D-1** Add `gen_ai.system` + per-task token counters — S
- **D-2** Horde + libcluster — replaces ETS AgentRegistry with cross-node `Horde.Registry` — L (BREAKING supervision tree)

## Key A2A Conformance Stories
After Wave A+B, CCEM APM becomes A2A v0.3.0 compatible:
- Serves AgentCard at `/.well-known/agent-card.json` ✓
- Tracks task lifecycle states ✓
- Maps AG-UI events to A2A task transitions ✓
- Maintains formation hierarchy as CCEM-specific extension (not in A2A spec)

## Critical Bug Found
`{:topic, t}` addressing in `Addressing.resolve/1` currently returns all agents instead of topic subscribers. Story A-2 must ship as a hotfix (v9.2.1) — this is a silent broadcast amplification bug.
