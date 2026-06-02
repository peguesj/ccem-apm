defmodule Apm.Supervisors.AuthSupervisor do
  @moduledoc """
  Supervises AgentLock authorization GenServers: session management,
  token issuance/validation, rate limiting, context tracking, and
  the authorization gate.

  `Apm.RateLimit` (Hammer 7.x ETS sliding window) replaces the former
  `Apm.Auth.RateLimiter` GenServer as the rate-limiting child (rl-s2).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Apm.Auth.SessionStore,
      Apm.Auth.TokenStore,
      # Hammer 7.x ETS sliding window — replaces the former custom RateLimiter GenServer (rl-s2)
      {Apm.RateLimit, clean_period: :timer.minutes(2)},
      Apm.Auth.ContextTracker,
      # Policy rules must start before AuthorizationGate (hot-path read)
      Apm.Auth.PolicyRulesStore,
      # Auto-approval policies for hierarchical scope matching
      Apm.Auth.AutoApprovalStore,
      # audit-s4 (CP-222): ApprovalAuditLog is now a stateless shim delegating to
      # AuditLog — no longer a supervised GenServer. Removed from children.
      # Policy decision store — NIST AI RMF GOVERN evidence ring buffer (CP-227)
      Apm.Auth.PolicyDecisionStore,
      # Composite risk score aggregator — MAP-2 rolling 5-min window (CP-231)
      Apm.Auth.RiskScoreAggregator,
      # Debouncing approval queue — batches notifications over 200ms window (US-323)
      Apm.Auth.ApprovalQueue,
      # Pending decisions queue for human-in-the-loop approvals
      Apm.Auth.PendingDecisions,
      Apm.Auth.AuthorizationGate,
      # Adaptive load-aware rate limiter — samples AgentRegistry queue every 5 s (rl-s7)
      Apm.Auth.AdaptiveRateLimiter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
