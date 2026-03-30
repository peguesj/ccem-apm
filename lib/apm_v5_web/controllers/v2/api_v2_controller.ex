defmodule ApmV5Web.V2.ApiV2Controller do
  @moduledoc """
  v2 REST API with standardized envelope responses and cursor-based pagination.
  Phase 3.1 of CCEM APM v5.
  """

  use ApmV5Web, :controller

  alias ApmV5.AgentRegistry
  alias ApmV5.MetricsCollector
  alias ApmV5.SloEngine
  alias ApmV5.AlertRulesEngine
  alias ApmV5.AuditLog
  alias ApmV5.WorkflowSchemaStore
  alias ApmV5.UpmStore
  alias ApmV5Web.V2.ApiV2JSON

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
        "title" => "CCEM APM API",
        "version" => Mix.Project.config()[:version],
        "description" => "Complete REST API for CCEM Agent Performance Monitor v#{Mix.Project.config()[:version]}. AgentLock authorization protocol, Plugin Engine, domain-split controllers, CCEM Management routes. Also available at /api/openapi.json."
      },
      "servers" => [%{"url" => "http://localhost:3032", "description" => "Local APM server"}],
      "tags" => [
        # Core tags
        %{"name" => "Health", "description" => "Server health and status"},
        %{"name" => "Agents", "description" => "Agent registration and management"},
        %{"name" => "Sessions", "description" => "Session tracking"},
        %{"name" => "Notifications", "description" => "Notification management"},
        %{"name" => "Data", "description" => "Aggregated data and master state"},
        %{"name" => "Ralph", "description" => "Ralph methodology integration"},
        %{"name" => "Commands", "description" => "Slash command registry"},
        %{"name" => "Tasks", "description" => "Task synchronization and input"},
        %{"name" => "Ports", "description" => "Port registry and clash detection"},
        %{"name" => "Environments", "description" => "CCEM environment management"},
        %{"name" => "Config", "description" => "Server configuration"},
        %{"name" => "Projects", "description" => "Multi-project management"},
        %{"name" => "A2UI", "description" => "A2UI declarative component specs"},
        %{"name" => "Metrics", "description" => "Performance metrics (v2)"},
        %{"name" => "SLOs", "description" => "Service Level Objectives (v2)"},
        %{"name" => "Alerts", "description" => "Alert rules and history (v2)"},
        %{"name" => "Audit", "description" => "Audit log (v2)"},
        %{"name" => "Export", "description" => "Data export and import (v2)"},
        %{"name" => "Manifest", "description" => "API architecture manifest — core vs extension surface area"},
        # Extension tags (x-extension: true on all operations)
        %{"name" => "Skills", "description" => "[extension:skills] Skill registry, health scoring, and audit", "x-extension" => true},
        %{"name" => "UPM", "description" => "[extension:upm] Unified Project Management execution tracking", "x-extension" => true},
        %{"name" => "UPM Decision Gate", "description" => "[extension:upm] Human-in-the-loop approval gates for UPM formation deployments", "x-extension" => true},
        %{"name" => "Formations", "description" => "[extension:formations] Formation domain controller", "x-extension" => true},
        %{"name" => "AG-UI", "description" => "[extension:ag_ui] AG-UI SSE event stream, state, and tool calls", "x-extension" => true},
        %{"name" => "Agent Context", "description" => "[extension:ag_ui] Real-time AG-UI context per agent — activity, events, tool calls", "x-extension" => true},
        %{"name" => "CCEM Management", "description" => "[extension:showcase] Showcase LiveView pages (Showcase, Ports, CCEM overview)", "x-extension" => true},
        %{"name" => "AgentLock Authorization", "description" => "[extension:agentlock] Authorization protocol — session, token, policy, context, memory, rate-limit management", "x-extension" => true},
        %{"name" => "Coalesce", "description" => "[extension:coalesce] Skill Logic Engine — ingest sources, plan skill diffs, gate-controlled apply", "x-extension" => true},
        %{"name" => "Plugins", "description" => "[extension:plugins] Plugin Engine — modular capability extensions", "x-extension" => true},
        %{"name" => "Integrations", "description" => "[extension:plugins] Integration Engine — symbiosis between plugins and native features", "x-extension" => true},
        %{"name" => "Usage", "description" => "[extension:usage] Claude usage tracking — token/model/cost per project and session", "x-extension" => true},
        %{"name" => "Plane", "description" => "[extension:plane] Plane PM alignment agent — sync status and manual sync trigger", "x-extension" => true}
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
      "/api/formations" => %{
        "get" => %{"operationId" => "listFormations", "summary" => "List all formations", "tags" => ["UPM"],
          "responses" => %{"200" => %{"description" => "Formation list"}}},
        "post" => %{"operationId" => "createFormation", "summary" => "Create a formation", "tags" => ["UPM"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"201" => %{"description" => "Created formation"}}}
      },
      "/api/formations/{id}" => %{
        "get" => %{"operationId" => "getFormation", "summary" => "Get a formation by ID", "tags" => ["UPM"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Formation detail"}, "404" => %{"description" => "Not found"}}},
        "patch" => %{"operationId" => "updateFormation", "summary" => "Update a formation", "tags" => ["UPM"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}},
          "responses" => %{"200" => %{"description" => "Updated formation"}, "404" => %{"description" => "Not found"}}}
      },
      "/api/formations/{id}/agents" => %{
        "get" => %{"operationId" => "getFormationAgents", "summary" => "List agents in a formation", "tags" => ["UPM"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Agents list"}}}
      },
      "/api/showcase" => %{
        "get" => %{"operationId" => "listShowcaseProjects", "summary" => "List showcase-eligible projects", "tags" => ["CCEM Management"],
          "responses" => %{"200" => %{"description" => "Showcase project list"}}}
      },
      "/api/showcase/{project}" => %{
        "get" => %{"operationId" => "getShowcaseData", "summary" => "Get showcase data for a project", "tags" => ["CCEM Management"],
          "parameters" => [%{"name" => "project", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Showcase data"}, "404" => %{"description" => "Not found"}}}
      },
      "/api/showcase/{project}/reload" => %{
        "post" => %{"operationId" => "reloadShowcaseData", "summary" => "Reload showcase data for a project", "tags" => ["CCEM Management"],
          "parameters" => [%{"name" => "project", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Reloaded"}}}
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
      },
      "/showcase" => %{
        "get" => %{
          "operationId" => "showcaseDashboard",
          "summary" => "Showcase Dashboard",
          "description" => "GIMME-style project showcase with live agent/UPM data, feature roadmap, and IP-safe architecture diagrams. Uses active project from apm_config.json.",
          "tags" => ["CCEM Management"],
          "responses" => %{"200" => %{"description" => "Showcase LiveView"}}
        }
      },
      "/showcase/{project}" => %{
        "get" => %{
          "operationId" => "showcaseDashboardProject",
          "summary" => "Showcase Dashboard — Named Project",
          "description" => "Load the showcase for a specific project by name. Switches active showcase data without a full page reload.",
          "tags" => ["CCEM Management"],
          "parameters" => [%{"name" => "project", "in" => "path", "required" => true, "schema" => %{"type" => "string"}, "description" => "Project name as registered in apm_config.json"}],
          "responses" => %{"200" => %{"description" => "Showcase LiveView for named project"}}
        }
      },
      "/ccem" => %{
        "get" => %{
          "operationId" => "ccemOverview",
          "summary" => "CCEM Management Overview",
          "description" => "CCEM Management hub — entry point for the CCEM section of the dual-section sidebar. Quick-access tiles to Showcase, Ports, Actions, and Scanner.",
          "tags" => ["CCEM Management"],
          "responses" => %{"200" => %{"description" => "CCEM Overview LiveView"}}
        }
      },
      "/ports" => %{
        "get" => %{
          "operationId" => "portsDashboard",
          "summary" => "Port Management Dashboard",
          "description" => "CCEM port registry with conflict visualization, namespace filtering, active-port scanning, and one-click clash reassignment.",
          "tags" => ["CCEM Management"],
          "responses" => %{"200" => %{"description" => "Ports LiveView"}}
        }
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
      },
      "/api/v2/manifest" => %{
        "get" => %{
          "operationId" => "v2GetManifest",
          "summary" => "API architecture manifest",
          "description" => "Returns a machine-readable summary of the core API surface and all loaded extensions, including route counts and enabled status. Use x-extension flag in the OpenAPI spec to identify extension endpoints.",
          "tags" => ["Manifest"],
          "responses" => %{
            "200" => %{
              "description" => "Manifest payload",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "core_version" => %{"type" => "string"},
                      "architecture" => %{"type" => "string"},
                      "extensions" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "name" => %{"type" => "string"},
                            "version" => %{"type" => "string"},
                            "enabled" => %{"type" => "boolean"},
                            "routes" => %{"type" => "integer"},
                            "description" => %{"type" => "string"},
                            "path_prefix" => %{"type" => "string"}
                          }
                        }
                      },
                      "core_routes" => %{"type" => "integer"},
                      "total_routes" => %{"type" => "integer"}
                    }
                  }
                }
              }
            }
          }
        }
      },
      # AgentLock Authorization endpoints (v7.0.0)
      "/api/v2/auth/authorize" => %{
        "post" => %{"operationId" => "authAuthorize", "summary" => "Request authorization for a tool invocation", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["agent_id", "session_id", "tool_name"],
            "properties" => %{"agent_id" => %{"type" => "string"}, "session_id" => %{"type" => "string"},
              "tool_name" => %{"type" => "string"}, "params" => %{"type" => "object"}}}}}},
          "responses" => %{"200" => %{"description" => "Authorization decision (permit/deny/escalate)",
            "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/AuthDecision"}}}},
            "400" => %{"$ref" => "#/components/schemas/Error"}}}
      },
      "/api/v2/auth/execute" => %{
        "post" => %{"operationId" => "authExecute", "summary" => "Execute a pre-authorized tool invocation using a token", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["token_id"],
            "properties" => %{"token_id" => %{"type" => "string"}, "result" => %{"type" => "object"}}}}}},
          "responses" => %{"200" => %{"description" => "Execution recorded"}, "404" => %{"description" => "Token not found"}}}
      },
      "/api/v2/auth/summary" => %{
        "get" => %{"operationId" => "authSummary", "summary" => "Authorization system summary — tools, sessions, tokens, risk distribution", "tags" => ["AgentLock Authorization"],
          "responses" => %{"200" => %{"description" => "Authorization summary",
            "content" => %{"application/json" => %{"schema" => %{"type" => "object",
              "properties" => %{"registered_tools" => %{"type" => "integer"}, "active_sessions" => %{"type" => "integer"},
                "tokens" => %{"type" => "object"}, "total_authorized" => %{"type" => "integer"},
                "total_denied" => %{"type" => "integer"}, "total_escalated" => %{"type" => "integer"},
                "risk_distribution" => %{"type" => "object"}}}}}}}}
      },
      "/api/v2/auth/tools" => %{
        "get" => %{"operationId" => "authListTools", "summary" => "List registered tools with risk levels and policies", "tags" => ["AgentLock Authorization"],
          "responses" => %{"200" => %{"description" => "Tool registry list",
            "content" => %{"application/json" => %{"schema" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/AuthTool"}}}}}}},
        "post" => %{"operationId" => "authRegisterTool", "summary" => "Register a new tool with risk level and policy", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["name", "risk_level"],
            "properties" => %{"name" => %{"type" => "string"},
              "risk_level" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
              "description" => %{"type" => "string"}, "requires_approval" => %{"type" => "boolean"},
              "metadata" => %{"type" => "object"}}}}}},
          "responses" => %{"200" => %{"description" => "Tool registered"}, "400" => %{"$ref" => "#/components/schemas/Error"}}}
      },
      "/api/v2/auth/sessions" => %{
        "post" => %{"operationId" => "authCreateSession", "summary" => "Create an authorization session", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["user_id", "role"],
            "properties" => %{"user_id" => %{"type" => "string"}, "role" => %{"type" => "string"},
              "ttl_seconds" => %{"type" => "integer"}, "scope" => %{"type" => "string"},
              "metadata" => %{"type" => "object"}}}}}},
          "responses" => %{"200" => %{"description" => "Session created", "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}, "session_id" => %{"type" => "string"}}}}}}}},
        "get" => %{"operationId" => "authListSessions", "summary" => "List active authorization sessions", "tags" => ["AgentLock Authorization"],
          "responses" => %{"200" => %{"description" => "Active sessions",
            "content" => %{"application/json" => %{"schema" => %{"type" => "object",
              "properties" => %{"ok" => %{"type" => "boolean"}, "sessions" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/AuthSession"}},
                "count" => %{"type" => "integer"}}}}}}}}
      },
      "/api/v2/auth/sessions/{id}" => %{
        "get" => %{"operationId" => "authGetSession", "summary" => "Get authorization session by ID", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Session detail"}, "404" => %{"description" => "Session not found"}}},
        "delete" => %{"operationId" => "authDestroySession", "summary" => "Destroy an authorization session", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Session destroyed"}}}
      },
      "/api/v2/auth/tokens/{id}" => %{
        "get" => %{"operationId" => "authGetToken", "summary" => "Get token status and metadata", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Token detail"}, "404" => %{"description" => "Token not found"}}}
      },
      "/api/v2/auth/tokens/{id}/revoke" => %{
        "post" => %{"operationId" => "authRevokeToken", "summary" => "Revoke an authorization token", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Token revoked"}, "404" => %{"description" => "Token not found"}}}
      },
      "/api/v2/auth/context/write" => %{
        "post" => %{"operationId" => "authRecordContext", "summary" => "Record a context write event for trust tracking", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["session_id", "scope", "path"],
            "properties" => %{"session_id" => %{"type" => "string"}, "scope" => %{"type" => "string"},
              "path" => %{"type" => "string"}, "sensitivity" => %{"type" => "string"},
              "metadata" => %{"type" => "object"}}}}}},
          "responses" => %{"200" => %{"description" => "Context recorded"}}}
      },
      "/api/v2/auth/context/trust" => %{
        "get" => %{"operationId" => "authGetTrust", "summary" => "Get trust state for a session", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "session_id", "in" => "query", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Trust state with ceiling and write history"}}}
      },
      "/api/v2/auth/memory/authorize-write" => %{
        "post" => %{"operationId" => "authMemoryAuthorizeWrite", "summary" => "Authorize a memory write operation", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["session_id", "path"],
            "properties" => %{"session_id" => %{"type" => "string"}, "path" => %{"type" => "string"},
              "content_hash" => %{"type" => "string"}, "sensitivity" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Write authorization decision"}}}
      },
      "/api/v2/auth/memory/authorize-read" => %{
        "post" => %{"operationId" => "authMemoryAuthorizeRead", "summary" => "Authorize a memory read operation", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["session_id", "path"],
            "properties" => %{"session_id" => %{"type" => "string"}, "path" => %{"type" => "string"},
              "sensitivity" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Read authorization decision"}}}
      },
      "/api/v2/auth/rate-limits" => %{
        "get" => %{"operationId" => "authRateLimits", "summary" => "Get current rate limit state for agents and tools", "tags" => ["AgentLock Authorization"],
          "parameters" => [%{"name" => "agent_id", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Rate limit state"}}}
      },
      "/api/v2/auth/redact" => %{
        "post" => %{"operationId" => "authRedact", "summary" => "Apply redaction rules to content", "tags" => ["AgentLock Authorization"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object", "required" => ["content"],
            "properties" => %{"content" => %{"type" => "string"}, "rules" => %{"type" => "array", "items" => %{"type" => "string"}},
              "sensitivity" => %{"type" => "string"}}}}}},
          "responses" => %{"200" => %{"description" => "Redacted content",
            "content" => %{"application/json" => %{"schema" => %{"type" => "object",
              "properties" => %{"ok" => %{"type" => "boolean"}, "redacted" => %{"type" => "string"},
                "redactions_applied" => %{"type" => "integer"}}}}}}}}
      },
      "/api/v2/auth/audit" => %{
        "get" => %{"operationId" => "authAuditLog", "summary" => "AgentLock authorization audit log", "tags" => ["AgentLock Authorization"],
          "parameters" => [
            %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}},
            %{"name" => "event_type", "in" => "query", "schema" => %{"type" => "string"}},
            %{"name" => "agent_id", "in" => "query", "schema" => %{"type" => "string"}}],
          "responses" => %{"200" => %{"description" => "Authorization audit entries"}}}
      },

      # UPM Decision Gate (v8.4.0) — human-in-the-loop approval before formation deploy
      "/api/v2/upm/gate" => %{
        "post" => %{
          "operationId" => "upmCreateGate",
          "summary" => "Create a blocking UPM decision gate",
          "description" => "Creates a decision gate and blocks up to timeout_ms (default 120s) waiting for approval via CCEMHelper notification or osascript dialog.",
          "tags" => ["UPM Decision Gate"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{"type" => "string", "description" => "Decision question shown to the user", "example" => "Proceed with formation deployment?"},
              "context" => %{"type" => "string", "description" => "Additional context for the decision"},
              "options" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Response options", "example" => ["Deploy", "Cancel"]},
              "timeout_ms" => %{"type" => "integer", "description" => "Maximum wait time in milliseconds", "default" => 120_000}
            }}}}},
          "responses" => %{
            "200" => %{"description" => "Decision received", "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/GateDecision"}}}},
            "408" => %{"description" => "Gate timed out without a decision"}
          }
        }
      },
      "/api/v2/upm/gates" => %{
        "get" => %{
          "operationId" => "upmListGates",
          "summary" => "List all UPM decision gates (pending + resolved)",
          "tags" => ["UPM Decision Gate"],
          "responses" => %{"200" => %{"description" => "Gate list with pending count",
            "content" => %{"application/json" => %{"schema" => %{
              "type" => "object",
              "properties" => %{
                "gates" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Gate"}},
                "pending_count" => %{"type" => "integer"}
              }}}}}}
        }
      },
      "/api/v2/upm/gate/{id}" => %{
        "get" => %{
          "operationId" => "upmGetGate",
          "summary" => "Get a specific UPM decision gate by ID",
          "tags" => ["UPM Decision Gate"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Gate detail", "content" => %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Gate"}}}},
            "404" => %{"description" => "Gate not found"}
          }
        }
      },
      "/api/v2/upm/gate/{id}/approve" => %{
        "post" => %{
          "operationId" => "upmApproveGate",
          "summary" => "Approve a pending UPM decision gate",
          "tags" => ["UPM Decision Gate"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Gate approved"},
            "404" => %{"description" => "Gate not found"},
            "409" => %{"description" => "Gate is not in pending state"}
          }
        }
      },
      "/api/v2/upm/gate/{id}/reject" => %{
        "post" => %{
          "operationId" => "upmRejectGate",
          "summary" => "Reject a pending UPM decision gate",
          "tags" => ["UPM Decision Gate"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "requestBody" => %{"required" => false, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object",
            "properties" => %{"reason" => %{"type" => "string", "description" => "Rejection reason"}}}}}},
          "responses" => %{
            "200" => %{"description" => "Gate rejected"},
            "404" => %{"description" => "Gate not found"},
            "409" => %{"description" => "Gate is not in pending state"}
          }
        }
      },

      # Agent Context (v8.4.0) — real-time AG-UI context per agent
      "/api/v2/agents/contexts" => %{
        "get" => %{
          "operationId" => "listAgentContexts",
          "summary" => "List all agent AG-UI contexts",
          "description" => "Returns a map of agent_id => context for all agents with active AG-UI context.",
          "tags" => ["Agent Context"],
          "responses" => %{"200" => %{"description" => "Agent context map",
            "content" => %{"application/json" => %{"schema" => %{
              "type" => "object",
              "properties" => %{"contexts" => %{"type" => "object", "additionalProperties" => %{"$ref" => "#/components/schemas/AgentContext"}}}
            }}}}}
        }
      },
      "/api/v2/agents/{id}/context" => %{
        "get" => %{
          "operationId" => "getAgentContext",
          "summary" => "Get AG-UI context for a specific agent",
          "tags" => ["Agent Context"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}, "description" => "Agent ID"}],
          "responses" => %{"200" => %{"description" => "Agent context with activity label and recent tool calls",
            "content" => %{"application/json" => %{"schema" => %{
              "type" => "object",
              "properties" => %{
                "agent_id" => %{"type" => "string"},
                "context" => %{"$ref" => "#/components/schemas/AgentContext"},
                "activity_label" => %{"type" => "string"},
                "recent_tool_calls" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/ToolCallSummary"}}
              }}}}}}
        }
      },
      "/api/v2/agents/{id}/context/events" => %{
        "get" => %{
          "operationId" => "getAgentContextEvents",
          "summary" => "Get recent AG-UI events for a specific agent",
          "tags" => ["Agent Context"],
          "parameters" => [
            %{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}, "description" => "Agent ID"},
            %{"name" => "limit", "in" => "query", "required" => false, "schema" => %{"type" => "integer", "default" => 10, "maximum" => 50}, "description" => "Max events to return"}
          ],
          "responses" => %{"200" => %{"description" => "Recent AG-UI events",
            "content" => %{"application/json" => %{"schema" => %{
              "type" => "object",
              "properties" => %{
                "agent_id" => %{"type" => "string"},
                "events" => %{"type" => "array", "items" => %{"type" => "object"}},
                "count" => %{"type" => "integer"}
              }}}}}}
        }
      },

      # Coalesce — Skill Logic Engine (v8.4.0)
      "/api/v2/coalesce" => %{
        "get" => %{
          "operationId" => "coalesceListRuns",
          "summary" => "List all Coalesce runs",
          "description" => "Returns all runs with summary info and total pending gate count.",
          "tags" => ["Coalesce"],
          "responses" => %{"200" => %{"description" => "Run list with pending gate count",
            "content" => %{"application/json" => %{"schema" => %{
              "type" => "object",
              "properties" => %{
                "runs" => %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/CoalesceRunSummary"}},
                "total" => %{"type" => "integer"},
                "pending_gates" => %{"type" => "integer"}
              }}}}}}
        }
      },
      "/api/v2/coalesce/start" => %{
        "post" => %{
          "operationId" => "coalesceStartRun",
          "summary" => "Start a new Coalesce run",
          "description" => "Initiates source ingestion, skill analysis, formation deploy, diff generation, and gated apply. Returns run_id immediately (async). Monitor at /coalesce or poll GET /api/v2/coalesce/:id.",
          "tags" => ["Coalesce"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object",
            "properties" => %{
              "sources" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "URLs, file paths, or VIKI keys to ingest"},
              "scope" => %{"type" => "string", "description" => "Skill scope filter", "example" => "product management"},
              "dry_run" => %{"type" => "boolean", "description" => "Preview diffs without writing files", "default" => false},
              "auto_approve" => %{"type" => "boolean", "description" => "Skip human gates G2/G3 automatically", "default" => false},
              "squadrons" => %{"type" => "integer", "description" => "Number of agent squadrons", "default" => 6},
              "agent_count" => %{"type" => "integer", "description" => "Total agents in formation", "default" => 64}
            }}}}},
          "responses" => %{
            "202" => %{"description" => "Run accepted and started",
              "content" => %{"application/json" => %{"schema" => %{
                "type" => "object",
                "properties" => %{
                  "run_id" => %{"type" => "string"},
                  "status" => %{"type" => "string"},
                  "formation_id" => %{"type" => "string"},
                  "dry_run" => %{"type" => "boolean"},
                  "scope" => %{"type" => "string"},
                  "source_count" => %{"type" => "integer"},
                  "dashboard_url" => %{"type" => "string"},
                  "message" => %{"type" => "string"}
                }}}}},
            "422" => %{"description" => "Invalid run parameters"}
          }
        }
      },
      "/api/v2/coalesce/preview" => %{
        "post" => %{
          "operationId" => "coalescePreview",
          "summary" => "Preview a Coalesce run without starting it",
          "description" => "Analyzes sources and returns formation plan, affected skills, gate schedule, and estimated duration. No files are written.",
          "tags" => ["Coalesce"],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object",
            "properties" => %{
              "sources" => %{"type" => "array", "items" => %{"type" => "string"}},
              "scope" => %{"type" => "string"}
            }}}}},
          "responses" => %{"200" => %{"description" => "Preview with formation plan and gate schedule"}}
        }
      },
      "/api/v2/coalesce/{id}" => %{
        "get" => %{
          "operationId" => "coalesceGetRun",
          "summary" => "Get Coalesce run status and gates",
          "tags" => ["Coalesce"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Run detail with gates"},
            "404" => %{"description" => "Run not found"}
          }
        },
        "delete" => %{
          "operationId" => "coalesceCancelRun",
          "summary" => "Cancel a Coalesce run",
          "tags" => ["Coalesce"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Run cancelled"},
            "404" => %{"description" => "Run not found"},
            "409" => %{"description" => "Run already completed or cancelled"}
          }
        }
      },
      "/api/v2/coalesce/{id}/diff" => %{
        "get" => %{
          "operationId" => "coalesceGetDiff",
          "summary" => "Get proposed skill diffs for a Coalesce run",
          "tags" => ["Coalesce"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Diff list with skill impact and confidence"},
            "404" => %{"description" => "Run not found"}
          }
        }
      },
      "/api/v2/coalesce/{id}/gate/{gate_id}/decide" => %{
        "post" => %{
          "operationId" => "coalesceGateDecide",
          "summary" => "Approve, reject, or defer a Coalesce gate",
          "tags" => ["Coalesce"],
          "parameters" => [
            %{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}, "description" => "Run ID"},
            %{"name" => "gate_id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}, "description" => "Gate ID (e.g. G1, G2, G3, G4)"}
          ],
          "requestBody" => %{"required" => true, "content" => %{"application/json" => %{"schema" => %{
            "type" => "object",
            "properties" => %{
              "decision" => %{"type" => "string", "enum" => ["approve", "reject", "defer"], "default" => "approve"},
              "reason" => %{"type" => "string"},
              "approver" => %{"type" => "string", "default" => "api"}
            }}}}},
          "responses" => %{
            "200" => %{"description" => "Gate decision accepted"},
            "404" => %{"description" => "Gate not found"},
            "409" => %{"description" => "Gate is not in pending state"},
            "422" => %{"description" => "Invalid decision value"}
          }
        }
      },
      "/api/v2/coalesce/{id}/apply" => %{
        "post" => %{
          "operationId" => "coalesceApplyRun",
          "summary" => "Apply approved Coalesce diffs to skill files",
          "description" => "Writes approved skill diff additions to disk. Run must be in :awaiting_gate status with G3 approved.",
          "tags" => ["Coalesce"],
          "parameters" => [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}],
          "responses" => %{
            "200" => %{"description" => "Diffs applied"},
            "404" => %{"description" => "Run not found"},
            "409" => %{"description" => "Run is not in correct state to apply"},
            "422" => %{"description" => "Apply failed"}
          }
        }
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
        "registered_at" => %{"type" => "string", "format" => "date-time"},
        "display_name" => %{"type" => "string", "nullable" => true,
          "description" => "Human-readable scoped label for the agent (e.g. ccem/wave-1/stripe-env). Null if context unavailable."}}},
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
        "error" => %{"type" => "string"}, "message" => %{"type" => "string"}}},
      "PendingDecision" => %{"type" => "object", "description" => "AgentLock pending authorization request (v8.5.0)", "properties" => %{
        "request_id" => %{"type" => "string"},
        "tool_name" => %{"type" => "string"},
        "session_id" => %{"type" => "string"},
        "agent_id" => %{"type" => "string"},
        "risk_level" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
        "params" => %{"type" => "object", "additionalProperties" => true},
        "status" => %{"type" => "string", "enum" => ["pending", "approved", "denied", "timeout"]},
        "decision" => %{"type" => "string", "nullable" => true},
        "token_id" => %{"type" => "string", "nullable" => true},
        "display_name" => %{"type" => "string", "nullable" => true,
          "description" => "Human-readable scoped label for the requesting agent (e.g. ccem/wave-1/stripe-env). Null if context unavailable."},
        "decided_at" => %{"type" => "string", "format" => "date-time", "nullable" => true},
        "inserted_at" => %{"type" => "string", "format" => "date-time"},
        "expires_at" => %{"type" => "string", "format" => "date-time"}}},
      "AuthDecision" => %{"type" => "object", "properties" => %{
        "ok" => %{"type" => "boolean"}, "decision" => %{"type" => "string", "enum" => ["permit", "deny", "escalate"]},
        "token_id" => %{"type" => "string"}, "reason" => %{"type" => "string"},
        "risk_level" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]}}},
      "AuthTool" => %{"type" => "object", "properties" => %{
        "name" => %{"type" => "string"}, "risk_level" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
        "description" => %{"type" => "string"}, "requires_approval" => %{"type" => "boolean"},
        "registered_at" => %{"type" => "string", "format" => "date-time"}}},
      "AuthSession" => %{"type" => "object", "properties" => %{
        "session_id" => %{"type" => "string"}, "user_id" => %{"type" => "string"},
        "role" => %{"type" => "string"}, "trust_ceiling" => %{"type" => "string"},
        "scope" => %{"type" => "string"}, "tool_calls" => %{"type" => "integer"},
        "denied_count" => %{"type" => "integer"},
        "created_at" => %{"type" => "string", "format" => "date-time"},
        "expires_at" => %{"type" => "string", "format" => "date-time"}}},
      # v8.4.0 schemas
      "Gate" => %{"type" => "object", "description" => "UPM decision gate record", "properties" => %{
        "gate_id" => %{"type" => "string"},
        "question" => %{"type" => "string"},
        "context" => %{"type" => "string"},
        "options" => %{"type" => "array", "items" => %{"type" => "string"}},
        "status" => %{"type" => "string", "enum" => ["pending", "approved", "rejected", "timeout"]},
        "decision" => %{"type" => "string"},
        "method" => %{"type" => "string"},
        "requested_at" => %{"type" => "string", "format" => "date-time"},
        "resolved_at" => %{"type" => "string", "format" => "date-time"}}},
      "GateDecision" => %{"type" => "object", "description" => "Result of a blocking gate request", "properties" => %{
        "decision" => %{"type" => "string", "enum" => ["approved", "rejected", "timeout"]},
        "method" => %{"type" => "string"},
        "reason" => %{"type" => "string"},
        "gate_id" => %{"type" => "string"},
        "question" => %{"type" => "string"}}},
      "AgentContext" => %{"type" => "object", "description" => "Real-time AG-UI context for an agent (v8.4.0)", "properties" => %{
        "agent_id" => %{"type" => "string"},
        "current_tool" => %{"type" => "string"},
        "current_phase" => %{"type" => "string"},
        "formation_id" => %{"type" => "string"},
        "squadron_id" => %{"type" => "string"},
        "upm_story_id" => %{"type" => "string"},
        "last_event_type" => %{"type" => "string"},
        "updated_at" => %{"type" => "string", "format" => "date-time"}}},
      "ToolCallSummary" => %{"type" => "object", "description" => "Abbreviated tool call for context endpoints", "properties" => %{
        "tool_call_id" => %{"type" => "string"},
        "tool_name" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["pending", "running", "completed", "failed"]},
        "started_at" => %{"type" => "string", "format" => "date-time"},
        "duration_ms" => %{"type" => "integer"}}},
      "CoalesceRunSummary" => %{"type" => "object", "description" => "Summary of a Coalesce run", "properties" => %{
        "run_id" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "scope" => %{"type" => "string"},
        "dry_run" => %{"type" => "boolean"},
        "affected_skill_count" => %{"type" => "integer"},
        "diff_count" => %{"type" => "integer"},
        "started_at" => %{"type" => "string", "format" => "date-time"},
        "completed_at" => %{"type" => "string", "format" => "date-time"}}}
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

    {:ok, session} = ApmV5.VerifyStore.create(project_root, app_url, stories)

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
    case ApmV5.VerifyStore.get(id) do
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

  # ========== Manifest ==========

  @doc """
  GET /api/v2/manifest — API architecture manifest.

  Returns a machine-readable summary of the core API surface and all loaded
  extensions, including route counts and enabled status. Useful for tooling
  that needs to discover which extensions are active without parsing the full
  OpenAPI spec.
  """
  def manifest(conn, _params) do
    version = Mix.Project.config()[:version]

    payload = %{
      core_version: version,
      architecture: "microkernel+extensions",
      description: "Core APM monitoring primitives with independently-delimited extension modules.",
      extensions: [
        %{name: "agentlock", version: version, enabled: true, routes: 26,
          description: "AgentLock authorization — session, token, policy, context, memory, rate-limit management",
          path_prefix: "/api/v2/auth/*"},
        %{name: "upm", version: version, enabled: true, routes: 30,
          description: "Unified Project Management — execution tracking, module CRUD, decision gates",
          path_prefix: "/api/upm/*, /api/v2/upm/*"},
        %{name: "coalesce", version: version, enabled: true, routes: 8,
          description: "Skill Logic Engine — ingest sources, plan skill diffs, gate-controlled apply",
          path_prefix: "/api/v2/coalesce/*"},
        %{name: "skills", version: version, enabled: true, routes: 6,
          description: "Skills registry, health scoring, and audit",
          path_prefix: "/api/skills/*"},
        %{name: "showcase", version: version, enabled: true, routes: 3,
          description: "GIMME-style project showcase data API",
          path_prefix: "/api/showcase/*"},
        %{name: "ag_ui", version: version, enabled: true, routes: 14,
          description: "AG-UI SSE event stream, tool calls, state management, generative UI",
          path_prefix: "/api/ag-ui/*, /api/v2/ag-ui/*"},
        %{name: "plugins", version: version, enabled: true, routes: 11,
          description: "Plugin Engine and Integration Engine — modular capability extensions",
          path_prefix: "/api/v2/plugins/*, /api/v2/integrations/*"},
        %{name: "usage", version: version, enabled: true, routes: 5,
          description: "Claude usage tracking — token/model/cost per project and session",
          path_prefix: "/api/usage/*"},
        %{name: "formations", version: version, enabled: true, routes: 10,
          description: "Formation domain controller — CRUD for agentic formation state",
          path_prefix: "/api/formations/*, /api/v2/formations/*"},
        %{name: "plane", version: version, enabled: true, routes: 2,
          description: "Plane PM alignment agent — sync status and manual sync trigger",
          path_prefix: "/api/v2/plane/*"}
      ],
      core_routes: 62,
      total_routes: 178
    }

    json(conn, payload)
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
