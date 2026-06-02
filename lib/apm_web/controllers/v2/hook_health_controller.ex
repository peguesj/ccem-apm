defmodule ApmWeb.V2.HookHealthController do
  @moduledoc """
  REST API for hook filesystem health monitoring.

  ## Routes (all under /api/v2)

  - `GET  /hooks/health`          — current health snapshot
  - `POST /hooks/scan`            — trigger immediate re-scan
  - `POST /hooks/clear/:project`  — rotate hook-errors.log if safe to do so
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.HookHealthMonitor

  @poll_attempts 4
  @poll_interval_ms 500

  # Filesystem-level issues that block rotation
  @filesystem_issues ~w(missing_remember missing_logs missing_tmp wrong_owner)a

  # ── GET /api/v2/hooks/health ──────────────────────────────────────────────

  @doc "Returns the current health snapshot from HookHealthMonitor."
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :health,
    summary: "Health check",
    tags: ["Hooks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def health(conn, _params) do
    result = HookHealthMonitor.current_health()
    json(conn, %{data: serialize_health(result)})
  end

  # ── POST /api/v2/hooks/scan ───────────────────────────────────────────────

  @doc "Triggers an immediate async re-scan."
  @spec scan(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :scan,
    summary: "Scan",
    tags: ["Hooks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def scan(conn, _params) do
    HookHealthMonitor.scan_now()

    json(conn, %{
      ok: true,
      queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ── POST /api/v2/hooks/clear/:project ────────────────────────────────────

  @doc """
  Clear-once-fixed: rotates hook-errors.log for a project.

  - Project healthy → rotate
  - Project unhealthy but ONLY content issues (recent_error_content / stale_log) → rotate
  - Project unhealthy with filesystem issues → 409
  - Project not found → 404
  """
  @spec clear(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :clear,
    summary: "Clear",
    tags: ["Hooks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def clear(conn, %{"project" => project_name}) do
    # Trigger fresh scan and wait briefly
    HookHealthMonitor.scan_now()
    health = poll_for_project(project_name, @poll_attempts)

    case find_project(health, project_name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "project '#{project_name}' not found in health scan"})

      %{status: :healthy, path: path} ->
        rotate_log(conn, path, project_name)

      %{issues: issues, path: path} ->
        fs_issues = Enum.filter(issues, &(&1 in @filesystem_issues))

        if fs_issues == [] do
          # Only content issues — allow rotation
          rotate_log(conn, path, project_name)
        else
          conn
          |> put_status(:conflict)
          |> json(%{
            error: "filesystem still broken",
            issues: Enum.map(issues, &to_string/1)
          })
        end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec poll_for_project(String.t(), non_neg_integer()) :: map()
  defp poll_for_project(_project_name, 0), do: HookHealthMonitor.current_health()

  defp poll_for_project(project_name, attempts) do
    health = HookHealthMonitor.current_health()

    if find_project(health, project_name) do
      health
    else
      Process.sleep(@poll_interval_ms)
      poll_for_project(project_name, attempts - 1)
    end
  end

  @spec find_project(map(), String.t()) :: map() | nil
  defp find_project(%{projects: projects}, name) do
    Enum.find(projects, &(&1.project == name))
  end

  defp find_project(_, _), do: nil

  @spec rotate_log(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  defp rotate_log(conn, project_path, _project_name) do
    log_path = Path.join([project_path, ".remember", "logs", "hook-errors.log"])
    rotated_to = log_path <> ".1"

    case File.rename(log_path, rotated_to) do
      :ok ->
        # Create fresh empty log
        File.write!(log_path, "")

        json(conn, %{ok: true, rotated_to: rotated_to})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "rotation failed: #{inspect(reason)}"})
    end
  end

  @spec serialize_health(map()) :: map()
  defp serialize_health(%{healthy: h, unhealthy: u, projects: ps}) do
    %{
      healthy: h,
      unhealthy: u,
      projects: Enum.map(ps, &serialize_project/1)
    }
  end

  defp serialize_health(other), do: other

  @spec serialize_project(map()) :: map()
  defp serialize_project(p) do
    %{
      project: p.project,
      path: p.path,
      status: to_string(p.status),
      issues: Enum.map(p.issues, &to_string/1),
      last_error_line: p.last_error_line,
      last_error_at: p.last_error_at && DateTime.to_iso8601(p.last_error_at),
      log_size: p.log_size,
      scanned_at: p.scanned_at && DateTime.to_iso8601(p.scanned_at)
    }
  end
end
