defmodule ApmV5Web.V2.AuthController do
  @moduledoc """
  REST API controller for AgentLock authorization endpoints.

  Provides 13 endpoints under `/api/v2/auth/*` for tool authorization,
  session management, token validation, audit queries, context tracking,
  and policy configuration.

  ## open_api_spex annotations (api-s5 Wave 1 / CP-262)
  Actions annotated: authorize, list_policy_rules (2 of 13)
  Remaining actions documented via build_spec/0 fallback until api-s7 (v9.4.0).
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # Validate requests for annotated actions only. open_api_spex's plug
  # checks the controller's `open_api_operation/1` and skips silently
  # when nil — so non-annotated actions pass through untouched.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5Web.Schemas

  alias ApmV5.Auth.{
    AuthorizationGate,
    SessionStore,
    TokenStore,
    ContextTracker,
    MemoryGate,
    RedactionEngine,
    RateLimiter,
    PolicyRulesStore,
    PendingDecisions,
    ApprovalAuditLog,
    PolicyDecisionStore,
    RiskScoreAggregator
  }

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  operation :authorize,
    summary: "Authorize a tool invocation",
    description: """
    Main AgentLock authorization gate. Evaluates the tool call against policy rules,
    session trust level, and risk thresholds. Returns allow/deny/ask decision.
    """,
    tags: ["AgentLock Authorization"],
    request_body: {"Authorization request", "application/json", Schemas.AuthorizeRequest, required: true},
    responses: [
      ok: {"Authorization decision", "application/json", Schemas.AuthDecision},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]

  @doc "POST /api/v2/auth/authorize — Main authorization gate"
  def authorize(conn, params) do
    agent_id = Map.get(params, "agent_id", "unknown")
    session_id = Map.get(params, "session_id", "default")
    tool_name = Map.get(params, "tool_name", "unknown")
    role = Map.get(params, "role", "agent")
    tool_params = Map.get(params, "params", %{})

    case AuthorizationGate.authorize(agent_id, session_id, tool_name, role, tool_params) do
      {:ok, token_id} ->
        json(conn, %{ok: true, allowed: true, decision: "allow", auth_token: token_id, token_id: token_id})

      {:error, :approval_required, detail} ->
        conn
        |> put_status(200)
        |> json(%{ok: true, allowed: false, decision: "ask", reason: :approval_required, detail: detail})

      {:error, reason, detail} ->
        conn
        |> put_status(200)
        |> json(%{ok: true, allowed: false, decision: "deny", reason: reason, detail: detail})
    end
  end

  @doc "POST /api/v2/auth/execute — Record execution with token"
  operation :execute,
    summary: "Execute",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def execute(conn, params) do
    token_id = Map.get(params, "token_id", "")
    tool_name = Map.get(params, "tool_name", "")
    result = Map.get(params, "result", %{})

    AuthorizationGate.record_execution(token_id, tool_name, result)
    json(conn, %{ok: true, consumed: true})
  end

  @doc "GET /api/v2/auth/summary — Authorization summary stats"
  operation :summary,
    summary: "Summary",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def summary(conn, _params) do
    summary = AuthorizationGate.summary()
    json(conn, %{ok: true, summary: summary})
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/tools — List registered tools"
  operation :list_tools,
    summary: "List tools",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Registered tools", "application/json", Schemas.AuthTool}
    ]

  def list_tools(conn, _params) do
    tools =
      AuthorizationGate.list_tools()
      |> Enum.map(&tool_to_json/1)

    json(conn, %{ok: true, tools: tools, count: length(tools)})
  end

  @doc "POST /api/v2/auth/tools — Register a tool"
  operation :register_tool,
    summary: "Register tool",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def register_tool(conn, params) do
    tool_name = Map.get(params, "name", "")
    risk_level = params |> Map.get("risk_level", "low") |> String.to_existing_atom()

    opts =
      [
        requires_auth: Map.get(params, "requires_auth", true),
        allowed_roles: Map.get(params, "allowed_roles", [])
      ]

    AuthorizationGate.register_tool(tool_name, risk_level, opts)
    json(conn, %{ok: true, registered: tool_name})
  end

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/sessions — Create session"
  operation :create_session,
    summary: "Create session",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def create_session(conn, params) do
    user_id = Map.get(params, "user_id", "unknown")
    role = Map.get(params, "role", "agent")

    opts = [
      data_boundary:
        params
        |> Map.get("data_boundary", "authenticated_user_only")
        |> String.to_existing_atom(),
      metadata: Map.get(params, "metadata", %{})
    ]

    {:ok, session_id} = SessionStore.create(user_id, role, opts)
    json(conn, %{ok: true, session_id: session_id})
  end

  @doc "GET /api/v2/auth/sessions — List active sessions"
  operation :list_sessions,
    summary: "List sessions",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Active auth sessions", "application/json", Schemas.AuthSession}
    ]

  def list_sessions(conn, _params) do
    sessions =
      SessionStore.list_active()
      |> Enum.map(&session_to_json/1)

    json(conn, %{ok: true, sessions: sessions, count: length(sessions)})
  end

  @doc "GET /api/v2/auth/sessions/:id — Get session"
  operation :get_session,
    summary: "Get session",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Single auth session", "application/json", Schemas.AuthSession}
    ]

  def get_session(conn, %{"id" => session_id}) do
    case SessionStore.get(session_id) do
      nil ->
        conn |> put_status(404) |> json(%{ok: false, error: "Session not found"})

      session ->
        json(conn, %{ok: true, session: session_to_json(session)})
    end
  end

  @doc "DELETE /api/v2/auth/sessions/:id — Destroy session"
  operation :destroy_session,
    summary: "Destroy session",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def destroy_session(conn, %{"id" => session_id}) do
    SessionStore.destroy(session_id)
    json(conn, %{ok: true, destroyed: session_id})
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/tokens/:id — Get token"
  operation :get_token,
    summary: "Get token",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_token(conn, %{"id" => token_id}) do
    case TokenStore.get(token_id) do
      nil ->
        conn |> put_status(404) |> json(%{ok: false, error: "Token not found"})

      token ->
        json(conn, %{
          ok: true,
          token: %{
            token_id: token.token_id,
            status: token.status,
            tool_name: token.tool_name,
            agent_id: token.agent_id,
            issued_at: DateTime.to_iso8601(token.issued_at),
            expires_at: DateTime.to_iso8601(token.expires_at)
          }
        })
    end
  end

  @doc "POST /api/v2/auth/tokens/:id/revoke — Revoke token"
  operation :revoke_token,
    summary: "Revoke token",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def revoke_token(conn, %{"id" => token_id}) do
    case TokenStore.revoke(token_id) do
      :ok -> json(conn, %{ok: true, revoked: token_id})
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{ok: false, error: "Token not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Context & Trust
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/context/write — Record context write"
  operation :record_context,
    summary: "Record context",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def record_context(conn, params) do
    session_id = Map.get(params, "session_id", "default")
    agent_id = Map.get(params, "agent_id", "unknown")
    source = params |> Map.get("source", "tool_output") |> String.to_existing_atom()
    content_hash = Map.get(params, "content_hash", "")

    {:ok, entry} = ContextTracker.record_write(session_id, agent_id, source, content_hash)

    json(conn, %{
      ok: true,
      trust_ceiling: ContextTracker.get_trust_ceiling(session_id),
      entry_id: entry.id
    })
  end

  @doc "GET /api/v2/auth/context/trust — Get trust ceiling"
  operation :get_trust,
    summary: "Get trust",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_trust(conn, params) do
    session_id = Map.get(params, "session_id", "default")
    ceiling = ContextTracker.get_trust_ceiling(session_id)
    all_ceilings = ContextTracker.all_trust_ceilings()

    json(conn, %{ok: true, session_trust: ceiling, all_ceilings: all_ceilings})
  end

  # ---------------------------------------------------------------------------
  # Memory Gate
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/memory/authorize-write — Authorize memory write"
  operation :authorize_memory_write,
    summary: "Authorize memory write",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def authorize_memory_write(conn, params) do
    session_id = Map.get(params, "session_id", "default")
    agent_id = Map.get(params, "agent_id", "unknown")
    content = Map.get(params, "content", "")
    persistence = params |> Map.get("persistence", "session") |> String.to_existing_atom()

    case MemoryGate.authorize_write(session_id, agent_id, content, persistence) do
      :ok ->
        json(conn, %{ok: true, allowed: true})

      {:error, reason, detail} ->
        json(conn, %{ok: true, allowed: false, reason: reason, detail: detail})
    end
  end

  @doc "POST /api/v2/auth/memory/authorize-read — Authorize memory read"
  operation :authorize_memory_read,
    summary: "Authorize memory read",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def authorize_memory_read(conn, params) do
    session_id = Map.get(params, "session_id", "default")
    agent_id = Map.get(params, "agent_id", "unknown")

    case MemoryGate.authorize_read(session_id, agent_id) do
      :ok ->
        json(conn, %{ok: true, allowed: true})

      {:error, reason, detail} ->
        json(conn, %{ok: true, allowed: false, reason: reason, detail: detail})
    end
  end

  # ---------------------------------------------------------------------------
  # Rate Limits
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/rate-limits — Current rate limit state"
  operation :rate_limits,
    summary: "Rate limits",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def rate_limits(conn, _params) do
    stats = RateLimiter.stats()
    json(conn, %{ok: true, rate_limits: stats})
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/redact — Redact sensitive data from text"
  operation :redact,
    summary: "Redact",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def redact(conn, params) do
    text = Map.get(params, "text", "")
    mode = params |> Map.get("mode", "auto") |> String.to_existing_atom()

    result = RedactionEngine.redact(text, mode)

    json(conn, %{
      ok: true,
      redacted_text: result.redacted_text,
      had_redactions: result.had_redactions,
      redaction_count: length(result.redactions)
    })
  end

  # ---------------------------------------------------------------------------
  # Audit
  # ---------------------------------------------------------------------------

  @doc """
  GET /api/v2/auth/audit — Query authorization audit log with cursor pagination.

  ## Query parameters
  - `after`  — integer id cursor (exclusive); return only events with id > after
  - `limit`  — page size (default 50, max 500)

  ## Response envelope
      %{
        ok: true,
        data: [audit_entry, ...],
        meta: %{next_cursor: integer | nil, has_more: boolean, count: integer}
      }
  """
  operation :audit_log,
    summary: "Audit log",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def audit_log(conn, params) do
    limit = params |> Map.get("limit", "50") |> parse_integer(50) |> min(500)
    after_cursor = params |> Map.get("after") |> parse_cursor()

    page_opts =
      if is_integer(after_cursor) do
        [limit: limit, after: after_cursor]
      else
        [limit: limit]
      end

    {data, next_cursor} =
      try do
        # Fetch a page of events (cursor-filtered server-side in ETS).
        {raw_events, _page_cursor} = ApmV5.AuditLog.query_page(page_opts)

        # Apply auth: event_type prefix filter on the client side.
        auth_events =
          Enum.filter(raw_events, fn entry ->
            event_type = Map.get(entry, :event_type, "")
            is_binary(event_type) and String.starts_with?(event_type, "auth:")
          end)

        # next_cursor is the raw integer id of the last matching event.
        cursor =
          case auth_events do
            [] -> nil
            _ -> auth_events |> List.last() |> Map.get(:id)
          end

        {Enum.map(auth_events, &audit_to_json/1), cursor}
      rescue
        _ -> {[], nil}
      end

    json(conn, %{
      ok: true,
      data: data,
      meta: %{
        next_cursor: next_cursor,
        has_more: not is_nil(next_cursor),
        count: length(data)
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Pending Decisions
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/pending — List pending escalation requests"
  operation :list_pending,
    summary: "List pending",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Pending decisions", "application/json", Schemas.PendingDecision}
    ]

  def list_pending(conn, _params) do
    pending = PendingDecisions.list_pending()
    |> Enum.map(&pending_to_json/1)
    json(conn, %{ok: true, pending: pending, count: length(pending)})
  end

  @doc "GET /api/v2/auth/pending/:id — Get/poll a single pending decision"
  operation :get_pending,
    summary: "Get pending",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Pending decision", "application/json", Schemas.PendingDecision}
    ]

  def get_pending(conn, %{"id" => request_id} = params) do
    wait_ms = params |> Map.get("wait", "0") |> to_integer() |> Kernel.*(1000) |> min(45_000)

    result =
      if wait_ms > 0 do
        PendingDecisions.poll(request_id, wait_ms)
      else
        case PendingDecisions.get(request_id) do
          nil -> :not_found
          entry -> {:immediate, entry}
        end
      end

    case result do
      {:decided, entry} ->
        json(conn, %{
          ok: true,
          status: "decided",
          decision: entry.decision,
          entry: pending_to_json(entry)
        })

      {:immediate, entry} ->
        json(conn, %{ok: true, entry: pending_to_json(entry)})

      {:timeout, :pending} ->
        json(conn, %{ok: true, status: "pending", decision: nil})

      :not_found ->
        conn |> put_status(404) |> json(%{ok: false, error: "Not found"})
    end
  end

  @doc "GET /api/v2/auth/decide — Browser-clickable approve/deny via ?request_id=&decision=approve|deny; redirects to /authorization"
  operation :decide_get,
    summary: "Decide get",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def decide_get(conn, params) do
    request_id = Map.get(params, "request_id", "")
    raw_decision = Map.get(params, "decision", "")

    decision =
      case raw_decision do
        "approve" -> :approve
        "deny" -> :deny
        _ -> nil
      end

    result =
      cond do
        is_nil(decision) or request_id == "" -> :bad_params
        true ->
          case PendingDecisions.decide(request_id, decision) do
            {:ok, _} -> {:ok, raw_decision}
            :ok -> {:ok, raw_decision}
            {:error, :not_found} -> :not_found
          end
      end

    # Redirect to /authorization with status in query string (no flash needed — API pipeline)
    redirect_to =
      case result do
        {:ok, d} -> "/authorization?decided=#{d}&id=#{request_id}"
        :not_found -> "/authorization?decided=not_found&id=#{request_id}"
        :bad_params -> "/authorization?decided=error"
      end

    conn |> redirect(to: redirect_to)
  end

  @doc "POST /api/v2/auth/decide — Approve or deny a pending escalation"
  operation :decide,
    summary: "Decide",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def decide(conn, params) do
    request_id = Map.get(params, "request_id", "")
    raw_decision = Map.get(params, "decision", "")

    decision =
      case raw_decision do
        "approve" -> :approve
        "deny" -> :deny
        _ -> nil
      end

    if is_nil(decision) do
      conn |> put_status(400) |> json(%{ok: false, error: "decision must be 'approve' or 'deny'"})
    else
      case PendingDecisions.decide(request_id, decision) do
        {:ok, token_id} ->
          json(conn, %{ok: true, decided: request_id, decision: raw_decision, token_id: token_id})

        :ok ->
          json(conn, %{ok: true, decided: request_id, decision: raw_decision})

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{ok: false, error: "Pending request not found"})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Policy Rules
  # ---------------------------------------------------------------------------

  operation :list_policy_rules,
    summary: "List policy rules",
    description: "Returns all permanent allow/deny/escalate policy rules for tool authorization.",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Policy rule list", "application/json", Schemas.PolicyRuleList}
    ]

  @doc "GET /api/v2/auth/policy/rules — List permanent allow/deny rules"
  def list_policy_rules(conn, _params) do
    rules = PolicyRulesStore.list_rules()
    json(conn, %{ok: true, rules: rules, count: length(rules)})
  end

  @doc "POST /api/v2/auth/policy/rules — Add permanent allow/deny rule"
  operation :add_policy_rule,
    summary: "Add policy rule",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def add_policy_rule(conn, params) do
    tool_name = Map.get(params, "tool_name", "")
    raw_action = Map.get(params, "action", "")

    action =
      case raw_action do
        "always_allow" -> :always_allow
        "always_deny" -> :always_deny
        _ -> nil
      end

    cond do
      tool_name == "" ->
        conn |> put_status(400) |> json(%{ok: false, error: "tool_name required"})

      is_nil(action) ->
        conn |> put_status(400) |> json(%{ok: false, error: "action must be 'always_allow' or 'always_deny'"})

      true ->
        PolicyRulesStore.add_rule(tool_name, action)
        json(conn, %{ok: true, tool_name: tool_name, action: raw_action})
    end
  end

  @doc "DELETE /api/v2/auth/policy/rules/:tool_name — Remove a permanent rule"
  operation :remove_policy_rule,
    summary: "Remove policy rule",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def remove_policy_rule(conn, %{"tool_name" => tool_name}) do
    PolicyRulesStore.remove_rule(tool_name)
    json(conn, %{ok: true, removed: tool_name})
  end

  @doc """
  GET /api/v2/auth/policy/decisions — Query authorization decisions (NIST AI RMF GOVERN evidence)

  Query params (all optional):
  - `agent_id` — substring match
  - `session_id` — exact match
  - `formation_id` — exact match
  - `outcome` — allow | deny | ask
  - `since` — ISO 8601 lower bound
  - `until` — ISO 8601 upper bound
  - `limit` — integer (default 200)
  - `stats` — if "true", return outcome stats summary only
  """
  operation :list_policy_decisions,
    summary: "List policy decisions",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_policy_decisions(conn, params) do
    if Map.get(params, "stats") == "true" do
      s = PolicyDecisionStore.stats()
      json(conn, %{ok: true, stats: s, total: PolicyDecisionStore.count()})
    else
      filter = build_decision_filter(params)
      decisions = PolicyDecisionStore.query(filter) |> Enum.map(&decision_to_json/1)
      json(conn, %{ok: true, decisions: decisions, count: length(decisions), total: PolicyDecisionStore.count()})
    end
  end

  defp build_decision_filter(params) do
    filter = %{}

    filter =
      case Map.get(params, "agent_id") do
        nil -> filter
        v -> Map.put(filter, :agent_id, v)
      end

    filter =
      case Map.get(params, "session_id") do
        nil -> filter
        v -> Map.put(filter, :session_id, v)
      end

    filter =
      case Map.get(params, "formation_id") do
        nil -> filter
        v -> Map.put(filter, :formation_id, v)
      end

    filter =
      case Map.get(params, "outcome") do
        nil -> filter
        v -> Map.put(filter, :outcome, parse_outcome(v))
      end

    filter =
      case Map.get(params, "since") do
        nil -> filter
        v -> case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> Map.put(filter, :since, dt)
          _ -> filter
        end
      end

    filter =
      case Map.get(params, "until") do
        nil -> filter
        v -> case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> Map.put(filter, :until, dt)
          _ -> filter
        end
      end

    case Map.get(params, "limit") do
      nil -> filter
      v ->
        case Integer.parse(v) do
          {n, _} when n > 0 -> Map.put(filter, :limit, n)
          _ -> filter
        end
    end
  end

  defp parse_outcome("allow"), do: :allow
  defp parse_outcome("deny"), do: :deny
  defp parse_outcome("ask"), do: :ask
  defp parse_outcome(_), do: nil

  defp decision_to_json(%{} = r) do
    %{
      id: r.id,
      policy_id: r[:policy_id],
      agent_id: r.agent_id,
      session_id: r.session_id,
      formation_id: r[:formation_id],
      tool_name: r.tool_name,
      risk_level: r.risk_level,
      outcome: r.outcome,
      trust_level: r[:trust_level],
      latency_ms: r[:latency_ms],
      timestamp: if(r[:timestamp], do: DateTime.to_iso8601(r.timestamp))
    }
  end

  # ---------------------------------------------------------------------------
  # apm-auth skill spec aliases (CCEM-565)
  # The 8 paths documented in the apm-auth skill but missing from the original
  # controller. Each delegates to the established machinery above.
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/session/start — Register agent session (apm-auth skill compat)"
  operation :session_start,
    summary: "Session start",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def session_start(conn, params) do
    user_id = Map.get(params, "agent_id", Map.get(params, "user_id", "unknown"))
    role = Map.get(params, "role", "agent")
    trust_level = Map.get(params, "trust_level", "standard")

    opts = [
      data_boundary: :authenticated_user_only,
      metadata: Map.merge(Map.get(params, "metadata", %{}), %{"trust_level" => trust_level})
    ]

    {:ok, session_id} = SessionStore.create(user_id, role, opts)
    json(conn, %{ok: true, session_id: session_id, trust_level: trust_level})
  end

  @doc "POST /api/v2/auth/session/heartbeat — Keepalive for agent session"
  operation :session_heartbeat,
    summary: "Session heartbeat",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def session_heartbeat(conn, params) do
    session_id = Map.get(params, "session_id", "")

    case SessionStore.get(session_id) do
      nil ->
        conn |> put_status(404) |> json(%{ok: false, error: "Session not found"})

      _session ->
        SessionStore.increment_tool_calls(session_id)
        json(conn, %{ok: true, session_id: session_id, refreshed: true})
    end
  end

  @doc "POST /api/v2/auth/session/end — Terminate agent session"
  operation :session_end,
    summary: "Session end",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def session_end(conn, params) do
    session_id = Map.get(params, "session_id", "")
    SessionStore.destroy(session_id)
    json(conn, %{ok: true, session_id: session_id, terminated: true})
  end

  @doc "POST /api/v2/auth/token/redeem — Redeem auth token for execution permit"
  operation :redeem_token,
    summary: "Redeem token",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def redeem_token(conn, params) do
    token_id = Map.get(params, "auth_token", Map.get(params, "token_id", ""))
    scope = Map.get(params, "scope", "")
    single_use = Map.get(params, "single_use", false)
    ttl_ms = Map.get(params, "ttl_ms", 30_000)

    if token_id == "" and scope != "" do
      # Mint a new scoped token (used by /specialize --authorize=once|time=N)
      {:ok, new_token_id} = TokenStore.generate("scope-agent", "scope-session", scope, %{ttl_ms: ttl_ms, single_use: single_use})

      json(conn, %{ok: true, auth_token: new_token_id, token_id: new_token_id, ttl_ms: ttl_ms, scope: scope})
    else
      case TokenStore.get(token_id) do
        nil ->
          conn |> put_status(404) |> json(%{ok: false, error: "Token not found or expired"})

        token ->
          json(conn, %{
            ok: true,
            valid: token.status == :active,
            token_id: token.token_id,
            tool_name: token.tool_name,
            expires_at: DateTime.to_iso8601(token.expires_at)
          })
      end
    end
  end

  @doc "GET /api/v2/auth/policies — List active policy rules (apm-auth skill compat)"
  operation :list_policies,
    summary: "List policies",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_policies(conn, _params) do
    rules = PolicyRulesStore.list_rules()
    json(conn, %{ok: true, policies: rules, rules: rules, count: length(rules)})
  end

  @doc "POST /api/v2/auth/policies — Create or update a policy rule"
  operation :create_policy,
    summary: "Create policy",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def create_policy(conn, params) do
    tool_name = Map.get(params, "tool", Map.get(params, "tool_name", ""))
    scope = Map.get(params, "scope", "")
    default_action = Map.get(params, "default", Map.get(params, "action", "allow"))
    name = Map.get(params, "name", "")

    effective_tool = cond do
      tool_name != "" -> tool_name
      String.starts_with?(scope, "formation:") -> "*"
      name != "" -> "*"
      true -> ""
    end

    action =
      case default_action do
        "allow" -> :always_allow
        "deny" -> :always_deny
        "always_allow" -> :always_allow
        "always_deny" -> :always_deny
        _ -> :always_allow
      end

    cond do
      effective_tool == "" ->
        conn |> put_status(400) |> json(%{ok: false, error: "tool or scope required"})

      true ->
        PolicyRulesStore.add_rule(effective_tool, action)
        json(conn, %{ok: true, tool_name: effective_tool, action: default_action, scope: scope, name: name})
    end
  end

  @doc "GET /api/v2/auth/approvals/pending — List pending human-approval decisions"
  operation :list_approvals_pending,
    summary: "List approvals pending",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_approvals_pending(conn, _params) do
    pending = PendingDecisions.list_pending() |> Enum.map(&pending_to_json/1)
    json(conn, %{ok: true, pending: pending, count: length(pending)})
  end

  @doc "POST /api/v2/auth/approvals/:id/decide — Approve or deny a pending decision"
  operation :decide_approval,
    summary: "Decide approval",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def decide_approval(conn, %{"id" => request_id} = params) do
    raw_decision = Map.get(params, "decision", "")
    sticky = Map.get(params, "sticky", false)

    decision =
      case raw_decision do
        "allow" -> :approve
        "approve" -> :approve
        "deny" -> :deny
        _ -> nil
      end

    cond do
      is_nil(decision) ->
        conn |> put_status(400) |> json(%{ok: false, error: "decision must be 'allow'/'approve' or 'deny'"})

      true ->
        result = PendingDecisions.decide(request_id, decision)

        if sticky and decision == :approve do
          case PendingDecisions.get(request_id) do
            %{tool_name: tool} when is_binary(tool) -> PolicyRulesStore.add_rule(tool, :always_allow)
            _ -> :ok
          end
        end

        case result do
          {:ok, token_id} ->
            json(conn, %{ok: true, decided: request_id, decision: raw_decision, token_id: token_id})

          :ok ->
            json(conn, %{ok: true, decided: request_id, decision: raw_decision})

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{ok: false, error: "Pending request not found"})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Notification Testing
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/notifications/test — Inject a test audit entry for CCEMHelper notification testing"
  operation :test_notification,
    summary: "Test notification",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def test_notification(conn, params) do
    tool_name = Map.get(params, "tool_name", "Bash")
    risk_level_str = Map.get(params, "risk_level", "high")

    risk_level =
      case risk_level_str do
        "critical" -> :critical
        "high" -> :high
        "medium" -> :medium
        _ -> :high
      end

    # Create a fake pending decision so CCEMHelper sees a real pending escalation
    {:ok, request_id} =
      PendingDecisions.add(
        tool_name,
        "test-session",
        risk_level,
        "test-agent",
        %{"command" => "echo test notification"}
      )

    # Also log an audit entry for visibility in the audit tab
    ApmV5.AuditLog.log("auth:test_notification", "agentlock", tool_name, %{
      tool_name: tool_name,
      risk_level: risk_level_str,
      request_id: request_id
    })

    # Broadcast on agentlock channel so any LiveView subscribers see it immediately
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:test_notification, %{
      tool_name: tool_name,
      risk_level: risk_level,
      request_id: request_id
    }})

    json(conn, %{ok: true, request_id: request_id, message: "Test notification injected"})
  end

  # ---------------------------------------------------------------------------
  # Approval History (US-326)
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/approvals/log — Record an authorization decision"
  operation :log_approval,
    summary: "Log approval",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def log_approval(conn, params) do
    entry = %{
      agent_id: Map.get(params, "agent_id", "unknown"),
      tool_name: Map.get(params, "tool_name", "unknown"),
      decision: params |> Map.get("decision", "approve") |> String.to_existing_atom(),
      request_id: Map.get(params, "request_id"),
      session_id: Map.get(params, "session_id"),
      risk_level: Map.get(params, "risk_level"),
      context_snapshot: Map.get(params, "context_snapshot", %{})
    }

    ApprovalAuditLog.log_decision(entry)
    json(conn, %{ok: true, logged: true})
  end

  @doc "GET /api/v2/approvals/history — List approval audit log with optional filters"
  operation :list_approval_history,
    summary: "List approval history",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"Approval audit entries", "application/json", Schemas.ApprovalAuditEntry}
    ]

  def list_approval_history(conn, params) do
    opts =
      []
      |> maybe_add_opt(:agent_id, Map.get(params, "agent_id"))
      |> maybe_add_opt(:tool_name, Map.get(params, "tool_name"))
      |> maybe_add_opt(:decision, parse_decision(Map.get(params, "decision")))
      |> maybe_add_opt(:limit, parse_limit(Map.get(params, "limit")))

    entries =
      ApprovalAuditLog.list_entries(opts)
      |> Enum.map(&audit_entry_to_json/1)

    json(conn, %{ok: true, entries: entries, count: length(entries)})
  end

  defp parse_decision("approve"), do: :approve
  defp parse_decision("deny"), do: :deny
  defp parse_decision(_), do: nil

  defp parse_limit(nil), do: nil
  defp parse_limit(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_limit(val) when is_integer(val), do: val
  defp parse_limit(_), do: nil

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp audit_entry_to_json(%{} = entry) do
    %{
      id: entry[:id],
      agent_id: entry.agent_id,
      tool_name: entry.tool_name,
      decision: entry.decision,
      request_id: entry[:request_id],
      session_id: entry[:session_id],
      risk_level: entry[:risk_level],
      timestamp: if(entry[:timestamp], do: DateTime.to_iso8601(entry.timestamp)),
      context_snapshot: entry[:context_snapshot] || %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp pending_to_json(%{} = entry) do
    %{
      request_id: entry.request_id,
      tool_name: entry.tool_name,
      session_id: entry.session_id,
      agent_id: entry.agent_id,
      risk_level: entry.risk_level,
      params: entry.params,
      status: entry.status,
      decision: entry.decision,
      token_id: Map.get(entry, :token_id),
      decided_at: if(entry.decided_at, do: DateTime.to_iso8601(entry.decided_at)),
      inserted_at: DateTime.to_iso8601(entry.inserted_at),
      expires_at: DateTime.to_iso8601(entry.expires_at)
    }
  end

  defp tool_to_json(%{} = tool) do
    %{
      name: tool.name,
      risk_level: tool.risk_level,
      requires_auth: tool.requires_auth,
      allowed_roles: tool.allowed_roles,
      data_boundary: tool.data_boundary,
      max_records: tool.max_records,
      rate_limit: tool.rate_limit,
      registered_at: if(tool.registered_at, do: DateTime.to_iso8601(tool.registered_at))
    }
  end

  defp session_to_json(%{} = session) do
    %{
      id: session.id,
      user_id: session.user_id,
      role: session.role,
      data_boundary: session.data_boundary,
      trust_ceiling: session.trust_ceiling,
      tool_call_count: session.tool_call_count,
      denied_count: session.denied_count,
      created_at: if(session.created_at, do: DateTime.to_iso8601(session.created_at)),
      expires_at: if(session.expires_at, do: DateTime.to_iso8601(session.expires_at))
    }
  end

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 50
    end
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(_), do: 50

  # parse_integer/2 — like to_integer/1 but with a configurable default.
  defp parse_integer(val, _default) when is_integer(val), do: val

  defp parse_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_integer(_val, default), do: default

  # parse_cursor/1 — parses an "after" query param to an integer cursor or nil.
  defp parse_cursor(nil), do: nil
  defp parse_cursor(val) when is_integer(val) and val > 0, do: val

  defp parse_cursor(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_cursor(_), do: nil

  defp audit_to_json(%{} = entry) do
    raw_id = Map.get(entry, :id)

    stable_id =
      cond do
        is_integer(raw_id) -> "audit-#{raw_id}"
        is_binary(raw_id) -> raw_id
        true ->
          tool = Map.get(entry, :event_type, "unknown")
          ts = Map.get(entry, :timestamp, "0")
          "audit-#{tool}-#{ts}"
      end

    %{
      id: stable_id,
      timestamp: Map.get(entry, :timestamp),
      event_type: Map.get(entry, :event_type),
      actor: Map.get(entry, :actor),
      resource: Map.get(entry, :resource),
      details: Map.get(entry, :details, %{}),
      correlation_id: Map.get(entry, :correlation_id)
    }
  end

  # ---------------------------------------------------------------------------
  # API Key Management (US-047 / CCEM-265)
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/api-keys — List all API keys (masked)"
  operation :list_api_keys,
    summary: "List api keys",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_api_keys(conn, _params) do
    keys = ApmV5.ApiKeyStore.list_keys()
    json(conn, %{ok: true, keys: keys, count: length(keys)})
  end

  @doc "POST /api/v2/auth/api-keys — Generate a new API key"
  operation :create_api_key,
    summary: "Create api key",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def create_api_key(conn, params) do
    label = Map.get(params, "label", "unnamed")

    case ApmV5.ApiKeyStore.generate_key(label) do
      {:ok, key} ->
        conn
        |> put_status(201)
        |> json(%{ok: true, key: key, label: label, message: "Store this key securely — it will not be shown again"})
    end
  end

  @doc "DELETE /api/v2/auth/api-keys/:id — Revoke an API key"
  operation :revoke_api_key,
    summary: "Revoke api key",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def revoke_api_key(conn, %{"id" => key}) do
    :ok = ApmV5.ApiKeyStore.revoke_key(key)
    json(conn, %{ok: true, revoked: true})
  end

  # ---------------------------------------------------------------------------
  # Risk Score Aggregator (CP-231 / comp-map2)
  # ---------------------------------------------------------------------------

  @doc """
  GET /api/v2/auth/risk-scores?scope=session|formation&limit=N

  Returns paginated composite risk aggregates sorted by score descending.

  Query params:
  - `scope` — `"session"` (default) or `"formation"`
  - `limit` — max results (default 10, max 100)
  """
  operation :list_risk_scores,
    summary: "List risk scores",
    tags: ["AgentLock Authorization"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_risk_scores(conn, params) do
    scope = Map.get(params, "scope", "session")
    limit = params |> Map.get("limit", "10") |> parse_risk_limit()

    {results, items_key} =
      case scope do
        "formation" ->
          {RiskScoreAggregator.top_formations(limit), "formations"}

        _ ->
          {RiskScoreAggregator.top_sessions(limit), "sessions"}
      end

    items =
      Enum.map(results, fn {id, agg} ->
        %{
          "id" => id,
          "score" => Float.round(agg.score, 4),
          "level" => to_string(agg.level),
          "tool_call_count" => agg.tool_call_count,
          "critical_count" => agg.critical_count,
          "denial_rate" => Float.round(agg.denial_rate, 4),
          "last_updated" => DateTime.to_iso8601(agg.last_updated)
        }
      end)

    body = %{
      "ok" => true,
      "scope" => scope,
      "count" => length(items),
      "limit" => limit
    }

    json(conn, Map.put(body, items_key, items))
  end

  defp parse_risk_limit(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> min(max(n, 1), 100)
      _ -> 10
    end
  end

  defp parse_risk_limit(v) when is_integer(v), do: min(max(v, 1), 100)
  defp parse_risk_limit(_), do: 10

  # api-s5 Wave 1: catch-all for non-annotated actions.
  # OpenApiSpex.ControllerSpecs's `before_compile` callback otherwise emits
  # `IO.warn` (returns `:ok`) which CastAndValidate misinterprets as a valid
  # operation struct and crashes. Returning `nil` triggers the documented
  # `{:skip_it, nil}` path so non-annotated actions pass through untouched.
  def open_api_operation(_action), do: nil
end
