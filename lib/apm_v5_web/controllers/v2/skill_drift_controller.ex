defmodule ApmV5Web.V2.SkillDriftController do
  @moduledoc """
  REST API controller for the Skill Drift Detector plugin.

  ## Endpoints
  - `GET  /api/v2/skill-drift/scan`   — Run scan and return raw findings
  - `GET  /api/v2/skill-drift/report` — Structured report grouped by severity
  - `POST /api/v2/skill-drift/fix`    — Auto-fix simple drift issues
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.SkillDrift.SkillDriftPlugin

  @doc "GET /api/v2/skill-drift/scan"
  @spec scan(Plug.Conn.t(), map()) :: Plug.Conn.t()
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
