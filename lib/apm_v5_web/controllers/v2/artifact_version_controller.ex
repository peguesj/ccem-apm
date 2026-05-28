defmodule ApmV5Web.V2.ArtifactVersionController do
  @moduledoc """
  HTTP API for `ApmV5.A2A.ArtifactVersionStore`.

  ## Endpoints

  - `GET  /api/v2/a2a/artifacts/:key/version`
    Returns the current version for the given artifact key.

  - `POST /api/v2/a2a/artifacts/:key/cas`
    Body: `{"expected": N, "agent_id": "..."}`
    Performs a compare-and-swap.  Returns `{"ok": true, "version": M}` on
    success or `{"ok": false, "conflict": true, "current_version": M}` on
    conflict.
  """

  use ApmV5Web, :controller

  alias ApmV5.A2A.ArtifactVersionStore

  @doc "GET /api/v2/a2a/artifacts/:key/version"
  @spec get_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_version(conn, %{"key" => key}) do
    version = ArtifactVersionStore.get_version(key)
    json(conn, %{key: key, version: version})
  end

  @doc "POST /api/v2/a2a/artifacts/:key/cas"
  @spec cas(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cas(conn, %{"key" => key} = params) do
    expected = Map.get(params, "expected", 0)
    agent_id = Map.get(params, "agent_id", "unknown")

    unless is_integer(expected) do
      conn
      |> put_status(422)
      |> json(%{error: "expected must be an integer"})
    else
      case ArtifactVersionStore.cas(key, expected, agent_id) do
        {:ok, new_version} ->
          json(conn, %{ok: true, version: new_version, key: key})

        {:error, :conflict, current_version} ->
          conn
          |> put_status(409)
          |> json(%{ok: false, conflict: true, current_version: current_version, key: key})
      end
    end
  end
end
