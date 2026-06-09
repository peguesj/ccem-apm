defmodule ApmWeb.V2.SkillDriftController do
  @moduledoc """
  REST API controller for the Skill Drift Detector plugin.

  ## Endpoints
  - `GET  /api/v2/skill-drift/scan`   — Run scan and return raw findings
  - `GET  /api/v2/skill-drift/report` — Structured report grouped by severity
  - `POST /api/v2/skill-drift/fix`    — Auto-fix simple drift issues
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Plugins.SkillDrift.SkillDriftPlugin

  @doc "GET /api/v2/skill-drift/scan"
  @spec scan(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:scan,
    summary: "Scan",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def scan(conn, params) do
    case SkillDriftPlugin.handle_action("skill_drift_scan", params, []) do
      {:ok, result} ->
        json(conn, %{status: "ok", data: result})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end

  @doc "GET /api/v2/skill-drift/report"
  @spec report(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:report,
    summary: "Report",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def report(conn, params) do
    case SkillDriftPlugin.handle_action("skill_drift_report", params, []) do
      {:ok, result} ->
        json(conn, %{status: "ok", data: result})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end

  @doc "POST /api/v2/skill-drift/fix"
  @spec fix(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:fix,
    summary: "Fix",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def fix(conn, params) do
    case SkillDriftPlugin.handle_action("skill_drift_fix", params, []) do
      {:ok, result} ->
        json(conn, %{status: "ok", data: result})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end
end
