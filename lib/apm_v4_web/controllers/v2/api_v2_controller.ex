defmodule ApmV4Web.V2.ApiV2Controller do
  @moduledoc """
  v2 REST API with standardized envelope responses and cursor-based pagination.
  Phase 3.1 of CCEM APM v5.
  """

  use ApmV4Web, :controller

  alias ApmV4.AgentRegistry
  alias ApmV4.MetricsCollector
  alias ApmV4.SloEngine
  alias ApmV4.AlertRulesEngine
  alias ApmV4.AuditLog
  alias ApmV4.WorkflowSchemaStore
  alias ApmV4.UpmStore
  alias ApmV4Web.V2.ApiV2JSON

  # ========== Agents ==========

  @doc "GET /api/v2/agents - list agents with cursor pagination"
  def list_agents(conn, params) do
    limit = ApiV2JSON.parse_limit(params)
    cursor = ApiV2JSON.decode_cursor(params["cursor"])

    agents =
      AgentRegistry.list_agents()
      |> Enum.sort_by(& &1.registered_at, :desc)

    {page, next_cursor, has_more} =
      ApiV2JSON.paginate(agents, cursor, limit, :id, :registered_at)

    meta = %{total: length(agents), cursor: next_cursor, has_more: has_more}
    links = if next_cursor, do: %{next: "/api/v2/agents?cursor=#{next_cursor}&limit=#{limit}"}, else: %{}

    json(conn, ApiV2JSON.envelope(page, meta, links))
  end

  @doc "GET /api/v2/agents/:id - single agent detail with metrics + health"
  def get_agent(conn, %{"id" => agent_id}) do
    case AgentRegistry.get_agent(agent_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(ApiV2JSON.error_response("not_found", "Agent not found"))

      agent ->
        health_score = MetricsCollector.compute_health_score(agent_id)
        metrics = MetricsCollector.get_agent_metrics(agent_id, limit: 10)

        data = Map.merge(agent, %{health_score: health_score, recent_metrics: metrics})
        json(conn, ApiV2JSON.envelope(data))
    end
  end

  # ========== Sessions ==========

  @doc "GET /api/v2/sessions - list sessions with cursor pagination"
  def list_sessions(conn, params) do
    limit = ApiV2JSON.parse_limit(params)
    cursor = ApiV2JSON.decode_cursor(params["cursor"])

    sessions =
      AgentRegistry.list_sessions()
      |> Enum.sort_by(& &1.registered_at, :desc)

    {page, next_cursor, has_more} =
      ApiV2JSON.paginate(sessions, cursor, limit, :session_id, :registered_at)

    meta = %{total: length(sessions), cursor: next_cursor, has_more: has_more}
    links = if next_cursor, do: %{next: "/api/v2/sessions?cursor=#{next_cursor}&limit=#{limit}"}, else: %{}

    json(conn, ApiV2JSON.envelope(page, meta, links))
  end

  # ========== Metrics ==========

  @doc "GET /api/v2/metrics - fleet metrics summary"
  def fleet_metrics(conn, _params) do
    metrics = MetricsCollector.get_fleet_metrics()
    json(conn, ApiV2JSON.envelope(metrics))
  end

  @doc "GET /api/v2/metrics/:agent_id - per-agent metrics with since param"
  def agent_metrics(conn, %{"agent_id" => agent_id} = params) do
    opts =
      case params["since"] do
        nil ->
          []

        since_str ->
          case DateTime.from_iso8601(since_str) do
            {:ok, dt, _} -> [since: dt]
            _ -> []
          end
      end

    metrics = MetricsCollector.get_agent_metrics(agent_id, opts)
    json(conn, ApiV2JSON.envelope(metrics, %{total: length(metrics)}))
  end

  # ========== SLOs ==========

  @doc "GET /api/v2/slos - all SLIs with error budgets"
  def list_slos(conn, _params) do
    slis = SloEngine.get_all_slis()

    data =
      Enum.map(slis, fn sli ->
        budget = SloEngine.get_error_budget(sli.name)

        sli
        |> Map.drop([:recent_events])
        |> Map.put(:error_budget, budget)
      end)

    json(conn, ApiV2JSON.envelope(data, %{total: length(data)}))
  end

  @doc "GET /api/v2/slos/:name - single SLI with history"
  def get_slo(conn, %{"name" => name_str}) do
    name = safe_to_existing_atom(name_str)

    case name && SloEngine.get_sli(name) do
      nil ->
        conn
        |> put_status(404)
        |> json(ApiV2JSON.error_response("not_found", "SLI not found"))

      sli ->
        budget = SloEngine.get_error_budget(name)
        history = SloEngine.get_history(name)

        data =
          sli
          |> Map.drop([:recent_events])
          |> Map.merge(%{error_budget: budget, history: history})

        json(conn, ApiV2JSON.envelope(data))
    end
  end

  # ========== Alerts ==========

  @doc "GET /api/v2/alerts - alert history with cursor pagination and filters"
  def list_alerts(conn, params) do
    limit = ApiV2JSON.parse_limit(params)

    opts = [limit: 1000]
    opts = if params["severity"], do: Keyword.put(opts, :severity, parse_severity(params["severity"])), else: opts
    opts = if params["rule_id"], do: Keyword.put(opts, :rule_id, params["rule_id"]), else: opts

    alerts =
      AlertRulesEngine.get_alert_history(opts)
      |> Enum.map(fn alert ->
        Map.update(alert, :fired_at, nil, fn
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          other -> other
        end)
      end)

    # Simple offset pagination for alerts (they use monotonic keys, not stable IDs for cursor)
    page = Enum.take(alerts, limit)
    has_more = length(alerts) > limit

    meta = %{total: length(alerts), has_more: has_more}
    json(conn, ApiV2JSON.envelope(page, meta))
  end

  @doc "GET /api/v2/alerts/rules - list alert rules"
  def list_alert_rules(conn, _params) do
    rules = AlertRulesEngine.list_rules()
    json(conn, ApiV2JSON.envelope(rules, %{total: length(rules)}))
  end

  @doc "POST /api/v2/alerts/rules - create alert rule"
  def create_alert_rule(conn, params) do
    rule_params = %{
      name: params["name"] || "unnamed",
      metric: params["metric"] || "",
      scope: parse_scope(params["scope"]),
      aggregation: safe_to_existing_atom(params["aggregation"]) || :avg,
      threshold: params["threshold"] || 0,
      comparator: safe_to_existing_atom(params["comparator"]) || :gt,
      window_s: params["window_s"] || 300,
      consecutive_breaches: params["consecutive_breaches"] || 1,
      severity: parse_severity(params["severity"]),
      enabled: Map.get(params, "enabled", true),
      channels: params["channels"] || ["pubsub"]
    }

    {:ok, rule_id} = AlertRulesEngine.add_rule(rule_params)

    conn
    |> put_status(201)
    |> json(ApiV2JSON.envelope(%{id: rule_id}, %{created: true}))
  end

  # ========== Audit ==========

  @doc "GET /api/v2/audit - audit log with cursor pagination and filters"
  def list_audit(conn, params) do
    limit = ApiV2JSON.parse_limit(params)

    opts = [limit: limit]
    opts = if params["event_type"], do: Keyword.put(opts, :event_type, params["event_type"]), else: opts
    opts = if params["actor"], do: Keyword.put(opts, :actor, params["actor"]), else: opts
    opts = if params["since"], do: Keyword.put(opts, :since, params["since"]), else: opts

    events = AuditLog.query(opts)

    meta = %{total: length(events), has_more: length(events) >= limit}
    json(conn, ApiV2JSON.envelope(events, meta))
  end

  # ========== OpenAPI ==========

  @doc "GET /api/v2/openapi.json - OpenAPI 3.0.3 spec (full coverage)"
  def openapi(conn, _params) do
    json(conn, build_spec())
  end

  defp build_spec do
    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "CCEM APM v4 API",
        "version" => "4.0.0",
        "description" => "Complete REST API for CCEM Agent Performance Monitor. Also available at /api/openapi.json."
      },
      "servers" => [%{"url" => "http://localhost:3031", "description" => "Local APM server"}],
      "tags" => [
        %{"name" => "Health", "description" => "Server health and status"},
        %{"name" => "Agents", "description" => "Agent registration and management"},
        %{"name" => "Sessions", "description" => "Session tracking"},
        %{"name" => "Notifications", "description" => "Notification management"},
        %{"name" => "Data", "description" => "Aggregated data and master state"},
        %{"name" => "Ralph", "description" => "Ralph methodology integration"},
        %{"name" => "Commands", "description" => "Slash command registry"},
        %{"name" => "Tasks", "description" => "Task synchronization and input"},
        %{"name" => "Skills", "description" => "Skill invocation tracking"},
        %{"name" => "UPM", "description" => "Unified Project Management execution"},
        %{"name" => "Ports", "description" => "Port registry and clash detection"},
        %{"name" => "Environments", "description" => "CCEM environment management"},
        %{"name" => "Config", "description" => "Server configuration"},
        %{"name" => "Projects", "description" => "Multi-project management"},
        %{"name" => "AG-UI", "description" => "AG-UI SSE event stream"},
        %{"name" => "A2UI", "description" => "A2UI declarative component specs"},
        %{"name" => "Metrics", "description" => "Performance metrics (v2)"},
        %{"name" => "SLOs", "description" => "Service Level Objectives (v2)"},
        %{"name" => "Alerts", "description" => "Alert rules and history (v2)"},
        %{"name" => "Audit", "description" => "Audit log (v2)"},
        %{"name" => "Export", "description" => "Data export and import (v2)"}
      ],
      "paths" => build_paths(),
      "components" => %{
        "schemas" => build_schemas(),
        "parameters" => build_parameters()
      }
    }
  end

  defp build_paths do
    Map.merge(build_v1_paths(), build_v2_paths())
  end

  defp build_v1_paths do
    %{
      "/health" => %{
        "get" => %{"operationId" => "healthCheck", "summary" => "Server health check", "tags" => ["Health"],
          "responses" => %{"200" => %{"description" => "Server is healthy",
            "content" => %{"application/json" => %{"schema" => %{"type" => "object",
              "properties" => %{"status" => %{"type" => "string"}, "timestamp" => %{"type" => "string", "format" => "date-time"}}}}}}}}
      },
      "/api/status" => %{
        "get" => %{"operationId" => "getStatus", "summary" => "APM server status", "tags" => ["Health"],
          "responses" => %{"200" => %{"description" => "Status info"}}}
      },
      "/api/agents" => %{
        "get" => %{"operationId" => "listAgents", "summary" => "List all agents", "tags" => ["Agents"],
          "parameters" => [%{"$ref" => "#/components/parameters/ProjectParam"}],
          "responses" => %{"200" => %{"description" => "Agent list",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Agent"}}}}}}}
      },
      "/api/register" => %{
        "post" => %{"operationId" => "registerAgent", "summary" => "Register an agent", "tags" => ["Agents"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["agent_id"],
            "properties" => %{"agent_id" => %{"type" => "string"}, "project" => %{"type" => "string"},
              "role" => %{"type" => "string"}, "status" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Registered"}, "400" => %{"$ref" => "#/components/schemas/Error"}}}
      },
      "/api/heartbeat" => %{
        "post" => %{"operationId" => "sendHeartbeat", "summary" => "Update agent heartbeat", "tags" => ["Agents"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["agent_id"],
            "properties" => %{"agent_id" => %{"type" => "string"}, "status" => %{"type" => "string"},
              "message" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Heartbeat recorded"}}}
      },
      "/api/agents/register" => %{
        "post" => %{"operationId" => "registerAgentV3", "summary" => "Register agent (v3-compat alias)", "tags" => ["Agents"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Agent"}}}},
          "responses" => %{"200" => %{"description" => "Registered"}}}
      },
      "/api/agents/update" => %{
        "post" => %{"operationId" => "updateAgentV3", "summary" => "Full agent update (v3-compat)", "tags" => ["Agents"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Agent"}}}},
          "responses" => %{"200" => %{"description" => "Updated"}}}
      },
      "/api/agents/discover" => %{
        "get" => %{"operationId" => "discoverAgents", "summary" => "Trigger agent discovery scan", "tags" => ["Agents"],
          "responses" => %{"200" => %{"description" => "Discovery results"}}}
      },
      "/api/data" => %{
        "get" => %{"operationId" => "getMasterData", "summary" => "Master data aggregation (active project)", "tags" => ["Data"],
          "responses" => %{"200" => %{"description" => "Aggregated APM state"}}}
      },
      "/api/notifications" => %{
        "get" => %{"operationId" => "listNotifications", "summary" => "List notifications", "tags" => ["Notifications"],
          "responses" => %{"200" => %{"description" => "Notification list",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Notification"}}}}}}}
      },
      "/api/notify" => %{
        "post" => %{"operationId" => "addNotification", "summary" => "Add a notification", "tags" => ["Notifications"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["message"],
            "properties" => %{"message" => %{"type" => "string"}, "type" => %{"type" => "string"},
              "agent_id" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Added"}}}
      },
      "/api/notifications/add" => %{
        "post" => %{"operationId" => "addNotificationV3", "summary" => "Add notification (v3-compat)", "tags" => ["Notifications"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Added"}}}
      },
      "/api/notifications/read-all" => %{
        "post" => %{"operationId" => "markAllNotificationsRead", "summary" => "Mark all notifications read", "tags" => ["Notifications"],
          "responses" => %{"200" => %{"description" => "Marked read"}}}
      },
      "/api/ralph" => %{
        "get" => %{"operationId" => "getRalph", "summary" => "Ralph data for active project", "tags" => ["Ralph"],
          "responses" => %{"200" => %{"description" => "Ralph state"}}}
      },
      "/api/ralph/flowchart" => %{
        "get" => %{"operationId" => "getRalphFlowchart", "summary" => "D3-compatible flowchart data", "tags" => ["Ralph"],
          "responses" => %{"200" => %{"description" => "Flowchart nodes and edges"}}}
      },
      "/api/commands" => %{
        "get" => %{"operationId" => "listCommands", "summary" => "List commands for active project", "tags" => ["Commands"],
          "responses" => %{"200" => %{"description" => "Command list"}}},
        "post" => %{"operationId" => "registerCommands", "summary" => "Register slash commands", "tags" => ["Commands"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Registered"}}}
      },
      "/api/tasks/sync" => %{
        "post" => %{"operationId" => "syncTasks", "summary" => "Replace active project's task list", "tags" => ["Tasks"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "properties" => %{"tasks" => %{"type" => "array", "items" => %{"type" => "object"}}}}}}},
          "responses" => %{"200" => %{"description" => "Synced"}}}
      },
      "/api/input/pending" => %{
        "get" => %{"operationId" => "getPendingInput", "summary" => "Get pending input requests", "tags" => ["Tasks"],
          "responses" => %{"200" => %{"description" => "Pending input requests"}}}
      },
      "/api/input/request" => %{
        "post" => %{"operationId" => "createInputRequest", "summary" => "Create input request", "tags" => ["Tasks"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Created"}}}
      },
      "/api/input/respond" => %{
        "post" => %{"operationId" => "respondToInput", "summary" => "Respond to input request", "tags" => ["Tasks"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Responded"}}}
      },
      "/api/skills" => %{
        "get" => %{"operationId" => "listSkills", "summary" => "List tracked skills", "tags" => ["Skills"],
          "parameters" => [%{"$ref" => "#/components/parameters/ProjectParam"},
            %{"name" => "session_id", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Skill invocations"}}}
      },
      "/api/skills/track" => %{
        "post" => %{"operationId" => "trackSkill", "summary" => "Track a skill invocation", "tags" => ["Skills"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["skill"],
            "properties" => %{"skill" => %{"type" => "string"}, "session_id" => %{"type" => "string"},
              "project" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Tracked"}}}
      },
      "/api/upm/register" => %{
        "post" => %{"operationId" => "upmRegister", "summary" => "Register a UPM execution session", "tags" => ["UPM"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Registered"}}}
      },
      "/api/upm/agent" => %{
        "post" => %{"operationId" => "upmAgent", "summary" => "Register agent with work-item binding", "tags" => ["UPM"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Registered"}}}
      },
      "/api/upm/event" => %{
        "post" => %{"operationId" => "upmEvent", "summary" => "Report UPM lifecycle event", "tags" => ["UPM"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Recorded"}}}
      },
      "/api/upm/status" => %{
        "get" => %{"operationId" => "upmStatus", "summary" => "Current UPM execution state", "tags" => ["UPM"],
          "responses" => %{"200" => %{"description" => "UPM state"}}}
      },
      "/api/ports" => %{
        "get" => %{"operationId" => "listPorts", "summary" => "List registered ports", "tags" => ["Ports"],
          "responses" => %{"200" => %{"description" => "Port registry"}}}
      },
      "/api/ports/scan" => %{
        "post" => %{"operationId" => "scanPorts", "summary" => "Scan for active ports", "tags" => ["Ports"],
          "responses" => %{"200" => %{"description" => "Scan results"}}}
      },
      "/api/ports/assign" => %{
        "post" => %{"operationId" => "assignPort", "summary" => "Assign a port to a service", "tags" => ["Ports"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "properties" => %{"port" => %{"type" => "integer"}, "service" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Assigned"}}}
      },
      "/api/ports/clashes" => %{
        "get" => %{"operationId" => "getPortClashes", "summary" => "Detect port clashes", "tags" => ["Ports"],
          "responses" => %{"200" => %{"description" => "Clash list"}}}
      },
      "/api/ports/set-primary" => %{
        "post" => %{"operationId" => "setPrimaryPort", "summary" => "Set primary port for a service", "tags" => ["Ports"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Set"}}}
      },
      "/api/projects" => %{
        "get" => %{"operationId" => "listProjects", "summary" => "List all projects with agent counts", "tags" => ["Projects"],
          "responses" => %{"200" => %{"description" => "Projects list"}}},
        "patch" => %{"operationId" => "updateProject", "summary" => "Update project metadata", "tags" => ["Projects"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Updated"}}}
      },
      "/api/config/reload" => %{
        "post" => %{"operationId" => "reloadConfig", "summary" => "Hot-reload multi-project config", "tags" => ["Config"],
          "responses" => %{"200" => %{"description" => "Reloaded"}}}
      },
      "/api/reload" => %{
        "post" => %{"operationId" => "reloadConfigAlias", "summary" => "Reload config (alias)", "tags" => ["Config"],
          "responses" => %{"200" => %{"description" => "Reloaded"}}}
      },
      "/api/plane/update" => %{
        "post" => %{"operationId" => "updatePlane", "summary" => "Update Plane PM context", "tags" => ["Projects"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Updated"}}}
      },
      "/api/environments" => %{
        "get" => %{"operationId" => "listEnvironments", "summary" => "List all Claude Code environments", "tags" => ["Environments"],
          "responses" => %{"200" => %{"description" => "Environment list"}}}
      },
      "/api/environments/{name}" => %{
        "get" => %{"operationId" => "getEnvironment", "summary" => "Full environment detail", "tags" => ["Environments"],
          "parameters" => [%{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Environment detail"}, "404" => %{"description" => "Not found"}}}
      },
      "/api/environments/{name}/exec" => %{
        "post" => %{"operationId" => "execInEnvironment", "summary" => "Execute command in environment", "tags" => ["Environments"],
          "parameters" => [%{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["command"],
            "properties" => %{"command" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Execution result"}}}
      },
      "/api/environments/{name}/session/start" => %{
        "post" => %{"operationId" => "startEnvironmentSession", "summary" => "Launch Claude Code session", "tags" => ["Environments"],
          "parameters" => [%{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Session started"}}}
      },
      "/api/environments/{name}/session/stop" => %{
        "post" => %{"operationId" => "stopEnvironmentSession", "summary" => "Kill Claude Code session", "tags" => ["Environments"],
          "parameters" => [%{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Session stopped"}}}
      },
      "/api/v2/export" => %{
        "get" => %{"operationId" => "exportData", "summary" => "Export APM data (JSON or CSV)", "tags" => ["Export"],
          "parameters" => [%{"name" => "format", "in" => "query", "schema" => %{"type" => "string", "enum" => ["json", "csv"]}}],
          "responses" => %{"200" => %{"description" => "Export data"}}}
      },
      "/api/v2/import" => %{
        "post" => %{"operationId" => "importData", "summary" => "Import APM data from JSON", "tags" => ["Export"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Imported"}}}
      },
      "/api/ag-ui/events" => %{
        "get" => %{"operationId" => "agUiEventStream", "summary" => "AG-UI SSE event stream", "tags" => ["AG-UI"],
          "parameters" => [%{"name" => "agent_id", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Server-sent events stream",
            "content" => %{"text/event-stream" => %{"schema" => %{"type" => "string"}}}}}
        }
      },
      "/api/a2ui/components" => %{
        "get" => %{"operationId" => "a2uiComponents", "summary" => "A2UI declarative component specs", "tags" => ["A2UI"],
          "responses" => %{"200" => %{"description" => "Component specifications"}}}
      },
      "/api/openapi.json" => %{
        "get" => %{"operationId" => "getOpenApiV1", "summary" => "OpenAPI 3.0.3 spec (v1 alias)", "tags" => ["Health"],
          "responses" => %{"200" => %{"description" => "OpenAPI specification"}}}
      }
    }
  end

  defp build_v2_paths do
    %{
      "/api/v2/agents" => %{
        "get" => %{"operationId" => "v2ListAgents", "summary" => "Paginated agent list (cursor-based)", "tags" => ["Agents"],
          "parameters" => [%{"$ref" => "#/components/parameters/CursorParam"}, %{"$ref" => "#/components/parameters/LimitParam"}],
          "responses" => %{"200" => %{"description" => "Paginated agents",
            "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/PaginatedAgents"}}}}}}
      },
      "/api/v2/agents/{id}" => %{
        "get" => %{"operationId" => "v2GetAgent", "summary" => "Agent detail with health score", "tags" => ["Agents"],
          "parameters" => [%{"$ref" => "#/components/parameters/AgentIdParam"}],
          "responses" => %{"200" => %{"description" => "Agent detail",
            "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Agent"}}}},
            "404" => %{"description" => "Not found"}}}
      },
      "/api/v2/sessions" => %{
        "get" => %{"operationId" => "v2ListSessions", "summary" => "Paginated session list", "tags" => ["Sessions"],
          "parameters" => [%{"$ref" => "#/components/parameters/CursorParam"}, %{"$ref" => "#/components/parameters/LimitParam"}],
          "responses" => %{"200" => %{"description" => "Paginated sessions"}}}
      },
      "/api/v2/metrics" => %{
        "get" => %{"operationId" => "v2FleetMetrics", "summary" => "Fleet-wide metrics summary", "tags" => ["Metrics"],
          "responses" => %{"200" => %{"description" => "Fleet metrics"}}}
      },
      "/api/v2/metrics/{agent_id}" => %{
        "get" => %{"operationId" => "v2AgentMetrics", "summary" => "Per-agent metrics", "tags" => ["Metrics"],
          "parameters" => [%{"$ref" => "#/components/parameters/AgentIdParam"}, %{"$ref" => "#/components/parameters/SinceParam"}],
          "responses" => %{"200" => %{"description" => "Agent metrics"}}}
      },
      "/api/v2/slos" => %{
        "get" => %{"operationId" => "v2ListSlos", "summary" => "All SLIs with error budgets", "tags" => ["SLOs"],
          "responses" => %{"200" => %{"description" => "SLO list",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/SLO"}}}}}}}
      },
      "/api/v2/slos/{name}" => %{
        "get" => %{"operationId" => "v2GetSlo", "summary" => "Single SLI with history", "tags" => ["SLOs"],
          "parameters" => [%{"name" => "name", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "SLO detail"}, "404" => %{"description" => "Not found"}}}
      },
      "/api/v2/alerts" => %{
        "get" => %{"operationId" => "v2ListAlerts", "summary" => "Alert history with filters", "tags" => ["Alerts"],
          "parameters" => [%{"$ref" => "#/components/parameters/CursorParam"}, %{"$ref" => "#/components/parameters/LimitParam"},
            %{"$ref" => "#/components/parameters/SeverityParam"},
            %{"name" => "rule_id", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Alert history",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Alert"}}}}}}}
      },
      "/api/v2/alerts/rules" => %{
        "get" => %{"operationId" => "v2ListAlertRules", "summary" => "List alert rules", "tags" => ["Alerts"],
          "responses" => %{"200" => %{"description" => "Alert rules",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/AlertRule"}}}}}}},
        "post" => %{"operationId" => "v2CreateAlertRule", "summary" => "Create alert rule", "tags" => ["Alerts"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["metric", "threshold"],
            "properties" => %{"id" => %{"type" => "string"}, "name" => %{"type" => "string"},
              "metric" => %{"type" => "string"}, "scope" => %{"type" => "string", "enum" => ["fleet", "agent"]},
              "threshold" => %{"type" => "number"}, "comparator" => %{"type" => "string"},
              "severity" => %{"type" => "string", "enum" => ["info", "warning", "critical"]},
              "consecutive_breaches" => %{"type" => "integer"}}}}}},
          "responses" => %{"201" => %{"description" => "Created"}, "400" => %{"description" => "Invalid rule"}}}
      },
      "/api/v2/audit" => %{
        "get" => %{"operationId" => "v2ListAudit", "summary" => "Audit log with cursor pagination", "tags" => ["Audit"],
          "parameters" => [%{"$ref" => "#/components/parameters/CursorParam"}, %{"$ref" => "#/components/parameters/LimitParam"},
            %{"$ref" => "#/components/parameters/SinceParam"},
            %{"name" => "event_type", "in" => "query", "schema" => %{"type" => "string"}},
            %{"name" => "actor", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Audit entries",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/AuditEntry"}}}}}}}
      },
      "/api/v2/openapi.json" => %{
        "get" => %{"operationId" => "v2GetOpenApi", "summary" => "OpenAPI 3.0.3 specification", "tags" => ["Health"],
          "responses" => %{"200" => %{"description" => "OpenAPI spec"}}}
      }
    }
  end

  defp build_schemas do
    %{
      "Agent" => %{"type" => "object", "properties" => %{
        "id" => %{"type" => "string"}, "name" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["active", "idle", "error", "offline"]},
        "project" => %{"type" => "string"}, "role" => %{"type" => "string"},
        "last_heartbeat" => %{"type" => "string", "format" => "date-time"},
        "registered_at" => %{"type" => "string", "format" => "date-time"}}},
      "PaginatedAgents" => %{"type" => "object", "properties" => %{
        "data" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Agent"}},
        "meta" => %{"type" => "object", "properties" => %{
          "total" => %{"type" => "integer"}, "cursor" => %{"type" => "string"},
          "has_more" => %{"type" => "boolean"}}}}},
      "Notification" => %{"type" => "object", "properties" => %{
        "id" => %{"type" => "string"}, "message" => %{"type" => "string"},
        "type" => %{"type" => "string"}, "read" => %{"type" => "boolean"},
        "timestamp" => %{"type" => "string", "format" => "date-time"}}},
      "AlertRule" => %{"type" => "object", "properties" => %{
        "id" => %{"type" => "string"}, "name" => %{"type" => "string"},
        "metric" => %{"type" => "string"}, "scope" => %{"type" => "string"},
        "threshold" => %{"type" => "number"},
        "comparator" => %{"type" => "string", "enum" => ["gt", "gte", "lt", "lte", "eq"]},
        "severity" => %{"type" => "string", "enum" => ["info", "warning", "critical"]},
        "enabled" => %{"type" => "boolean"}, "consecutive_breaches" => %{"type" => "integer"},
        "window_s" => %{"type" => "integer"}}},
      "Alert" => %{"type" => "object", "properties" => %{
        "id" => %{"type" => "string"}, "rule_id" => %{"type" => "string"},
        "value" => %{"type" => "number"},
        "severity" => %{"type" => "string", "enum" => ["info", "warning", "critical"]},
        "timestamp" => %{"type" => "string", "format" => "date-time"},
        "acknowledged" => %{"type" => "boolean"}}},
      "SLO" => %{"type" => "object", "properties" => %{
        "name" => %{"type" => "string"}, "target" => %{"type" => "number"},
        "current" => %{"type" => "number"},
        "status" => %{"type" => "string", "enum" => ["ok", "at_risk", "breached"]},
        "error_budget_remaining" => %{"type" => "number"}}},
      "AuditEntry" => %{"type" => "object", "properties" => %{
        "id" => %{"type" => "string"}, "action" => %{"type" => "string"},
        "actor" => %{"type" => "string"}, "resource" => %{"type" => "string"},
        "timestamp" => %{"type" => "string", "format" => "date-time"},
        "metadata" => %{"type" => "object", "additionalProperties" => true}}},
      "PaginatedResponse" => %{"type" => "object", "properties" => %{
        "data" => %{"type" => "array", "items" => %{}},
        "next_cursor" => %{"type" => "string"}, "total" => %{"type" => "integer"}}},
      "Error" => %{"type" => "object", "properties" => %{
        "error" => %{"type" => "string"}, "message" => %{"type" => "string"}}}
    }
  end

  defp build_parameters do
    %{
      "CursorParam" => %{"name" => "cursor", "in" => "query", "required" => false,
        "description" => "Pagination cursor for next page", "schema" => %{"type" => "string"}},
      "LimitParam" => %{"name" => "limit", "in" => "query", "required" => false,
        "description" => "Maximum results to return", "schema" => %{"type" => "integer", "default" => 50, "maximum" => 500}},
      "AgentIdParam" => %{"name" => "id", "in" => "path", "required" => true,
        "description" => "Agent ID", "schema" => %{"type" => "string"}},
      "SinceParam" => %{"name" => "since", "in" => "query", "required" => false,
        "description" => "Return results after this ISO 8601 timestamp", "schema" => %{"type" => "string", "format" => "date-time"}},
      "SeverityParam" => %{"name" => "severity", "in" => "query", "required" => false,
        "description" => "Filter by severity", "schema" => %{"type" => "string", "enum" => ["info", "warning", "critical"]}},
      "ProjectParam" => %{"name" => "project", "in" => "query", "required" => false,
        "description" => "Filter by project name", "schema" => %{"type" => "string"}}
    }
  end

  # ========== Private Helpers ==========

  # ========== Workflows (WorkflowSchemaStore) ==========

  @doc "GET /api/v2/workflows"
  def list_workflows(conn, _params) do
    json(conn, ApiV2JSON.envelope(WorkflowSchemaStore.list_workflows()))
  end

  @doc "POST /api/v2/workflows"
  def create_workflow(conn, params) do
    case WorkflowSchemaStore.register_workflow(params) do
      {:ok, wf} ->
        conn |> put_status(:created) |> json(ApiV2JSON.envelope(wf))

      {:error, reason} ->
        conn |> put_status(422) |> json(ApiV2JSON.error_response("validation_error", reason))
    end
  end

  @doc "GET /api/v2/workflows/:id"
  def get_workflow(conn, %{"id" => id}) do
    case WorkflowSchemaStore.get_workflow(id) do
      {:ok, wf} ->
        json(conn, ApiV2JSON.envelope(wf))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(ApiV2JSON.error_response("not_found", "Workflow not found"))
    end
  end

  @doc "PATCH /api/v2/workflows/:id"
  def update_workflow(conn, %{"id" => id} = params) do
    attrs = Map.drop(params, ["id"])

    case WorkflowSchemaStore.update_workflow(id, attrs) do
      {:ok, wf} ->
        json(conn, ApiV2JSON.envelope(wf))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(ApiV2JSON.error_response("not_found", "Workflow not found"))
    end
  end

  # ========== Formations (UpmStore) ==========

  @doc "GET /api/v2/formations"
  def list_formations(conn, _params) do
    json(conn, ApiV2JSON.envelope(UpmStore.list_formations()))
  end

  @doc "POST /api/v2/formations"
  def create_formation(conn, params) do
    {:ok, id} = UpmStore.register_formation(params)

    formation = UpmStore.get_formation(id)

    conn
    |> put_status(:created)
    |> json(ApiV2JSON.envelope(formation))
  end

  @doc "GET /api/v2/formations/:id"
  def get_formation(conn, %{"id" => id}) do
    case UpmStore.get_formation(id) do
      nil ->
        conn |> put_status(404) |> json(ApiV2JSON.error_response("not_found", "Formation not found"))

      formation ->
        agents = AgentRegistry.list_formation(id)
        data = Map.put(formation, :agents, agents)
        json(conn, ApiV2JSON.envelope(data))
    end
  end

  @doc "GET /api/v2/formations/:id/agents"
  def get_formation_agents(conn, %{"id" => id}) do
    agents = AgentRegistry.list_formation(id)
    json(conn, ApiV2JSON.envelope(agents, %{total: length(agents)}))
  end

  # ========== Verification (VerifyStore) ==========

  @doc "POST /api/v2/verify/double — initiate double-verification session"
  def verify_double(conn, params) do
    project_root = Map.get(params, "project_root", "")
    app_url = Map.get(params, "app_url", "")
    stories = Map.get(params, "stories", [])

    {:ok, session} = ApmV4.VerifyStore.create(project_root, app_url, stories)

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(
      [
        %{event: "verify_pass_1_start", title: "Verify Pass 1 Starting",
          message: "Double verification initiated for #{project_root}"},
        %{event: "verify_pass_1_complete", title: "Verify Pass 1 Complete",
          message: "Pass 1 finished for #{project_root}"},
        %{event: "verify_pass_2_start", title: "Verify Pass 2 Starting",
          message: "Pass 2 beginning for #{project_root}"},
        %{event: "verify_pass_2_complete", title: "Verify Pass 2 Complete",
          message: "Pass 2 finished for #{project_root}"},
        %{event: "verify_consensus", title: "Verify Consensus",
          message: "Double verification consensus reached for #{project_root}"}
      ],
      fn %{event: event, title: title, message: message} ->
        AgentRegistry.add_notification(%{
          type: "info",
          title: title,
          message: message,
          category: "skill",
          event: event,
          timestamp: now
        })
      end
    )

    conn
    |> put_status(:ok)
    |> json(%{ok: true, id: session.id, status: session.status})
  end

  @doc "GET /api/v2/verify/:id — poll verification session status"
  def verify_status(conn, %{"id" => id}) do
    case ApmV4.VerifyStore.get(id) do
      {:ok, session} ->
        conn
        |> put_status(:ok)
        |> json(%{
          id: session.id,
          project_root: session.project_root,
          app_url: session.app_url,
          stories: session.stories,
          status: session.status,
          pass_1_result: session.pass_1_result,
          pass_2_result: session.pass_2_result,
          started_at: DateTime.to_iso8601(session.started_at),
          completed_at: if(session.completed_at, do: DateTime.to_iso8601(session.completed_at), else: nil)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Verification session not found", id: id})
    end
  end

  defp safe_to_existing_atom(nil), do: nil

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_existing_atom(atom) when is_atom(atom), do: atom

  defp parse_severity(nil), do: :info
  defp parse_severity(s) when is_binary(s), do: safe_to_existing_atom(s) || :info
  defp parse_severity(s) when is_atom(s), do: s

  defp parse_scope(nil), do: :fleet
  defp parse_scope("agent"), do: :agent
  defp parse_scope("fleet"), do: :fleet
  defp parse_scope(_), do: :fleet

end
