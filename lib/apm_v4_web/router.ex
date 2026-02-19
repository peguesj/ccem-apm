defmodule ApmV4Web.Router do
  use ApmV4Web, :router

  pipeline :browser do
    plug ApmV4Web.Plugs.CorrelationId
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ApmV4Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug ApmV4Web.Plugs.CorrelationId
    plug :accepts, ["json"]
    plug ApmV4Web.Plugs.CORS
    plug ApmV4Web.Plugs.ApiAuth
  end

  pipeline :api_flexible do
    plug :accepts, ["json", "jsonl"]
    plug ApmV4Web.Plugs.CORS
  end

  # Browser routes
  scope "/", ApmV4Web do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/apm-all", AllProjectsLive, :index
    live "/ralph", RalphFlowchartLive, :index
    live "/skills", SkillsLive, :index
    live "/timeline", SessionTimelineLive, :index
    live "/docs", DocsLive, :index
    live "/docs/*path", DocsLive, :show
    live "/ports", PortsLive, :index
  end

  # v3-compatible health check (outside /api scope)
  scope "/", ApmV4Web do
    pipe_through :api
    get "/health", ApiController, :health
  end

  # REST API
  scope "/api", ApmV4Web do
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

    # CCEM environment manager endpoints
    get "/environments", ApiController, :environments
    get "/environments/:name", ApiController, :environment_detail
    post "/environments/:name/exec", ApiController, :exec_command
    post "/environments/:name/session/start", ApiController, :start_session
    post "/environments/:name/session/stop", ApiController, :stop_session
  end

  # v2 REST API (Phase 3.1)
  scope "/api/v2", ApmV4Web.V2 do
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
  end

  # A2UI flexible format endpoint
  scope "/api", ApmV4Web do
    pipe_through :api_flexible

    get "/a2ui/components", A2uiController, :components
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:apm_v4, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ApmV4Web.Telemetry
    end
  end
end
