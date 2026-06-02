defmodule ApmWeb.UserSocket do
  @moduledoc """
  Phoenix UserSocket — routes channel connections for the APM web interface.

  Routes `agent:*` to `AgentChannel`, `metrics:live` to `MetricsChannel`,
  and `alerts:*` to `AlertsChannel`.
  """

  use Phoenix.Socket

  channel "agent:*", ApmWeb.AgentChannel
  channel "metrics:live", ApmWeb.MetricsChannel
  channel "alerts:feed", ApmWeb.AlertsChannel
  # Wave 4: AG-UI bidirectional WebSocket channel (US-047)
  channel "ag_ui:*", ApmWeb.AgUiChannel
  # v8.4.0: Showcase sync WebSocket channel — formation events + agent context
  channel "showcase:*", ApmWeb.ShowcaseChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
