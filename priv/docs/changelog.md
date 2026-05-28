# Changelog

All notable changes to CCEM APM are documented in this file. Latest: v9.1.3 — Wave 7-9 TDD Validation + Compile Fixes.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [9.1.4] - 2026-05-12

Three new plugins (Builder, Composio, Open Design), HookHealthMonitor, ActionRunStore, govern LiveView polish, story-refs API, sidebar SSOT correction.

### Added
- **Builder Plugin** — interactive 5-step wizard (`/plugins/builder`) for scaffolding new CCEM plugins from existing repos. BuilderEngine GenServer with ETS session storage and PubSub broadcasts; RepositoryAnalyzer for GitHub/local path/.git ingestion
- **Composio Plugin** — MCP server registry, tool store, account store, webhook handler. ComposioClient HTTP integration with paginated tool fetching
- **Open Design Plugin** — design-handoff client + monitor + JSX→LiveComponent ingestion path (`/plugins/open-design`)
- **HookHealthMonitor** — cross-project hook filesystem health scanning. Async ETS state, `/api/v2/hook_health/*` endpoints, root-owned path detection
- **ActionRunStore** — persistent action execution run history with replay support
- **Story-refs API** — UpmStore + UpmController endpoints for cross-referencing stories with commits/PRs (extends 01605f4 work)
- **v2 controllers** — `/api/v2/{action,builder,composio,hook_health,open_design}` controllers with corresponding test suites

### Changed
- **Govern LiveViews polish** — approvals, alignment, coalesce, dashboard, intake, skills layout refinements
- **action_engine.ex** — execution context tracking + run store integration
- **plugin_registry.ex** — auto-register Builder, Composio, Open Design, HookHealth plugins at boot
- **design_system.ex** — minor refinements

### Fixed
- **Sidebar SSOT** — replaced `@app_version "9.1.3"` compile-time attribute (re-introduced in e1614d7) with inline `to_string(Application.spec(:apm_v5, :vsn))`. This removes the staleness footgun: `Application.spec/2` is stdlib (always loaded, sidesteps the original `UndefinedFunctionError` concern) while still reading from the `.app` manifest sourced from mix.exs

---

## [9.1.3] - 2026-05-11

Wave 7-9 TDD test suites, ConversationMonitorLive compile fixes, stream_configure fix for map-based items.

### Added
- **PolicyRulesStore test suite** (CP-191) — 8 tests covering wildcard rule fallback, exact match precedence, removal idempotency (tagged `:govern_intelligence`)
- **Auth controller test suite** (CP-191) — 21 tests covering all 8 apm-auth skill-spec endpoints: session/start, session/heartbeat, session/end, token/redeem, policies GET+POST, approvals/pending, approvals/:id/decide, plus authorize decision field (tagged `:govern_intelligence`)
- **Platform TDD suite** (CP-198) — 34 tests for Extend, Platform, and AI Platform module verification with compile gate (tagged `:platform`)

### Fixed
- **ConversationMonitorLive** — Added missing private functions: `page_window/2` (pagination), `apply_filter/2` (query filtering), `refresh_conversations/2` (PubSub state refresh)
- **stream_configure** — Fixed dom_id configuration for map-based conversation items to prevent ArgumentError at mount/3 (CCEM-567)

---

## [9.1.2] - 2026-05-05

Hook Filesystem Repair, Claude Code Harness Plugin, audit_hook_performance action, and structural LiveView recovery.

### Added
- **Claude Code Harness Plugin** — `HarnessPlugin` (`:ccem` scope), `HarnessMonitor` GenServer (15s session.json poll, PubSub `"harness:state"`), `HookTelemetryBuffer` ETS ring buffer (500 cap, subscribes `"apm:hooks"`). LiveView at `/plugins/harness` with 3-tab layout (health/hooks/session), API at `/api/v2/harness/*` with 5 endpoints (health, hooks, session, plans, settings) with 503 on dead GenServer (CP-199–CP-202)
- **repair_hooks action** — `ActionEngine` `repair_hooks` catalog entry (category: hooks, icon: wrench) that runs `repair_hooks.sh`, detects root-owned `.remember` dirs via `find -not -user`, emits APM notification with `sudo_command` field. `/repair-hooks` Claude Code skill with check|fix|fix-sudo|status subcommands (CP-203–CP-205)
- **audit_hook_performance action** — Scans `~/.claude/settings.json` for performance culprits: cold-start `npx` invocations, blocking `curl` calls in hooks, `claude-flow` session-end hooks

### Fixed
- **SessionManagerLive** — Added missing `sidebar_collapsed`/`inspector_open` assigns; stripped null byte corruption in `:live_view` atom
- **harness_live.ex** — Replaced unsupported `style=` attribute on `<.icon>` with `<span>` wrapper; fixes `--warnings-as-errors` compile failure
- **Structural LiveView recovery** — 25+ broken pages migrated to `<.page_layout>` shell (Pattern A: 21 files), GenServer `mount` calls guarded with `try/rescue/catch :exit` (Pattern B: 5 files), intake/scanner data tables wired with `phx-click` row interactivity (Pattern C: 2 files)

### Changed
- Plugin registry: HarnessPlugin added to `@default_plugins`
- Application supervision: HarnessMonitor + HookTelemetryBuffer added to supervision tree
- Router: `/plugins/harness` LiveView route + `/api/v2/harness/*` API routes registered
- Hook registry: harness hooks added

---

## [9.0.0] - 2026-04-06

Major ecosystem refactoring: Diligent architecture type, 4 new integrations, Synergize cross-copilot action, Railway-inspired graph visualizations, RoutingGraph fix, Showcase dual-tab, and comprehensive UX improvements.

### Added
- **Diligent Architecture** — new first-class architecture type (Fleet -> Formation -> Squadron -> Swarm -> Agent) with ArchitectureBehaviour, ArchitectureStore GenServer, ArchitectureLive at `/architecture`, and Railway-inspired glassmorphic D3 graph (ArchitectureGraph hook)
- **RoutingGraph JS hook** — D3 force-directed authorization routing visualization (was completely missing, causing blank `/routing` page)
- **Showcase dual-tab** — Engine (APM-integrated) + Standalone (iframe/external) mode toggle
- **4 new integrations** — ClaudeMem (project memory files), ClaudeFlow (methodology workflows), ClaudeExpertise (expertise sources), UAT (test runner bridge)
- **Synergize action** — generates cross-copilot configuration for 9 IDEs (GitHub Copilot, Cursor, Continue, Cline, Codex, Roo Code, JetBrains, Replit, Antigravity) with symlink/copy/reference modes
- **ProcessMemoryMonitor GenServer** — sweeps all registered processes every 30s, ETS ring buffer, PubSub diagnostics
- **ErrorDaemon** — Erlang :logger handler for error capture with 5s dedup and PubSub broadcast
- **NotificationSettings GenServer** — per-category notification preferences with JSON persistence
- **SettingsStore + SettingsLive** — centralized 6-tab settings page at `/settings` (General/Notifications/Auth/Integrations/Plugins/Display)
- **V2 Tasks API** — `POST /api/v2/tasks/register` for hook-based background task population
- **Library markdown rendering** — Earmark integration for description rendering with AI-generated placeholders
- **Nav hierarchy** — Library expandable subsection with 7 children, dynamic plugin child nav items via SidebarHelpers
- **Dockerfile + docker-compose.yml** — containerization support for APM server

### Fixed
- **app.js merge conflict** — resolved unresolved `<<<<<<< HEAD` markers that would break JS build
- **Skills hook name mismatch** — `SkillsHook` properly mapped as `Skills:` key in hook registry
- **Port reconciliation** — Dashboard and `/ports` now use same PortManager data source with PubSub refresh
- **Auth routing** — RoutingGraph D3 hook created and registered (was phantom reference)

### Changed
- `mix.exs`: version bumped 8.11.1 -> 9.0.0
- `@server_version` / `@app_version`: "8.11.1" -> "9.0.0"
- Dashboard right column: replaced Commands/Todos tabs with Formation/Sessions tabs
- Dashboard inspector tab: added AG-UI context section and formation breadcrumb
- Integration registry: 4 new default integrations (7 total)
- Memory management: ETS caps + periodic pruning in AgentRegistry (5000), SessionManager (500), AuthorizationGate (5000), ClaudeUsageStore (10000)

---

## [8.11.0] - 2026-03-30

Authorization UX Redesign, Plugin System Expansion, Session Filters, Library Dashboard, Skills Fix Wizard, /529 Rate Limit Skill.

### Added
- **Authorization panel redesign** — full-screen modal replaced with inline notification panel; graduated actions (approve once, allow 5/15/30/60min, always allow, deny, always deny); rich context display with action type, command preview, and approval reasoning
- **Plugin system expansion** — 3 scopes (APM/CCEM/Claude Code); `ClaudeCodePluginBridge` reads Claude Code plugin ecosystem; `PluginRepositoryStore` GenServer manages plugin repositories; 2 new LiveView tabs (Repositories, Claude Code Plugins)
- **Plugin repository REST API** — 7 new endpoints: `GET /api/v2/plugins/cc/plugins`, `GET /api/v2/plugins/cc/summary`, `GET /api/v2/plugins/repositories` (list), `POST /api/v2/plugins/repositories` (create), `GET /api/v2/plugins/repositories/:id`, `PATCH /api/v2/plugins/repositories/:id`, `DELETE /api/v2/plugins/repositories/:id`
- **Library dashboard** — 7-tab resource catalog (agents/skills/MCP servers/tools/commands/patterns/learnings); `LibraryStore` GenServer with ETS backing; `LibraryLive` at `/library`; REST endpoints at `GET /api/v2/library/*`
- **Session manager filters** — search bar, group by (project/init context/worktree), active-only toggle, per-session hide/show in `SessionManagerLive`
- **Skills Fix Wizard improvements** — templates/examples repair options, CCEM scope badge, removed disabled checkboxes
- **/529 rate limit skill** — exponential backoff, model downgrade cascade (opus->sonnet->haiku), automatic retry, hook integration
- **CCEMHelper notification improvements** — osascript notification fallback when UNUserNotificationCenter unavailable; notification permission guide; `/api/status` now includes `projects` array

### Removed
- **`crate_digger_status` action** removed from ActionEngine

### Changed
- `mix.exs`: version bumped 8.10.1 -> 8.11.0
- Authorization approval flow uses inline graduated actions instead of full-screen modal overlay

---

## [8.10.1] - 2026-03-30

### Added
- **ClaudeCodePlugin**: PluginBehaviour plugin discovering MCP servers, hooks, skills, sessions from ~/.claude/settings.json
- **ClaudePlatformLvmPlugin**: PluginBehaviour plugin with static model capabilities for claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5, claude-sonnet-4-5-20250514
- **LvmIntegration**: IntegrationBehaviour integration with symbiosis link to usage_tracking native feature
- **ClaudeCodeDiscoveryLive**: /plugins/claude-code LiveView with 4 tabs (MCP Servers, Hooks, Skills, Sessions)
- **LvmStatusLive**: /integrations/lvm LiveView with 3 tabs (Models, Usage, Dynamic Capabilities)
- **GET /api/usage/limits**: Model capability and utilization endpoint with optional project filter
- **API Key CRUD**: GET/POST/DELETE /api/v2/auth/api-keys endpoints delegating to ApiKeyStore
- **ClaudeUsageStore LVM table**: `@lvm_table` ETS for model capability persistence, record_model_capabilities/2, get_all_model_capabilities/0
- **ActionEngine lvm_integration_setup**: Seeds model capabilities and verifies integration registry
- **Skills AgentLock cross-reference**: Skill drawer shows authorization status and recent auth decisions
- **CCEMHelper Usage tabs**: Summary/By Model/Sessions tabbed view in MenuBarView
- **CCEMHelper Usage settings**: Default tab, refresh interval, token format preferences in SettingsView

### Verified (existing implementations)
- CCEM-265: Bearer token middleware (ApiAuth plug active)
- CCEM-266: Health-check cascade (GET /health, GET /api/status)
- CCEM-267: Skills UX pagination, dry-run preview, shift-select
- CCEM-269: GET /api/notifications/:id route

## [8.10.0] - 2026-03-30

Agent Alignment Registry, Dashboard Widgets, AutoApproval Policies, Command Context Enrichment, LVM Integration Foundation.

### Added
- **`ApmV5.Auth.AutoApprovalStore`** GenServer — hierarchical scope matching for automatic tool approval. ETS-backed with TTL expiration every 30s. AND logic: all specified scopes (agent_id, formation_id, session_id, project) must match. Precedence: agent > formation > session > project. Supports `allowed_tools`, `allowed_risk_levels`, `allow_action_types` filtering. 313 LOC, 27 tests.
- **`ApmV5Web.V2.AutoApprovalController`** — 6 REST endpoints at `/api/v2/auth/auto-approval-policies`: list, create, show, update, delete, test-match (dry-run policy matching).
- **`ApmV5.Auth.CommandContextExtractor`** — tool-agnostic command intent analysis. Classifies bash, SQL, file, network operations as `:destructive`, `:write`, `:read`, or `:unknown`. 40+ regex patterns for common commands. Returns `action_type`, `action_detail`, `risk_rationale`, `approval_reasoning`. 388 LOC, 28 tests.
- **`PendingDecisions` command context enrichment** — all escalated approval requests now include `action_type`, `action_detail`, `risk_rationale`, `approval_reasoning` fields from `CommandContextExtractor.analyze/2`. Human-readable notification body with command-specific context.
- **`AuthorizationGate` auto-approval pipeline** — checks `AutoApprovalStore.find_matching/6` before escalating to human approval. Auto-approved requests issue tokens and increment policy counters. Broadcasts `:auth_auto_approved` events.
- **`ApmV5.WidgetRegistry`** GenServer — ETS-backed registry for 8 core dashboard widgets: agent_fleet, formation_monitor, notification_hub, upm_status, metrics_overview, skill_health, port_status, recent_activity. Plugin-extensible via `register_widget/1`. Widget schema includes category, source_module, refresh_interval, grid dimensions, config_schema.
- **`ApmV5.LayoutStore`** GenServer — 6 built-in layout presets (Default, Compact, Detailed, Analyst, Operator, Developer) + 12 scenario presets loaded from `priv/dashboard/presets.json`. Per-session user layouts in ETS. 12-column CSS grid coordinate system with responsive breakpoints.
- **`ApmV5.AgentIdentity`** module — agent manifest and alignment utilities. 67-agent registry with referential integrity validation across GenServers, supervisors, plugins, and integrations.
- **`ApmV5Web.AlignmentLive`** at `/alignment` — agent alignment dashboard with D3.js dependency graph visualization.

### Changed
- `mix.exs`: version bumped 8.9.0 -> 8.10.0
- `@server_version` in `ApiController`: 8.9.0 -> 8.10.0
- `@app_version` in `SidebarNav`: 8.9.0 -> 8.10.0
- `AuthorizationGate.authorize/5`: auto-approval check inserted before PendingDecisions escalation
- `PendingDecisions.add/5`: CommandContextExtractor enrichment on every escalation

---

## [8.9.0] - 2026-03-30

Platform Refactor — Modular Sidebar, Agent Identity, Formation Grouping, Plane-PM Align, Notification Buffer.

### Added
- **Modular sidebar 5-section taxonomy**: CORE, AUTHORIZATION, PLUGINS (dynamic), INTEGRATIONS (dynamic), SYSTEM sections. Dynamic plugin nav items from `PluginBehaviour.nav_items/0`. Integration entries from `IntegrationRegistry`. `safe_list_plugins/0` + `safe_list_integrations/0` with try/catch guards.
- **`ApmV5.PlanePmAlign`** persistent GenServer — polls Plane API every 5 minutes, broadcasts `"plane:sync"` PubSub, registered with APM on startup with `agent_type: "persistent_service"`. REST: `GET /api/v2/plane/sync-status`, `POST /api/v2/plane/sync`.
- **Agent identity taxonomy** — `agent_name` (human label), `agent_type` (normalized enum: orchestrator|squadron_lead|swarm_agent|cluster_agent|individual|persistent_service|quality_agent|unknown), `agent_definition` (instance or purpose) fields added to `AgentRegistry`. `normalize_agent_type/1` validates and normalizes raw type strings.
- **Formation graph TB layout** — top-to-bottom with session columns as 4th layout mode (`?layout=tb` URL param). Namespace-scoped bounding rectangles behind node clusters. Auto-collapse for namespaces with >50 nodes. `?scope=` URL param for namespace filtering.
- **Notification buffer cap** increased from 200 → 2,000 events. Grouped view UI by category with collapse/expand per group. `derive_category/1` from notification type field.
- **Native conversation monitoring** — `SessionManager` multi-path scan covers both APM sessions (`~/Developer/ccem/apm/sessions/*.json`) and Claude Code JSONL (`~/.claude/projects/*/*.jsonl`). `ConversationMonitorLive` reuses `SessionManager.list_sessions/0` as single source of truth. `source: :claude_native` badge for native conversations.
- **Plugin/Integration architecture** — `PluginBehaviour` optional callbacks: `nav_items/0`, `settings_path/0`, `plugin_live_module/0`. `IntegrationBehaviour` optional callbacks: `target_native_feature/0`, `required_plugin/0`. `AgentlockIntegration.target_native_feature/0` returns `:authorization`.
- **AG-UI improvements** — `EventBus` replay buffer 500 → 20,000 events. A2A Router history cap 200 → 2,000 entries.
- **Usage LiveView** expandable per-project input/output/cache token breakdown bar charts.
- **Skills LiveView** — Fix Wizard steps independently selectable (click any step to jump). Step 2 (Preview) loads async via background Task.
- **Timeline LiveView** swim-lane redesign — category lanes (lifecycle/auth/formation/task/tool/system), time window selector (15m/30m/1h/6h/24h), drill-down panel on event selection.
- **`BackgroundTasksStore`** `add/1` alias for `register_task/1`. Auto-registers agents via `AgentRegistry.register_agent/3` side-effect.
- **`NamespaceResolver`** uses `agent_name` field for human-readable labels when available.

### Changed
- `mix.exs`: version bumped 8.7.0 → 8.9.0
- `@server_version` in `ApiController`: 8.7.0 → 8.9.0
- `@app_version` in `SidebarNav`: 8.7.0 → 8.9.0
- `ApmV5.PlanePmAlign` added to supervision tree; registers itself with APM on startup

---

## [8.7.0] - 2026-03-29

SimpleAgents CCEM APM Plugin — integrates the SimpleAgents Rust LLM framework into the plugin dashboard.

### Added
- **`ApmV5.Plugins.SimpleAgents.SimpleAgentsPlugin`** — new plugin with 7 actions: `workspace_info` (reads Cargo.toml, workspace version, crate inventory), `list_traces` (discovers workflow trace JSON files), `get_trace` (parse + normalize single trace), `trace_summary` (aggregate stats: total/completed/failed, success_rate_pct, avg/max/min duration_ms), `provider_stats` (groups by inferred provider), `list_workflows` (YAML workflow files in examples/ and workers/), `parity_status` (parity-fixtures binding contract JSON files).
- Registered as 10th default plugin in `ApmV5.Plugins.PluginRegistry.@default_plugins`.

### Changed
- `mix.exs`: version bumped 8.6.0 → 8.7.0
- `@server_version` / `@app_version`: 8.6.0 → 8.7.0

---

## [8.6.0] - 2026-03-29

AgentLock Notification Reliability + In-Browser Approval Modal.

### Added
- **CCEMHelper direct notification delivery** — dedicated `AGENTLOCK_APPROVAL` `UNNotificationCategory` with Approve/Deny action buttons. Notification title: "AgentLock: [displayName]", body: "[tool] requires approval · [risk] risk". `pending_id` key in `userInfo`; `didReceive` resolves `pending_id` first, falls back to `request_id`.
- **CCEMHelper test notification** button in `SettingsView` — fires direct `UNUserNotificationContent` without APM round-trip; shows permission alert if not granted.
- **APM in-browser approval modal** — full-screen overlay (z-[9999], backdrop-blur) with agent name, tool, risk, 20s `CountdownTimer`, Approve/Deny buttons in `AuthorizationLive`.
- **DashboardLive floating banner strip** — compact approval banner above UPM panel; subscribes `agentlock:pending` PubSub; inline Approve/Deny + deep-link.
- **`GET /api/v2/auth/decide`** — browser-clickable URL: `?request_id=&decision=approve|deny` redirects to `/authorization`.
- **`NamespaceResolver.cached/1`** and `put_cache/1` rescue `ArgumentError` — no crash when GenServer restarts.

### Fixed
- `NotificationLive` AgentLock category: phx-click Approve/Reject buttons replace broken `<a href>` GET links. `approve_action`/`reject_action` handlers call `PendingDecisions.decide/2` with `request_id` from notification metadata.

### Changed
- `mix.exs`: version bumped 8.5.0 → 8.6.0
- `@server_version` / `@app_version`: 8.5.0 → 8.6.0

---

## [8.5.0] - 2026-03-28

AgentLock gate notifications + 20s timeout + namespace UX — CCEMHelper delivers macOS banners within 1-2s of gate creation.

### Added
- **`ApmV5.NamespaceResolver`** GenServer — ETS cache converting raw agent_id/session_id/request_id to human-readable scoped labels (`project/role/task-slug`, `project/branch`, `tool:HHMM`). Added to supervision tree after SessionManager.
- **AuthorizationLive countdown banners** — Live countdown (20s) per pending gate above the tab bar; inline Approve/Deny buttons; `CountdownTimer` JS hook; real-time PubSub updates.
- **`display_name` field** on `PendingDecision` and `Agent` OpenAPI schemas — human-readable scoped label; null if context unavailable.

### Changed
- **20s gate TTL**: `PendingDecisions` TTL 120s → 20s; sweep interval 15s → 3s. `DecisionGate` default timeout 120s → 20s; expire check 15s → 3s. `agentlock_pre_tool.sh` hook reduced to single 15s poll attempt.
- **Immediate APM notify**: `PendingDecisions.add/5` fires `POST /api/notify` via fire-and-forget Task — CCEMHelper delivers macOS banner within 1-2s (not after 8s poll delay).
- **Human-readable display names**: `AgentPanel`, `SessionManagerLive`, `DashboardLive`, `AuthorizationLive` audit log show NamespaceResolver labels as primary identifier; raw IDs in `title` tooltips.
- **CCEMHelper**: Pending poll interval 8s → 3s; `PendingDecision.displayName` field; notification body format `tool · agent-label — risk`.
- `mix.exs`: version bumped 8.4.0 → 8.5.0

---

## [8.1.0] - 2026-03-27

Session Management LiveView + CCEMHelper Help/About/Settings — CCEM↔APM session connector.

### Added
- **`ApmV5.SessionManager`** GenServer — polls `~/Developer/ccem/apm/sessions/*.json` every 30s, enriches sessions with agents, ports, plugins, and claude config directory counts. Broadcasts `"apm:sessions"` PubSub on changes.
- **`/sessions` LiveView** (`SessionManagerLive`) — split-panel view: session list (left) with active/inactive badges + pulse animation; 5-tab detail panel (right): Overview, Claude Config, Agents, Ports, Plugins. 10s auto-refresh.
- **Sessions nav item** in sidebar (APM Monitoring section) using `hero-computer-desktop` icon.
- **`/sessions/:id` route** for direct deep-link to specific session.
- **CCEMHelper Settings panel** (`SettingsView`) — APM URL with live connection test, notification toggles, Launch at Login, Open Dashboard on Connect. `@AppStorage` with `io.pegues.ccem.*` key prefix.
- **CCEMHelper About panel** (`AboutView`) — version/build from bundle, GitHub link, Open APM Dashboard.
- **CCEMHelper Help panel** (`HelpView`) — Quick Start, Keyboard Shortcuts, Troubleshooting sections.
- **MenuBarView footer section** — Settings..., About CCEMHelper, Help buttons with `.sheet` presentation.

### Changed
- Supervision tree: `ApmV5.SessionManager` added after `ClaudeUsageStore`.
- Router: `/sessions` and `/sessions/:id` live routes added to `live_session :default`.
- Sidebar: Sessions nav item added in APM Monitoring section.

---

## [7.0.0] - 2026-03-21

AgentLock authorization protocol integration -- 3-layer security model (Agent -> Gate -> Execution), 10 new auth modules, 19 new REST endpoints, 2 new LiveViews, CCEMHelper rename.

### Added
- **AgentLock Authorization Protocol** -- 3-layer authorization model: Agent (identity + capabilities), Gate (policy evaluation + rate limiting), Execution (context tracking + memory isolation)
- 10 new modules under `lib/apm_v5/auth/`:
  - `Types` -- shared type definitions for authorization domain (tokens, policies, contexts)
  - `PolicyEngine` -- rule-based policy evaluation engine with allow/deny/conditional outcomes
  - `TokenStore` -- ETS-backed token issuance, validation, and revocation with TTL expiry
  - `SessionStore` -- authorization session lifecycle management with ETS persistence
  - `RateLimiter` -- per-agent and per-scope rate limiting with sliding window counters
  - `ContextTracker` -- execution context tracking with scope inheritance and audit trail
  - `MemoryGate` -- memory access control enforcing read/write/execute permissions per scope
  - `RedactionEngine` -- content redaction pipeline with configurable rules and audit logging
  - `AuthorizationGate` -- central gate combining policy, rate limit, and context checks into a single authorize/2 call
  - `AgentLifecycle` -- agent identity registration, capability grants, and lifecycle state machine
- 19 new REST endpoints under `/api/v2/auth/*` -- token CRUD, policy management, session control, rate limit queries, context inspection, redaction preview
- `AuthorizationLive` LiveView at `/authorization` -- real-time authorization dashboard with token status, policy browser, rate limit gauges, and session inspector
- `RoutingLive` LiveView at `/routing` -- endpoint routing visualization with auth requirement indicators and middleware chain display
- 5 new `ActionEngine` actions in the `authorization` category: `rotate_tokens`, `audit_permissions`, `enforce_policy_set`, `reset_rate_limits`, `redact_scope`
- 6 new ETS tables: `auth_tokens`, `auth_sessions`, `auth_policies`, `auth_rate_limits`, `auth_contexts`, `auth_redactions`
- 4 new PubSub topics: `apm:auth:tokens`, `apm:auth:policies`, `apm:auth:sessions`, `apm:auth:rate_limits`
- AG-UI EventBus `CUSTOM` event emission for all authorization events (token issued/revoked, policy evaluated, rate limit hit, context created)

### Changed
- **CCEMAgent renamed to CCEMHelper** -- the macOS menubar companion app is now called CCEMHelper to avoid confusion with AI agents managed by APM; all source paths, bundle identifiers, documentation references, and build commands updated accordingly
- `mix.exs`: version bumped 6.4.0 -> 7.0.0
- `application.ex`: 10 new auth GenServers added to supervision tree

### Fixed
- **Duplicate Getting Started modal** -- the GettingStartedWizard modal no longer re-appears on every LiveView navigation; dismissed state is persisted in localStorage

---

## [6.4.0] - 2026-03-18

Skills UX overhaul — WCAG 2.1 AA compliance, guided Fix Wizard, card grid layout, slide-in detail drawer, Session invocation timeline, AG-UI health indicators, and SkillsHook JS.

### Added
- `SkillsLive` full rewrite — WCAG AA: skip links, ARIA landmarks (`main`, `complementary`, `banner`, tablist/tab/tabpanel roles), `aria-live="polite"` for search result announcements
- Card grid layout with health-ring SVG indicator (green ≥80 / yellow 50–79 / red <50), tier badge (Healthy / Needs Attention / Critical), trigger pills
- Slide-in detail drawer (`#skill-drawer`) with keyboard focus trap — Escape navigates back through wizard steps or closes
- Fix Wizard 4-step flow: `:diagnose → :select → :preview → :done` with `MapSet`-backed repair type selection; invokes `ActionEngine` for `fix_skill_frontmatter`, `complete_skill_description`, `add_skill_triggers`
- Session tab: vertical invocation timeline sorted by `last_seen` descending, absolute-positioned colored dots, methodology badge, relative timestamp
- AG-UI tab: summary stats row (Connected/Degraded/Broken counts), per-skill health dot + border + text color helpers, Repair button for critical skills
- `assets/js/hooks/skills.js` — `SkillsHook` LiveView hook: `/` shortcut focuses search input, focus trap management for drawer, previous-focus restoration on drawer close
- Search + filter bar: debounced text search (300ms), tier dropdown filter, real-time `phx-change`

### Changed
- `app.js`: `SkillsHook` registered in `Hooks` map
- `mix.exs`: version bumped 6.3.0 → 6.4.0

---

## [6.3.0] - 2026-03-18

Claude usage management — track model/token usage at user and project scope, surfaced in LiveView, CCEM skills, hooks, and CCEMHelper menubar.

### Added
- `ClaudeUsageStore` GenServer — ETS-backed token/model usage tracking per `{project, model}` key; broadcasts on `"apm:usage"` PubSub after each `record_usage/4` call; effort level inference (low/medium/high/intensive) from tool_calls:session ratio
- `UsageController` — REST controller at `/api/usage/*`: `GET /api/usage`, `GET /api/usage/summary`, `GET /api/usage/project/:name`, `POST /api/usage/record`, `DELETE /api/usage/project/:name`
- `UsageLive` LiveView at `/usage` — 10s auto-refresh, PubSub subscription, summary bar with token progress bars, per-model breakdown table, per-project accordion with effort badges and Reset buttons
- `claude_usage_record.sh` — PostToolUse hook: fire-and-forget to `POST /api/usage/record` on every Claude Code tool invocation
- `claude_usage_check.sh` — PreToolUse hook: warns to stderr when project effort_level is `intensive` (>100 tool_calls/session)
- Usage section added to sidebar nav (under APM Monitoring, `hero-cpu-chip` icon)
- `UsageModels.swift`, `fetchUsageSummary()` in `APMClient`, `usageSummary` in `EnvironmentMonitor`, `usageSection` in `MenuBarView` — CCEMHelper menubar shows tokens, top model, effort badge
- Usage Management section added to `ccem-apm` SKILL.md with API quick reference and effort level table
- `usage_constraints.md` memory file with model selection guidance, effort thresholds, and hook references

### Changed
- `application.ex` — `ClaudeUsageStore` added to supervision tree before `ApmV5Web.Endpoint`
- `~/.claude/settings.json` — PostToolUse and PreToolUse hooks registered for usage recording and threshold checking

---

## [6.2.0] - 2026-03-18

Architecture consolidation — domain controller extraction, reusable LiveView components, LiveView integration test suite.

### Added
- `UpmApiController` — domain controller extracted from `ApiController` for UPM execution tracking endpoints
- `FormationApiController` — domain controller for formation CRUD (list, get, create, update, agents)
- `ShowcaseApiController` — domain controller for showcase data REST API (index, show, reload)
- `AgentPanel` component — extracted from `DashboardLive`; renders agent cards with tier/status/type badges and filter support
- `PortPanel` component — extracted from `DashboardLive`; renders port cards with clash alerts and remediation display
- LiveView integration test suite — 14 ExUnit tests: 8 `DashboardLive` tests + 6 `ShowcaseLive` tests

### Changed
- `ApiController` responsibility reduced — UPM, formation, and showcase routes delegated to dedicated domain controllers
- `DashboardLive` simplified — `AgentPanel` and `PortPanel` extracted as independent components

---

## [6.1.0] - 2026-03-17

Observability — agent activity log, showcase activity tab, feature inspector, template system, project dropdown UX.

### Added
- `AgentActivityLog` GenServer — ring buffer (200 events), lifecycle/tool/thinking/text EventBus topics, PubSub on `apm:activity_log`, REST at `GET /api/agents/activity-log`
- Showcase Activity Tab — D3.js force-directed agent graph, anime.js pulse rings for active agents, 30-event pull-down log
- Showcase Feature Inspector — right-column panel with acceptance criteria checklist, related agents by `story_id`, status mini-timeline
- Showcase Template System — `TEMPLATES` registry (engine/formation layouts), `applyTemplate(id)` via `showcase:template-changed` event
- Project Dropdown UX — `Active`, `Recently Active`, and `Other` sections in project selector, `categorize_projects/2` helper function

---

## [5.2.0] - 2026-03-12

E2E stabilization — unified sidebar, notification overhaul, AG-UI visualizer, version cleanup, docs refresh.

### Added
- Shared `sidebar_nav` component replacing 20 inline sidebar duplicates
- AG-UI LiveView at `/ag-ui` — real-time event feed with 14 type filters, pause/resume, router stats, agent state viewer
- Notification formatting with type icons, category badges, deduplication with count badges
- Notification showcase noise filter (default on) with batch dismiss
- Skills AG-UI pill tab with hook repair button
- Dependency graph formation/squadron/swarm hierarchy grouping
- AG-UI Protocol documentation page

### Changed
- All 20 LiveViews use shared sidebar component
- All version strings dynamic (no hardcoded v4 references)
- Heartbeat auto-registers unknown agents (upsert, no more 404)
- Health check port corrected (3031 to 3032)
- Uptime uses monotonic time set at application startup
- `/upm` route redirects to `/workflow/upm`

### Fixed
- Sidebar nav drift across 20 pages
- Notification noise (19/22 showcase entries)
- Getting Started modal re-showing on navigation
- Uptime showing ~74 years
- Dashboard agent count mismatch between views

---

## [5.1.0] - 2026-03-11

Interactive management suite — contextual AG-UI chat, agent controls, getting started wizard, CCEMHelper v3.0.0.

### Added
- InspectorChatLive, AgentControlPanel, ScopeBreadcrumb components
- SSE LiveView hook for streaming chat
- ChatStore GenServer with ETS persistence
- Agent control REST endpoints
- GettingStartedWizard modal slideshow
- Showcase SVG diagrams with IntersectionObserver animation
- TooltipOverlay guided tour system

---

## [5.0.0] - 2026-03-11

AG-UI protocol integration — backward-compatible event bridge for agentic monitoring.

### Added
- AG-UI EventRouter, HookBridge, StateManager, EventStream GenServers
- AG-UI v2 REST controller with SSE streams
- Built-in documentation wiki with 15+ pages
- 60+ REST API endpoints with expanded OpenAPI spec

---

## [4.3.0] - 2026-03-02

Cross-platform installer, Docker socket repair, session hardening.

---

## [4.2.0] - 2026-03-02

Dynamic APM — skills registry, enhanced background tasks, project scanner Claude-native scan.

---

## [4.0.0] - 2026-02-19

Complete rewrite from Python to Phoenix/Elixir with multi-project support.

### Added

- **Phoenix/Elixir Backend**: OTP supervision tree with 14 specialized GenServers, PubSub-based event broadcasting, ETS-backed in-memory caching
- **Multi-Project Support**: Single server instance serves multiple projects with namespace isolation, project selector in dashboard, session tracking per-project, cross-project analytics
- **Dashboard UI**: D3.js force-directed dependency graph, real-time LiveView updates without page refresh, daisyUI/Tailwind component styling, responsive design, right panel tabs (Inspector, Ralph, UPM, Commands, TODOs), filter bar with status/type/project/text search
- **Agent Fleet Management**: Tier-based classification (1/2/3), flexible typing (individual, squadron, swarm, orchestrator), advanced statuses (active, idle, error, discovered, completed), automatic discovery via environment scanner, heartbeat monitoring with token/progress tracking, dependency and coordination tracking
- **Ralph Methodology Integration**: PRD JSON format for structured requirements, story-based workflows, autonomous fix loops, D3 swimlane flowchart at `/ralph`, escalation rules, real-time progress tracking
- **UPM (Unified Project Management)**: Wave-based organization, story tracking with estimates, event logging, dynamic agent allocation, Ralph integration, status reporting
- **Skills Tracking System**: Skill catalog, co-occurrence matrix heatmap, methodology detection (TDD, refactor-max, fix-loop), UEBA analytics, trending analysis, anomaly detection
- **Session Timeline Visualization**: Chronological event log, interactive timeline navigation, filtering by event type/agent/date, JSON export, immutable audit trail
- **SwiftUI Menubar Agent (CCEMHelper)**: Native macOS AppKit system tray app, real-time agent count and health display, quick actions, token tracking progress bar, health monitoring, login item auto-launch, URLSession polling
- **UPM Execution Tracking API**: `POST /api/upm/register`, `POST /api/upm/agent`, `POST /api/upm/event`, `GET /api/upm/status`
- **Port Management API**: `GET /api/ports`, `POST /api/ports/scan`, `POST /api/ports/assign`, `GET /api/ports/clashes`, `POST /api/ports/set-primary`
- **REST API**: Backward-compatible v1 API, new v2 API with OpenAPI spec, 50+ endpoints, server-sent events at `/api/ag-ui/events`, data import/export, rate limiting with Retry-After headers
- **Documentation Wiki System**: Interactive docs at `/docs`, full-text search, breadcrumb navigation, styled markdown rendering, syntax-highlighted code blocks, responsive viewer
- **GenServer Stores**: ConfigLoader, DashboardStore, AgentRegistry, ProjectStore, UpmStore, SkillTracker, MetricsCollector, AlertRulesEngine, AuditLog, EventStream, AgentDiscovery, EnvironmentScanner, CommandRunner, DocsStore, SloEngine
- **PubSub Topics**: `apm:agents`, `apm:notifications`, `apm:config`, `apm:tasks`, `apm:commands`, `apm:upm`, `apm:skills`, `apm:audit`
- **LiveView Pages**: DashboardLive (`/`), AllProjectsLive (`/apm-all`), SkillsLive (`/skills`), RalphFlowchartLive (`/ralph`), SessionTimelineLive (`/timeline`), DocsLive (`/docs`), FormationLive (`/formation`), PortsLive (`/ports`)
- **Health and Monitoring**: `/health` endpoint, `/api/status` detailed status, menubar connection status, agent/session/skill metrics, token usage per agent, task completion rates, error rate tracking
- **Notifications**: Info/warning/error/success levels, auto-dismiss and persistent alerts, bell icon with unread count, action buttons
- **Security**: API key authentication support, CORS configuration, rate limiting with adaptive backoff, audit logging, session isolation by project

### Changed

- **Backend**: Python/Flask replaced with Elixir/Phoenix
- **Database**: SQLite replaced with ETS for core storage
- **Configuration**: Format updated to v4 schema (still JSON-based, now with `projects` array)
- **Heartbeat Protocol**: Simplified from v3
- **API**: Endpoints remain compatible but extended with v2 namespace

### Fixed

- **Startup Time**: Reduced from ~15s (v3) to ~5s
- **Memory Usage**: Reduced from ~800MB (v3) to ~500MB baseline
- **Agent Registration Latency**: Reduced from ~500ms (v3) to <100ms
- **Dashboard Update Latency**: Reduced from ~200ms (v3) to <50ms
- **Concurrent Agent Capacity**: Increased from ~300 (v3) to 1000+ tested

### Removed

- Python codebase (replaced entirely by Elixir)
- SQLite database dependency
- Flask web framework
- Manual workflow orchestration (replaced by Ralph automation)

---

## [4.0.0-rc1] - 2026-02-10

Release candidate for v4.0.0.

### Added

- Final API stabilization
- Production deployment documentation

### Fixed

- Edge cases in multi-project session registration
- WebSocket reconnection reliability

---

## [4.0.0-beta.1] - 2026-01-15

Beta release for testing.

### Added

- Core Phoenix/Elixir architecture
- Initial multi-project support
- Basic dashboard UI

---

## [3.x] - Python Era

### Added

- Flask web server
- SQLite persistence
- Basic agent registration
- Manual workflow orchestration
- Limited analytics

> v3 maintained in legacy branch for historical reference.

---

## [2.x] - Early Days

### Added

- Simple REST API
- Session tracking
- Agent heartbeats
- Basic notifications

> No longer supported.

---

## [1.x] - Pre-Release

Internal research prototype. No longer supported.

---

## Migration Guide (v3 to v4)

1. **Install Elixir** 1.14+ and Erlang/OTP 25+
2. **Clone new v4 repo**: `git clone <url> apm-v5`
3. **Update config**: Map v3 projects to `apm_config.json` v4 schema
4. **Export v3 data**: `curl http://old-server/api/v2/export > backup.json`
5. **Import to v4**: `curl -X POST http://localhost:3032/api/v2/import -d @backup.json`
6. **Test agent registration**: Verify agents connect to new server
7. **Update agent configs**: Point to new server/port if needed
8. **Switch production**: Update hooks and menubar app URL

> **Important:** Always back up `apm_config.json` before upgrading. See [Deployment](admin/deployment.md) for detailed steps.

---

## Future Roadmap

### v5.3 (Q2 2026)

- Database backend (PostgreSQL) option
- Erlang clustering support
- Advanced SLO engine
- Slack/Discord notifications
- GraphQL API

### v6.0 (Q3 2026)

- Full distributed architecture
- Advanced federation for multi-org
- AI-powered recommendations
- Custom dashboard builder
- Embedded agent marketplace

---

## Version Numbering

CCEM APM follows semantic versioning:

- **MAJOR**: Breaking API changes or major rewrites
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes and improvements

## How to Report Issues

- GitHub Issues: https://github.com/your-org/ccem-apm/issues
- Documentation: See [Troubleshooting](admin/troubleshooting.md)

## Credits

CCEM APM built with Elixir/Phoenix, LiveView, D3.js, daisyUI, and Swift. Designed for the Claude Code platform and AI agent workflows.

---

*Last Updated: 2026-03-30*
