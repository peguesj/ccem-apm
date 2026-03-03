# Changelog

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
- Bandit HTTP server on port 3031

### Migration from v3
- Full REST API backward compatibility
- Same session registration flow
- Same notification API
- Config file format preserved
