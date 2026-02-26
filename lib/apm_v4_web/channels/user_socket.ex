defmodule ApmV4Web.UserSocket do
  use Phoenix.Socket

  channel "agent:*", ApmV4Web.AgentChannel
  channel "metrics:live", ApmV4Web.MetricsChannel
  channel "alerts:feed", ApmV4Web.AlertsChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
