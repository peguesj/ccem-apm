# CCEM APM v6.1.0 Feature Inventory
Generated: 2026-03-17

## Routes (136 total)

### Browser Routes (33)

| Method | Path | Handler | Type | Notes |
|--------|------|---------|------|-------|
| GET | `/` | DashboardLive | LiveView | Main dashboard |
| GET | `/apm-all` | AllProjectsLive | LiveView | Multi-project overview |
| GET | `/ralph` | RalphFlowchartLive | LiveView | Ralph flowchart |
| GET | `/workflow/:type` | WorkflowLive | LiveView | Workflow viewer |
| GET | `/skills` | SkillsLive | LiveView | Skills registry/health |
| GET | `/timeline` | SessionTimelineLive | LiveView | Session timeline |
| GET | `/docs` | DocsLive | LiveView | Documentation wiki |
| GET | `/docs/*path` | DocsLive | LiveView | Doc page viewer |
| GET | `/formation` | FormationLive | LiveView | Formation graph |
| GET | `/notifications` | NotificationLive | LiveView | Notification center |
| GET | `/ports` | PortsLive | LiveView | Port manager |
| GET | `/tasks` | TasksLive | LiveView | Background tasks |
| GET | `/scanner` | ScannerLive | LiveView | Project scanner |
| GET | `/actions` | ActionsLive | LiveView | Action engine |
| GET | `/analytics` | AnalyticsLive | LiveView | Analytics dashboard |
| GET | `/health` | HealthCheckLive | LiveView | Health checks |
| GET | `/conversations` | ConversationMonitorLive | LiveView | Conversation monitor |
| GET | `/plugins` | PluginDashboardLive | LiveView | Plugin dashboard |
| GET | `/backfill` | BackfillLive | LiveView | Backfill manager |
| GET | `/drtw` | DrtwLive | LiveView | DRTW discovery |
| GET | `/ag-ui` | AgUiLive | LiveView | AG-UI protocol viewer |
| GET | `/intake` | IntakeLive | LiveView | Intake event pipeline |
| GET | `/uat` | UatLive | LiveView | UAT test runner |
| GET | `/tool-calls` | ToolCallLive | LiveView | Tool call tracker |
| GET | `/generative-ui` | GenerativeUILive | LiveView | Generative UI components |
| GET | `/a2a` | A2ALive | LiveView | A2A messaging |
| GET | `/showcase` | ShowcaseLive | LiveView | Showcase viewer |
| GET | `/showcase/:project` | ShowcaseLive | LiveView | Per-project showcase |
| GET | `/ccem` | CcemOverviewLive | LiveView | CCEM overview |
| GET | `/api/docs` | PageController | Controller | Scalar OpenAPI docs |
| GET | `/upm` | PageController | Controller | Redirects to workflow UPM |
| GET | `/docs/upm/status` | PageController | Controller | Redirects to showcase |
| GET | `/dev/dashboard` | Phoenix.LiveDashboard | LiveDashboard | Dev only |

### REST API v1 Routes (66)

| Method | Path | Handler | Action | Notes |
|--------|------|---------|--------|-------|
| GET | `/api/status` | ApiController | :status | Server status |
| GET | `/api/agents` | ApiController | :agents | List agents |
| POST | `/api/register` | ApiController | :register | Register agent |
| POST | `/api/heartbeat` | ApiController | :heartbeat | Agent heartbeat |
| POST | `/api/notify` | ApiController | :notify | Send notification |
| GET | `/api/ag-ui/events` | AgUiController | :events | AG-UI SSE stream |
| GET | `/api/data` | ApiController | :data | Aggregated data |
| GET | `/api/notifications` | ApiController | :notifications | List notifications |
| POST | `/api/notifications/add` | ApiController | :add_notification | Add notification |
| POST | `/api/notifications/read-all` | ApiController | :read_all_notifications | Mark all read |
| GET | `/api/ralph` | ApiController | :ralph | Ralph status |
| GET | `/api/ralph/flowchart` | ApiController | :ralph_flowchart | Ralph flowchart data |
| GET | `/api/commands` | ApiController | :commands | List commands |
| POST | `/api/commands` | ApiController | :register_commands | Register commands |
| GET | `/api/agents/activity-log` | ApiController | :activity_log | Agent activity log |
| GET | `/api/agents/discover` | ApiController | :discover_agents | Discover agents |
| POST | `/api/agents/register` | ApiController | :register | Alias for register |
| POST | `/api/agents/update` | ApiController | :update_agent | Update agent status |
| GET | `/api/input/pending` | ApiController | :pending_input | Pending input requests |
| POST | `/api/input/request` | ApiController | :request_input | Request input |
| POST | `/api/input/respond` | ApiController | :respond_input | Respond to input |
| POST | `/api/tasks/sync` | ApiController | :sync_tasks | Sync tasks |
| POST | `/api/config/reload` | ApiController | :reload_config | Reload config |
| POST | `/api/reload` | ApiController | :reload_config | Alias for reload |
| POST | `/api/plane/update` | ApiController | :update_plane | Update Plane data |
| GET | `/api/skills` | ApiController | :skills | List skills |
| POST | `/api/skills/track` | ApiController | :track_skill | Track skill usage |
| GET | `/api/skills/registry` | SkillsController | :registry | Skills registry |
| POST | `/api/skills/audit` | SkillsController | :audit | Run skills audit |
| GET | `/api/skills/:name/health` | SkillsController | :health | Skill health score |
| GET | `/api/skills/:name` | SkillsController | :show | Skill detail |
| GET | `/api/projects` | ApiController | :projects | List projects |
| PATCH | `/api/projects` | ApiController | :update_project | Update project |
| GET | `/api/v2/export` | ApiController | :export | Export data |
| POST | `/api/v2/import` | ApiController | :import_data | Import data |
| POST | `/api/upm/register` | ApiController | :upm_register | Register UPM session |
| POST | `/api/upm/agent` | ApiController | :upm_agent | Register UPM agent |
| POST | `/api/upm/event` | ApiController | :upm_event | Record UPM event |
| GET | `/api/upm/status` | ApiController | :upm_status | UPM status |
| GET | `/api/ports` | ApiController | :ports | List ports |
| POST | `/api/ports/scan` | ApiController | :scan_ports | Scan active ports |
| POST | `/api/ports/assign` | ApiController | :assign_port | Assign port |
| GET | `/api/ports/clashes` | ApiController | :port_clashes | Detect clashes |
| POST | `/api/ports/set-primary` | ApiController | :set_primary_port | Set primary port |
| GET | `/api/environments` | ApiController | :environments | List environments |
| GET | `/api/environments/:name` | ApiController | :environment_detail | Environment detail |
| POST | `/api/environments/:name/exec` | ApiController | :exec_command | Execute command |
| POST | `/api/environments/:name/session/start` | ApiController | :start_session | Start session |
| POST | `/api/environments/:name/session/stop` | ApiController | :stop_session | Stop session |
| GET | `/api/openapi.json` | ApiV2Controller | :openapi | OpenAPI spec (alias) |
| POST | `/api/hooks/deploy` | ApiController | :deploy_hooks | Deploy hooks |
| GET | `/api/bg-tasks` | ApiController | :list_bg_tasks | List background tasks |
| POST | `/api/bg-tasks` | ApiController | :register_bg_task | Register task |
| GET | `/api/bg-tasks/:id` | ApiController | :get_bg_task | Get task |
| GET | `/api/bg-tasks/:id/logs` | ApiController | :get_bg_task_logs | Get task logs |
| PATCH | `/api/bg-tasks/:id` | ApiController | :update_bg_task | Update task |
| POST | `/api/bg-tasks/:id/stop` | ApiController | :stop_bg_task | Stop task |
| DELETE | `/api/bg-tasks/:id` | ApiController | :delete_bg_task | Delete task |
| POST | `/api/scanner/scan` | ApiController | :scanner_scan | Trigger scan |
| GET | `/api/scanner/results` | ApiController | :scanner_results | Scan results |
| GET | `/api/scanner/status` | ApiController | :scanner_status | Scanner status |
| GET | `/api/actions` | ApiController | :list_actions | List actions |
| POST | `/api/actions/run` | ApiController | :run_action | Run action |
| GET | `/api/actions/runs` | ApiController | :list_action_runs | List runs |
| GET | `/api/actions/runs/:id` | ApiController | :get_action_run | Get run |
| GET | `/api/telemetry` | ApiController | :telemetry | Time-bucketed telemetry |
| POST | `/api/intake` | ApiController | :intake_submit | Submit intake event |
| GET | `/api/intake` | ApiController | :intake_list | List intake events |
| GET | `/api/intake/watchers` | ApiController | :intake_watchers | List watchers |

Note: `/api/tasks/*` routes are aliases for `/api/bg-tasks/*` (7 routes, not counted separately).

### REST API v2 Routes (37)

| Method | Path | Handler | Action | Notes |
|--------|------|---------|--------|-------|
| GET | `/api/v2/agents` | ApiV2Controller | :list_agents | Paginated agents |
| GET | `/api/v2/agents/:id` | ApiV2Controller | :get_agent | Agent detail |
| GET | `/api/v2/sessions` | ApiV2Controller | :list_sessions | List sessions |
| GET | `/api/v2/metrics` | ApiV2Controller | :fleet_metrics | Fleet metrics |
| GET | `/api/v2/metrics/:agent_id` | ApiV2Controller | :agent_metrics | Agent metrics |
| GET | `/api/v2/slos` | ApiV2Controller | :list_slos | List SLOs |
| GET | `/api/v2/slos/:name` | ApiV2Controller | :get_slo | Get SLO |
| GET | `/api/v2/alerts` | ApiV2Controller | :list_alerts | List alerts |
| GET | `/api/v2/alerts/rules` | ApiV2Controller | :list_alert_rules | List alert rules |
| POST | `/api/v2/alerts/rules` | ApiV2Controller | :create_alert_rule | Create alert rule |
| GET | `/api/v2/audit` | ApiV2Controller | :list_audit | Audit log |
| GET | `/api/v2/openapi.json` | ApiV2Controller | :openapi | OpenAPI spec (canonical) |
| GET | `/api/v2/workflows` | ApiV2Controller | :list_workflows | List workflows |
| POST | `/api/v2/workflows` | ApiV2Controller | :create_workflow | Create workflow |
| GET | `/api/v2/workflows/:id` | ApiV2Controller | :get_workflow | Get workflow |
| PATCH | `/api/v2/workflows/:id` | ApiV2Controller | :update_workflow | Update workflow |
| GET | `/api/v2/formations` | ApiV2Controller | :list_formations | List formations |
| POST | `/api/v2/formations` | ApiV2Controller | :create_formation | Create formation |
| GET | `/api/v2/formations/:id` | ApiV2Controller | :get_formation | Get formation |
| GET | `/api/v2/formations/:id/agents` | ApiV2Controller | :get_formation_agents | Formation agents |
| POST | `/api/v2/verify/double` | ApiV2Controller | :verify_double | Double-verify |
| GET | `/api/v2/verify/:id` | ApiV2Controller | :verify_status | Verify status |
| POST | `/api/v2/ag-ui/emit` | AgUiV2Controller | :emit | Emit AG-UI event |
| GET | `/api/v2/ag-ui/events` | AgUiV2Controller | :stream_events | SSE event stream |
| GET | `/api/v2/ag-ui/events/:agent_id` | AgUiV2Controller | :stream_agent_events | Agent SSE stream |
| GET | `/api/v2/ag-ui/state/:agent_id` | AgUiV2Controller | :get_state | Get agent state |
| PUT | `/api/v2/ag-ui/state/:agent_id` | AgUiV2Controller | :set_state | Set agent state |
| PATCH | `/api/v2/ag-ui/state/:agent_id` | AgUiV2Controller | :patch_state | Patch agent state |
| GET | `/api/v2/ag-ui/router/stats` | AgUiV2Controller | :router_stats | Router stats |
| GET | `/api/v2/ag-ui/diagnostics` | AgUiDiagnosticsController | :diagnostics | EventBus diagnostics |
| GET | `/api/v2/tool-calls` | ToolCallController | :index | List tool calls |
| GET | `/api/v2/tool-calls/stats` | ToolCallController | :stats | Tool call stats |
| GET | `/api/v2/tool-calls/stream` | ToolCallController | :stream | Tool call SSE stream |
| GET | `/api/v2/tool-calls/agent/:agent_id` | ToolCallController | :by_agent | Tool calls by agent |
| GET | `/api/v2/tool-calls/:id` | ToolCallController | :show | Tool call detail |
| GET | `/api/v2/generative-ui/components` | GenerativeUIController | :index | List GenUI components |
| POST | `/api/v2/generative-ui/components` | GenerativeUIController | :create | Create GenUI component |
| GET | `/api/v2/generative-ui/components/:id` | GenerativeUIController | :show | Get GenUI component |
| PUT | `/api/v2/generative-ui/components/:id` | GenerativeUIController | :update | Update GenUI component |
| DELETE | `/api/v2/generative-ui/components/:id` | GenerativeUIController | :delete | Delete GenUI component |
| GET | `/api/v2/approvals` | ApprovalController | :index | List approvals |
| GET | `/api/v2/approvals/:id` | ApprovalController | :show | Get approval |
| POST | `/api/v2/approvals/request` | ApprovalController | :request | Request approval |
| POST | `/api/v2/approvals/:id/approve` | ApprovalController | :approve | Approve gate |
| POST | `/api/v2/approvals/:id/reject` | ApprovalController | :reject | Reject gate |
| GET | `/api/v2/chat/:scope` | ChatController | :index | List chat messages |
| POST | `/api/v2/chat/:scope/send` | ChatController | :send_message | Send chat message |
| DELETE | `/api/v2/chat/:scope` | ChatController | :clear | Clear chat scope |
| POST | `/api/v2/a2a/send` | A2AController | :send_message | Send A2A message |
| GET | `/api/v2/a2a/messages/:agent_id` | A2AController | :messages | Agent messages |
| POST | `/api/v2/a2a/ack` | A2AController | :ack | Ack A2A message |
| GET | `/api/v2/a2a/stats` | A2AController | :stats | A2A stats |
| GET | `/api/v2/a2a/history/:agent_id` | A2AController | :history | A2A history |
| POST | `/api/v2/a2a/broadcast` | A2AController | :broadcast_message | Broadcast A2A |
| POST | `/api/v2/a2a/fan-out` | A2AController | :fan_out | Fan-out A2A |
| GET | `/api/v2/a2a/stream/:agent_id` | A2AController | :stream | A2A SSE stream |
| GET | `/api/v2/ag-ui/migration` | MigrationController | :migration_status | Migration status |
| POST | `/api/v2/agents/:id/control` | AgentControlController | :control_agent | Control agent |
| GET | `/api/v2/agents/:id/messages` | AgentControlController | :list_messages | Agent messages |
| POST | `/api/v2/agents/:id/messages` | AgentControlController | :send_message | Send to agent |
| POST | `/api/v2/formations/:id/control` | AgentControlController | :control_formation | Control formation |
| POST | `/api/v2/squadrons/:id/control` | AgentControlController | :control_squadron | Control squadron |
| GET | `/api/a2ui/components` | A2uiController | :components | A2UI components (flexible) |

---

## LiveViews (27 total)

### DashboardLive (`/`)
- **File**: `lib/apm_v5_web/live/dashboard_live.ex`
- **Module**: `ApmV5Web.DashboardLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:agents`, `apm:notifications`, `apm:config`, `apm:tasks`, `apm:commands`, `apm:upm`, `apm:ports`
- **EventBus**: `lifecycle:*`, `state:*`, `activity:*`, `special:custom`
- **Key assigns**: page_title, projects, active_project, agents, notifications, uptime, tasks, commands, ralph_data, upm_status, port_clashes, graph_expanded, chat_scope, chat_messages, saved_layouts, filter_status
- **handle_event**: drill_project, clear_drill, switch_tab, select_agent, toggle_lock, toggle_collapse, widget_resize, refresh, switch_project, toggle_other_projects, toggle_graph, set_graph_view, toggle_anon, list_toggle_node, send_chat, chat_scope_change, update_chat_input, run_port_remediation, save_layout, load_layout, delete_layout, save_preset, load_preset, delete_preset, apply_filter, clear_filter, toggle_showcase
- **push_events**: agents_updated, hierarchy_data, graph_toggle_anon, show_toast
- **Hooks**: Clock, DependencyGraph
- **Tests**: None

### AllProjectsLive (`/apm-all`)
- **File**: `lib/apm_v5_web/live/all_projects_live.ex`
- **Module**: `ApmV5Web.AllProjectsLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:agents`, `apm:notifications`, `apm:config`, `apm:tasks`
- **Key assigns**: projects, agents, active_count, notifications, session_count, widgets, drill_project, inspector_tab
- **handle_event**: drill_project, clear_drill, toggle_lock, toggle_collapse, widget_resize, inspect_agent, switch_inspector_tab
- **push_events**: agents_updated, hierarchy_data, show_toast
- **Hooks**: Clock, DependencyGraph
- **Tests**: None

### RalphFlowchartLive (`/ralph`)
- **File**: `lib/apm_v5_web/live/ralph_flowchart_live.ex`
- **Module**: `ApmV5Web.RalphFlowchartLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:config`
- **Key assigns**: steps, edges, ralph_data, visible_count, active_step, selected_step
- **handle_event**: next_step, prev_step, reset_steps, advance_step, jump_to_step, select_step
- **push_events**: flowchart_data
- **Hooks**: RalphFlowchart
- **Tests**: Yes (`ralph_flowchart_live_test.exs`)

### WorkflowLive (`/workflow/:type`)
- **File**: `lib/apm_v5_web/live/workflow_live.ex`
- **Module**: `ApmV5Web.WorkflowLive`
- **Has @moduledoc**: No
- **Key assigns**: workflow, all_workflows, steps, edges, selected_step
- **handle_event**: select_step, clear_step
- **Hooks**: WorkflowGraph
- **Tests**: None

### SkillsLive (`/skills`)
- **File**: `lib/apm_v5_web/live/skills_live.ex`
- **Module**: `ApmV5Web.SkillsLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:skills`
- **EventBus**: `special:custom`
- **Key assigns**: tab, active_session, session_skills, catalog, co_occurrence, registry_skills, selected_skill, audit_loading
- **handle_event**: set_tab, audit_all, select_skill, clear_selected, fix_frontmatter, repair_hooks
- **Tests**: None

### SessionTimelineLive (`/timeline`)
- **File**: `lib/apm_v5_web/live/session_timeline_live.ex`
- **Module**: `ApmV5Web.SessionTimelineLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:agents`, `apm:audit`
- **EventBus**: `lifecycle:*`, `tool:*`, `state:*`, `text:*`, `thinking:*`
- **Key assigns**: sessions, agents, selected_session, time_range
- **handle_event**: select_session, set_time_range, refresh
- **push_events**: timeline_data
- **Hooks**: SessionTimeline
- **Tests**: Yes (`session_timeline_live_test.exs`)

### DocsLive (`/docs`, `/docs/*path`)
- **File**: `lib/apm_v5_web/live/docs_live.ex`
- **Module**: `ApmV5Web.DocsLive`
- **Has @moduledoc**: Yes
- **Key assigns**: toc, search_query, search_results, current_path, doc_html, doc_title, page_headings, prev_page, next_page, collapsed_categories
- **handle_event**: search, clear_search, toggle_category, toggle_mobile_toc
- **Hooks**: DocContent
- **Tests**: None

### FormationLive (`/formation`)
- **File**: `lib/apm_v5_web/live/formation_live.ex`
- **Module**: `ApmV5Web.FormationLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:agents`, `apm:upm`
- **EventBus**: `lifecycle:*`
- **Key assigns**: agents, formations, active_formation, selected_node, wave_progress
- **handle_event**: refresh, select_formation, select_squadron, select_agent, node_clicked
- **push_events**: formation_data
- **Hooks**: FormationGraph
- **Tests**: None

### NotificationLive (`/notifications`)
- **File**: `lib/apm_v5_web/live/notification_live.ex`
- **Module**: `ApmV5Web.NotificationLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:notifications`
- **EventBus**: `special:custom`
- **Key assigns**: notifications, active_tab, tab_counts, expanded_ids, expanded_formations, expanded_upm, pending_decisions, lazy_context, hide_showcase
- **handle_event**: set_tab, toggle_expand, toggle_showcase_filter, dismiss_category, mark_all_read, approve_action, reject_action, toggle_formation_panel, toggle_upm_panel, load_context
- **Hooks**: LoadContext
- **Tests**: None

### PortsLive (`/ports`)
- **File**: `lib/apm_v5_web/live/ports_live.ex`
- **Module**: `ApmV5Web.PortsLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:ports`
- **Key assigns**: port_map, clashes, port_ranges, status_filter, namespace_filter, filtered
- **handle_event**: scan_ports, filter, namespace_filter, assign_port
- **Tests**: None

### TasksLive (`/tasks`)
- **File**: `lib/apm_v5_web/live/tasks_live.ex`
- **Module**: `ApmV5Web.TasksLive`
- **Has @moduledoc**: No
- **EventBus**: `activity:*`
- **Refresh**: 5s timer
- **Key assigns**: filter, selected_task_id, tasks
- **handle_event**: filter, view_logs, close_logs, stop_task, delete_task
- **Tests**: None

### ScannerLive (`/scanner`)
- **File**: `lib/apm_v5_web/live/scanner_live.ex`
- **Module**: `ApmV5Web.ScannerLive`
- **Has @moduledoc**: No
- **EventBus**: `activity:*`
- **Refresh**: 3s timer
- **Key assigns**: base_path, scanning, scanner_status, results
- **handle_event**: scan, update_path
- **Tests**: None

### ActionsLive (`/actions`)
- **File**: `lib/apm_v5_web/live/actions_live.ex`
- **Module**: `ApmV5Web.ActionsLive`
- **Has @moduledoc**: No
- **EventBus**: `activity:*`
- **Refresh**: 3s timer
- **Key assigns**: catalog, runs, projects, show_modal, selected_action, project_path, selected_paths
- **handle_event**: open_run_modal, close_modal, update_path, select_project, run_action, view_result, scan_projects, toggle_row, select_all, deselect_all, range_select, run_bulk_action
- **Hooks**: ShiftSelect
- **Tests**: None

### AnalyticsLive (`/analytics`)
- **File**: `lib/apm_v5_web/live/analytics_live.ex`
- **Module**: `ApmV5Web.AnalyticsLive`
- **Has @moduledoc**: No
- **EventBus**: `lifecycle:*`, `tool:*`
- **Refresh**: 30s timer
- **handle_event**: refresh
- **Tests**: None

### HealthCheckLive (`/health`)
- **File**: `lib/apm_v5_web/live/health_check_live.ex`
- **Module**: `ApmV5Web.HealthCheckLive`
- **Has @moduledoc**: No
- **EventBus**: `lifecycle:*`
- **Refresh**: 15s timer
- **Key assigns**: checks, overall
- **handle_event**: run_checks
- **Tests**: None

### ConversationMonitorLive (`/conversations`)
- **File**: `lib/apm_v5_web/live/conversation_monitor_live.ex`
- **Module**: `ApmV5Web.ConversationMonitorLive`
- **Has @moduledoc**: No
- **PubSub**: `apm:conversations`
- **EventBus**: `lifecycle:*`
- **Tests**: None

### PluginDashboardLive (`/plugins`)
- **File**: `lib/apm_v5_web/live/plugin_dashboard_live.ex`
- **Module**: `ApmV5Web.PluginDashboardLive`
- **Has @moduledoc**: No
- **Refresh**: 120s timer
- **handle_event**: rescan
- **Tests**: None

### BackfillLive (`/backfill`)
- **File**: `lib/apm_v5_web/live/backfill_live.ex`
- **Module**: `ApmV5Web.BackfillLive`
- **Has @moduledoc**: No
- **Refresh**: 10s timer
- **handle_event**: sync_to_plane, check_api, insert_rule
- **Tests**: None

### DrtwLive (`/drtw`)
- **File**: `lib/apm_v5_web/live/drtw_live.ex`
- **Module**: `ApmV5Web.DrtwLive`
- **Has @moduledoc**: Yes
- **Tests**: None

### AgUiLive (`/ag-ui`)
- **File**: `lib/apm_v5_web/live/ag_ui_live.ex`
- **Module**: `ApmV5Web.AgUiLive`
- **Has @moduledoc**: Yes
- **PubSub**: `ag_ui:events`, `apm:agents`
- **Key assigns**: events, router_stats, agents, selected_agent, agent_state, enabled_types, paused
- **handle_event**: toggle_type, toggle_pause, clear_events, refresh, select_agent
- **Tests**: None

### IntakeLive (`/intake`)
- **File**: `lib/apm_v5_web/live/intake_live.ex`
- **Module**: `ApmV5Web.IntakeLive`
- **Has @moduledoc**: No
- **PubSub**: `intake:events`
- **Key assigns**: events, watchers, filter_source, filter_type
- **handle_event**: filter_source, filter_type
- **Tests**: None

### UatLive (`/uat`)
- **File**: `lib/apm_v5_web/live/uat_live.ex`
- **Module**: `ApmV5Web.UatLive`
- **Has @moduledoc**: Yes
- **handle_event**: run_all, run_test, select_test
- **Tests**: None

### ToolCallLive (`/tool-calls`)
- **File**: `lib/apm_v5_web/live/tool_call_live.ex`
- **Module**: `ApmV5Web.ToolCallLive`
- **Has @moduledoc**: Yes
- **EventBus**: `tool:*`
- **Key assigns**: active_calls, stats, agent_filter
- **handle_event**: filter_agent
- **Tests**: None

### GenerativeUILive (`/generative-ui`)
- **File**: `lib/apm_v5_web/live/generative_ui_live.ex`
- **Module**: `ApmV5Web.GenerativeUILive`
- **Has @moduledoc**: Yes
- **EventBus**: `special:custom`
- **Key assigns**: components, agent_filter
- **handle_event**: filter_agent
- **Tests**: None

### A2ALive (`/a2a`)
- **File**: `lib/apm_v5_web/live/a2a_live.ex`
- **Module**: `ApmV5Web.A2ALive`
- **Has @moduledoc**: Yes
- **EventBus**: `a2a:*`, `special:custom`
- **Refresh**: 5s timer
- **Key assigns**: stats, recent_messages, send_form
- **handle_event**: send_test
- **Tests**: None

### ShowcaseLive (`/showcase`, `/showcase/:project`)
- **File**: `lib/apm_v5_web/live/showcase_live.ex`
- **Module**: `ApmV5Web.ShowcaseLive`
- **Has @moduledoc**: Yes
- **PubSub**: `apm:agents`, `apm:config`, `apm:upm`, `ag_ui:events`, `apm:showcase`, `apm:activity_log`
- **Refresh**: 5s heartbeat push
- **Key assigns**: all_projects, showcase_projects, active_project, showcase_data, features, version, activity_log
- **handle_event**: switch_project, switch_template
- **push_events**: showcase:data, showcase:agents, showcase:orch, showcase:activity, showcase:template-changed, showcase:project-changed
- **Hooks**: ShowcaseHook
- **Tests**: None

### CcemOverviewLive (`/ccem`)
- **File**: `lib/apm_v5_web/live/ccem_overview_live.ex`
- **Module**: `ApmV5Web.CcemOverviewLive`
- **Has @moduledoc**: Yes
- **Tests**: None

---

## GenServers (47 total)

### Core Infrastructure

#### ApmV5.ConfigLoader
- **Purpose**: Loads and manages apm_config.json, syncs sessions
- **ETS**: None (state in GenServer)
- **PubSub broadcasts**: `apm:config` -> `:config_reloaded`
- **Public API**: `get_config/0`, `get_project/1`, `update_project/1`
- **Supervision**: Direct child of ApmV5.Supervisor
- **Tests**: Yes

#### ApmV5.DashboardStore
- **Purpose**: Persists dashboard layouts, presets, and view configurations
- **Public API**: `save_layout/2`, `load_layout/1`, `delete_layout/1`, `save_preset/2`, `load_preset/1`, `delete_preset/1`, `save_view/2`, `load_view/1`, `delete_view/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.AgentRegistry
- **Purpose**: Core agent registration, heartbeat, and fleet management
- **Public API**: `register_agent/2,3`, `get_agent/1`, `list_agents/0,1`, `wave_progress/1`
- **PubSub broadcasts**: `apm:agents` -> `:agent_registered`, `:agent_updated`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.ApiKeyStore
- **Purpose**: API key generation, validation, and revocation
- **ETS**: Named table with read_concurrency
- **Public API**: `generate_key/1`, `revoke_key/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.AuditLog
- **Purpose**: Audit trail with ring buffer and ETS storage
- **ETS**: `:apm_audit_log` (ordered_set), ring buffer table (set)
- **Public API**: `log/3,4`, `log_sync/4,5`, `query/1`, `tail/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.ProjectStore
- **Purpose**: Project-scoped task sync, commands, Plane data, input requests
- **PubSub broadcasts**: `apm:tasks`, `apm:commands`, `apm:plane`
- **Public API**: `sync_tasks/2`, `get_tasks/1`, `register_commands/2`, `get_commands/1`, `update_plane/2`, `add_input_request/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.EventStream
- **Purpose**: AG-UI event stream with emit helpers
- **PubSub subscribes**: `ag_ui:events`
- **Public API**: `emit/1,2`, `get_events/0,2`, `emit_run_started/1,2`, `emit_run_finished/3`, `emit_text_message_start/2,3`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.Correlation
- **Purpose**: Request correlation ID generation and process dictionary storage
- **Public API**: `generate/0`, `put/1`, `get/0`, `with_correlation/2`
- **Tests**: Yes (not a GenServer; utility module)

### Monitoring & Metrics

#### ApmV5.MetricsCollector
- **Purpose**: Agent metric recording and querying
- **Public API**: `record/3`, `get_agent_metrics/1,2`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.SloEngine
- **Purpose**: SLO/SLI tracking and error budget calculation
- **Public API**: `get_sli/1`, `get_error_budget/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.AlertRulesEngine
- **Purpose**: Custom alert rule management with threshold evaluation
- **Public API**: `add_rule/1`, `update_rule/2`, `delete_rule/1`, `enable_rule/1`, `disable_rule/1`, `evaluate/3`, `get_alert_history/1`, `acknowledge/1`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.HealthCheckRunner
- **Purpose**: Periodic health checks for system components
- **Public API**: `get_checks/0`, `get_overall_health/0`, `run_now/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AnalyticsStore
- **Purpose**: Session analytics aggregation
- **Refresh**: Periodic
- **Public API**: `get_summary/0`, `get_sessions/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.ConnectionTracker
- **Purpose**: Track active WebSocket/session connections
- **ETS**: Named table with read_concurrency
- **Public API**: `register/3`, `update_heartbeat/1`, `get_connections_by_project/1`, `disconnect/1`
- **Supervision**: Not in supervision tree (started on demand)
- **Tests**: None

### Discovery & Scanning

#### ApmV5.AgentDiscovery
- **Purpose**: Periodic polling for agent discovery
- **Public API**: `discover_now/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.ProjectScanner
- **Purpose**: Scan directories for project configs, stack, ports, agent counts
- **Public API**: `scan/0,1`, `scan_claude_native/1`, `get_results/0`, `get_status/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.EnvironmentScanner
- **Purpose**: Scan and cache environment configurations
- **ETS**: Named table with read_concurrency
- **Public API**: `get_environment/1`, `rescan/0`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.PluginScanner
- **Purpose**: Scan for MCP servers and plugins
- **Public API**: `get_mcp_servers/0`, `get_plugins/0`, `rescan/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.ConversationWatcher
- **Purpose**: Watch active Claude Code conversations
- **PubSub broadcasts**: `apm:conversations` -> `:conversations_updated`
- **Public API**: `get_conversations/0`, `get_active_count/0`
- **Supervision**: Direct child
- **Tests**: None

### Actions & Tasks

#### ApmV5.ActionEngine
- **Purpose**: 4-action catalog (update_hooks, add_memory_pointer, backfill_apm_config, analyze_project)
- **Public API**: `list_catalog/0`, `run_action/2`, `list_runs/0`, `get_run/1`, `project_status/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.BackgroundTasksStore
- **Purpose**: Track background tasks with logs, runtime, and lifecycle
- **Public API**: `register_task/1`, `update_task/2`, `append_log/2`, `stop_task/1`, `list_tasks/0,1`, `get_task/1`, `delete_task/1`, `get_task_logs/1,2`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.CommandRunner
- **Purpose**: Execute commands in named environments
- **ETS**: Named table with read_concurrency
- **Public API**: `exec/2,3`, `kill/1`
- **Supervision**: Direct child
- **Tests**: Yes

### Skills & Hooks

#### ApmV5.SkillTracker
- **Purpose**: Track skill invocations per session/project
- **PubSub broadcasts**: `apm:skills` -> `:skill_tracked`
- **Public API**: `track_skill/2,4`, `get_session_skills/1`, `get_project_skills/1`, `get_skill_catalog/0`
- **Supervision**: Direct child
- **Tests**: Yes

#### ApmV5.SkillsRegistryStore
- **Purpose**: Skills registry with health scoring
- **ETS**: `:skills_registry`
- **Public API**: `list_skills/0`, `get_skill/1`, `health_score/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.SkillHookDeployer
- **Purpose**: Deploy hook files from templates to projects
- **ETS**: Named table
- **Public API**: `deploy_hooks/2,3`
- **Supervision**: Direct child
- **Tests**: None

### UPM & Formations

#### ApmV5.UpmStore
- **Purpose**: UPM session, agent, and event tracking
- **PubSub broadcasts**: `apm:upm` -> `:upm_session_registered`, `:upm_agent_registered`, `:upm_event`
- **Public API**: `register_session/1`, `register_agent/1`, `record_event/1`, `get_session/1`, `get_status/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.WorkflowSchemaStore
- **Purpose**: Unified workflow schema storage (ship/upm/ralph)
- **ETS**: Named table with read_concurrency
- **Public API**: `register_workflow/1`, `get_workflow/1`, `update_phase/2`, `update_workflow/2`, `list_workflows/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.VerifyStore
- **Purpose**: Double-verify session management
- **ETS**: Named table with read_concurrency
- **PubSub broadcasts**: `apm:verify` -> `:verify_created`, `:verify_updated`
- **Public API**: `create/3`, `get/1`, `update/2`
- **Supervision**: Direct child
- **Tests**: None

### Port Management

#### ApmV5.PortManager
- **Purpose**: Port assignment, clash detection, namespace ranges, remediation
- **PubSub broadcasts**: `apm:ports` -> `:port_assigned`
- **Public API**: `assign_port/1`, `get_port_map/0`, `detect_clashes/0`, `get_port_ranges/0`, `scan_active_ports/0`, `suggest_remediation/1`, `reassign_port/2`, `set_primary_port/2,3`, `get_project_configs/0`
- **Supervision**: Direct child
- **Tests**: None

### Documentation & Content

#### ApmV5.DocsStore
- **Purpose**: Markdown documentation loader with TOC, search, and pagination
- **Public API**: `get_page/1`, `get_toc/0`, `get_page_meta/1`, `get_adjacent_pages/1`, `search/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.ShowcaseDataStore
- **Purpose**: Showcase data loading and caching per project
- **PubSub broadcasts**: `apm:showcase` -> `:showcase_data_reloaded`
- **Public API**: `get_showcase_data/1`, `reload/0,1`, `get_features/1`, `filter_showcase_projects/1`
- **Supervision**: Direct child
- **Tests**: None

### Backfill & Intake

#### ApmV5.BackfillStore
- **Purpose**: Backfill run tracking and persistent rule state
- **Public API**: `get_state/0`, `add_run/1`, `set_rule_checked/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.Intake.Store
- **Purpose**: Intake event pipeline with watcher dispatch
- **ETS**: Named table (ordered_set)
- **PubSub broadcasts**: `intake:events` -> `:intake_event`
- **Public API**: `submit/1`, `list/0,1`, `get/1`, `register_watcher/1`
- **Supervision**: Direct child
- **Tests**: None

### AG-UI Protocol Layer (15 GenServers)

#### ApmV5.AgUi.EventBus
- **Purpose**: AG-UI event bus with topic-based publish/subscribe
- **Public API**: `publish/1,2`, `subscribe/1,2`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.EventRouter
- **Purpose**: Route AG-UI events to subscribers by type
- **Public API**: `route/1`, `emit_and_route/2`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.StateManager
- **Purpose**: Per-agent state with JSON Patch delta support
- **Public API**: `get_state/1`, `get_state_versioned/1`, `set_state/2`, `apply_delta/2`, `remove_state/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.V4Compat
- **Purpose**: Bridge EventBus events to v4 PubSub topics
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.ToolCallTracker
- **Purpose**: Tool call lifecycle tracking (start, args, result, error)
- **Public API**: `track_start/2,3`, `track_args/2`, `track_result/2`, `track_error/2`, `get_active/0`, `get_stats/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.DashboardStateSync
- **Purpose**: Sync AG-UI state to dashboard assigns
- **Public API**: `get_snapshot/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.ActivityTracker
- **Purpose**: Track per-agent activity from EventBus events
- **Public API**: `get_activity/1`, `list_activities/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.MetricsBridge
- **Purpose**: Bridge AG-UI events to MetricsCollector
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.AuditBridge
- **Purpose**: Bridge AG-UI events to AuditLog
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.EventBusHealth
- **Purpose**: EventBus diagnostics and health monitoring
- **Public API**: `diagnostics/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.GenerativeUI.Registry
- **Purpose**: Generative UI component registry
- **ETS**: Named table with read_concurrency
- **Public API**: `register_component/2`, `update_component/2`, `remove_component/1`, `list_by_agent/1`, `get/1`, `list_all/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.ApprovalGate
- **Purpose**: Approval gate lifecycle (request, approve, reject)
- **Public API**: `request_approval/2`, `approve/1,2`, `reject/2`, `list_by_agent/1`, `get/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgUi.A2A.Router
- **Purpose**: Agent-to-Agent message routing with fan-out and broadcast
- **ETS**: Named table with read_concurrency
- **Public API**: `send/1`, `get_messages/1`, `ack_message/2`, `history/1`, `stats/0`, `broadcast/1`, `fan_out/1`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.AgentActivityLog
- **Purpose**: Ring buffer for agent activity log entries
- **Public API**: `list_recent/0,1`, `get_agent_log/1,2`, `clear/0`
- **Supervision**: Direct child
- **Tests**: None

#### ApmV5.ChatStore
- **Purpose**: Scoped chat message persistence
- **ETS**: Named table
- **PubSub subscribes**: AG-UI topic
- **Public API**: `list_messages/1,2`, `send_message/2,3`, `get_message/1`, `clear_scope/1`
- **Supervision**: Direct child
- **Tests**: None

---

## JS Hooks (15 total)

### Clock (inline in app.js)
- **Events handled**: None (self-updating timer)
- **Events pushed**: None
- **External libs**: None
- **Used in**: DashboardLive, AllProjectsLive

### DependencyGraph (`assets/js/hooks/dependency_graph.js`)
- **Events handled**: `hierarchy_data`, `agents_updated`, `graph_toggle_anon`
- **Events pushed**: None
- **External libs**: D3.js v7 (lazy CDN load)
- **Used in**: DashboardLive, AllProjectsLive

### RalphFlowchart (`assets/js/hooks/ralph_flowchart.js`)
- **Events handled**: `flowchart_data`
- **Events pushed**: `select_step`
- **External libs**: D3.js v7 (vendored)
- **Used in**: RalphFlowchartLive

### WidgetResize (`assets/js/hooks/widget_resize.js`)
- **Events handled**: None
- **Events pushed**: `widget_resize`
- **External libs**: None
- **Used in**: AllProjectsLive (via widget component)

### SessionTimeline (`assets/js/hooks/session_timeline.js`)
- **Events handled**: `timeline_data`
- **Events pushed**: (indirect via pushEvent binding)
- **External libs**: D3.js v7 (vendored)
- **Used in**: SessionTimelineLive

### FormationGraph (`assets/js/hooks/formation_graph.js`)
- **Events handled**: `formation_data`
- **Events pushed**: `node_clicked`
- **External libs**: D3.js v7 (CDN lazy load), design_tokens.js
- **Used in**: FormationLive

### Toast (`assets/js/hooks/toast.js`)
- **Events handled**: `show_toast`
- **Events pushed**: None
- **External libs**: None
- **Used in**: DashboardLive (via Layouts)

### DocContent (`assets/js/hooks/doc_content.js`)
- **Events handled**: None (runs on mount/update)
- **Events pushed**: None
- **External libs**: highlight.js (12 languages: elixir, js, ts, bash, json, swift, sql, yaml, xml, css, erlang, shell)
- **Used in**: DocsLive

### WorkflowGraph (`assets/js/hooks/workflow_graph.js`)
- **Events handled**: None (data from assigns)
- **Events pushed**: `select_step`
- **External libs**: D3.js v7 (vendored)
- **Used in**: WorkflowLive

### ShiftSelect (`assets/js/hooks/shift_select.js`)
- **Events handled**: None (DOM click handling)
- **Events pushed**: `range_select`
- **External libs**: None
- **Used in**: ActionsLive

### TooltipOverlay (`assets/js/hooks/tooltip_overlay.js`)
- **Events handled**: `start-tour`, `stop-tour`
- **Events pushed**: `tour-ended`
- **External libs**: None
- **Used in**: Getting started wizard

### InspectorChat (`assets/js/hooks/inspector_chat.js`)
- **Events handled**: `inspector:set-agent`, `inspector:set-scope`
- **Events pushed**: `chat:stream-start`, `chat:stream-content`, `chat:stream-end`, `chat:new-message`
- **External libs**: None (SSE via EventSource)
- **Used in**: DashboardLive (inspector chat panel)

### GettingStartedShowcase (`assets/js/hooks/getting_started_showcase.js`)
- **Events handled**: `showcase:reshow`
- **Events pushed**: `showcase:dismiss`
- **External libs**: lottie-web (CDN lazy load)
- **Used in**: GettingStartedShowcase component

### ShowcaseHook (`assets/js/hooks/showcase.js`)
- **Events handled**: `showcase:data`, `showcase:agents`, `showcase:orch`, `showcase:activity`, `showcase:template-changed`, `showcase:project-changed`
- **Events pushed**: None
- **External libs**: showcase-engine.js (1634 lines, loaded from priv/static)
- **Used in**: ShowcaseLive

### LoadContext (`assets/js/hooks/load_context.js`)
- **Events handled**: None (fires on mount)
- **Events pushed**: `load_context`
- **External libs**: None
- **Used in**: NotificationLive

---

## REST API Controllers (17 total)

### ApiController (`lib/apm_v5_web/controllers/api_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: 65 public functions handling v1 REST endpoints
- **Key endpoints**: status, agents, register, heartbeat, notify, data, notifications, ralph, commands, skills, projects, upm, ports, environments, bg-tasks, scanner, actions, telemetry, intake
- **Tests**: Yes (api_controller_test.exs, api_controller_v3_compat_test.exs, environment_api_test.exs)

### ApiV2Controller (`lib/apm_v5_web/controllers/v2/api_v2_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: 22 public functions for v2 REST
- **Key endpoints**: agents (paginated), sessions, metrics, SLOs, alerts, audit, openapi, workflows, formations, verify
- **Tests**: Yes (api_v2_controller_test.exs)

### AgUiController (`lib/apm_v5_web/controllers/ag_ui_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: events (SSE stream)
- **Tests**: Yes

### AgUiV2Controller (`lib/apm_v5_web/controllers/v2/ag_ui_v2_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: emit, stream_events, stream_agent_events, get_state, set_state, patch_state, router_stats
- **Tests**: None

### AgUiDiagnosticsController (`lib/apm_v5_web/controllers/ag_ui_diagnostics_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: diagnostics
- **Tests**: None

### ToolCallController (`lib/apm_v5_web/controllers/tool_call_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: index, stats, by_agent, show, stream
- **Tests**: None

### GenerativeUIController (`lib/apm_v5_web/controllers/generative_ui_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: index, show, create, update, delete
- **Tests**: None

### ApprovalController (`lib/apm_v5_web/controllers/approval_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: index, show, request, approve, reject
- **Tests**: None

### ChatController (`lib/apm_v5_web/controllers/v2/chat_controller.ex`)
- **Has @moduledoc**: No
- **Actions**: index, send_message, clear
- **Tests**: None

### A2AController (`lib/apm_v5_web/controllers/a2a_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: send_message, messages, ack, stats, history, broadcast_message, fan_out, stream
- **Tests**: None

### AgentControlController (`lib/apm_v5_web/controllers/v2/agent_control_controller.ex`)
- **Has @moduledoc**: No
- **Actions**: control_agent, control_formation, control_squadron, list_messages, send_message
- **Tests**: None

### MigrationController (`lib/apm_v5_web/controllers/migration_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: migration_status
- **Tests**: None

### SkillsController (`lib/apm_v5_web/controllers/skills_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: registry, show, health, audit
- **Tests**: None

### A2uiController (`lib/apm_v5_web/controllers/a2ui_controller.ex`)
- **Has @moduledoc**: Yes
- **Actions**: components
- **Tests**: Yes

### PageController (`lib/apm_v5_web/controllers/page_controller.ex`)
- **Has @moduledoc**: No
- **Actions**: home, upm_redirect, redirect_to_showcase, upm_showcase, api_docs
- **Tests**: Yes

### ErrorJSON / ErrorHTML
- **Tests**: Yes for both

### ApiV2JSON (`lib/apm_v5_web/controllers/v2/api_v2_json.ex`)
- **Purpose**: JSON envelope, pagination, cursor helpers for v2 API
- **Tests**: None

---

## Components (10 total)

### CoreComponents (`lib/apm_v5_web/components/core_components.ex`)
- **Has @moduledoc**: Yes
- **Functions**: flash/1, button/1, input/1 (6 clauses), header/1, table/1, list/1, icon/1, show/1, hide/1, translate_error/1, translate_errors/2
- **Notable**: Standard Phoenix generator components, daisyUI themed

### SidebarNav (`lib/apm_v5_web/components/sidebar_nav.ex`)
- **Has @moduledoc**: Yes
- **Functions**: sidebar_nav/1
- **Notable**: Used by all 27 LiveViews; dual-section dynamic nav

### Layouts (`lib/apm_v5_web/components/layouts.ex`)
- **Has @moduledoc**: Yes
- **Functions**: app/1, flash_group/1, theme_toggle/1
- **Notable**: Root layout with theme switching

### GettingStartedWizard (`lib/apm_v5_web/components/getting_started_wizard.ex`)
- **Has @moduledoc**: Yes
- **Functions**: wizard/1
- **Notable**: Modal slideshow for onboarding; imported by most LiveViews

### GettingStartedShowcase (`lib/apm_v5_web/components/getting_started_showcase.ex`)
- **Has @moduledoc**: Yes
- **Functions**: showcase/1
- **Notable**: SVG diagram showcase for wizard slides

### InspectorChat (`lib/apm_v5_web/components/inspector_chat.ex`)
- **Has @moduledoc**: Yes
- **Functions**: chat_panel/1
- **Notable**: AG-UI contextual chat panel

### AgentControlPanel (`lib/apm_v5_web/components/agent_control_panel.ex`)
- **Has @moduledoc**: Yes
- **Functions**: control_bar/1
- **Notable**: Agent connect/disconnect/restart controls

### ScopeBreadcrumb (`lib/apm_v5_web/components/scope_breadcrumb.ex`)
- **Has @moduledoc**: Yes
- **Functions**: breadcrumb/1, parse_scope/1 (6 clauses)
- **Notable**: Hierarchical scope navigation (global -> project -> formation -> squadron -> agent)

### ShowcaseDiagrams (`lib/apm_v5_web/components/showcase_diagrams.ex`)
- **Has @moduledoc**: Yes
- **Notable**: SVG diagram rendering for showcase

### Accessibility (`lib/apm_v5_web/components/accessibility.ex`)
- **Has @moduledoc**: Yes
- **Functions**: skip_link/1, live_region/1, status_badge/1, metric_meter/1
- **Notable**: WCAG AA compliance helpers

---

## WebSocket Channels (4 total)

### AgUiChannel (`ag_ui:lobby`, `ag_ui:<agent_id>`)
- **File**: `lib/apm_v5_web/channels/ag_ui_channel.ex`
- **handle_in**: emit, subscribe, state:get, state:patch, a2a:send
- **Tests**: None

### AgentChannel (`agent:fleet`, `agent:<agent_id>`)
- **File**: `lib/apm_v5_web/channels/agent_channel.ex`
- **handle_in**: send_command
- **Tests**: Yes

### AlertsChannel (`alerts:feed`)
- **File**: `lib/apm_v5_web/channels/alerts_channel.ex`
- **handle_in**: acknowledge
- **Tests**: Yes

### MetricsChannel (`metrics:live`)
- **File**: `lib/apm_v5_web/channels/metrics_channel.ex`
- **Tests**: Yes

---

## Plugs (3 total)

| Plug | File | Has @moduledoc | Tests |
|------|------|----------------|-------|
| CorrelationId | `lib/apm_v5_web/plugs/correlation_id.ex` | Yes | Yes |
| CORS | `lib/apm_v5_web/plugs/cors.ex` | Yes | No |
| ApiAuth | `lib/apm_v5_web/plugs/api_auth.ex` | Yes | Yes |

---

## Utility Modules (non-GenServer, 14 total)

| Module | File | Purpose |
|--------|------|---------|
| ApmV5.Ralph | `lib/apm_v5/ralph.ex` | PRD JSON loader and flowchart builder |
| ApmV5.GraphBuilder | `lib/apm_v5/graph_builder.ex` | Hierarchy tree builder for dependency graphs |
| ApmV5.Uptime | `lib/apm_v5/uptime.ex` | Server uptime calculation |
| ApmV5.SessionParser | `lib/apm_v5/session_parser.ex` | JSONL session file parser |
| ApmV5.ExportManager | `lib/apm_v5/export_manager.ex` | Data export (JSON/CSV) and import |
| ApmV5.PrdScanner | `lib/apm_v5/prd_scanner.ex` | Scan for prd.json files |
| ApmV5.WorkflowRegistry | `lib/apm_v5/workflow_registry.ex` | Static workflow definitions |
| ApmV5.A2ui.ComponentBuilder | `lib/apm_v5/a2ui/component_builder.ex` | A2UI JSON component builder |
| ApmV5.AgUi.HookBridge | `lib/apm_v5/ag_ui/hook_bridge.ex` | Translate v4 hooks to AG-UI events |
| ApmV5.AgUi.LifecycleMapper | `lib/apm_v5/ag_ui/lifecycle_mapper.ex` | Map agent lifecycle to AG-UI events (ETS) |
| ApmV5.AgUi.SubscriptionStore | `lib/apm_v5/ag_ui/subscription_store.ex` | Topic subscription registry (ETS) |
| ApmV5.AgUi.Topics | `lib/apm_v5/ag_ui/topics.ex` | AG-UI topic taxonomy and matching |
| ApmV5.AgUi.A2A.Addressing | `lib/apm_v5/ag_ui/a2a/addressing.ex` | A2A address resolution |
| ApmV5.AgUi.A2A.Envelope | `lib/apm_v5/ag_ui/a2a/envelope.ex` | A2A message envelope struct |
| ApmV5.AgUi.A2A.Patterns | `lib/apm_v5/ag_ui/a2a/patterns.ex` | A2A messaging patterns |
| ApmV5.Intake.Dispatcher | `lib/apm_v5/intake/dispatcher.ex` | Intake event dispatch |
| ApmV5.Intake.Watcher | `lib/apm_v5/intake/watcher.ex` | Watcher behaviour |
| ApmV5.Intake.Watchers.LogWatcher | `lib/apm_v5/intake/watchers/log_watcher.ex` | Log file watcher |
| ApmV5.Intake.Watchers.NotificationWatcher | `lib/apm_v5/intake/watchers/notification_watcher.ex` | Notification watcher |
| ApmV5.Intake.Watchers.UatWatcher | `lib/apm_v5/intake/watchers/uat_watcher.ex` | UAT test watcher |
| ApmV5.Logger.JsonFormatter | `lib/apm_v5/logger/json_formatter.ex` | Structured JSON log formatter |
| ApmV5.UpmPersistentRule | `lib/apm_v5/upm_persistent_rule.ex` | UPM persistent rule enforcement |
| ApmV5.BackfillRunner | `lib/apm_v5/backfill_runner.ex` | Backfill execution runner |
| ApmV5.PlaneClient | `lib/apm_v5/plane_client.ex` | Plane PM API client |

---

## Coverage Gaps

### Missing @moduledoc (20 modules)
- `lib/apm_v5_web/telemetry.ex`
- `lib/apm_v5_web/router.ex`
- `lib/apm_v5_web/live/actions_live.ex`
- `lib/apm_v5_web/live/tasks_live.ex`
- `lib/apm_v5_web/live/health_check_live.ex`
- `lib/apm_v5_web/live/scanner_live.ex`
- `lib/apm_v5_web/live/workflow_live.ex`
- `lib/apm_v5_web/live/intake_live.ex`
- `lib/apm_v5_web/live/backfill_live.ex`
- `lib/apm_v5_web/live/plugin_dashboard_live.ex`
- `lib/apm_v5_web/live/analytics_live.ex`
- `lib/apm_v5_web/live/conversation_monitor_live.ex`
- `lib/apm_v5_web/endpoint.ex`
- `lib/apm_v5_web/controllers/v2/chat_controller.ex`
- `lib/apm_v5_web/controllers/v2/agent_control_controller.ex`
- `lib/apm_v5_web/controllers/page_controller.ex`
- `lib/apm_v5_web/channels/user_socket.ex`
- `lib/apm_v5_web/channels/alerts_channel.ex`
- `lib/apm_v5_web/channels/agent_channel.ex`
- `lib/apm_v5_web/channels/metrics_channel.ex`

### Missing @spec (project-wide)
Zero `@spec` annotations found in any web-layer module (LiveViews, controllers, components, channels, plugs). Some business-logic GenServers have `@spec` annotations, but the majority do not. This is a systemic gap.

**Modules with @spec**: ApmV5.AgUi.EventBus, ApmV5.AgUi.EventRouter, ApmV5.AgUi.Topics, ApmV5.AgUi.HookBridge, ApmV5.AgUi.LifecycleMapper, ApmV5.AgentRegistry, ApmV5.ChatStore, ApmV5.BackgroundTasksStore, ApmV5.MetricsCollector, ApmV5.SloEngine, ApmV5.AlertRulesEngine, ApmV5.Correlation, ApmV5.ExportManager, ApmV5.Ralph, ApmV5.GraphBuilder, ApmV5.SkillsRegistryStore, ApmV5.ProjectScanner

**Modules without @spec (78+ modules)**: All LiveViews (27), all controllers (17), all components (10), all channels (4), all plugs (3), plus 17+ GenServers.

### Missing Tests

**GenServers without tests (32)**:
chat_store, backfill_store, workflow_schema_store, plugin_scanner, health_check_runner, project_scanner, action_engine, docs_store, skills_registry_store, intake_store, upm_store, agent_discovery, event_bus_health, activity_tracker, v4_compat, a2a_router, tool_call_tracker, state_manager, event_router, approval_gate, dashboard_state_sync, audit_bridge, event_bus, metrics_bridge, background_tasks_store, conversation_watcher, connection_tracker, verify_store, agent_activity_log, analytics_store, skill_hook_deployer, showcase_data_store

**LiveViews without tests (25 of 27)**:
All except RalphFlowchartLive and SessionTimelineLive.

**Controllers without tests (12 of 17)**:
a2a_controller, ag_ui_diagnostics_controller, approval_controller, generative_ui_controller, migration_controller, skills_controller, tool_call_controller, ag_ui_v2_controller, agent_control_controller, api_v2_json, chat_controller, page_html

### Existing Tests (35 files)
- 3 channel tests
- 7 controller tests
- 2 LiveView tests
- 2 plug tests
- 15 GenServer/utility tests
- 1 integration test (full_stack_test.exs)
- test_helper.exs

### Potential Dead Code
- `ApmV5.ConnectionTracker` -- GenServer not in supervision tree (not started in application.ex)
- `/api/tasks/*` routes -- complete duplication of `/api/bg-tasks/*` (7 route aliases)
- `ApmV5.UpmPersistentRule` -- referenced but unclear if actively used
- `ApmV5.BackfillRunner` -- utility module, verify caller chain

---

## Summary Statistics

| Category | Count |
|----------|-------|
| **Routes (total)** | 136 |
| Browser / LiveView routes | 33 |
| REST API v1 routes | 66 |
| REST API v2 routes | 37 |
| **LiveViews** | 27 |
| **GenServers** | 47 |
| **JS Hooks** | 15 |
| **Components** | 10 |
| **Controllers** | 17 |
| **Channels** | 4 |
| **Plugs** | 3 |
| **Utility modules** | 24 |
| **Test files** | 35 |
| **Missing @moduledoc** | 20 |
| **Missing @spec** | 78+ |
| **GenServers without tests** | 32 of 47 |
| **LiveViews without tests** | 25 of 27 |
| **Controllers without tests** | 12 of 17 |
| **Elixir deps** | 15 |
| **Mix version** | 6.1.0 |
| **Elixir requirement** | ~> 1.15 |
| **Supervision strategy** | one_for_one |
| **Supervised children** | 50 |
