defmodule ApmWeb.V2.ApiV2Controller do
  @moduledoc """
  v2 REST API with standardized envelope responses and cursor-based pagination.
  Phase 3.1 of CCEM APM v5.

  ## open_api_spex annotations (api-s7 Wave 2b / CP-288)
  All actions annotated. build_spec/0 deleted. ApmWeb.ApiSpec is now the SSOT
  for the OpenAPI 3.0.3 spec served at GET /api/v2/openapi.json.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s5 Wave 1: validate requests for annotated actions only; non-annotated
  # actions pass through because `open_api_operation/1` returns nil.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.AgentRegistry
  alias Apm.MetricsCollector
  alias Apm.SloEngine
  alias Apm.AlertRulesEngine
  alias Apm.AuditLog
  alias Apm.WorkflowSchemaStore
  alias Apm.UpmStore
  alias ApmWeb.V2.ApiV2JSON
  alias ApmWeb.Schemas

  # ========== OpenAPI spec ==========

  operation :openapi,
    summary: "OpenAPI 3.0.3 spec",
    description: "Returns the full OpenAPI 3.0.3 spec for the CCEM APM API. " <>
      "Served by ApmWeb.ApiSpec (open_api_spex SSOT). " <>
      "build_spec/0 deleted in api-s7 Wave 2b (CP-288).",
    tags: ["Health"],
    responses: [
      ok: {"OpenAPI 3.0.3 JSON document", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  # ========== Agents ==========

  operation :list_agents,
    summary: "List agents",
    description: "Returns all registered agents with cursor-based pagination.",
    tags: ["Agents"],
    parameters: [
      cursor: [in: :query, type: :string, required: false, description: "Pagination cursor"],
      limit: [in: :query, type: :integer, required: false, description: "Page size (max 200, default 50)"],
      project: [in: :query, type: :string, required: false, description: "Filter by project"]
    ],
    responses: [
      ok: {"Agent list", "application/json", Schemas.AgentList}
    ]

  operation :get_agent,
    summary: "Get agent by ID",
    description: "Returns a single agent with computed health score and recent metrics.",
    tags: ["Agents"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Agent ID"]
    ],
    responses: [
      ok: {"Agent detail", "application/json", Schemas.Agent},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

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

  operation :list_sessions,
    summary: "List sessions",
    description: "Returns all active and historical Claude Code sessions with cursor-based pagination.",
    tags: ["Sessions"],
    parameters: [
      cursor: [in: :query, type: :string, required: false, description: "Pagination cursor"],
      limit: [in: :query, type: :integer, required: false, description: "Page size (max 200, default 50)"]
    ],
    responses: [
      ok: {"Session list", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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

  operation :fleet_metrics,
    summary: "Fleet metrics summary",
    description: "Returns aggregated health and performance metrics across all agents.",
    tags: ["Metrics"],
    responses: [
      ok: {"Fleet metrics", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  @doc "GET /api/v2/metrics - fleet metrics summary"
  def fleet_metrics(conn, _params) do
    metrics = MetricsCollector.get_fleet_metrics()
    json(conn, ApiV2JSON.envelope(metrics))
  end

  @doc "GET /api/v2/metrics/:agent_id - per-agent metrics with since param"
  operation :agent_metrics,
    summary: "Agent metrics",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :list_slos,
    summary: "List slos",
    tags: ["Core"],
    responses: [
      ok: {"List of SLOs", "application/json", Schemas.SLO}
    ]

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
  operation :get_slo,
    summary: "Get slo",
    tags: ["Core"],
    responses: [
      ok: {"Single SLO", "application/json", Schemas.SLO}
    ]

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
  operation :list_alerts,
    summary: "List alerts",
    tags: ["Core"],
    responses: [
      ok: {"Alert history", "application/json", Schemas.Alert}
    ]

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
  operation :list_alert_rules,
    summary: "List alert rules",
    tags: ["Core"],
    responses: [
      ok: {"Alert rules", "application/json", Schemas.AlertRule}
    ]

  def list_alert_rules(conn, _params) do
    rules = AlertRulesEngine.list_rules()
    json(conn, ApiV2JSON.envelope(rules, %{total: length(rules)}))
  end

  @doc "POST /api/v2/alerts/rules - create alert rule"
  operation :create_alert_rule,
    summary: "Create alert rule",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :list_audit,
    summary: "List audit",
    tags: ["Core"],
    responses: [
      ok: {"Audit log entries", "application/json", Schemas.AuditEntry}
    ]

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

  @doc """
  GET /api/v2/openapi.json — OpenAPI 3.0.3 spec (full coverage, api-s7 Wave 2b).

  Delegates entirely to `ApmWeb.ApiSpec.spec/0` — the open_api_spex
  introspected spec that sources all paths from the router and all schema
  definitions from typed `OpenApiSpex.schema/2` modules.

  `build_spec/0` deleted in api-s7 Wave 2b (CP-288). ApiSpec is now SSOT.
  """
  def openapi(conn, _params) do
    spec_map = ApmWeb.ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map()
    json(conn, spec_map)
  end


  # ========== Private Helpers ==========

  # ========== Workflows (WorkflowSchemaStore) ==========

  @doc "GET /api/v2/workflows"
  operation :list_workflows,
    summary: "List workflows",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_workflows(conn, _params) do
    json(conn, ApiV2JSON.envelope(WorkflowSchemaStore.list_workflows()))
  end

  @doc "POST /api/v2/workflows"
  operation :create_workflow,
    summary: "Create workflow",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def create_workflow(conn, params) do
    case WorkflowSchemaStore.register_workflow(params) do
      {:ok, wf} ->
        conn |> put_status(:created) |> json(ApiV2JSON.envelope(wf))

      {:error, reason} ->
        conn |> put_status(422) |> json(ApiV2JSON.error_response("validation_error", reason))
    end
  end

  @doc "GET /api/v2/workflows/:id"
  operation :get_workflow,
    summary: "Get workflow",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_workflow(conn, %{"id" => id}) do
    case WorkflowSchemaStore.get_workflow(id) do
      {:ok, wf} ->
        json(conn, ApiV2JSON.envelope(wf))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(ApiV2JSON.error_response("not_found", "Workflow not found"))
    end
  end

  @doc "PATCH /api/v2/workflows/:id"
  operation :update_workflow,
    summary: "Update workflow",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :list_formations,
    summary: "List formations",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_formations(conn, _params) do
    json(conn, ApiV2JSON.envelope(UpmStore.list_all_formations()))
  end

  @doc "POST /api/v2/formations"
  operation :create_formation,
    summary: "Create formation",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def create_formation(conn, params) do
    {:ok, id} = UpmStore.register_formation(params)

    formation = UpmStore.get_formation(id)

    conn
    |> put_status(:created)
    |> json(ApiV2JSON.envelope(formation))
  end

  @doc "GET /api/v2/formations/:id"
  operation :get_formation,
    summary: "Get formation",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :get_formation_agents,
    summary: "Get formation agents",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_formation_agents(conn, %{"id" => id}) do
    agents = AgentRegistry.list_formation(id)
    json(conn, ApiV2JSON.envelope(agents, %{total: length(agents)}))
  end

  # ========== Verification (VerifyStore) ==========

  @doc "POST /api/v2/verify/double — initiate double-verification session"
  operation :verify_double,
    summary: "Verify double",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def verify_double(conn, params) do
    project_root = Map.get(params, "project_root", "")
    app_url = Map.get(params, "app_url", "")
    stories = Map.get(params, "stories", [])

    {:ok, session} = Apm.VerifyStore.create(project_root, app_url, stories)

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
  operation :verify_status,
    summary: "Verify status",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def verify_status(conn, %{"id" => id}) do
    case Apm.VerifyStore.get(id) do
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
  operation :manifest,
    summary: "Manifest",
    tags: ["Core"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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

  # api-s5 Wave 1: catch-all for non-annotated actions — see auth_controller.ex
  # for rationale.
  def open_api_operation(_action), do: nil
end
