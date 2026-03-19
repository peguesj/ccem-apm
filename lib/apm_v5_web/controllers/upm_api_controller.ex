defmodule ApmV5Web.UpmApiController do
  @moduledoc """
  UPM execution tracking API endpoints.

  Extracted from ApiController as part of refactor-max domain split.
  Handles UPM session lifecycle: register, agent binding, events, and status.
  All routes mounted at /api/upm/* in the router.
  """

  use ApmV5Web, :controller

  alias ApmV5.UpmStore

  @doc "POST /api/upm/register -- register a UPM execution session"
  @spec upm_register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_register(conn, params) do
    {:ok, session_id} = UpmStore.register_session(params)

    conn
    |> put_status(201)
    |> json(%{ok: true, upm_session_id: session_id})
  end

  @doc "POST /api/upm/agent -- register an agent with work-item binding"
  @spec upm_agent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_agent(conn, params) do
    case UpmStore.register_agent(params) do
      :ok ->
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
    json(conn, %{ok: true})
  end

  @doc "GET /api/upm/status -- current UPM execution state"
  @spec upm_status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upm_status(conn, _params) do
    status = UpmStore.get_status()
    json(conn, status)
  end
end
