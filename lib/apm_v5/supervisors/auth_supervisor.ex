defmodule ApmV5.Supervisors.AuthSupervisor do
  @moduledoc """
  Supervises AgentLock authorization GenServers: session management,
  token issuance/validation, rate limiting, context tracking, and
  the authorization gate.
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
      ApmV5.Auth.RateLimiter,
      ApmV5.Auth.ContextTracker,
      ApmV5.Auth.AuthorizationGate
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
