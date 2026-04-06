defmodule ApmV5.Proxy.Supervisor do
  @moduledoc "Supervisor for Proxy Cache + RateLimiter."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.Proxy.Cache,
      ApmV5.Proxy.RateLimiter
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
