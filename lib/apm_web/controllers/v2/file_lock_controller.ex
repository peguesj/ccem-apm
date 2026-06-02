defmodule ApmWeb.V2.FileLockController do
  @moduledoc """
  HTTP API for `Apm.A2A.FileLockRegistry`.

  ## Endpoints

  - `GET    /api/v2/locks`              — List all active (non-expired) locks.
  - `POST   /api/v2/locks/acquire`      — Acquire a lock.
    Body: `{agent_id, file_path, ttl_ms}` (ttl_ms optional, default 30 000).
    Returns 201 + `{lock_id, file_path, holder, expires_at}` on success,
    or 409 + `{error, holder, expires_at}` if the path is already locked.
  - `DELETE /api/v2/locks/:lock_id`     — Release a lock by lock_id.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.A2A.FileLockRegistry

  @doc "GET /api/v2/locks"
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :index,
    summary: "List",
    tags: ["File Locks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, _params) do
    locks =
      FileLockRegistry.list_locks()
      |> Enum.map(&serialise_lock/1)

    json(conn, %{locks: locks, count: length(locks)})
  end

  @doc "POST /api/v2/locks/acquire"
  @spec acquire(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :acquire,
    summary: "Acquire",
    tags: ["File Locks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def acquire(conn, params) do
    agent_id = Map.get(params, "agent_id")
    file_path = Map.get(params, "file_path")
    ttl_ms = Map.get(params, "ttl_ms", 30_000)

    cond do
      is_nil(agent_id) or agent_id == "" ->
        conn
        |> put_status(422)
        |> json(%{error: "agent_id is required"})

      is_nil(file_path) or file_path == "" ->
        conn
        |> put_status(422)
        |> json(%{error: "file_path is required"})

      not is_integer(ttl_ms) or ttl_ms <= 0 ->
        conn
        |> put_status(422)
        |> json(%{error: "ttl_ms must be a positive integer"})

      true ->
        case FileLockRegistry.acquire(agent_id, file_path, ttl_ms) do
          {:ok, lock_id} ->
            [lock] =
              FileLockRegistry.list_locks()
              |> Enum.filter(&(&1.lock_id == lock_id))

            conn
            |> put_status(201)
            |> json(serialise_lock(lock))

          {:error, :locked, info} ->
            conn
            |> put_status(409)
            |> json(%{
              error: "file_path is already locked",
              holder: info.holder,
              expires_at: DateTime.to_iso8601(info.expires_at)
            })
        end
    end
  end

  @doc "DELETE /api/v2/locks/:lock_id"
  @spec release(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :release,
    summary: "Release",
    tags: ["File Locks"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def release(conn, %{"lock_id" => lock_id}) do
    FileLockRegistry.release(lock_id)
    send_resp(conn, 204, "")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp serialise_lock(%{
         lock_id: lock_id,
         file_path: file_path,
         holder: holder,
         expires_at: expires_at
       }) do
    %{
      lock_id: lock_id,
      file_path: file_path,
      holder: holder,
      expires_at: DateTime.to_iso8601(expires_at)
    }
  end
end
