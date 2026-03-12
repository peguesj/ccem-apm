defmodule ApmV5Web.V2.AgUiDiagnosticsController do
  @moduledoc """
  Diagnostics endpoint for EventBus health monitoring.

  ## US-041 Acceptance Criteria (DoD):
  - GET /api/v2/ag-ui/diagnostics returns topic stats and throughput
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.EventBusHealth

  @doc "GET /api/v2/ag-ui/diagnostics - EventBus health and throughput data."
  def diagnostics(conn, _params) do
    json(conn, EventBusHealth.diagnostics())
  end
end
