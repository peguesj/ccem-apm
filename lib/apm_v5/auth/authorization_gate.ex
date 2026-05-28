defmodule ApmV5.Auth.AuthorizationGate do
  @moduledoc """
  Central authorization enforcement GenServer (Layer 2) for AgentLock.

  Intercepts tool calls, evaluates policy via PolicyEngine, issues
  execution tokens via TokenStore, and delegates escalations to
  the existing ApprovalGate.

  ## Authorization Pipeline
  1. Validate session via SessionStore
  2. Evaluate policy via PolicyEngine
  3. Check rate limits via RateLimiter
  4. Issue token via TokenStore (if permitted)
  5. Delegate to ApprovalGate (if escalation needed)
  6. Log to AuditLog
  7. Broadcast on PubSub + AG-UI EventBus

  ## ETS Table
  `:agentlock_tool_registry` — registered tools with permissions
  """

  use GenServer

  require Logger

  alias ApmV5.Auth.Types
  alias ApmV5.Auth.Types.AuthTool
  alias ApmV5.Auth.{PolicyEngine, TokenStore, SessionStore, RateLimiter, FormationRateLimiter,
                     ContextTracker, PolicyRulesStore, PendingDecisions}

  @tool_registry :agentlock_tool_registry

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a tool with AgentLock permissions.
  """
  @spec register_tool(String.t(), Types.risk_level(), keyword()) :: :ok
  def register_tool(tool_name, risk_level, opts \\ []) do
    GenServer.call(__MODULE__, {:register_tool, tool_name, risk_level, opts})
  end

  @doc """
  Authorize a tool call. Returns `{:ok, token_id}` or `{:error, reason, detail}`.

  This is the main entry point called by hooks and API endpoints.
  """
  @spec authorize(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def authorize(agent_id, session_id, tool_name, role \\ "agent", params \\ %{}) do
    ApmV5.Instrumentation.span(
      [:apm_v5, :auth, :authorization_gate, :evaluate],
      %{tool: tool_name, agent_id: agent_id, session_id: session_id, role: role},
      fn ->
        GenServer.call(__MODULE__, {:authorize, agent_id, session_id, tool_name, role, params})
      end
    )
  end

  @doc """
  Record execution completion for a consumed token.
  """
  @spec record_execution(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def record_execution(token_id, tool_name, result \\ %{}) do
    GenServer.cast(__MODULE__, {:record_execution, token_id, tool_name, result})
  end

  @doc "List all registered tools."
  @spec list_tools() :: [AuthTool.t()]
  def list_tools do
    case :ets.info(@tool_registry) do
      :undefined -> []
      _ ->
        :ets.tab2list(@tool_registry)
        |> Enum.map(fn {_name, tool} -> tool end)
        |> Enum.sort_by(& &1.name)
    end
  end

  @doc "Get a specific registered tool."
  @spec get_tool(String.t()) :: AuthTool.t() | nil
  def get_tool(tool_name) do
    case :ets.lookup(@tool_registry, tool_name) do
      [{^tool_name, tool}] -> tool
      [] -> nil
    end
  end

  @doc "Get authorization summary stats."
  @spec summary() :: map()
  def summary do
    GenServer.call(__MODULE__, :summary)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@tool_registry, [:named_table, :set, :public, read_concurrency: true])

    # Register default tools from PolicyEngine risk map
    PolicyEngine.default_risk_map()
    |> Enum.each(fn {name, risk} ->
      tool = %AuthTool{
        name: name,
        risk_level: risk,
        requires_auth: risk not in [:none],
        registered_at: DateTime.utc_now()
      }

      :ets.insert(@tool_registry, {name, tool})
    end)

    Logger.info(
      "[AuthorizationGate] Started — #{map_size(PolicyEngine.default_risk_map())} default tools registered"
    )

    {:ok, %{total_authorized: 0, total_denied: 0, total_escalated: 0}}
  end

  @impl true
  def handle_call({:register_tool, tool_name, risk_level, opts}, _from, state) do
    tool = %AuthTool{
      name: tool_name,
      risk_level: risk_level,
      requires_auth: Keyword.get(opts, :requires_auth, risk_level not in [:none]),
      allowed_roles: Keyword.get(opts, :allowed_roles, []),
      data_boundary: Keyword.get(opts, :data_boundary, :authenticated_user_only),
      max_records: Keyword.get(opts, :max_records, 100),
      rate_limit: Keyword.get(opts, :rate_limit),
      registered_at: DateTime.utc_now()
    }

    :ets.insert(@tool_registry, {tool_name, tool})
    log_audit("auth:tool_registered", tool_name, %{risk_level: risk_level})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:authorize, agent_id, session_id, tool_name, role, params}, _from, state) do
    # 1. Get tool (or use defaults)
    tool = get_tool(tool_name)

    # 2. Check rate limits before policy evaluation
    case RateLimiter.check(agent_id, tool_name) do
      {:error, :rate_limited, retry_after_ms} ->
        broadcast({:auth_rate_limited, %{tool_name: tool_name, agent_id: agent_id, retry_after_ms: retry_after_ms}})
        broadcast_decision(tool_name, :rate_limited, :medium, session_id)

        log_audit("auth:rate_limited", tool_name, %{
          agent_id: agent_id,
          retry_after_ms: retry_after_ms
        })

        result = {:error, :rate_limited, "Rate limit exceeded. Retry after #{retry_after_ms}ms"}
        new_state = %{state | total_denied: state.total_denied + 1}
        {:reply, result, new_state}

      :ok ->
        # 2b. Formation-level rate check (sqrt-scaled aggregate budget)
        formation_id = Map.get(params, :formation_id) || Map.get(params, "formation_id")
        tool_risk = get_tool_risk(tool_name)
        formation_check =
          if is_binary(formation_id) and byte_size(formation_id) > 0 do
            FormationRateLimiter.check(agent_id, formation_id, tool_name, tool_risk)
          else
            :ok
          end

        case formation_check do
          {:deny, scope} ->
            broadcast({:auth_rate_limited, %{tool_name: tool_name, agent_id: agent_id, scope: scope, formation_id: formation_id, retry_after_ms: 1_000}})
            broadcast_decision(tool_name, :rate_limited, :medium, session_id)
            log_audit("auth:formation_rate_limited", tool_name, %{agent_id: agent_id, formation_id: formation_id, scope: scope})
            result = {:error, :rate_limited, "Formation rate limit exceeded (scope: #{scope}). Retry after 1000ms"}
            new_state = %{state | total_denied: state.total_denied + 1}
            {:reply, result, new_state}

          :ok ->
            # 3a. Check permanent policy rules (always_allow / always_deny override)
            policy_rule = PolicyRulesStore.check_rule(tool_name)

        # 3b. Build evaluation context
        trust_ceiling = get_trust_ceiling(session_id)

        context =
          Map.merge(params, %{
            trust_ceiling: trust_ceiling,
            tool_registry: tool,
            data_boundary: Map.get(params, :data_boundary, :authenticated_user_only),
            policy_rule: policy_rule,
            agent_id: agent_id,
            session_id: session_id,
            formation_id: Map.get(params, :formation_id),
            project: Map.get(params, :project)
          })

        # 4. Evaluate policy (policy_rule override may short-circuit)
        decision = PolicyEngine.evaluate(tool_name, role, context)

        # 5. Process decision
        {result, new_state} =
          case {decision.allowed, decision.needs_approval} do
            {true, false} ->
              # Permitted — issue token
              case TokenStore.generate(agent_id, session_id, tool_name, params) do
                {:ok, token_id} ->
                  RateLimiter.record(agent_id, tool_name)
                  SessionStore.increment_tool_calls(session_id)

                  broadcast({:auth_granted, %{
                    token_id: token_id,
                    tool_name: tool_name,
                    agent_id: agent_id,
                    risk_level: decision.risk_level
                  }})
                  broadcast_decision(tool_name, :granted, decision.risk_level, session_id)

                  log_audit("auth:authorization_granted", tool_name, %{
                    agent_id: agent_id,
                    token_id: token_id,
                    risk_level: decision.risk_level
                  })

                  {{:ok, token_id}, %{state | total_authorized: state.total_authorized + 1}}
              end

            {false, true} ->
              # Needs approval — check for auto-approval policies first
              auto_approval_policy = ApmV5.Auth.AutoApprovalStore.find_matching(
                agent_id,
                Map.get(context, :formation_id),
                session_id,
                Map.get(context, :project),
                tool_name,
                decision.risk_level
              )

              case auto_approval_policy do
                nil ->
                  # No matching auto-approval policy — escalate to human
                  {:ok, request_id} =
                    PendingDecisions.add(tool_name, session_id, decision.risk_level, agent_id, params)

                  gate_id =
                    try do
                      case ApmV5.AgUi.ApprovalGate.request_approval(agent_id, %{
                        tool_name: tool_name,
                        risk_level: decision.risk_level,
                        reason: decision.detail
                      }) do
                        {:ok, gid} -> gid
                        _ -> request_id
                      end
                    rescue
                      _ -> request_id
                    end

                  broadcast({:auth_escalated, %{
                    gate_id: gate_id,
                    request_id: request_id,
                    tool_name: tool_name,
                    agent_id: agent_id,
                    risk_level: decision.risk_level
                  }})
                  broadcast_decision(tool_name, :escalated, decision.risk_level, session_id)

                  log_audit("auth:authorization_escalated", tool_name, %{
                    agent_id: agent_id,
                    gate_id: gate_id,
                    request_id: request_id,
                    risk_level: decision.risk_level
                  })

                  {{:error, :approval_required,
                    "Pending approval queued: #{request_id}. Use /authorization to approve."},
                   %{state | total_escalated: state.total_escalated + 1}}

                policy ->
                  # Auto-approval policy matched — auto-approve and issue token
                  case TokenStore.generate(agent_id, session_id, tool_name, params) do
                    {:ok, token_id} ->
                      RateLimiter.record(agent_id, tool_name)
                      SessionStore.increment_tool_calls(session_id)
                      ApmV5.Auth.AutoApprovalStore.increment_approval_count(policy.policy_id)

                      broadcast({:auth_auto_approved, %{
                        token_id: token_id,
                        tool_name: tool_name,
                        agent_id: agent_id,
                        policy_id: policy.policy_id,
                        risk_level: decision.risk_level
                      }})
                      broadcast_decision(tool_name, :auto_approved, decision.risk_level, session_id)

                      log_audit("auth:auto_approval_granted", tool_name, %{
                        agent_id: agent_id,
                        token_id: token_id,
                        policy_id: policy.policy_id,
                        risk_level: decision.risk_level
                      })

                      {{:ok, token_id}, %{state | total_authorized: state.total_authorized + 1}}

                    _ ->
                      # Token generation failed — escalate
                      {:ok, _request_id} =
                        PendingDecisions.add(tool_name, session_id, decision.risk_level, agent_id, params)

                      log_audit("auth:auto_approval_token_failed", tool_name, %{
                        agent_id: agent_id,
                        policy_id: policy.policy_id
                      })

                      {{:error, :token_generation_failed, "Failed to generate token for auto-approval"},
                       %{state | total_denied: state.total_denied + 1}}
                  end
              end

            {false, false} ->
              # Denied
              SessionStore.increment_denied(session_id)

              broadcast({:auth_denied, %{
                tool_name: tool_name,
                agent_id: agent_id,
                reason: decision.reason,
                risk_level: decision.risk_level
              }})
              broadcast_decision(tool_name, :denied, decision.risk_level, session_id)

              log_audit("auth:authorization_denied", tool_name, %{
                agent_id: agent_id,
                reason: decision.reason,
                detail: decision.detail
              })

              {{:error, decision.reason, decision.detail},
               %{state | total_denied: state.total_denied + 1}}
          end

            {:reply, result, new_state}
        end
    end
  end

  @impl true
  def handle_call(:summary, _from, state) do
    tools = list_tools()
    sessions = SessionStore.list_active()
    tokens = TokenStore.stats()

    summary = %{
      registered_tools: length(tools),
      active_sessions: length(sessions),
      tokens: tokens,
      total_authorized: state.total_authorized,
      total_denied: state.total_denied,
      total_escalated: state.total_escalated,
      risk_distribution:
        tools
        |> Enum.map(& &1.risk_level)
        |> Enum.frequencies()
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_cast({:record_execution, token_id, tool_name, result}, state) do
    case TokenStore.validate_and_consume(token_id, tool_name) do
      {:ok, _token} ->
        broadcast({:token_consumed, %{token_id: token_id, tool_name: tool_name}})

        log_audit("auth:token_consumed", tool_name, %{
          token_id: token_id,
          duration_ms: Map.get(result, :duration_ms, 0)
        })

      {:error, reason} ->
        Logger.warning("[AuthorizationGate] Token consumption failed: #{reason} for #{token_id}")
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get_trust_ceiling(session_id) do
    try do
      ContextTracker.get_trust_ceiling(session_id)
    rescue
      _ -> :authoritative
    catch
      :exit, _ -> :authoritative
    end
  end

  defp log_audit(event_type, resource, details) do
    try do
      ApmV5.AuditLog.log(event_type, "agentlock", resource, details)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp broadcast_decision(tool_name, status, risk_level, session_id) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:agentlock", %{
      event: "authorization_decision",
      tool: tool_name,
      status: status,
      risk_level: risk_level,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp get_tool_risk(tool_name) do
    case get_tool(tool_name) do
      nil -> :low
      tool -> tool.risk_level || :low
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", event)

    # Also emit via AG-UI EventBus if available
    try do
      event_name =
        case event do
          {:auth_granted, _} -> "auth_granted"
          {:auth_denied, _} -> "auth_denied"
          {:auth_escalated, _} -> "auth_escalated"
          {:auth_rate_limited, _} -> "auth_rate_limited"
          {:token_consumed, _} -> "auth_token_consumed"
          _ -> nil
        end

      if event_name do
        {_tag, data} = event

        ApmV5.AgUi.EventBus.publish("special:custom", %{
          type: "CUSTOM",
          name: event_name,
          data: data
        })
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
