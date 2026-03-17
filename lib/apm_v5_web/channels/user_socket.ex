defmodule ApmV5Web.UserSocket do
  @moduledoc """
  Phoenix UserSocket — routes channel connections for the APM web interface.

  Routes `agent:*` to `AgentChannel`, `metrics:live` to `MetricsChannel`,
  and `alerts:*` to `AlertsChannel`.
  """

  use Phoenix.Socket

  channel "agent:*", ApmV5Web.AgentChannel
  channel "metrics:live", ApmV5Web.MetricsChannel
  channel "alerts:feed", ApmV5Web.AlertsChannel
  # Wave 4: AG-UI bidirectional WebSocket channel (US-047)
  channel "ag_ui:*", ApmV5Web.AgUiChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
