# CCEM APM v6.1.0 Code Quality Audit
Generated: 2026-03-17
Agent: SB-3 (fmt-ccem-refactor-20260317)

## Executive Summary

| Metric | Value |
|--------|-------|
| Total .ex files | 143 |
| Total lines of Elixir | 30,118 |
| GenServers | 47 |
| ETS tables | 41 |
| LiveViews | 27 |
| Controllers | 14 |
| JS hooks | 15 |
| Test files | 35 |
| Files without tests | 111 (77.6%) |
| @moduledoc coverage | 86.0% (123/143) |
| @spec coverage | 21.7% (257/1184 public functions) |
| Static analysis tools | None (no Dialyzer, Credo, or Sobelow) |
| Critical issues | 7 |
| Complexity hotspots | 5 |

**Overall assessment**: The codebase has grown organically through rapid feature delivery across 6 major versions. Documentation at the module level is reasonable (86%), but typespec coverage is critically low (21.7%). The flat supervision tree with 50 children under a single `one_for_one` supervisor is the most significant architectural concern. Test coverage by file is very low (22.4%), though the 35 test files that exist are well-structured.

---

## 1. Documentation Gaps

### Missing @moduledoc (20 files)

| File | Type |
|------|------|
| `lib/apm_v5_web/channels/agent_channel.ex` | Channel |
| `lib/apm_v5_web/channels/alerts_channel.ex` | Channel |
| `lib/apm_v5_web/channels/metrics_channel.ex` | Channel |
| `lib/apm_v5_web/channels/user_socket.ex` | Socket |
| `lib/apm_v5_web/controllers/page_controller.ex` | Controller |
| `lib/apm_v5_web/controllers/v2/agent_control_controller.ex` | Controller |
| `lib/apm_v5_web/controllers/v2/chat_controller.ex` | Controller |
| `lib/apm_v5_web/endpoint.ex` | Endpoint |
| `lib/apm_v5_web/live/actions_live.ex` | LiveView |
| `lib/apm_v5_web/live/analytics_live.ex` | LiveView |
| `lib/apm_v5_web/live/backfill_live.ex` | LiveView |
| `lib/apm_v5_web/live/conversation_monitor_live.ex` | LiveView |
| `lib/apm_v5_web/live/health_check_live.ex` | LiveView |
| `lib/apm_v5_web/live/intake_live.ex` | LiveView |
| `lib/apm_v5_web/live/plugin_dashboard_live.ex` | LiveView |
| `lib/apm_v5_web/live/scanner_live.ex` | LiveView |
| `lib/apm_v5_web/live/tasks_live.ex` | LiveView |
| `lib/apm_v5_web/live/workflow_live.ex` | LiveView |
| `lib/apm_v5_web/router.ex` | Router |
| `lib/apm_v5_web/telemetry.ex` | Telemetry |

### Missing @spec Coverage

- **1,184** public functions defined across the codebase
- **257** have @spec annotations (21.7% coverage)
- **927** public functions have no typespec
- No Dialyxir dependency installed for compile-time typespec checking

---

## 2. Test Coverage Gaps

### Summary
- **35** test files covering **32** lib modules (22.4% file coverage)
- **111** lib files have no corresponding test
- Approximately **408** test cases exist across all test files

### Critical untested modules (GenServers with state)

| Module | LOC | Risk |
|--------|-----|------|
| `ActionEngine` | 996 | High -- file I/O, System.cmd, curl calls |
| `PortManager` | 497 | High -- System.cmd (lsof, ps) in handle_call |
| `BackgroundTasksStore` | 185 | Medium -- task lifecycle tracking |
| `ChatStore` | 233 | Medium -- message persistence |
| `UpmStore` | 331 | Medium -- 3 ETS tables, formation data |
| `ProjectScanner` | 285 | Medium -- file system scanning |
| `SkillsRegistryStore` | 232 | Medium -- health scoring |
| `ShowcaseDataStore` | 209 | Low -- read-only display data |

### Critical untested modules (AG-UI subsystem)

| Module | LOC | Risk |
|--------|-----|------|
| `EventBus` | 248 | High -- central event routing |
| `EventRouter` | 259 | High -- event dispatch |
| `StateManager` | 235 | High -- AG-UI state |
| `ToolCallTracker` | 237 | Medium -- tool call lifecycle |
| `ApprovalGate` | 224 | Medium -- approval workflows |
| `DashboardStateSync` | 220 | Medium -- state synchronization |
| `ActivityTracker` | 191 | Low |

### Critical untested modules (Web layer)

All 27 LiveViews are untested except `RalphFlowchartLive` and `SessionTimelineLive`.
All controllers except `ApiController`, `AgUiController`, `PageController`, and `ErrorController` variants are untested.

---

## 3. Complexity Hotspots

### Largest Files (Elixir)

| File | Lines | Functions | Recommendation |
|------|-------|-----------|----------------|
| `dashboard_live.ex` | 1,914 | 55 handle clauses | **CRITICAL** -- Split into sub-LiveViews or components |
| `api_controller.ex` | 1,137 | 65 actions | **HIGH** -- Split by resource domain |
| `action_engine.ex` | 996 | 4 handle + massive private functions | **HIGH** -- Extract action executors into modules |
| `api_v2_controller.ex` | 854 | 22 actions | **MEDIUM** -- Split by resource domain |
| `uat_live.ex` | 847 | 5 handle clauses | **MEDIUM** -- Mostly template, review for extraction |
| `all_projects_live.ex` | 784 | 13 handle clauses | **MEDIUM** -- Extract tab content to components |
| `getting_started_wizard.ex` | 725 | Component | **LOW** -- Template-heavy, acceptable |
| `actions_live.ex` | 675 | 14 handle clauses | **MEDIUM** -- Extract action form to component |
| `notification_live.ex` | 598 | 12 handle clauses | **MEDIUM** |
| `port_manager.ex` | 497 | 10 handle clauses | **HIGH** -- Blocking System.cmd in handle_call |

### Largest Files (JavaScript)

| File | Lines | Recommendation |
|------|-------|----------------|
| `dependency_graph.js` | 691 | **MEDIUM** -- D3 graph, inherently complex |
| `getting_started_showcase.js` | 570 | **LOW** -- Self-contained showcase |
| `ralph_flowchart.js` | 395 | **LOW** |

### High-Coupling Modules (Most Aliased)

| Module | Alias Count | Role |
|--------|-------------|------|
| `AgUi.EventBus` | 17 | Central event hub |
| `AgentRegistry` | 13 | Core agent state |
| `EventStream` | 8 | Event broadcasting |
| `ConfigLoader` | 7 | Configuration |
| `UpmStore` | 5 | UPM state management |
| `Ralph` | 4 | Workflow orchestration |

---

## 4. GenServer Analysis

### Overview
- **47 GenServers** all under a single `one_for_one` supervisor
- **41 ETS tables** created across the system
- **0 sub-supervisors** -- flat supervision tree is a major architectural concern

### High-Priority GenServers

| Module | State Fields | Handle Clauses | LOC | Issues |
|--------|-------------|----------------|-----|--------|
| `ActionEngine` | 1 (runs map) | 4 | 996 | No state pruning -- runs map grows unbounded; massive private function tree for 10+ action types |
| `PortManager` | 4 | 10 | 497 | **Blocking System.cmd (lsof, ps) inside handle_call** -- can stall entire GenServer |
| `AgentRegistry` | 1 + 3 ETS | 10 | 467 | Reasonable, but high coupling (13 aliases) |
| `DashboardStore` | 2 + 1 ETS | 16 | 301 | Highest handle_call count; File I/O in callbacks |
| `MetricsCollector` | 0 + 2 ETS | 6 | 368 | Good -- uses ETS for state, periodic pruning |
| `UpmStore` | 0 + 3 ETS | 3 | 331 | Good structure, 3 ETS tables well-organized |
| `EventStream` | varies | 4 | 204 | Has pruning, reasonable |
| `ChatStore` | 0 + 1 ETS | 8 | 233 | Has max_messages_per_scope (500), good |
| `SloEngine` | 0 + 2 ETS | 4 | 273 | Good -- uses named ETS tables |
| `DocsStore` | varies | 6 | 266 | Legacy loading path, otherwise fine |

### AG-UI GenServers (11 total)

| Module | LOC | Handle Clauses | Issues |
|--------|-----|----------------|--------|
| `EventBus` | 248 | 7 | Highest coupling (17 aliases), central bottleneck risk |
| `EventRouter` | 259 | 3 | Coupled to EventBus |
| `ToolCallTracker` | 237 | 2 | Has pruning (@max_age_ms) |
| `StateManager` | 235 | 5 | |
| `ApprovalGate` | 224 | 5 | |
| `DashboardStateSync` | 220 | 3 | |
| `ActivityTracker` | 191 | 5 | |
| `EventBusHealth` | 161 | 4 | Monitors EventBus health |
| `V4Compat` | 149 | 2 | Legacy shim -- candidate for removal |
| `AuditBridge` | 109 | 2 | |
| `MetricsBridge` | 93 | 2 | |

### Supervision Tree Concern

All 50 children (47 GenServers + Telemetry + PubSub + Endpoint) are under a single `one_for_one` supervisor. This means:
1. **No failure isolation** -- a crash in `EventBus` does not restart its dependents (`EventRouter`, `V4Compat`, etc.)
2. **No startup ordering guarantees** beyond list position
3. **No grouped restart** for related subsystems (AG-UI cluster, Intake cluster, etc.)

**Recommended**: Introduce sub-supervisors for:
- AG-UI subsystem (11 GenServers)
- Intake subsystem (Store + 3 watchers)
- Metrics cluster (MetricsCollector + SloEngine + MetricsBridge)
- Core stores (AgentRegistry, ProjectStore, ConfigLoader)

---

## 5. LiveView Analysis

| Module | LOC | Events | Assigns | PubSub | Issues |
|--------|-----|--------|---------|--------|--------|
| `DashboardLive` | 1,914 | 37 event + 18 info | 155 | 12 | **CRITICAL** -- God-object LiveView |
| `UatLive` | 847 | 5 | 10 | 0 | Template-heavy, low interaction |
| `AllProjectsLive` | 784 | 13 | 35 | 6 | Large, multi-tab, candidate for split |
| `ActionsLive` | 675 | 14 | 52 | 1 | Many assigns, complex form state |
| `NotificationLive` | 598 | 12 | 36 | 5 | Moderate complexity |
| `SkillsLive` | 537 | 8 | 27 | 3 | Moderate |
| `DocsLive` | 534 | 5 | 27 | 0 | Content-heavy |
| `FormationLive` | 475 | 15 | 17 | 5 | Moderate |
| `RalphFlowchartLive` | 364 | 8 | 33 | 1 | Has tests |
| `ShowcaseLive` | 361 | 12 | 32 | 7 | Moderate |

**DashboardLive** is the most critical hotspot: 1,914 lines, 37 handle_event clauses, 18 handle_info clauses, 155 assign calls, and 12 PubSub subscriptions. It should be decomposed into focused sub-LiveViews or live components.

---

## 6. Dead Code / Stale Modules

### Confirmed Dead Code
| Module | LOC | Evidence |
|--------|-----|----------|
| `AgUi.A2A.Addressing` | ~50 | 0 external references, not in router |
| `AgUi.A2A.Patterns` | ~50 | 0 external references, not in router |
| `ConnectionTracker` | 117 | 0 external references, not in supervision tree but started in `application.ex`? No -- not listed in children. **Dead code.** |

### Near-Dead / Legacy Code
| Module | LOC | Evidence |
|--------|-----|----------|
| `AgUi.V4Compat` | 149 | Legacy shim for v4 PubSub topics; candidate for removal |
| `MigrationController` | ~100 | Documents deprecated topics; informational only |
| `Logger.JsonFormatter` | ~80 | Commented out in config/dev.exs, never activated |
| `UpmPersistentRule` | ~50 | Documentation-only module (no executable code called) |

### TODO/FIXME/HACK Comments
- **3 legacy references** in `dashboard_live.ex` (backward compat graph, wizard events)
- **Multiple "legacy" references** in AG-UI subsystem (HookBridge, V4Compat, EventRouter, LifecycleMapper) -- expected, these are bridge modules
- **No FIXME/HACK/XXX markers** found -- good

---

## 7. Security / Configuration Concerns

### Hardcoded Values

| Value | Occurrences | Risk |
|-------|-------------|------|
| `localhost:3032` | 15+ in lib/ | **Medium** -- should use `Application.get_env` consistently |
| `3032` (port) | 10+ hardcoded | **Medium** -- ConfigLoader has default, but ActionEngine and others bypass it |
| `http://localhost:3032` in generated curl commands | 5 in ActionEngine | **Low** -- generated for local use, but should be dynamic |

### check_origin
- `check_origin: false` in `endpoint.ex` -- acceptable for a local dev tool, but should be documented as intentional

### API Authentication
- Localhost bypass in `ApiAuth` plug -- appropriate for local-first tool
- Bearer token auth for non-localhost -- present but untested

### No Static Analysis
- No Dialyxir (compile-time type checking)
- No Credo (code style/consistency)
- No Sobelow (security-focused static analysis)
- No ExCoveralls (test coverage reporting)
- No ExDoc (documentation generation)

---

## 8. Dependency Analysis

### Current Dependencies (25 total)
```elixir
{:phoenix, "~> 1.8.3"}
{:phoenix_html, "~> 4.1"}
{:phoenix_live_reload, "~> 1.2"}       # dev only
{:phoenix_live_view, "~> 1.1.0"}
{:lazy_html, ">= 0.1.0"}              # test only
{:phoenix_live_dashboard, "~> 0.8.3"}
{:esbuild, "~> 0.10"}                 # dev only
{:tailwind, "~> 0.3"}                 # dev only
{:heroicons, github: "tailwindlabs/heroicons", tag: "v2.2.0"}
{:telemetry_metrics, "~> 1.0"}
{:telemetry_poller, "~> 1.0"}
{:gettext, "~> 1.0"}
{:jason, "~> 1.2"}
{:dns_cluster, "~> 0.2.0"}
{:bandit, "~> 1.5"}
{:earmark, "~> 1.4"}
{:ag_ui_ex, "~> 0.1.0"}
```

- **No unused dependencies** detected (`mix deps.unlock --unused` clean)
- **Missing dev/test tooling**: dialyxir, credo, sobelow, ex_doc, excoveralls

---

## 9. Blocking Operations in GenServers

| Module | Operation | Location | Severity |
|--------|-----------|----------|----------|
| `PortManager` | `System.cmd("lsof", ...)` | `handle_call(:scan_active_ports)` | **CRITICAL** -- blocks GenServer for all callers during lsof scan |
| `PortManager` | `System.cmd("lsof", ...)` per PID | `enrich_process_info/2` called per port | **CRITICAL** -- N+1 system calls in handle_call |
| `PortManager` | `System.cmd("ps", ...)` per PID | `get_full_command/1` | **HIGH** -- additional blocking call per port |
| `DashboardStore` | `File.read/File.write` | Multiple handle_call clauses | **MEDIUM** -- local file I/O, fast but not zero-cost |
| `ActionEngine` | Async via `Task.start` | `handle_call(:run_action)` | **OK** -- properly delegated to async task |

---

## 10. Memory Leak Risks

| Module | State Type | Pruning | Risk |
|--------|-----------|---------|------|
| `ActionEngine` | `%{runs: %{}}` map | **None** | **HIGH** -- runs accumulate indefinitely |
| `AgentRegistry` | 3 ETS tables | Partial (notifications pruned on read) | **Medium** -- agents/sessions not TTL'd |
| `EventStream` | Events list | Yes (max events) | Low |
| `ChatStore` | ETS table | Yes (@max_messages_per_scope 500) | Low |
| `BackfillStore` | List in state | Yes (@max_runs 50) | Low |
| `IntakeStore` | ETS ordered_set | Yes (@max_events 1000) | Low |
| `A2A.Router` | Message queues in state | Yes (@max_queue_size 100) | Low |
| `ToolCallTracker` | ETS table | Yes (prune_old_entries, @max_age_ms 1hr) | Low |

---

## Refactor Priority Matrix

| # | Area | Severity | Effort | ROI | Priority | Description |
|---|------|----------|--------|-----|----------|-------------|
| 1 | DashboardLive decomposition | Critical | High | High | **P0** | 1,914-line god-object LiveView with 55 handle clauses, 155 assigns, 12 PubSub subs. Extract into focused sub-LiveViews. |
| 2 | Supervision tree restructuring | Critical | Medium | High | **P0** | 50 children under single one_for_one supervisor. Add sub-supervisors for AG-UI, Intake, Metrics, Core clusters. |
| 3 | PortManager blocking calls | Critical | Low | High | **P1** | System.cmd (lsof/ps) in handle_call blocks GenServer. Move to handle_continue or async Task. |
| 4 | ApiController split | High | Medium | Medium | **P1** | 1,137 lines, 65 actions. Split by resource domain (agents, sessions, tasks, notifications, etc.) |
| 5 | ActionEngine unbounded state | High | Low | Medium | **P1** | Runs map never pruned. Add @max_runs or TTL. |
| 6 | Test coverage expansion | High | High | High | **P2** | 111 of 143 files untested (77.6%). Prioritize GenServers and AG-UI subsystem. |
| 7 | Typespec coverage | Medium | High | Medium | **P2** | 21.7% spec coverage. Add @spec to all public GenServer APIs and controller actions. |
| 8 | Static analysis tooling | Medium | Low | High | **P2** | Add dialyxir, credo, sobelow to mix.exs dev/test deps. |
| 9 | Dead code removal | Low | Low | Low | **P3** | Remove A2A.Addressing, A2A.Patterns, ConnectionTracker. Evaluate V4Compat, JsonFormatter. |
| 10 | Hardcoded port/host values | Low | Low | Low | **P3** | Centralize 3032/localhost references through ConfigLoader. |

---

## Appendix A: All GenServers by Category

### Core State Management (7)
AgentRegistry, ConfigLoader, DashboardStore, ProjectStore, ApiKeyStore, AuditLog, UpmStore

### Feature Stores (10)
BackgroundTasksStore, BackfillStore, ChatStore, DocsStore, SkillsRegistryStore, SkillTracker, ShowcaseDataStore, VerifyStore, WorkflowSchemaStore, PortManager

### Processing Engines (6)
ActionEngine, AlertRulesEngine, MetricsCollector, SloEngine, EventStream, CommandRunner

### Discovery/Scanning (5)
AgentDiscovery, EnvironmentScanner, HealthCheckRunner, ProjectScanner, PluginScanner

### Agents/Watchers (4)
ConversationWatcher, AgentActivityLog, AnalyticsStore, ConnectionTracker

### Skill/Hook (2)
SkillHookDeployer, WorkflowSchemaStore

### AG-UI Subsystem (11)
EventBus, EventRouter, StateManager, V4Compat, ToolCallTracker, DashboardStateSync, ActivityTracker, MetricsBridge, AuditBridge, EventBusHealth, ApprovalGate

### A2A Subsystem (1)
A2A.Router

### Intake Subsystem (1)
Intake.Store

## Appendix B: Built JS Bundle

- `priv/static/assets/js/app.js`: **27,039 lines** (bundled output) -- includes D3.js, all hooks, LiveView client
- `priv/static/showcase/showcase-engine.js`: 1,634 lines
- `priv/static/showcase/showcase.js`: 682 lines

The 27K-line app.js bundle suggests D3.js is bundled monolithically rather than tree-shaken. The esbuild config should be reviewed for code-splitting opportunities.
