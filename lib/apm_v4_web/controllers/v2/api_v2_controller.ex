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

  @doc "GET /api/v2/openapi.json - OpenAPI 3.0 spec"
  def openapi(conn, _params) do
    spec = %{
      openapi: "3.0.3",
      info: %{
        title: "CCEM APM v5 API",
        version: "2.0.0",
        description: "v2 REST API for CCEM Agent Performance Monitor"
      },
      paths: %{
        "/api/v2/agents" => %{
          get: %{summary: "List agents", parameters: [cursor_param(), limit_param()]}
        },
        "/api/v2/agents/{id}" => %{
          get: %{summary: "Get agent detail", parameters: [id_param()]}
        },
        "/api/v2/sessions" => %{
          get: %{summary: "List sessions", parameters: [cursor_param(), limit_param()]}
        },
        "/api/v2/metrics" => %{
          get: %{summary: "Fleet metrics summary"}
        },
        "/api/v2/metrics/{agent_id}" => %{
          get: %{summary: "Agent metrics", parameters: [agent_id_param(), since_param()]}
        },
        "/api/v2/slos" => %{
          get: %{summary: "List all SLIs with error budgets"}
        },
        "/api/v2/slos/{name}" => %{
          get: %{summary: "Get single SLI with history"}
        },
        "/api/v2/alerts" => %{
          get: %{summary: "Alert history", parameters: [cursor_param(), limit_param(), severity_param(), rule_id_param()]}
        },
        "/api/v2/alerts/rules" => %{
          get: %{summary: "List alert rules"},
          post: %{summary: "Create alert rule"}
        },
        "/api/v2/audit" => %{
          get: %{summary: "Audit log", parameters: [cursor_param(), limit_param(), event_type_param(), actor_param(), since_param()]}
        },
        "/api/v2/openapi.json" => %{
          get: %{summary: "This OpenAPI spec"}
        }
      }
    }

    json(conn, spec)
  end

  # ========== Private Helpers ==========

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

  # OpenAPI parameter helpers
  defp cursor_param, do: %{name: "cursor", in: "query", schema: %{type: "string"}}
  defp limit_param, do: %{name: "limit", in: "query", schema: %{type: "integer", default: 50, maximum: 200}}
  defp id_param, do: %{name: "id", in: "path", required: true, schema: %{type: "string"}}
  defp agent_id_param, do: %{name: "agent_id", in: "path", required: true, schema: %{type: "string"}}
  defp since_param, do: %{name: "since", in: "query", schema: %{type: "string", format: "date-time"}}
  defp severity_param, do: %{name: "severity", in: "query", schema: %{type: "string"}}
  defp rule_id_param, do: %{name: "rule_id", in: "query", schema: %{type: "string"}}
  defp event_type_param, do: %{name: "event_type", in: "query", schema: %{type: "string"}}
  defp actor_param, do: %{name: "actor", in: "query", schema: %{type: "string"}}
end
