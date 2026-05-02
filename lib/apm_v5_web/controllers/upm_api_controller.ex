defmodule ApmV5Web.UpmApiController do
  @moduledoc """
  UPM execution tracking API endpoints.

  Extracted from ApiController as part of refactor-max domain split.
  Handles UPM session lifecycle: register, agent binding, events, and status.
  All routes mounted at /api/upm/* in the router.

  Broadcasts PubSub events on all mutations to `"apm:upm"` topic.
  """

  use ApmV5Web, :controller

  alias ApmV5.UpmStore

  @pubsub ApmV5.PubSub
  @topic "apm:upm"

  @doc "POST /api/upm/register -- register a UPM execution session"
  @spec upm_register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_register(conn, params) do
    {:ok, session_id} = UpmStore.register_session(params)

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:upm_session_registered, %{
      session_id: session_id,
      project: params["project"],
      formation_id: params["formation_id"]
    }})

    conn
    |> put_status(201)
    |> json(%{ok: true, upm_session_id: session_id})
  end

  @doc "POST /api/upm/agent -- register an agent with work-item binding"
  @spec upm_agent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_agent(conn, params) do
    case UpmStore.register_agent(params) do
      :ok ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:upm_agent_registered, %{
          agent_id: params["agent_id"],
          upm_session_id: params["upm_session_id"],
          work_item_id: params["work_item_id"]
        }})

        json(conn, %{ok: true})

      {:error, :session_not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "UPM session not found", upm_session_id: params["upm_session_id"]})
    end
  end

  @doc "POST /api/upm/event -- report a UPM lifecycle event"
  @spec upm_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_event(conn, params) do
    :ok = UpmStore.record_event(params)

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:upm_event_recorded, %{
      event_type: params["event_type"],
      upm_session_id: params["upm_session_id"],
      agent_id: params["agent_id"]
    }})

    json(conn, %{ok: true})
  end

  @doc "GET /api/upm/status -- current UPM execution state"
  @spec upm_status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_status(conn, _params) do
    status = UpmStore.get_status()
    json(conn, status)
  end

  @doc """
  POST /api/v2/upm/sessions/from_design_handoff

  Create a UPM session from a design handoff ZIP README.

  Required body params:
  - `readme_content` — raw README.md string from the design handoff package
  - `project` — project name
  - `prd_branch` — feature branch name (e.g. "ralph/design-system-v2")

  Optional:
  - `plane_project_id` — Plane project UUID for issue tracking
  """
  @spec from_design_handoff(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def from_design_handoff(conn, params) do
    case UpmStore.create_session_from_design_handoff(params) do
      {:ok, session_id} ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:upm_session_registered, %{
          session_id: session_id,
          input_type: "design_handoff",
          project: params["project"]
        }})

        conn
        |> put_status(201)
        |> json(%{ok: true, upm_session_id: session_id, input_type: "design_handoff"})

      {:error, :missing_readme} ->
        conn
        |> put_status(422)
        |> json(%{error: "readme_content is required"})

      {:error, :no_implementation_order} ->
        conn
        |> put_status(422)
        |> json(%{error: "README must contain an '## Implementation Order' section"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: to_string(reason)})
    end
  end
end
