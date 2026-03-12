# Changelog

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
