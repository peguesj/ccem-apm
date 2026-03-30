defmodule ApmV5Web.V2.AuthController do
  @moduledoc """
  REST API controller for AgentLock authorization endpoints.

  Provides 13 endpoints under `/api/v2/auth/*` for tool authorization,
  session management, token validation, audit queries, context tracking,
  and policy configuration.
  """

  use ApmV5Web, :controller

  alias ApmV5.Auth.{
    AuthorizationGate,
    SessionStore,
    TokenStore,
    ContextTracker,
    MemoryGate,
    RedactionEngine,
    RateLimiter,
    PolicyRulesStore,
    PendingDecisions
  }

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/authorize — Main authorization gate"
  def authorize(conn, params) do
    agent_id = Map.get(params, "agent_id", "unknown")
    session_id = Map.get(params, "session_id", "default")
    tool_name = Map.get(params, "tool_name", "unknown")
    role = Map.get(params, "role", "agent")
    tool_params = Map.get(params, "params", %{})

    case AuthorizationGate.authorize(agent_id, session_id, tool_name, role, tool_params) do
      {:ok, token_id} ->
        json(conn, %{ok: true, allowed: true, token_id: token_id})

      {:error, reason, detail} ->
        conn
        |> put_status(200)
        |> json(%{ok: true, allowed: false, reason: reason, detail: detail})
    end
  end

  @doc "POST /api/v2/auth/execute — Record execution with token"
  def execute(conn, params) do
    token_id = Map.get(params, "token_id", "")
    tool_name = Map.get(params, "tool_name", "")
    result = Map.get(params, "result", %{})

    AuthorizationGate.record_execution(token_id, tool_name, result)
    json(conn, %{ok: true, consumed: true})
  end

  @doc "GET /api/v2/auth/summary — Authorization summary stats"
  def summary(conn, _params) do
    summary = AuthorizationGate.summary()
    json(conn, %{ok: true, summary: summary})
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/tools — List registered tools"
  def list_tools(conn, _params) do
    tools =
      AuthorizationGate.list_tools()
      |> Enum.map(&tool_to_json/1)

    json(conn, %{ok: true, tools: tools, count: length(tools)})
  end

  @doc "POST /api/v2/auth/tools — Register a tool"
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
  def list_sessions(conn, _params) do
    sessions =
      SessionStore.list_active()
      |> Enum.map(&session_to_json/1)

    json(conn, %{ok: true, sessions: sessions, count: length(sessions)})
  end

  @doc "GET /api/v2/auth/sessions/:id — Get session"
  def get_session(conn, %{"id" => session_id}) do
    case SessionStore.get(session_id) do
      nil ->
        conn |> put_status(404) |> json(%{ok: false, error: "Session not found"})

      session ->
        json(conn, %{ok: true, session: session_to_json(session)})
    end
  end

  @doc "DELETE /api/v2/auth/sessions/:id — Destroy session"
  def destroy_session(conn, %{"id" => session_id}) do
    SessionStore.destroy(session_id)
    json(conn, %{ok: true, destroyed: session_id})
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/tokens/:id — Get token"
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
  def rate_limits(conn, _params) do
    stats = RateLimiter.stats()
    json(conn, %{ok: true, rate_limits: stats})
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/auth/redact — Redact sensitive data from text"
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

  @doc "GET /api/v2/auth/audit — Query authorization audit log"
  def audit_log(conn, params) do
    limit = params |> Map.get("limit", "50") |> to_integer()

    # Delegate to AuditLog with auth-specific filter
    entries =
      try do
        ApmV5.AuditLog.tail(limit)
        |> Enum.filter(fn entry ->
          event_type = Map.get(entry, :event_type, "")
          String.starts_with?(event_type, "auth:")
        end)
        |> Enum.map(&audit_to_json/1)
      rescue
        _ -> []
      end

    json(conn, %{ok: true, entries: entries, count: length(entries)})
  end

  # ---------------------------------------------------------------------------
  # Pending Decisions
  # ---------------------------------------------------------------------------

  @doc "GET /api/v2/auth/pending — List pending escalation requests"
  def list_pending(conn, _params) do
    pending = PendingDecisions.list_pending()
    |> Enum.map(&pending_to_json/1)
    json(conn, %{ok: true, pending: pending, count: length(pending)})
  end

  @doc "GET /api/v2/auth/pending/:id — Get/poll a single pending decision"
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

  @doc "GET /api/v2/auth/policy/rules — List permanent allow/deny rules"
  def list_policy_rules(conn, _params) do
    rules = PolicyRulesStore.list_rules()
    json(conn, %{ok: true, rules: rules, count: length(rules)})
  end

  @doc "POST /api/v2/auth/policy/rules — Add permanent allow/deny rule"
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
  def remove_policy_rule(conn, %{"tool_name" => tool_name}) do
    PolicyRulesStore.remove_rule(tool_name)
    json(conn, %{ok: true, removed: tool_name})
  end

  # ---------------------------------------------------------------------------
  # Notification Testing
  # ---------------------------------------------------------------------------

  @doc "POST /api/v2/notifications/test — Inject a test audit entry for CCEMHelper notification testing"
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
end
