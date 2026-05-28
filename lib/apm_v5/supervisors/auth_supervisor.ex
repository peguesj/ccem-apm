defmodule ApmV5.Supervisors.AuthSupervisor do
  @moduledoc """
  Supervises AgentLock authorization GenServers: session management,
  token issuance/validation, rate limiting, context tracking, and
  the authorization gate.

  `ApmV5.RateLimit` (Hammer 7.x ETS sliding window) replaces the former
  `ApmV5.Auth.RateLimiter` GenServer as the rate-limiting child (rl-s2).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.Auth.SessionStore,
      ApmV5.Auth.TokenStore,
      # Hammer 7.x ETS sliding window — replaces the former custom RateLimiter GenServer (rl-s2)
      {ApmV5.RateLimit, clean_period: :timer.minutes(2)},
      ApmV5.Auth.ContextTracker,
      # Policy rules must start before AuthorizationGate (hot-path read)
      ApmV5.Auth.PolicyRulesStore,
      # Auto-approval policies for hierarchical scope matching
      ApmV5.Auth.AutoApprovalStore,
      # Approval audit log — records all authorization decisions (US-326)
      ApmV5.Auth.ApprovalAuditLog,
      # Debouncing approval queue — batches notifications over 200ms window (US-323)
      ApmV5.Auth.ApprovalQueue,
      # Pending decisions queue for human-in-the-loop approvals
      ApmV5.Auth.PendingDecisions,
      ApmV5.Auth.AuthorizationGate,
      # Adaptive load-aware rate limiter — samples AgentRegistry queue every 5 s (rl-s7)
      ApmV5.Auth.AdaptiveRateLimiter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
