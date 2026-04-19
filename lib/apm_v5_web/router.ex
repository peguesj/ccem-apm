defmodule ApmV5Web.Router do
  @moduledoc """
  Phoenix Router for the CCEM APM web application.

  Defines browser and API pipelines, live routes for all LiveViews,
  and the REST API surface under /api/* and /api/v2/*.

  ## API Architecture

  Routes are organized into two layers:

  ### Core APM (microkernel)
  Fundamental monitoring primitives — agent lifecycle, sessions, notifications,
  health, telemetry, ports, background tasks, project scanner, and actions.
  These routes exist in every deployment regardless of which extensions are enabled.

  ### Extensions
  Domain-specific capabilities mounted alongside the core. Each extension is clearly
  delimited with a section comment. Extensions can be identified in the OpenAPI spec
  by the `x-extension: true` flag on their operations.

  | Extension     | Tag                      | Path prefix(es)              |
  |---------------|--------------------------|------------------------------|
  | agentlock     | AgentLock Authorization  | /api/v2/auth/*               |
  | upm           | UPM / UPM Decision Gate  | /api/upm/*, /api/v2/upm/*    |
  | coalesce      | Coalesce                 | /api/v2/coalesce/*           |
  | skills        | Skills                   | /api/skills/registry, etc.   |
  | showcase      | CCEM Management          | /api/showcase/*              |
  | ag_ui         | AG-UI                    | /api/ag-ui/*, /api/v2/ag-ui/*|
  | plugins       | Plugins / Integrations   | /api/v2/plugins/*, etc.      |
  | usage         | Usage                    | /api/usage/*                 |
  | formations    | Formations               | /api/formations/*            |

  See `GET /api/v2/manifest` for a machine-readable summary.
  """

  use ApmV5Web, :router

  pipeline :browser do
    plug ApmV5Web.Plugs.CorrelationId
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ApmV5Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug ApmV5Web.Plugs.CorrelationId
    plug :accepts, ["json"]
    plug ApmV5Web.Plugs.CORS
    plug ApmV5Web.Plugs.ApiAuth
  end

  pipeline :api_flexible do
    plug :accepts, ["json", "jsonl"]
    plug ApmV5Web.Plugs.CORS
  end

  # ── BROWSER ROUTES ─────────────────────────────────────────────────────────

  scope "/", ApmV5Web do
    pipe_through :browser

    # Scalar API Reference (interactive OpenAPI docs)
    get "/api/docs", PageController, :api_docs

    # Core monitoring views
    live "/", DashboardLive, :index
    live "/apm-all", AllProjectsLive, :index
    live "/ralph", RalphFlowchartLive, :index
    live "/workflow/:type", WorkflowLive, :show
    live "/skills", SkillsLive, :index
    live "/timeline", SessionTimelineLive, :index
    live "/docs", DocsLive, :index
    get "/docs/upm/status", PageController, :redirect_to_showcase
    live "/docs/*path", DocsLive, :show
    live "/formation", FormationLive, :index
    live "/notifications", NotificationLive, :index
    live "/ports", PortsLive, :index
    live "/tasks", TasksLive, :index
    live "/scanner", ScannerLive, :index
    live "/actions", ActionsLive, :index
    live "/actions/alignment", AlignmentLive, :index
    live "/architecture", ArchitectureLive, :index
    live "/analytics", AnalyticsLive, :index
    live "/health", HealthCheckLive, :index
    live "/conversations", ConversationMonitorLive, :index
    live "/backfill", BackfillLive, :index
    live "/drtw", DrtwLive, :index
    live "/intake", IntakeLive, :index
    live "/uat", UatLive, :index
    live "/tool-calls", ToolCallLive, :index
    live "/a2a", A2ALive, :index
    live "/sessions", SessionManagerLive, :index
    live "/sessions/:id", SessionManagerLive, :show

    # Extension: ag_ui
    live "/ag-ui", AgUiLive, :index
    live "/generative-ui", GenerativeUILive, :index

    # Extension: showcase
    live "/showcase", ShowcaseLive, :index
    live "/showcase/:project", ShowcaseLive, :project
    live "/ccem", CcemOverviewLive, :index

    # Extension: agentlock
    live "/authorization", AuthorizationLive, :index
    live "/approvals-history", ApprovalHistoryLive, :index
    live "/routing", RoutingLive, :index

    # Extension: usage
    live "/usage", UsageLive, :index

    # Extension: coalesce
    live "/coalesce", CoalesceLive, :index

    # Extension: plugins
    live "/plugins", PluginDashboardLive, :index
    live "/plugins/ralph", RalphPluginLive, :index
    live "/plugins/ag_ui", AgUiPluginLive, :index
    live "/plugins/claude-code", ClaudeCodeDiscoveryLive, :index
    live "/integrations", PluginDashboardLive, :integrations_tab
    live "/integrations/lvm", LvmStatusLive, :index

    # Extension: skill drift detector
    live "/skill-drift", SkillDriftLive, :index

    # Extension: library
    live "/library", LibraryLive, :index

    # Extension: upm
    live "/upm/module", UpmLive, :index
    live "/upm/module/:project_id", UpmLive, :project
    live "/upm/module/:project_id/board", UpmLive, :board
    get "/upm", PageController, :upm_redirect
  end

  # ── CORE APM — REST API (v1) ───────────────────────────────────────────────
  # Fundamental monitoring primitives: agent lifecycle, sessions, notifications,
  # health, telemetry, ports, background tasks, project scanner, actions.

  scope "/api", ApmV5Web do
    pipe_through :api

    # Agent lifecycle
    get "/status", ApiController, :status
    get "/agents", ApiController, :agents
    post "/register", ApiController, :register
    post "/heartbeat", ApiController, :heartbeat
    post "/notify", ApiController, :notify
    get "/agents/activity-log", ApiController, :activity_log
    get "/agents/discover", ApiController, :discover_agents
    post "/agents/register", ApiController, :register
    post "/agents/update", ApiController, :update_agent

    # Notifications
    get "/notifications", ApiController, :notifications
    get "/notifications/:id", ApiController, :get_notification
    post "/notifications/add", ApiController, :add_notification
    post "/notifications/read-all", ApiController, :read_all_notifications

    # Sessions & data
    get "/data", ApiController, :data

    # Ralph
    get "/ralph", ApiController, :ralph
    get "/ralph/flowchart", ApiController, :ralph_flowchart

    # Commands
    get "/commands", ApiController, :commands
    post "/commands", ApiController, :register_commands

    # Tasks / input
    post "/tasks/sync", ApiController, :sync_tasks
    get "/input/pending", ApiController, :pending_input
    post "/input/request", ApiController, :request_input
    post "/input/respond", ApiController, :respond_input

    # Projects & config
    get "/projects", ApiController, :projects
    patch "/projects", ApiController, :update_project
    post "/config/reload", ApiController, :reload_config
    post "/reload", ApiController, :reload_config
    post "/plane/update", ApiController, :update_plane

    # Export / import
    get "/v2/export", ApiController, :export
    post "/v2/import", ApiController, :import_data

    # Ports
    get "/ports", ApiController, :ports
    post "/ports/scan", ApiController, :scan_ports
    post "/ports/assign", ApiController, :assign_port
    get "/ports/clashes", ApiController, :port_clashes
    post "/ports/set-primary", ApiController, :set_primary_port

    # CCEM environments
    get "/environments", ApiController, :environments
    get "/environments/:name", ApiController, :environment_detail
    post "/environments/:name/exec", ApiController, :exec_command
    post "/environments/:name/session/start", ApiController, :start_session
    post "/environments/:name/session/stop", ApiController, :stop_session

    # Hook deployment
    post "/hooks/deploy", ApiController, :deploy_hooks

    # Background tasks (/bg-tasks canonical)
    get "/bg-tasks", ApiController, :list_bg_tasks
    post "/bg-tasks", ApiController, :register_bg_task
    get "/bg-tasks/:id", ApiController, :get_bg_task
    get "/bg-tasks/:id/logs", ApiController, :get_bg_task_logs
    patch "/bg-tasks/:id", ApiController, :update_bg_task
    post "/bg-tasks/:id/stop", ApiController, :stop_bg_task
    delete "/bg-tasks/:id", ApiController, :delete_bg_task

    # Background tasks (/tasks alias)
    get "/tasks", ApiController, :list_bg_tasks
    post "/tasks", ApiController, :register_bg_task
    get "/tasks/:id", ApiController, :get_bg_task
    get "/tasks/:id/logs", ApiController, :get_bg_task_logs
    patch "/tasks/:id", ApiController, :update_bg_task
    post "/tasks/:id/stop", ApiController, :stop_bg_task
    delete "/tasks/:id", ApiController, :delete_bg_task

    # Project scanner
    post "/scanner/scan", ApiController, :scanner_scan
    get "/scanner/results", ApiController, :scanner_results
    get "/scanner/status", ApiController, :scanner_status

    # Actions
    get "/actions", ApiController, :list_actions
    post "/actions/run", ApiController, :run_action
    get "/actions/runs", ApiController, :list_action_runs
    get "/actions/runs/:id", ApiController, :get_action_run

    # Telemetry
    get "/telemetry", ApiController, :telemetry

    # Intake
    post "/intake", ApiController, :intake_submit
    get "/intake", ApiController, :intake_list
    get "/intake/watchers", ApiController, :intake_watchers

    # OpenAPI spec alias (v1-friendly URL)
    get "/openapi.json", V2.ApiV2Controller, :openapi

    # ── EXTENSION: skills (v1) ─────────────────────────────────────────────
    get "/skills", ApiController, :skills
    post "/skills/track", ApiController, :track_skill
    get "/skills/registry", SkillsController, :registry
    post "/skills/audit", SkillsController, :audit
    get "/skills/:name/health", SkillsController, :health
    get "/skills/:name", SkillsController, :show

    # ── EXTENSION: upm (v1) ───────────────────────────────────────────────
    # UPM execution tracking
    post "/upm/register", UpmApiController, :upm_register
    post "/upm/agent", UpmApiController, :upm_agent
    post "/upm/event", UpmApiController, :upm_event
    get "/upm/status", UpmApiController, :upm_status

    # UPM module CRUD
    get "/upm/projects", UpmController, :list_projects
    post "/upm/projects", UpmController, :create_project
    post "/upm/projects/scan", UpmController, :scan_projects
    get "/upm/projects/:id", UpmController, :get_project
    put "/upm/projects/:id", UpmController, :update_project
    delete "/upm/projects/:id", UpmController, :delete_project
    get "/upm/pm_integrations", UpmController, :list_pm_integrations
    post "/upm/pm_integrations", UpmController, :create_pm_integration
    get "/upm/pm_integrations/:id", UpmController, :get_pm_integration
    put "/upm/pm_integrations/:id", UpmController, :update_pm_integration
    delete "/upm/pm_integrations/:id", UpmController, :delete_pm_integration
    post "/upm/pm_integrations/:id/test", UpmController, :test_pm_integration
    get "/upm/vcs_integrations", UpmController, :list_vcs_integrations
    post "/upm/vcs_integrations", UpmController, :create_vcs_integration
    get "/upm/vcs_integrations/:id", UpmController, :get_vcs_integration
    put "/upm/vcs_integrations/:id", UpmController, :update_vcs_integration
    delete "/upm/vcs_integrations/:id", UpmController, :delete_vcs_integration
    post "/upm/vcs_integrations/:id/test", UpmController, :test_vcs_integration
    get "/upm/work_items", UpmController, :list_work_items
    get "/upm/work_items/drift", UpmController, :drift_report
    post "/upm/sync", UpmController, :sync_all
    post "/upm/sync/:project_id", UpmController, :sync_project
    get "/upm/sync/status", UpmController, :sync_status

    # ── EXTENSION: formations (v1) ────────────────────────────────────────
    get "/formations", FormationApiController, :list_formations
    post "/formations", FormationApiController, :create_formation
    get "/formations/:id", FormationApiController, :get_formation
    patch "/formations/:id", FormationApiController, :update_formation
    get "/formations/:id/agents", FormationApiController, :get_formation_agents

    # ── EXTENSION: showcase (v1) ──────────────────────────────────────────
    get "/showcase", ShowcaseApiController, :index
    get "/showcase/:project", ShowcaseApiController, :show
    post "/showcase/:project/reload", ShowcaseApiController, :reload

    # ── EXTENSION: ag_ui (v1) ─────────────────────────────────────────────
    get "/ag-ui/events", AgUiController, :events

    # ── EXTENSION: worktrees (v1) ─────────────────────────────────────────
    get "/worktrees", V2.WorktreeController, :index
    post "/worktrees/register", V2.WorktreeController, :register
    get "/worktrees/:id", V2.WorktreeController, :show
    patch "/worktrees/:id", V2.WorktreeController, :update
    delete "/worktrees/:id", V2.WorktreeController, :delete

    # ── EXTENSION: usage (v1) ─────────────────────────────────────────────
    get "/usage", UsageController, :index
    get "/usage/summary", UsageController, :summary
    get "/usage/project/:name", UsageController, :project
    post "/usage/record", UsageController, :record
    get "/usage/limits", UsageController, :limits
    delete "/usage/project/:name", UsageController, :reset
  end

  # ── CORE APM — REST API (v2) ───────────────────────────────────────────────

  scope "/api/v2", ApmV5Web.V2 do
    pipe_through :api

    # Core: agents, sessions, metrics, SLOs, alerts, audit
    get "/agents", ApiV2Controller, :list_agents
    get "/agents/:id", ApiV2Controller, :get_agent
    get "/sessions", ApiV2Controller, :list_sessions
    get "/metrics", ApiV2Controller, :fleet_metrics
    get "/metrics/:agent_id", ApiV2Controller, :agent_metrics
    get "/slos", ApiV2Controller, :list_slos
    get "/slos/:name", ApiV2Controller, :get_slo
    get "/alerts", ApiV2Controller, :list_alerts
    get "/alerts/rules", ApiV2Controller, :list_alert_rules
    post "/alerts/rules", ApiV2Controller, :create_alert_rule
    get "/audit", ApiV2Controller, :list_audit
    get "/openapi.json", ApiV2Controller, :openapi

    # Core: manifest (this endpoint — API architecture overview)
    get "/manifest", ApiV2Controller, :manifest

    # Core: workflows
    get "/workflows", ApiV2Controller, :list_workflows
    post "/workflows", ApiV2Controller, :create_workflow
    get "/workflows/:id", ApiV2Controller, :get_workflow
    patch "/workflows/:id", ApiV2Controller, :update_workflow

    # Core: formations (v2 — mirrors v1 formations)
    get "/formations", ApiV2Controller, :list_formations
    post "/formations", ApiV2Controller, :create_formation
    get "/formations/:id", ApiV2Controller, :get_formation
    get "/formations/:id/agents", ApiV2Controller, :get_formation_agents

    # Core: verification
    post "/verify/double", ApiV2Controller, :verify_double
    get "/verify/:id", ApiV2Controller, :verify_status

    # Core: agent control
    post "/agents/:id/control", AgentControlController, :control_agent
    get "/agents/:id/messages", AgentControlController, :list_messages
    post "/agents/:id/messages", AgentControlController, :send_message
    post "/formations/:id/control", AgentControlController, :control_formation
    post "/squadrons/:id/control", AgentControlController, :control_squadron

    # Core: tool calls
    get "/tool-calls", ToolCallController, :index
    get "/tool-calls/stats", ToolCallController, :stats
    get "/tool-calls/stream", ToolCallController, :stream
    get "/tool-calls/agent/:agent_id", ToolCallController, :by_agent
    get "/tool-calls/:id", ToolCallController, :show

    # Core: chat
    get "/chat/:scope", ChatController, :index
    post "/chat/:scope/send", ChatController, :send_message
    delete "/chat/:scope", ChatController, :clear

    # Core: A2A messaging
    post "/a2a/send", A2AController, :send_message
    get "/a2a/messages/:agent_id", A2AController, :messages
    post "/a2a/ack", A2AController, :ack
    get "/a2a/stats", A2AController, :stats
    get "/a2a/history/:agent_id", A2AController, :history
    post "/a2a/broadcast", A2AController, :broadcast_message
    post "/a2a/fan-out", A2AController, :fan_out
    get "/a2a/stream/:agent_id", A2AController, :stream

    # Core: approvals
    get "/approvals", ApprovalController, :index
    get "/approvals/:id", ApprovalController, :show
    post "/approvals/request", ApprovalController, :request
    post "/approvals/:id/approve", ApprovalController, :approve
    post "/approvals/:id/reject", ApprovalController, :reject

    # Core: notifications test
    post "/notifications/test", AuthController, :test_notification

    # ── EXTENSION: ag_ui (v2) ─────────────────────────────────────────────
    post "/ag-ui/emit", AgUiV2Controller, :emit
    post "/ag-ui/tool", AgUiV2Controller, :tool_call
    get "/ag-ui/events", AgUiV2Controller, :stream_events
    get "/ag-ui/events/:agent_id", AgUiV2Controller, :stream_agent_events
    get "/ag-ui/state/:agent_id", AgUiV2Controller, :get_state
    put "/ag-ui/state/:agent_id", AgUiV2Controller, :set_state
    patch "/ag-ui/state/:agent_id", AgUiV2Controller, :patch_state
    get "/ag-ui/router/stats", AgUiV2Controller, :router_stats
    get "/ag-ui/diagnostics", AgUiDiagnosticsController, :diagnostics
    get "/ag-ui/migration", MigrationController, :migration_status

    # Extension: agent context (ag_ui companion)
    get "/agents/contexts", AgentContextController, :index
    get "/agents/:id/context", AgentContextController, :show
    get "/agents/:id/context/events", AgentContextController, :events

    # Extension: generative UI (ag_ui companion)
    get "/generative-ui/components", GenerativeUIController, :index
    post "/generative-ui/components", GenerativeUIController, :create
    get "/generative-ui/components/:id", GenerativeUIController, :show
    put "/generative-ui/components/:id", GenerativeUIController, :update
    delete "/generative-ui/components/:id", GenerativeUIController, :delete

    # ── EXTENSION: agentlock ──────────────────────────────────────────────
    post "/auth/authorize", AuthController, :authorize
    post "/auth/execute", AuthController, :execute
    get "/auth/summary", AuthController, :summary
    get "/auth/tools", AuthController, :list_tools
    post "/auth/tools", AuthController, :register_tool
    post "/auth/sessions", AuthController, :create_session
    get "/auth/sessions", AuthController, :list_sessions
    get "/auth/sessions/:id", AuthController, :get_session
    delete "/auth/sessions/:id", AuthController, :destroy_session
    get "/auth/tokens/:id", AuthController, :get_token
    post "/auth/tokens/:id/revoke", AuthController, :revoke_token
    post "/auth/context/write", AuthController, :record_context
    get "/auth/context/trust", AuthController, :get_trust
    post "/auth/memory/authorize-write", AuthController, :authorize_memory_write
    post "/auth/memory/authorize-read", AuthController, :authorize_memory_read
    get "/auth/rate-limits", AuthController, :rate_limits
    post "/auth/redact", AuthController, :redact
    get "/auth/audit", AuthController, :audit_log
    get "/auth/pending", AuthController, :list_pending
    get "/auth/pending/:id", AuthController, :get_pending
    get "/auth/decide", AuthController, :decide_get
    post "/auth/decide", AuthController, :decide
    # API key management (US-047)
    get "/auth/api-keys", AuthController, :list_api_keys
    post "/auth/api-keys", AuthController, :create_api_key
    delete "/auth/api-keys/:id", AuthController, :revoke_api_key

    # Approval audit history (US-326)
    post "/approvals/log", AuthController, :log_approval
    get "/approvals/history", AuthController, :list_approval_history

    get "/auth/policy/rules", AuthController, :list_policy_rules
    post "/auth/policy/rules", AuthController, :add_policy_rule
    delete "/auth/policy/rules/:tool_name", AuthController, :remove_policy_rule

    # Auto-approval policies (hierarchical scope matching)
    get "/auth/auto-approval-policies", AutoApprovalController, :index
    post "/auth/auto-approval-policies", AutoApprovalController, :create
    get "/auth/auto-approval-policies/:id", AutoApprovalController, :show
    patch "/auth/auto-approval-policies/:id", AutoApprovalController, :update
    delete "/auth/auto-approval-policies/:id", AutoApprovalController, :delete
    post "/auth/auto-approval-policies/test-match", AutoApprovalController, :test_match

    # ── EXTENSION: upm (v2) ───────────────────────────────────────────────
    post "/upm/gate", UpmDecisionController, :create
    get "/upm/gates", UpmDecisionController, :index
    get "/upm/gate/:id", UpmDecisionController, :show
    post "/upm/gate/:id/approve", UpmDecisionController, :approve
    post "/upm/gate/:id/reject", UpmDecisionController, :reject

    # ── EXTENSION: plugins ────────────────────────────────────────────────
    get "/plugins", PluginController, :index
    post "/plugins/reload", PluginController, :reload

    # CC bridge (read-only) — MUST be before /:name catch-all
    get "/plugins/cc/plugins", PluginController, :cc_plugins
    get "/plugins/cc/summary", PluginController, :cc_summary

    # Repository management
    get "/plugins/repositories", RepositoryController, :index
    post "/plugins/repositories", RepositoryController, :create
    get "/plugins/repositories/:name", RepositoryController, :show
    patch "/plugins/repositories/:name", RepositoryController, :update
    delete "/plugins/repositories/:name", RepositoryController, :delete

    # Plugin CRUD (catch-all /:name routes MUST be last)
    get "/plugins/:name", PluginController, :show
    post "/plugins/:name/action", PluginController, :invoke_action
    get "/plugins/:name/board", PluginController, :board
    get "/plugins/:name/issues", PluginController, :issues

    # ── EXTENSION: integrations ───────────────────────────────────────────
    get "/integrations", IntegrationController, :index
    post "/integrations/reload", IntegrationController, :reload
    get "/integrations/:name", IntegrationController, :show
    post "/integrations/:name/action", IntegrationController, :invoke_action
    get "/integrations/:name/status", IntegrationController, :status

    # ── EXTENSION: coalesce ───────────────────────────────────────────────
    post "/coalesce/start", CoalesceController, :start
    post "/coalesce/preview", CoalesceController, :preview
    get "/coalesce", CoalesceController, :index
    get "/coalesce/:id", CoalesceController, :show
    get "/coalesce/:id/diff", CoalesceController, :diff
    post "/coalesce/:id/gate/:gate_id/decide", CoalesceController, :gate_decide
    post "/coalesce/:id/apply", CoalesceController, :apply_run
    delete "/coalesce/:id", CoalesceController, :cancel

    # ── EXTENSION: plane (upm companion) ──────────────────────────────────
    get "/plane/sync-status", PlaneController, :sync_status
    post "/plane/sync", PlaneController, :sync

    # ── EXTENSION: widgetization engine ──────────────────────────────────
    get "/widgets", WidgetController, :index
    get "/widgets/:id", WidgetController, :show
    patch "/widgets/:id/config", WidgetController, :update_config
    get "/dashboard/layout", WidgetController, :get_layout
    post "/dashboard/layout", WidgetController, :save_layout
    post "/dashboard/pin", WidgetController, :pin_widget

    # ── EXTENSION: skill drift detector ──────────────────────────────────
    get "/skill-drift/scan", SkillDriftController, :scan
    get "/skill-drift/report", SkillDriftController, :report
    post "/skill-drift/fix", SkillDriftController, :fix

    # ── EXTENSION: library ────────────────────────────────────────────────
    get "/library", LibraryController, :index
    get "/library/agents", LibraryController, :agents
    get "/library/skills", LibraryController, :skills
    get "/library/commands", LibraryController, :commands
    get "/library/mcp", LibraryController, :mcp
    get "/library/tools", LibraryController, :tools
    get "/library/hooks", LibraryController, :hooks
    get "/library/patterns", LibraryController, :patterns
    get "/library/learnings", LibraryController, :learnings
    get "/library/graph", LibraryController, :graph
    post "/library/refresh", LibraryController, :refresh
  end

  # A2UI flexible format endpoint
  scope "/api", ApmV5Web do
    pipe_through :api_flexible

    get "/a2ui/components", A2uiController, :components
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:apm_v5, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ApmV5Web.Telemetry
    end
  end

  # ── CATCH-ALL (must be last) ───────────────────────────────────────────────
  # Serves a clean 404 page for any unrecognised GET so users never see the
  # Phoenix debug error page (which can crash in dev when CodeReloader.Server
  # is unavailable).
  scope "/", ApmV5Web do
    pipe_through :browser
    get "/*path", PageController, :not_found
  end
end
