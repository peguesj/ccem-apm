defmodule ApmV4Web.ApiController do
  @moduledoc """
  JSON API endpoints ported from the Python APM HTTPServer.

  Provides: GET /api/status, POST /api/register, POST /api/heartbeat,
  GET /api/agents, POST /api/notify.
  """

  use ApmV4Web, :controller

  alias ApmV4.AgentRegistry

  @server_version "4.0.0"

  def status(conn, _params) do
    start_time = Application.get_env(:apm_v4, :server_start_time, System.monotonic_time(:second))
    uptime = System.monotonic_time(:second) - start_time
    agents = AgentRegistry.list_agents()
    sessions = AgentRegistry.list_sessions()

    session_id =
      case sessions do
        [s | _] -> s.session_id
        [] -> "none"
      end

    json(conn, %{
      status: "ok",
      uptime: uptime,
      agent_count: length(agents),
      session_id: session_id,
      server_version: @server_version
    })
  end

  def register(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      metadata = %{
        name: params["name"] || agent_id,
        tier: params["tier"] || 1,
        status: params["status"] || "idle",
        deps: params["deps"] || [],
        metadata: params["metadata"] || %{}
      }

      :ok = AgentRegistry.register_agent(agent_id, metadata)

      conn
      |> put_status(201)
      |> json(%{ok: true, agent_id: agent_id})
    end
  end

  def heartbeat(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      status = params["status"] || "active"

      case AgentRegistry.update_status(agent_id, status) do
        :ok ->
          json(conn, %{ok: true, agent_id: agent_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{error: "Agent not found", agent_id: agent_id})
      end
    end
  end

  def agents(conn, _params) do
    agents = AgentRegistry.list_agents()
    json(conn, %{agents: agents})
  end

  def notify(conn, params) do
    notification = %{
      title: params["title"] || "Notification",
      message: params["message"] || "",
      level: params["level"] || "info"
    }

    id = AgentRegistry.add_notification(notification)
    json(conn, %{ok: true, id: id})
  end
end
