# Changelog

All notable changes to CCEM APM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

Interactive management suite — contextual AG-UI chat, agent controls, getting started wizard, CCEMAgent v3.0.0.

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
- **SwiftUI Menubar Agent (CCEMAgent)**: Native macOS AppKit system tray app, real-time agent count and health display, quick actions, token tracking progress bar, health monitoring, login item auto-launch, URLSession polling
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

*Last Updated: 2026-03-12*
