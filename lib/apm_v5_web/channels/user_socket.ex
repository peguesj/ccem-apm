defmodule ApmV5Web.UserSocket do
  use Phoenix.Socket

  channel "agent:*", ApmV5Web.AgentChannel
  channel "metrics:live", ApmV5Web.MetricsChannel
  channel "alerts:feed", ApmV5Web.AlertsChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
