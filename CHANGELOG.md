# Changelog

## v4.1.0 (2026-03-02)

UPM Module — Unified Project Management with PM/VCS integrations, bidirectional sync, LiveView dashboard, and CCEMAgent integration.

### Added
- **UPM.ProjectRegistry**: ETS-backed GenServer; scan, upsert, delete projects; persists to `~/.ccem/upm/projects.json`
- **UPM.PMIntegrationStore**: PM platform store (Plane, Linear, Jira, Monday, MSProject) with adapter-delegated test_connection
- **UPM.VCSIntegrationStore**: VCS store (GitHub, AzureDevOps) with sync_type (bidirectional/push/pull)
- **UPM.WorkItemStore**: Work item store with drift detection (`detect_drift/1`, `detect_drift_all/0`)
- **UPM.SyncEngine**: 5-minute scheduled bidirectional sync GenServer; PubSub `upm:sync`
- **PM Adapters**: Plane (PlaneClient), Linear (GraphQL/:httpc), Jira/Monday/MSProject (stubs)
- **VCS Adapters**: GitHub (`gh` CLI), AzureDevOps (`az devops` CLI)
- **UpmController**: 22 REST endpoints at `/api/upm/*` (projects, PM integrations, VCS integrations, work items, sync)
- **UpmLive**: LiveView at `/upm`, `/upm/:id`, `/upm/:id/board` with Kanban board and PubSub for all 5 UPM topics
- **Nav item**: UPM (hero-circle-stack) added to all 19 LiveViews
- **CCEMAgent UPMMonitor**: `@Observable` Swift class polling UPM endpoints every 60s
- **CCEMAgent UPMModels**: Codable Swift structs for all UPM data types
- **CCEMAgent MenuBar**: UPM section with project count, sync/drift stats, recent sync history, and quick actions

### Architecture
- 5 new OTP supervisor children: UPM.ProjectRegistry, PMIntegrationStore, VCSIntegrationStore, WorkItemStore, SyncEngine
- PubSub topics: `upm:projects`, `upm:pm_integrations`, `upm:vcs_integrations`, `upm:work_items`, `upm:sync`
- 28 new routes (3 browser LiveView + 25 API)

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
