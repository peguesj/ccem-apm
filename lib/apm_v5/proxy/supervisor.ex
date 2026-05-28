defmodule ApmV5.Proxy.Supervisor do
  @moduledoc """
  Supervisor for Proxy Cache + RateLimiter.

  `ApmV5.Proxy.RateLimiter` is no longer a GenServer (rl-s2); the shared
  `ApmV5.RateLimit` Hammer instance started by `AuthSupervisor` is used
  instead.  The former `ApmV5.Proxy.RateLimiter` child is removed here to
  avoid a duplicate start error.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.Proxy.Cache
      # ApmV5.Proxy.RateLimiter removed — now delegates to ApmV5.RateLimit (rl-s2)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
