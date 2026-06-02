defmodule Apm.Proxy.Supervisor do
  @moduledoc """
  Supervisor for Proxy Cache + RateLimiter.

  `Apm.Proxy.RateLimiter` is no longer a GenServer (rl-s2); the shared
  `Apm.RateLimit` Hammer instance started by `AuthSupervisor` is used
  instead.  The former `Apm.Proxy.RateLimiter` child is removed here to
  avoid a duplicate start error.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Apm.Proxy.Cache
      # Apm.Proxy.RateLimiter removed — now delegates to Apm.RateLimit (rl-s2)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
