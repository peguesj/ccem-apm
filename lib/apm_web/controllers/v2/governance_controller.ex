defmodule ApmWeb.V2.GovernanceController do
  @moduledoc """
  REST API controller for governance and compliance endpoints.

  ## Endpoints

    * `GET  /api/v2/governance/controls`          — full control registry
    * `GET  /api/v2/governance/report`            — JSON compliance report
    * `GET  /api/v2/governance/report?format=md`  — Markdown compliance report
    * `POST /api/v2/governance/report/refresh`    — force report cache refresh
    * `GET  /api/v2/governance/circuit-breakers`  — list active circuit breakers
    * `POST /api/v2/governance/circuit-breakers/:session_id/close` — manual override

  Spec: CP-229/US-461 · CP-233/US-465 · CP-234/US-466 — v9.3.0
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Governance.{ControlRegistry, ComplianceReportEngine, IncidentResponseEngine}

  # ---------------------------------------------------------------------------
  # GET /api/v2/governance/controls
  # ---------------------------------------------------------------------------

  @doc """
  Returns the full ControlRegistry as JSON.
  """
  operation :list_controls,
    summary: "List controls",
    tags: ["Governance"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_controls(conn, _params) do
    controls =
      ControlRegistry.list_controls()
      |> Enum.map(fn {id, ctrl} ->
        frameworks =
          ctrl
          |> Map.drop([:name, :description, :status])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        %{
          id: to_string(id),
          name: ctrl.name,
          description: ctrl.description,
          status: to_string(ctrl.status),
          frameworks: frameworks
        }
      end)
      |> Enum.sort_by(& &1.id)

    json(conn, %{
      controls: controls,
      frameworks: ControlRegistry.framework_index()
    })
  end

  # ---------------------------------------------------------------------------
  # GET /api/v2/governance/report
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current compliance posture report.

  Pass `?format=md` or `?format=markdown` for a Markdown rendering.
  """
  operation :report,
    summary: "Report",
    tags: ["Governance"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def report(conn, params) do
    format = Map.get(params, "format", "json")
    report = ComplianceReportEngine.generate()

    case format do
      f when f in ["md", "markdown"] ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, ComplianceReportEngine.to_markdown(report))

      _ ->
        json(conn, ComplianceReportEngine.to_json(report))
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v2/governance/report/refresh
  # ---------------------------------------------------------------------------

  @doc """
  Forces cache invalidation and regenerates the compliance report.
  """
  operation :refresh_report,
    summary: "Refresh report",
    tags: ["Governance"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def refresh_report(conn, _params) do
    report = ComplianceReportEngine.refresh()
    json(conn, ComplianceReportEngine.to_json(report))
  end

  # ---------------------------------------------------------------------------
  # GET /api/v2/governance/circuit-breakers
  # ---------------------------------------------------------------------------

  @doc """
  Returns all currently active circuit breaker entries.
  """
  operation :list_circuit_breakers,
    summary: "List circuit breakers",
    tags: ["Governance"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_circuit_breakers(conn, _params) do
    circuits = IncidentResponseEngine.list_active_circuits()
    json(conn, %{circuits: circuits, count: length(circuits)})
  end

  # ---------------------------------------------------------------------------
  # POST /api/v2/governance/circuit-breakers/:session_id/close
  # ---------------------------------------------------------------------------

  @doc """
  Manually closes a circuit breaker for the given session_id, restoring
  normal policy evaluation.
  """
  operation :close_circuit,
    summary: "Close circuit",
    tags: ["Governance"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def close_circuit(conn, %{"session_id" => session_id}) do
    case IncidentResponseEngine.close_circuit(session_id) do
      :ok ->
        json(conn, %{status: "ok", session_id: session_id, message: "Circuit closed manually."})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No active circuit for session #{session_id}"})
    end
  end
end
