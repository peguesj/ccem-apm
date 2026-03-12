defmodule ApmV5Web.Router do
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

  # Browser routes
  scope "/", ApmV5Web do
    pipe_through :browser

    # Scalar API Reference (interactive OpenAPI docs)
    get "/api/docs", PageController, :api_docs

    live "/", DashboardLive, :index
    live "/apm-all", AllProjectsLive, :index
    live "/ralph", RalphFlowchartLive, :index
    live "/workflow/:type", WorkflowLive, :show
    live "/skills", SkillsLive, :index
    live "/timeline", SessionTimelineLive, :index
    live "/docs", DocsLive, :index
    live "/docs/*path", DocsLive, :show
    live "/formation", FormationLive, :index
    live "/notifications", NotificationLive, :index
    live "/ports", PortsLive, :index
    live "/tasks", TasksLive, :index
    live "/scanner", ScannerLive, :index
    live "/actions", ActionsLive, :index
    live "/analytics", AnalyticsLive, :index
    live "/health", HealthCheckLive, :index
    live "/conversations", ConversationMonitorLive, :index
    live "/plugins", PluginDashboardLive, :index
    live "/backfill", BackfillLive, :index
    live "/drtw", DrtwLive, :index
    live "/ag-ui", AgUiLive, :index
    live "/intake", IntakeLive, :index

    # /upm redirects to workflow UPM view
    get "/upm", PageController, :upm_redirect
  end

  # v3-compatible health check (JSON) — served under /api scope instead
  # to avoid conflict with HealthCheckLive at /health in browser scope.

  # REST API
  scope "/api", ApmV5Web do
    pipe_through :api

    # Existing v4 endpoints (keep)
    get "/status", ApiController, :status
    get "/agents", ApiController, :agents
    post "/register", ApiController, :register
    post "/heartbeat", ApiController, :heartbeat
    post "/notify", ApiController, :notify

    # AG-UI SSE endpoint
    get "/ag-ui/events", AgUiController, :events

    # v3-compatible endpoints (new)
    get "/data", ApiController, :data
    get "/notifications", ApiController, :notifications
    post "/notifications/add", ApiController, :add_notification
    post "/notifications/read-all", ApiController, :read_all_notifications
    get "/ralph", ApiController, :ralph
    get "/ralph/flowchart", ApiController, :ralph_flowchart
    get "/commands", ApiController, :commands
    post "/commands", ApiController, :register_commands
    get "/agents/discover", ApiController, :discover_agents
    post "/agents/register", ApiController, :register
    post "/agents/update", ApiController, :update_agent
    get "/input/pending", ApiController, :pending_input
    post "/input/request", ApiController, :request_input
    post "/input/respond", ApiController, :respond_input
    post "/tasks/sync", ApiController, :sync_tasks
    post "/config/reload", ApiController, :reload_config
    post "/reload", ApiController, :reload_config
    post "/plane/update", ApiController, :update_plane

    # Skills tracking
    get "/skills", ApiController, :skills
    post "/skills/track", ApiController, :track_skill

    # Skills registry (US-004)
    get "/skills/registry", SkillsController, :registry
    post "/skills/audit", SkillsController, :audit
    get "/skills/:name/health", SkillsController, :health
    get "/skills/:name", SkillsController, :show

    # v4-only endpoints
    get "/projects", ApiController, :projects
    patch "/projects", ApiController, :update_project

    # v2 export/import
    get "/v2/export", ApiController, :export
    post "/v2/import", ApiController, :import_data

    # UPM execution tracking
    post "/upm/register", ApiController, :upm_register
    post "/upm/agent", ApiController, :upm_agent
    post "/upm/event", ApiController, :upm_event
    get "/upm/status", ApiController, :upm_status

    # Port management
    get "/ports", ApiController, :ports
    post "/ports/scan", ApiController, :scan_ports
    post "/ports/assign", ApiController, :assign_port
    get "/ports/clashes", ApiController, :port_clashes
    post "/ports/set-primary", ApiController, :set_primary_port

    # CCEM environment manager endpoints
    get "/environments", ApiController, :environments
    get "/environments/:name", ApiController, :environment_detail
    post "/environments/:name/exec", ApiController, :exec_command
    post "/environments/:name/session/start", ApiController, :start_session
    post "/environments/:name/session/stop", ApiController, :stop_session

    # OpenAPI spec alias (v1-friendly URL, same as /api/v2/openapi.json)
    get "/openapi.json", V2.ApiV2Controller, :openapi

    # Hook deployment
    post "/hooks/deploy", ApiController, :deploy_hooks

    # Background tasks (US-005 enhanced)
    get "/bg-tasks", ApiController, :list_bg_tasks
    post "/bg-tasks", ApiController, :register_bg_task
    get "/bg-tasks/:id", ApiController, :get_bg_task
    get "/bg-tasks/:id/logs", ApiController, :get_bg_task_logs
    patch "/bg-tasks/:id", ApiController, :update_bg_task
    post "/bg-tasks/:id/stop", ApiController, :stop_bg_task
    delete "/bg-tasks/:id", ApiController, :delete_bg_task

    # Background tasks — /tasks alias (acceptance criteria uses /tasks/:id)
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

    # Agent telemetry (time-bucketed)
    get "/telemetry", ApiController, :telemetry

    # Intake event pipeline
    post "/intake", ApiController, :intake_submit
    get "/intake", ApiController, :intake_list
    get "/intake/watchers", ApiController, :intake_watchers

  end

  # v2 REST API (Phase 3.1)
  scope "/api/v2", ApmV5Web.V2 do
    pipe_through :api

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

    # Workflows (WorkflowSchemaStore)
    get "/workflows", ApiV2Controller, :list_workflows
    post "/workflows", ApiV2Controller, :create_workflow
    get "/workflows/:id", ApiV2Controller, :get_workflow
    patch "/workflows/:id", ApiV2Controller, :update_workflow

    # Formations (UpmStore)
    get "/formations", ApiV2Controller, :list_formations
    post "/formations", ApiV2Controller, :create_formation
    get "/formations/:id", ApiV2Controller, :get_formation
    get "/formations/:id/agents", ApiV2Controller, :get_formation_agents

    # Verification (VerifyStore)
    post "/verify/double", ApiV2Controller, :verify_double
    get "/verify/:id", ApiV2Controller, :verify_status

    # AG-UI Protocol (v5)
    post "/ag-ui/emit", AgUiV2Controller, :emit
    get "/ag-ui/events", AgUiV2Controller, :stream_events
    get "/ag-ui/events/:agent_id", AgUiV2Controller, :stream_agent_events
    get "/ag-ui/state/:agent_id", AgUiV2Controller, :get_state
    put "/ag-ui/state/:agent_id", AgUiV2Controller, :set_state
    patch "/ag-ui/state/:agent_id", AgUiV2Controller, :patch_state
    get "/ag-ui/router/stats", AgUiV2Controller, :router_stats

    # Chat (ChatStore)
    get "/chat/:scope", ChatController, :index
    post "/chat/:scope/send", ChatController, :send_message
    delete "/chat/:scope", ChatController, :clear

    # Agent control (US-012)
    post "/agents/:id/control", AgentControlController, :control_agent
    get "/agents/:id/messages", AgentControlController, :list_messages
    post "/agents/:id/messages", AgentControlController, :send_message
    post "/formations/:id/control", AgentControlController, :control_formation
    post "/squadrons/:id/control", AgentControlController, :control_squadron
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
end
