defmodule ApmV5Web.V2.AgUiDiagnosticsController do
  @moduledoc """
  Diagnostics endpoint for EventBus health monitoring.

  ## US-041 Acceptance Criteria (DoD):
  - GET /api/v2/ag-ui/diagnostics returns topic stats and throughput
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5.AgUi.EventBusHealth

  @doc "GET /api/v2/ag-ui/diagnostics - EventBus health and throughput data."
  operation :diagnostics,
    summary: "Diagnostics",
    tags: ["AG-UI"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def diagnostics(conn, _params) do
    json(conn, EventBusHealth.diagnostics())
  end
end
