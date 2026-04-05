defmodule ApmV5.StatusPayloadBuilder do
  @moduledoc """
  Builds /api/status and /health payloads. Extracted from ApiController so that
  StatusCache can call these at warmup time (before the first HTTP request).

  These functions aggregate over all projects × agents and account for the bulk
  of cold-start latency on /api/status. By warming the cache eagerly during app
  boot, the first request hits warm ETS data (<50ms).
  """

  alias ApmV5.AgentRegistry
  alias ApmV5.ConfigLoader

  @server_version "8.11.1"

  @spec build_status_payload() :: map()
  def build_status_payload do
    uptime = ApmV5.Uptime.seconds()
    agents = AgentRegistry.list_agents()
    sessions = AgentRegistry.list_sessions()
    agent_counts_by_project = build_agent_counts_by_project(agents)

    session_id =
      case sessions do
        [s | _] -> s.session_id
        [] -> "none"
      end

    config = safe_get_config()
    project_list = Map.get(config, "projects", [])
    project_summaries = build_project_summaries(project_list, agent_counts_by_project)

    %{
      status: "ok",
      uptime: uptime,
      agent_count: length(agents),
      session_id: session_id,
      server_version: @server_version,
      total_projects: length(project_list),
      active_project: Map.get(config, "active_project"),
      projects: project_summaries
    }
  end

  @spec build_health_payload() :: map()
  def build_health_payload do
    uptime = ApmV5.Uptime.seconds()
    agents = AgentRegistry.list_agents()
    agent_counts_by_project = build_agent_counts_by_project(agents)
    config = safe_get_config()
    projects = Map.get(config, "projects", [])
    project_summaries = build_project_summaries(projects, agent_counts_by_project)

    %{
      status: "ok",
      uptime: uptime,
      server_version: @server_version,
      total_projects: length(projects),
      active_project: Map.get(config, "active_project"),
      projects: project_summaries
    }
  end

  defp build_agent_counts_by_project(agents) do
    {by_project, nil_count} =
      Enum.reduce(agents, {%{}, 0}, fn agent, {acc, nil_c} ->
        case Map.get(agent, :project_name) do
          nil -> {acc, nil_c + 1}
          name -> {Map.update(acc, name, 1, &(&1 + 1)), nil_c}
        end
      end)

    {by_project, nil_count}
  end

  defp build_project_summaries(project_list, {by_project, nil_count}) do
    Enum.map(project_list, fn p ->
      name = p["name"]
      named = Map.get(by_project, name, 0)

      %{
        name: name,
        status: p["status"] || "active",
        agent_count: named + nil_count,
        session_count: length(Map.get(p, "sessions", []))
      }
    end)
  end

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
