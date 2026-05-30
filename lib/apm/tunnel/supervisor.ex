defmodule Apm.Tunnel.Supervisor do
  @moduledoc """
  Supervision tree for the outbound relay tunnel.

  Only starts children when TUNNEL_RELAY_URL env var is set so the tunnel
  is a zero-cost no-op in default (local-only) deployments.
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      if System.get_env("TUNNEL_RELAY_URL") do
        [Apm.Tunnel.Client]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
