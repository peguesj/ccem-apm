# Changelog

## v8.6.0 (2026-03-29)

### AgentLock Notification Reliability + In-Browser Approval Modal

- **CCEMHelper direct notification delivery** (US-001): `postPendingDecisionNotification` now uses dedicated `AGENTLOCK_APPROVAL` UNNotificationCategory with Approve/Deny actions. Notification title uses human-readable `displayName` as "AgentLock: [displayName]"; body is "[tool] requires approval · [risk] risk". `pending_id` key added to `userInfo` (alongside legacy `request_id`) so action handler can submit the decision. `APMNotificationReceiver.didReceive` resolves `pending_id` first, then falls back to `request_id`. `CCEMHelperApp.init()` registers `AGENTLOCK_APPROVAL` category alongside existing `agentlock` category.
- **CCEMHelper Test Notification button** (US-002): `SettingsView` gains a "Test Notification" button that fires a direct `UNUserNotificationContent` without any APM round-trip. If notification permission is not granted, shows an alert directing user to System Settings > Notifications > CCEMHelper.
- **APM in-browser AgentLock approval modal** (US-003): `AuthorizationLive` shows a full-screen overlay modal (`z-[9999]`, backdrop-blur) when any pending decision exists — displays agent display name (NamespaceResolver), tool, risk level, params preview, 20s countdown timer, and Approve/Deny buttons. `DashboardLive` shows a compact floating banner strip above the UPM panel for each pending gate with inline Approve/Deny + link to `/authorization`. Dashboard subscribes to `agentlock:pending` PubSub topic and handles `{:pending_decision_added, entry}` / `{:pending_decision_resolved, entry}` messages with toast notifications.

### Changed
- `mix.exs`: version bumped 8.5.0 → 8.6.0
- `@server_version` in `ApiController`: 8.4.0 → 8.6.0
- `@app_version` in `SidebarNav`: 8.4.0 → 8.6.0

## v8.5.0 (2026-03-28)

### AgentLock Gate Notifications + 20s Timeout + Namespace UX

- **NamespaceResolver** (`ApmV5.NamespaceResolver`): GenServer + ETS cache converting raw agent_id/session_id/request_id to human-readable scoped labels.
- **20s gate TTL**: `PendingDecisions` TTL reduced from 120s → 20s; sweep interval 15s → 3s.
- **AuthorizationLive countdown banners**: Live countdown (20s) per pending gate displayed above the tab bar; inline Approve/Deny buttons; `CountdownTimer` JS hook.
- **CCEMHelper**: Pending poll interval 8s → 3s; `PendingDecision.displayName` field.

### Changed
- `mix.exs`: version bumped 8.4.0 → 8.5.0

## v8.3.0 (2026-03-27)

CCEM APM v8.3.0 — AgentLock macOS notifications: end-to-end fix.

### Fixed
- `PendingDecisions.list_pending/0`: excludes expired entries (TTL=120s) — eliminates stale backlog that blocked new notification delivery
- `AuthAuditEntry` (CCEMHelper): stable `id` field decoded from JSON, falls back to UUID — eliminates silent dedup drops for repeated denial events
- `APMClient` port key mismatch: aligned to `io.pegues.ccem.apmPort` — Settings port field now works correctly
- `EnvironmentMonitor`: removed duplicate `setNotificationCategories` from `requestNotificationPermission()` — eliminates race with `CCEMHelperApp.init()` category registration
- `postAgentLockNotification`: embeds `request_id` in `content.userInfo` — Approve/Deny buttons on audit-path escalation banners now call `submitDecision` correctly
- `APMNotificationReceiver`: approve/deny actions + banner tap both deep-link to `/authorization` dashboard

### Added
- `CCEMHelperApp.init()`: `UserDefaults.standard.register(defaults:)` — all 4 notification toggles default to `true` on fresh install (no setup required)
- `APMClient`: host key support (`io.pegues.ccem.apmHost`) — base URL built from host + port
- `POST /api/v2/notifications/test`: inject test pending decision for CCEMHelper notification testing (CCEM-281)
- `EnvironmentMonitor`: UserDefaults gating wired — `notifyAgentLock`, `notifyAgentLifecycle`, `notifyFormation`, `notifySystem` toggles in Settings now actually gate notifications

### Changed
- `mix.exs`: version bumped 8.2.0 → 8.3.0

## v8.2.0 (2026-03-27)

CCEM APM v8.2.0 — AgentLock Gap9 fix, CoWork awareness, CCEMHelper Settings window.

### Added
- `ApmV5.Auth.PendingDecisions`: Gap 9 fix — `decide(:approve)` now calls `TokenStore.generate/4` and stores `token_id` on approved entry; broadcasts include `token_id`; HTTP poll response returns `token_id` so hooks can receive their authorization token without re-authorization
- `ApmV5.SessionManager`: CoWork awareness — `cowork_context/0` reads `~/.claude/teams/` and `~/.claude/tasks/`; enriched sessions include `:cowork` map with `teams` list and `tasks` count (`total`/`active`)
- `agentlock_pre_tool.sh`: approval polling loop — when `reason: approval_required`, hook polls `GET /api/v2/auth/pending/:id?wait=30` up to 2× (60s total); on approval stores token and exits 0; on deny or timeout exits 2
- `CCEMHelper`: `@Environment(\.openSettings)` gear icon in menu header — always visible regardless of menu height; replaces broken `NSApp.sendAction(Selector("showSettingsWindow:"))` approach

### Changed
- `ApmV5Web.V2.AuthController`: `pending_to_json/1` includes `token_id`; `decide/2` action returns `token_id` on approve; `get_pending/2` threads full entry through poll result
- `ApmV5.Auth.PendingDecisions`: `poll/2` + `do_poll/2` return `{:decided, entry}` (full map) instead of `{:decided, decision atom}` — carries `token_id` through to HTTP layer
- `CCEMHelper/Views/MenuBarView.swift`: `@Environment(\.openSettings)` declared; both header gear and "Notification Settings…" menu item use `openSettings()` call
- `mix.exs`: version bumped 8.1.0 → 8.2.0

## v8.1.0 (2026-03-27)

CCEM APM v8.1.0 — Session Manager + CCEMHelper Settings/About/Help.

### Added
- `ApmV5.SessionManager` GenServer: polls `~/Developer/ccem/apm/sessions/*.json` every 30s, ETS `:session_manager_cache`, broadcasts `"apm:sessions"` PubSub on hash change
- `SessionManagerLive` at `/sessions` + `/sessions/:id`: left panel session list, right panel 5 tabs (Overview/Claude Config/Agents/Ports/Plugins), 10s auto-refresh
- `CCEMHelper/Views/SettingsView.swift`: APM URL config, notification toggles (AgentLock/Formation/System), connection test
- `CCEMHelper/Views/AboutView.swift`: version/build from bundle, GitHub link
- `CCEMHelper/Views/HelpView.swift`: Quick Start, Keyboard Shortcuts, Troubleshooting

### Changed
- `mix.exs`: version bumped 8.0.0 → 8.1.0

## v8.0.0 (2026-03-27)

CCEM APM v8.0.0 — Plugin/Integration Engine Standard.

### Added
- `ApmV5.Plugins.PluginBehaviour` v2: extended with `supervisor_children/0`, `inspector_component/0`, `default_enabled?/0`, `on_enable/0`, `on_disable/0`, `live_views/0` optional callbacks
- `ApmV5.Integrations.IntegrationBehaviour`: new behaviour contract for external protocol bridges — `integration_name/0`, `protocol/0`, `connect/1`, `disconnect/0`, `status/0`, `handle_event/3`, `supervisor_children/0`
- `ApmV5.Plugins.PluginSupervisor`: DynamicSupervisor for plugin-owned child processes
- `ApmV5.Integrations.IntegrationSupervisor`: DynamicSupervisor for integration-owned child processes
- `ApmV5.Integrations.IntegrationRegistry`: GenServer + ETS `:integration_registry` — `register/1`, `list_integrations/0`, `get_integration/1`, `call_integration_event/3`, `reload_defaults/0`
- 8 new plugins extracted: `ralph`, `formations`, `uat`, `skills`, `ports`, `usage`, `devops`, `alerting`
- 2 new integrations: `agentlock` (auth pipeline — PolicyEngine/TokenStore/RateLimiter/AuthorizationGate), `ag_ui` (AG-UI protocol — EventBus publish/subscribe/replay)
- `ApmV5Web.V2.IntegrationController`: 5 REST endpoints at `/api/v2/integrations/*` — index, show, invoke_action, status, reload
- `PluginDashboardLive`: Integrations tab with protocol/status/version badges; subscribes to `"apm:integrations"` PubSub
- `application.ex`: `PluginSupervisor` before `PluginRegistry`, `IntegrationSupervisor` + `IntegrationRegistry` added to supervision tree

### Changed
- `mix.exs`: version bumped 7.3.0 → 8.0.0
- `PluginRegistry @default_plugins`: expanded from 1 (Plane) to 9 (all bundled plugins)
- `IntegrationRegistry @default_integrations`: populated with AgentLock + AG-UI integrations


## v7.3.0 (2026-03-24)

CCEM APM v7.3.0 — Modularized Plugin Engine + Plane PM first-class integration.

### Added
- `ApmV5.Plugins.PluginBehaviour`: `@behaviour` contract for all APM plugins — `plugin_name/0`, `plugin_description/0`, `plugin_version/0`, `list_endpoints/0`, `handle_action/3`, optional `inspector_section/1`
- `ApmV5.Plugins.PluginRegistry`: GenServer + ETS `:plugin_registry` — `register_plugin/1`, `list_plugins/0`, `get_plugin/1`, `call_plugin_action/3`; auto-registers bundled default plugins on init
- `ApmV5.Plugins.Plane.PlanePlugin`: Plane PM plugin — `list_issues`, `get_issue`, `list_projects`, `board_state`, `search_issues` actions; backed by existing `ApmV5.PlaneClient`; CCEM project pre-configured; state normalization (Backlog/Todo/In Progress/Done/Cancelled)
- `ApmV5Web.V2.PluginController`: REST API under `/api/v2/plugins/*` — index, show, action (POST), board (GET shortcut), issues (GET shortcut)
- `GET /api/v2/plugins` — list all registered plugins with metadata + endpoint descriptors
- `GET /api/v2/plugins/:name` — get single plugin
- `POST /api/v2/plugins/:name/action` — invoke named action with params
- `GET /api/v2/plugins/:name/board` — Kanban board state shortcut
- `GET /api/v2/plugins/:name/issues` — list/search issues shortcut (auto-selects `search_issues` when `?query=` present)
- `PluginDashboardLive /plugins`: tabbed UI — MCP Servers, Discovered Plugins, Registered Plugins (engine), Plane PM board with Kanban columns + issue inspector pull-out drawer; PubSub `"apm:plugins"` for live registration events
- `application.ex`: `ApmV5.Plugins.PluginRegistry` added to supervision tree before AuthSupervisor

### Changed
- `mix.exs`: version bumped 7.2.0 → 7.3.0


## v7.2.0 (2026-03-24)

CCEM APM v7.2.0 — AgentLock skills inspection, UPM workflow deep-link, showcase scope tabs, notification GET endpoint.

### Added
- `SkillsRegistryStore.compute_auth_gate/2`: detects high-risk tools (Write/Edit/Bash/MultiEdit/NotebookEdit/Task) referenced in SKILL.md and checks for agentlock_pre_tool.sh presence; exposes `auth_gated` + `auth_missing_tools` per skill
- `SkillsLive`: AgentLock authorization section in inspector drawer — green "Auth Gated" badge or yellow "Auth Missing" badge with tool chips + "Gate with AgentLock" CTA button
- `GET /api/notifications/:id`: new endpoint returning single notification with full refs/trace/metadata/actions payload; backed by `AgentRegistry.get_notification/1`
- `WorkflowLive /workflow/upm`: pill-tab bar with "Default" (standard UPM diagram) and "Current" (live UPM phase, active wave/story, stack-specific TSC gate, formation status) tabs
- `ApiController.notify/2`: auto-enriches UPM notifications (`type` starts with "upm:" or `category == "upm"`) with "View Workflow" action pointing to `/workflow/upm`
- Showcase scope pull-tabs (All/CCEM/APM/Latest) with `localStorage` persistence; filters feature cards by project scope

### Changed
- `mix.exs`: version bumped 7.1.1 → 7.2.0


## v7.1.1 (2026-03-24)

CCEM APM v7.1.1 — Notification schema expansion, CCEMAgent daemon, showcase stability hardening.

### Added
- `AgentRegistry.add_notification/1`: new fields `refs`, `trace`, `metadata`, `actions` — full referential integrity
- `NotificationLive`: expanded detail panel with refs grid, trace tree, metadata, action buttons
- CCEMHelper launchd daemon: `io.pegues.agent-j.labs.ccem.helper.plist` auto-restarts on boot

### Fixed
- `ShowcaseHook`: DOM guard + try/catch prevents "view crashed" on first WebSocket
- `ShowcaseHook._loadIframe()`: CSS injection suppresses duplicate standalone headers

### Changed
- `mix.exs`: version bumped 7.1.0 → 7.1.1


## v7.1.0 (2026-03-24)

CCEM APM v7.1.0 — Showcase UX fixes: project dropdown now fully syncs the content area on project switch, roadmap modal handles empty-feature projects gracefully, and the standalone showcase is renamed to "ccem" with pull-tab section navigation.

### Fixed
- `ShowcaseLive`: removed `was_initialized` guard from `load_project/2` — `showcase:project-changed` is now always pushed, ensuring the engine syncs on direct URL navigation to `/showcase/:project` and on all subsequent project switches
- `ShowcaseEngine.updateProject/1`: now calls `_renderCenterColumn()` and `_renderRightColumn()` in addition to the orchestration bar and feature cards, so switching projects updates the architecture panel, inspector, and all center content
- `ShowcaseEngine._renderRoadmapModal/0`: divide-by-zero guard when `features.length === 0` (was producing `NaN%` in the progress bar); adds empty-state message instead of a visually blank modal body
- `ShowcaseEngine.updateProject/1`: resets `selectedFeature` and `selectedFeatureId` on project switch to clear stale inspector state

### Changed
- `mix.exs`: version bumped 7.0.0 → 7.1.0

## v6.4.0 (2026-03-18)

CCEM APM v6.4.0 — Skills UX overhaul: WCAG 2.1 AA compliance, guided Fix Wizard, card grid layout, slide-in detail drawer, Session invocation timeline, AG-UI health indicators, and SkillsHook JS.

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

## v6.3.0 (2026-03-18)

CCEM APM v6.3.0 — Claude usage management: token/model tracking at user and project scope, UsageLive dashboard, PostToolUse/PreToolUse hooks, CCEMAgent menubar integration.

### Added
- `ClaudeUsageStore` GenServer (ETS, PubSub, effort level inference)
- `UsageController` REST API at `/api/usage/*` (5 endpoints)
- `UsageLive` LiveView at `/usage` (summary bar, model table, project accordion, 10s refresh)
- PostToolUse hook `claude_usage_record.sh` — fire-and-forget to `/api/usage/record`
- PreToolUse hook `claude_usage_check.sh` — intensive usage warning
- CCEMAgent: `UsageModels.swift`, `fetchUsageSummary()`, `usageSection` in MenuBarView

### Changed
- `application.ex`: `ClaudeUsageStore` in supervision tree
- `router.ex`: `/usage` live route + `/api/usage/*` REST routes
- `sidebar_nav.ex`: Usage nav item (hero-cpu-chip, APM Monitoring section)
- `mix.exs`: version bumped 6.2.0 → 6.3.0
- `~/.claude/settings.json`: new PostToolUse and PreToolUse usage hooks

## v6.2.0 (2026-03-17)

CCEM APM v6.2 — refactor-max: ApiController domain split, DashboardLive decomposition, LiveView integration tests, and OpenAPI v6.1.0.

### Added
- **UpmApiController** (`controllers/upm_api_controller.ex`) — Domain controller for UPM execution tracking: `upm_register`, `upm_agent`, `upm_event`, `upm_status` extracted from ApiController
- **FormationApiController** (`controllers/formation_api_controller.ex`) — Domain controller for formation CRUD: list, get, create, update, agents via `UpmStore` + `AgentRegistry`
- **ShowcaseApiController** (`controllers/showcase_api_controller.ex`) — Domain controller for showcase data REST API: index, show, reload via `ShowcaseDataStore`
- **AgentPanel component** (`components/agent_panel.ex`) — Functional component extracted from DashboardLive Agent Fleet section; includes tier/status/agent_type badges and filter support
- **PortPanel component** (`components/port_panel.ex`) — Functional component extracted from DashboardLive Ports tab; includes clash alerts, remediation display, project port configs, and badge helpers
- **DashboardLive integration tests** (`test/apm_v5_web/live/dashboard_live_test.exs`) — 8 tests verifying AgentPanel and PortPanel component integration within DashboardLive
- **ShowcaseLive integration tests** (`test/apm_v5_web/live/showcase_live_test.exs`) — 6 tests including nil-session regression: ShowcaseLive must not crash when UpmStore has no active sessions

### Changed
- **Router** — `/api/upm/*` routes now delegated to `UpmApiController`; `/api/formations/*` and `/api/showcase/*` routes added for domain controllers
- **ApiController** — UPM functions (`upm_register/agent/event/status`) removed; responsibility moved to `UpmApiController`
- **DashboardLive** — Agent Fleet section replaced by `AgentPanel.agent_fleet/1` component call; Ports tab replaced by `PortPanel.port_manager/1` component call; unused badge helpers (`tier_badge_class`, `stack_badge`, `ns_badge`, `server_type_badge`) removed; line count reduced from 1,923 to 1,765 (158 lines)
- **OpenAPI spec** — Version bumped to 6.1.0; added `/api/formations`, `/api/formations/{id}`, `/api/formations/{id}/agents`, `/api/showcase`, `/api/showcase/{project}`, `/api/showcase/{project}/reload` endpoint definitions; added Formations tag

### Version
- Bumped to v6.2.0

## v6.1.0 (2026-03-17)

CCEM APM v6.1 — Agentic activity visualization, showcase inspector, project dropdown UX, and infrastructure telemetry.

### Added
- **AgentActivityLog** (`lib/apm_v5/agent_activity_log.ex`) — GenServer ring buffer (200 events) that subscribes to `lifecycle:*`, `tool:*`, `thinking:*`, `text:*` EventBus topics; PubSub broadcast on `"apm:activity_log"`; REST at `GET /api/agents/activity-log?limit=N&agent_id=X`
- **ShowcaseEngine — Activity tab** — D3.js force-directed graph showing live agent status-colored nodes with anime.js pulse rings for active agents; collapsible action log pull-down (30 most recent events with type badges); data fed via `showcase:activity` push_event on every heartbeat + per-entry
- **ShowcaseEngine — Feature Inspector** — Right-column contextual panel activated by clicking any feature card; shows description, acceptance criteria checklist, related agents filtered by story_id, timing rows, status mini-timeline, "View Formation" and "Copy ID" action buttons; `setPushEventFn` bridge for LiveView event propagation
- **ShowcaseEngine — Template system** — `TEMPLATES` registry with `engine` (default 3-col) and `formation` layouts; `applyTemplate(id)` dispatch; switchable via `showcase:template-changed` AG-UI event
- **ShowcaseEngine — In-place project update** — `updateProject(data)` surgically re-renders orchestration bar and feature cards only, eliminating full destroy+rebuild flash on project switch

### Changed
- **Project dropdown** (`dashboard_live.ex`) — Sectioned into Active (check-circle), Recently Active (clock, 30-day window), and "Show N other" collapsible toggle; `categorize_projects/2` helper recomputes on config reload
- **Getting Started wizard** — Added `phx-update="ignore"` to wrapper div; eliminates 1s flash caused by morphdom resetting client-side `style="display:flex"` to `"display:none"` after `handle_params/3` completes
- **ShowcaseLive** — Subscribes to `"apm:activity_log"` PubSub; pushes `showcase:activity` on entry + heartbeat; `updateProject` path avoids full reinit on project switch
- **Version** — Bumped to v6.1.0

## v6.0.0 (2026-03-16)

CCEM APM v6 — CCEM UI, port management, agentic hierarchy graph, and showcase integration complete.

### Added
- **PortsLive** (`live/ports_live.ex`) — `/ports` dashboard with utilization heatmap, conflict detection, project accordion, and add-port form using `PortManager` GenServer
- **CCEM sidebar sections** — Dual-section sidebar nav: CCEM MANAGEMENT (Showcase, Projects, Ports, Actions, Scanner) and APM MONITORING (Dashboard, Agents, Formations, AG-UI, Conversations, Skills, Tasks, Health, Notifications); collapsible section headers with icon-only mode support
- **Agentic hierarchy graph** (`assets/js/hooks/dependency_graph.js`) — D3 v7 top-down tree rendering live formation data: Session → Formation → Squadron → Swarm → Agent → Task; level-based colors (purple/blue/cyan/green/orange/yellow); status dots; hover tooltips; auto-fit zoom; fetches `/api/v2/formations` + `/api/agents` on mount; live-updates via `hierarchy_data` and `agents_updated` push_events
- **ActionEngine port actions** — 4 catalog entries: `register_all_ports`, `update_port_namespace`, `analyze_port_assignment`, `smart_reassign_ports`
- **ShowcaseLive** — `/showcase` LiveView with full APM chrome, project dropdown, PubSub real-time data (merged from v5.5.0 milestone)
- **ShowcaseDataStore** — Per-project data GenServer with 3-tier path resolution and ETS cache
- **ShowcaseHook** + **ShowcaseEngine** — JS hook bridging LiveView push_event to containerized rendering engine

### Changed
- **Dependency graph** — Replaced static Phoenix module DAG with live agentic hierarchy tree (Session → Formation → Squadron → Swarm → Agent → Task); D3 loaded lazily from CDN
- **WebSocket config** — `check_origin: false, timeout: 60_000` on `/live` socket for reliable LiveView connections
- **Showcase CSS** — Injected/removed by `ShowcaseHook._loadStyles()` only (no global root layout link)
- **Version** — Bumped to v6.0.0

## v5.5.0 (2026-03-16)

Integrates the standalone Showcase dashboard into the APM server as a project-scoped LiveView at `/showcase`, replacing the separate `python3 -m http.server 8080` workflow with real-time PubSub-driven data delivery.

### Added
- **ShowcaseLive** (`live/showcase_live.ex`) — LiveView at `/showcase` with APM chrome (sidebar nav, header, project dropdown), PubSub subscriptions for agent/UPM/config/AG-UI events, 5s heartbeat data push
- **ShowcaseDataStore** (`showcase_data_store.ex`) — GenServer loading per-project showcase data from disk (features, narratives, design system, redaction rules); ETS-cached, per-project keyed with reload support
- **ShowcaseHook** (`assets/js/hooks/showcase.js`) — JS hook bridging LiveView push_event to ShowcaseEngine; handles `showcase:data`, `showcase:agents`, `showcase:orch`, `showcase:project-changed`
- **ShowcaseEngine** (`priv/static/showcase/showcase-engine.js`) — Containerized refactor of showcase.js as `window.ShowcaseEngine` class; all DOM queries scoped to container, no polling, data via hook methods
- **Showcase CSS** (`priv/static/showcase/showcase-styles.css`) — Scoped under `.showcase-scope` to prevent leaking into APM daisyUI theme
- **Sidebar nav** — "Showcase" item with `hero-presentation-chart-bar` icon added before Docs
- **Route** — `live "/showcase", ShowcaseLive, :index` in browser scope

### Changed
- **Version** — Bumped to v5.5.0
- **Supervision tree** — Added `ShowcaseDataStore` to `application.ex` children
- **Root layout** — Added showcase-styles.css stylesheet link
- **app.js** — Registered `ShowcaseHook` in LiveView hooks

### Architecture
- Hybrid LiveView shell + JS hook (Option D): LiveView provides APM chrome and PubSub subscriptions, JS hook bridges events to the existing 682-line rendering engine
- Project switching propagates via `push_event("showcase:project-changed")` — no iframe postMessage fragility
- 3-column layout (features/architecture/inspector) renders identically to standalone

## v5.3.0 (2026-03-12)

Integrates the `ag_ui_ex` Hex package (v0.1.0) as the canonical AG-UI protocol SDK, replacing all hardcoded event type strings with library-provided constants.

### Changed
- **ag_ui_ex dependency** — Added `{:ag_ui_ex, "~> 0.1.0"}` to mix.exs; all AG-UI event types now sourced from `AgUi.Core.Events.EventType`
- **EventStream** — All convenience emitters (`emit_run_started/2`, `emit_text_message_start/3`, etc.) use `EventType.xxx()` constants instead of string literals
- **HookBridge** — Legacy-to-AG-UI translation uses `EventType` constants for all `EventStream.emit/2` calls
- **EventRouter** — Case match routing uses compile-time module attributes derived from `EventType` constants
- **ChatStore** — `handle_info` pattern matches and `EventStream.emit` calls use `EventType` module attributes
- **AgUiV2Controller** — `POST /api/v2/ag-ui/emit` validates event types via `EventType.valid?/1`, returns 422 with valid type list on invalid input
- **AgUiLive** — Event type filter list populated from `EventType.all/0` instead of hardcoded `~w()` sigil
- **Tests** — All AG-UI test assertions use `EventType` constants; added integration tests for `EventType.all/0`, `EventType.valid?/1`, and constant value correctness
- **Version** — Bumped to v5.3.0

### Dependencies
- Added: `ag_ui_ex ~> 0.1.0` (Elixir SDK for AG-UI protocol — [hex.pm/packages/ag_ui_ex](https://hex.pm/packages/ag_ui_ex))

## v5.2.0 (2026-03-12)

E2E stabilization — unified sidebar, notification overhaul, AG-UI visualizer, version cleanup, docs refresh.

### Added
- **Shared sidebar_nav component** (`components/sidebar_nav.ex`) — single canonical sidebar replacing 20 inline duplicates across all LiveViews; dynamic version from `Application.spec/2`, 19-item nav list with active state
- **AG-UI LiveView** (`ag_ui_live.ex`) — real-time event feed at `/ag-ui` with 14 event type filter toggles, pause/resume, router stats panel, per-agent state viewer via StateManager
- **Notification formatting** — structured rendering with type-specific colored icons, category badges, `format_message/1` JSON-to-readable parser, deduplication with count badges
- **Notification grouping** — `hide_showcase` toggle (default on) to filter showcase noise, batch dismiss by category, `dedup_notifications/1` collapsing repeated entries
- **Skills AG-UI tab** — pill tab switcher (Registry | Session | AG-UI) showing skills as event emitters with connection indicators and hook repair button
- **Dependency graph hierarchy** — formation/squadron/swarm grouping in `buildHierarchyFromFlat`, swarm/cluster icons, "Unaffiliated" label replacing "Ungrouped"
- **AG-UI Protocol documentation** (`priv/docs/developer/ag-ui-protocol.md`) — event types, architecture, REST endpoints, HookBridge translation, state management
- **UAT nav item** — `/uat` route and sidebar entry

### Changed
- **All 20 LiveViews** migrated from inline sidebar to shared `<.sidebar_nav>` component
- **Version strings** — all hardcoded "v4", "v4.0.0", "CCEM APM v4" replaced with dynamic version; zero matches for `APM v4` in `lib/`
- **Dashboard scoping** — agent count label clarified to "Agents (All)" in All Projects view
- **Getting Started modal** — starts hidden (`display:none`), JS reveals on first visit only; version text generalized
- **Heartbeat endpoint** — auto-registers unknown agents (upsert) instead of returning 404
- **Health check** — port reference fixed from 3031 to 3032
- **Uptime display** — `Application.put_env(:server_start_time)` set at startup; monotonic time used consistently
- **`/upm` route** — redirects to `/workflow/upm` via PageController
- **Docs content** — all version references updated to v5.2.0; API reference expanded with v2 AG-UI endpoints

### Fixed
- Sidebar navigation inconsistencies across 20 pages (each had its own copy with drift)
- Notification panel showing 19/22 raw JSON showcase entries as noise
- Getting Started modal re-showing on every page navigation
- Heartbeat 404 errors for agents not pre-registered
- Health check testing APM on wrong port (3031 vs 3032)
- Uptime showing ~74 years (server_start_time never set)
- Dashboard agent count mismatch between views (84 in All Projects vs 4 in Dashboard)
- Dependency graph labeling "ungrouped" agents inconsistently
- `EventStream.recent/1` API mismatch in AG-UI LiveView (corrected to `get_events/2`)

## v5.1.0 (2026-03-11)

Interactive management suite — contextual AG-UI chat, agent controls, getting started wizard, CCEMAgent v3.0.0.

### Added
- **InspectorChatLive component** (`components/inspector_chat.ex`) — contextual AG-UI chat panel in inspector column, scoped to selected resource, real-time message streaming via PubSub
- **AgentControlPanel component** (`components/agent_control_panel.ex`) — Connect/Disconnect/Restart buttons per agent, formation-level controls, status indicator with pulse animation
- **SSE LiveView hook** (`hooks/inspector_chat.js`) — EventSource to AG-UI SSE endpoint with streaming typewriter text, expandable tool cards, exponential backoff reconnection, 200 message buffer
- **ScopeBreadcrumb component** (`components/scope_breadcrumb.ex`) — scope navigation breadcrumb (All > Project > Formation > Squadron > Agent), click to re-scope chat and controls
- **ChatStore GenServer** (`apm_v5/chat_store.ex`) — ETS-backed message persistence per scope, 500 max FIFO, TEXT_MESSAGE subscription, REST endpoints at `/api/v2/chat/:scope`
- **Agent control REST endpoints** — `POST /api/v2/agents/:id/control`, `/formations/:id/control`, `/squadrons/:id/control`, `GET/POST /agents/:id/messages`
- **GettingStartedWizard** (`components/getting_started_wizard.ex`) — 6-slide modal slideshow with progress dots, Skip button, LocalStorage flag, help menu re-trigger
- **Showcase SVG diagrams** (`components/showcase_diagrams.ex`) — pure SVG C4 L2 Container diagram with IntersectionObserver animation, WCAG AA, prefers-reduced-motion support
- **TooltipOverlay hook** (`hooks/tooltip_overlay.js`) — guided tour system with backdrop dimming, arrows, Next/Prev/Skip/Done, `?` keyboard shortcut

### Changed
- **DashboardLive** — inspector panel now includes ScopeBreadcrumb, AgentControlPanel, InspectorChat; new event handlers for chat, scope, agent control, wizard
- **CCEMAgent v3.0.0** — APMClient v2 with configurable port (UserDefaults), APMEventStream actor (SSE + Combine), agent management actions, mini-chat view, multi-server support with health checking

### CCEMAgent v3.0.0
- **APMEventStream** (`Services/APMEventStream.swift`) — Swift actor for SSE streaming with URLSession bytes, Combine PassthroughSubject, exponential backoff
- **APMClient v2** — configurable port via UserDefaults, `controlAgent/controlFormation` REST methods, `fetchChatMessages/sendChatMessage` chat API
- **AgentActionsManager** — per-agent Connect/Disconnect/Restart buttons, formation deploy/cancel controls
- **Mini-chat view** — compact chat (last 5 messages) in menu bar popup with text input and Open Full Chat button
- **MultiServerManager** — multi-server support with Add Server, port configuration, per-server health checking, UserDefaults persistence

## v5.0.0 (2026-03-11)

AG-UI protocol integration — backward-compatible event bridge for agentic monitoring.

### Added
- **AG-UI EventRouter** (`lib/apm_v5/ag_ui/event_router.ex`) — GenServer that routes typed AG-UI events (RUN_STARTED, STEP_STARTED, STEP_FINISHED, TOOL_CALL_START, TOOL_CALL_END, CUSTOM, STATE_SNAPSHOT, STATE_DELTA) to AgentRegistry, FormationStore, Dashboard, and MetricsCollector
- **AG-UI HookBridge** (`lib/apm_v5/ag_ui/hook_bridge.ex`) — translates legacy hook payloads (register, heartbeat, notify, tool-use) into typed AG-UI events; full backward compatibility with existing hooks
- **AG-UI StateManager** (`lib/apm_v5/ag_ui/state_manager.ex`) — ETS-backed per-agent state with snapshot/delta pattern using RFC 6902 JSON Patch
- **AG-UI v2 Controller** (`ag_ui_v2_controller.ex`) — REST endpoints: emit, stream (SSE), state snapshot/delta, router stats
- **AG-UI SSE streams** — global (`/api/v2/ag-ui/events`) and per-agent (`/api/v2/ag-ui/events/:agent_id`) event streams
- **Built-in documentation wiki** — 15+ markdown pages under `/docs` with sidebar navigation, search, and syntax highlighting
- **shift_select.js** hook — multi-select UI interaction for LiveView pages

### Changed
- **60+ REST API endpoints** (up from 50+) with expanded v2 OpenAPI spec
- **30+ GenServers** (up from 17) under OTP supervision
- **README.md** rewritten to document AG-UI architecture and GenServer catalog
- **All docs** updated to reflect v5 port (3032), AG-UI, and expanded feature set
- **MetricsCollector** enhanced with AG-UI event counting and routing stats
- **DashboardStore** updated with AG-UI event feed integration

### Fixed
- EventRouter feedback loop (self-subscription on PubSub `ag_ui:events` topic)
- DocsStore markdown rendering edge cases
- ExportManager test stability

## v4.3.0 (2026-03-02)

Cross-platform installer, Docker socket repair, session hardening.

### Added
- **Cross-platform installer**: Modular `install.sh` + `installer/` framework with `--prefix`, `--skip-*`, `--dry-run` flags; library modules for UI, detection, deps, build, hooks, and service management; launchd/systemd service templates using `io.pegues.agent-j.labs` reverse-DNS prefix
- **/docksock skill**: Docker socket repair automation — `status`, `repair`, `restart`, `nuke` subcommands with `--force`, `--verbose`, `--no-restart` switches; auto-detects broken `~/.docker/run/docker.sock` symlink and repairs from `docker.raw.sock`
- **CCEMAgent DockerSocketRepair.swift**: Native Swift service with `DockerSocketStatus` enum, `status()`, `repair()`, `restart()` static methods; dynamic "Docker: OK"/"Repair Docker Socket" menu item in actionsSection
- **session_init.sh hardening**: Stale PID validation (verifies process is actually BEAM/elixir/mix), `cleanup_stale_beam()` for zombie processes in T/U/D state, port conflict detection and recovery via netstat, polling startup health check (5x2s) with early failure detection

### Changed
- **Port canonicalized to 3032**: All 8 sources of truth updated (runtime.exs, dev.exs, hook_common.sh, session_init.sh, apm_config.json, 4 CCEMAgent Swift files, apm-server-wrapper.sh, project hooks)
- **CCEMAgent bundle identifier**: Updated to `io.pegues.agent-j.labs.ccem.agent` in Info.plist
- **APMServerManager.swift**: launchctl bootstrap/kickstart integration for service lifecycle

### Fixed
- CCEMAgent showing disconnected when APM running on 3032 (Swift files still referenced 3031)
- Zombie BEAM processes surviving Docker Desktop crashes and holding port indefinitely

## v4.2.0 (2026-03-02)

Dynamic APM + Claude-native feature expansion.

### Added
- **SkillsRegistryStore**: GenServer scanning `~/.claude/skills/*/SKILL.md` with ETS cache; health score algorithm (frontmatter 30%, description quality 25%, trigger keywords 20%, examples 15%, template 10%); 10-minute refresh cycle
- **Skills Registry REST API**: `GET /api/skills/registry`, `GET /api/skills/:name`, `GET /api/skills/:name/health`, `POST /api/skills/audit` via new `SkillsController`
- **SkillsLive Registry tab**: three-tier health dashboard (healthy/needs_attention/critical) with detail panel, health breakdown bars, Audit All + per-skill Fix buttons; nav icon → beaker
- **ActionEngine skill-audit actions**: `fix_skill_frontmatter`, `complete_skill_description`, `add_skill_triggers`, `backfill_project_memory`, `update_hooks` — read/write SKILL.md frontmatter, extend descriptions, backfill CLAUDE.md APM memory section, add APM PreToolUse hook
- **BackgroundTasksStore enhanced**: new fields `agent_name`, `agent_definition`, `invoking_process`, `log_path`, `runtime_ms`, `os_pid`; `get_task_logs/2` reads from log_path; `update_task/2` broadcasts PubSub `tasks:updated`
- **Enhanced BackgroundTasks API**: `GET /api/tasks/:id/logs`, `POST /api/tasks/:id/stop`, `PATCH /api/tasks/:id` (update metadata), plus `/tasks/*` route aliases for all bg-tasks endpoints
- **ProjectScanner Claude-native scan**: `scan_claude_native/1` returns hooks, MCPs, active listening ports (lsof), CLAUDE.md section names, UPM/formation presence detection
- **CCEMAgent UI (v4.2.0)**: background tasks section showing agent_name + formatted runtime_ms; server version in connected header; "last 24h" telemetry window; consistent section headers with icons; "Last sync:" UPM label; `BackgroundTask` model + `fetchBackgroundTasks()` APMClient method

### Architecture
- SkillsRegistryStore added to OTP supervision tree
- BackgroundTasksStore PubSub integration on task updates
- SkillsController added as dedicated controller (not api_controller)
- ActionEngine: `update_hooks` catalog entry renamed `deploy_apm_hooks` to accommodate new skill-audit variant

## v4.0.0 (2026-02-25)

Formation UX integration — full Wave 3 delivery.

### Added
- **Formation hierarchy**: `POST/GET /api/v2/formations` REST endpoints + swim-lane FormationGraph JS hook (D3 + DOM, squadron/swarm lanes with color grouping)
- **Wave tracking**: `wave_number`/`wave_total` fields on `POST /api/register`; `AgentRegistry.wave_progress/1` for ETS aggregation; wave progress bar in FormationLive inspector panel
- **Double-verify**: `VerifyStore` GenServer (ETS) + `POST /api/v2/verify/double` + `GET /api/v2/verify/:id`; emits 5 ordered toast events (`verify_pass_1_start` → `verify_consensus`)
- **Workflow schemas**: `WorkflowSchemaStore` GenServer + `GET/POST/PATCH /api/v2/workflows` REST endpoints
- **Skill hook deployer**: `SkillHookDeployer` GenServer + `POST /api/hooks/deploy` + `GET /api/hooks/templates`; priv/hook_templates for upm, deploy:agents-v2, skill pre-tool-use
- **Ship integration**: `POST /api/ship/register`, `POST /api/ship/event`, `GET /api/ship/status` wired through WorkflowSchemaStore
- **Notification panel refactor**: 5 tabs (All/Agents/Formations/Skills/Ship), unread count badges, expandable metadata cards, View/Open-PR action buttons, mark-all-read
- **Dashboard sidebar**: daisyUI drawer sidebar nav with 7 sections; `@sidebar_open`/`@current_section` assigns
- **deploy_agents category**: wave_number/wave_total/wave_status fields propagated through notify pipeline
- **OpenAPI spec**: updated to cover all new formation, workflow, verify, hooks, ship paths + VerificationSession schema component
- **Live-integration-testing MCPs**: chrome-devtools, playwright, puppeteer added to `.mcp.json`
- **Session init hook**: idempotent APM start + session registration + hook deployment on skill launch

### Architecture
- VerifyStore, WorkflowSchemaStore, SkillHookDeployer added to OTP supervision tree
- AgentRegistry extended with wave_number/wave_total metadata fields + wave_progress/1

## v4.0.0 (2026-02-19)

Complete rewrite from Python APM v3 to Phoenix/Elixir.

### Added
- Phoenix LiveView dashboard with daisyUI styling
- Multi-project support with project switcher
- D3.js dependency graph with force-directed layout
- Agent fleet management (individual, squadron, swarm, orchestrator types)
- Ralph methodology flowchart page with D3 visualization
- UPM (Unified Project Management) execution tracking
- Skills tracking with UEBA analytics and co-occurrence matrix
- Session timeline with Gantt-style D3 visualization
- All Projects widget dashboard with resizable panels
- 50+ REST API endpoints (v3-compatible + v4 extensions)
- v2 API with OpenAPI 3.0 spec
- AG-UI SSE endpoint for real-time event streaming
- A2UI component endpoint
- Global filter bar (Splunk/ELK-style) for agent search
- Layout and filter preset save/restore
- Notification system with bell dropdown
- Dark/light theme toggle
- SwiftUI menubar agent (CCEMAgent) for macOS
- Session init hooks for automatic APM start
- Built-in documentation wiki at `/docs`
- Earmark-based markdown rendering with search
- DocsStore GenServer for doc caching and TOC generation

### Architecture
- 17 GenServers with ETS-backed state
- PubSub-driven real-time updates (8 topics)
- No database dependency -- config file persistence
- Bandit HTTP server on port 3032

### Migration from v3
- Full REST API backward compatibility
- Same session registration flow
- Same notification API
- Config file format preserved
