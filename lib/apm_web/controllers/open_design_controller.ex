defmodule ApmWeb.OpenDesignController do
  @moduledoc """
  REST API for the open-design plugin.

  Routes (all under /api/v2/open-design):
    GET  /health           — daemon status from OpenDesignMonitor
    GET  /agents           — detected agent CLIs
    GET  /skills           — full skill catalog
    GET  /skills/:id       — single skill
    GET  /design-systems   — design system catalog
    GET  /design-systems/:id — single design system
    GET  /projects         — all projects
    GET  /projects/:id     — single project
    GET  /templates        — artifact templates

  Returns 503 if the open-design daemon is unreachable.
  """

  use ApmWeb, :controller

  alias Apm.Plugins.OpenDesign.OpenDesignClient
  alias Apm.Plugins.OpenDesign.OpenDesignMonitor

  @daemon_port 17_456

  # ── Health ────────────────────────────────────────────────────────────────────

  def health(conn, _params) do
    state = safe_monitor_state()
    status = if state[:reachable], do: :ok, else: :service_unavailable
    json(conn |> put_status(status), state)
  end

  # ── Agents ────────────────────────────────────────────────────────────────────

  def agents(conn, _params) do
    case OpenDesignClient.list_agents(@daemon_port) do
      {:ok, agents} ->
        json(conn, %{agents: agents, count: length(agents)})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running on port #{@daemon_port}"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Skills ────────────────────────────────────────────────────────────────────

  def skills(conn, _params) do
    case OpenDesignClient.list_skills(@daemon_port) do
      {:ok, skills} ->
        json(conn, %{skills: skills, count: length(skills)})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def skill_detail(conn, %{"id" => id}) do
    case OpenDesignClient.get_skill(id, @daemon_port) do
      {:ok, skill} ->
        json(conn, skill)

      {:error, {:http_error, 404}} ->
        conn |> put_status(404) |> json(%{error: "skill not found: #{id}"})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Design Systems ────────────────────────────────────────────────────────────

  def design_systems(conn, _params) do
    case OpenDesignClient.list_design_systems(@daemon_port) do
      {:ok, ds} ->
        json(conn, %{design_systems: ds, count: length(ds)})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def design_system_detail(conn, %{"id" => id}) do
    case OpenDesignClient.get_design_system(id, @daemon_port) do
      {:ok, ds} -> json(conn, ds)
      {:error, {:http_error, 404}} -> conn |> put_status(404) |> json(%{error: "not found: #{id}"})
      {:error, :daemon_unreachable} -> conn |> put_status(503) |> json(%{error: "daemon not running"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Projects ──────────────────────────────────────────────────────────────────

  def projects(conn, _params) do
    case OpenDesignClient.list_projects(@daemon_port) do
      {:ok, projects} ->
        json(conn, %{projects: projects, count: length(projects)})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def project_detail(conn, %{"id" => id}) do
    case OpenDesignClient.get_project(id, @daemon_port) do
      {:ok, project} -> json(conn, project)
      {:error, {:http_error, 404}} -> conn |> put_status(404) |> json(%{error: "not found: #{id}"})
      {:error, :daemon_unreachable} -> conn |> put_status(503) |> json(%{error: "daemon not running"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Templates ─────────────────────────────────────────────────────────────────

  def templates(conn, _params) do
    case OpenDesignClient.list_templates(@daemon_port) do
      {:ok, templates} ->
        json(conn, %{templates: templates, count: length(templates)})

      {:error, :daemon_unreachable} ->
        conn |> put_status(503) |> json(%{error: "open-design daemon not running"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp safe_monitor_state do
    case Process.whereis(OpenDesignMonitor) do
      nil ->
        %{reachable: false, error: "OpenDesignMonitor not started"}

      _pid ->
        OpenDesignMonitor.current_state()
    end
  rescue
    _ -> %{reachable: false, error: "monitor unavailable"}
  end
end
