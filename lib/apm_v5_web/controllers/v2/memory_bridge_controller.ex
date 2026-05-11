defmodule ApmV5Web.V2.MemoryBridgeController do
  @moduledoc """
  REST API for the ClaudeMemBridge — read-only projection of
  `~/.claude-mem/claude-mem.db` in a VIKI-compatible message shape.

  ## Routes (under /api/v2)

  - `GET /memory/bridge/observations?query=&limit=` — FTS/LIKE search
  - `GET /memory/bridge/session/:session_id`         — observations for one session
  - `GET /memory/bridge/stats`                       — count + min/max ts
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.Memory.ClaudeMemBridge

  # ── GET /api/v2/memory/bridge/observations ──────────────────────────────────

  @doc "Search observations by query string."
  @spec observations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def observations(conn, params) do
    query = Map.get(params, "query", "")
    limit = parse_limit(Map.get(params, "limit", "50"))

    case ClaudeMemBridge.search(query, limit: limit) do
      {:ok, rows} ->
        json(conn, %{data: rows, count: length(rows)})

      {:error, :db_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "claude-mem database unavailable"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  # ── GET /api/v2/memory/bridge/session/:session_id ──────────────────────────

  @doc "Return all observations for a given memory_session_id."
  @spec session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def session(conn, %{"session_id" => session_id}) do
    case ClaudeMemBridge.session(session_id) do
      {:ok, rows} ->
        json(conn, %{data: rows, session_id: session_id, count: length(rows)})

      {:error, :db_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "claude-mem database unavailable"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  # ── GET /api/v2/memory/bridge/stats ────────────────────────────────────────

  @doc "Return aggregate stats: observation count, min ts, max ts."
  @spec stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stats(conn, _params) do
    case ClaudeMemBridge.stats() do
      {:ok, data} ->
        json(conn, data)

      {:error, :db_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "claude-mem database unavailable"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec parse_limit(String.t() | integer()) :: pos_integer()
  defp parse_limit(n) when is_integer(n) and n > 0, do: min(n, 500)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, 500)
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50
end
