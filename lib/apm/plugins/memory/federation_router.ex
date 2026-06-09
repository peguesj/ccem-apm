defmodule Apm.Plugins.Memory.FederationRouter do
  @moduledoc """
  Source-tagged fanout router for multi-backend memory queries (ADR-D3).

  Dispatches `route_query/2` in parallel to configured memory sources:

  - `:claude_mem` — Reads `~/.claude-mem/claude-mem.db` read-only via
    `Exqlite` (soft dependency). FTS search on `observations.content`.
  - `:viki` — HTTP POST to `#{:viki}/api/search` with a Bearer token.
  - `:serena` — MCP-only; not directly callable from a GenServer.
    Returns `{:not_implemented, :serena}` for every query.

  Each source result is tagged with `:source` and returned in a unified
  envelope. Per-source timeout is 500 ms; partial results are allowed.
  Results are sorted by `:score` descending before the top-N slice.

  ## Usage

      iex> Apm.Plugins.Memory.FederationRouter.route_query(
      ...>   %{query: "elixir supervisor", sources: [:claude_mem, :viki]},
      ...>   []
      ...> )
      {:ok, %{results: [...], sources_queried: [:claude_mem, :viki], ...}}
  """

  require Logger

  @default_timeout_ms 500
  @default_top_n 20

  @sqlite3 Exqlite.Sqlite3
  @db_path "~/.claude-mem/claude-mem.db"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Dispatch a query to one or more memory sources in parallel.

  ## Params map

  - `:query` (required) — free-text search string
  - `:sources` — list of source atoms; defaults to `[:claude_mem, :viki]`
  - `:top_n` — max results to return; defaults to `#{@default_top_n}`
  - `:timeout_ms` — per-source timeout in ms; defaults to `#{@default_timeout_ms}`

  ## Returns

  `{:ok, %{results: [...], sources_queried: [...], errors: [...], total: n}}`
  """
  @spec route_query(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def route_query(params, _ctx) do
    query = Map.get(params, :query) || Map.get(params, "query")

    unless is_binary(query) and byte_size(query) > 0 do
      {:error, {:invalid_params, "query must be a non-empty string"}}
    else
      sources = Map.get(params, :sources) || Map.get(params, "sources") || [:claude_mem, :viki]
      top_n = Map.get(params, :top_n) || Map.get(params, "top_n") || @default_top_n

      timeout_ms =
        Map.get(params, :timeout_ms) || Map.get(params, "timeout_ms") || @default_timeout_ms

      {results, errors} = fanout(query, sources, timeout_ms)

      sorted =
        results
        |> Enum.sort_by(& &1[:score], :desc)
        |> Enum.take(top_n)

      {:ok,
       %{
         results: sorted,
         sources_queried: sources,
         errors: errors,
         total: length(sorted)
       }}
    end
  end

  # ── Fanout ──────────────────────────────────────────────────────────────────

  @spec fanout(String.t(), [atom()], pos_integer()) :: {list(map()), list(map())}
  defp fanout(query, sources, timeout_ms) do
    sources
    |> Task.async_stream(
      fn source -> {source, query_source(source, query)} end,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {_source, {:ok, items}}}, {acc_results, acc_errors} ->
        {acc_results ++ items, acc_errors}

      {:ok, {source, {:not_implemented, reason}}}, {acc_results, acc_errors} ->
        Logger.debug("[FederationRouter] #{source} not implemented: #{inspect(reason)}")
        {acc_results, [%{source: source, error: :not_implemented} | acc_errors]}

      {:ok, {source, {:error, reason}}}, {acc_results, acc_errors} ->
        Logger.warning("[FederationRouter] #{source} error: #{inspect(reason)}")
        {acc_results, [%{source: source, error: reason} | acc_errors]}

      {:exit, :timeout}, {acc_results, acc_errors} ->
        Logger.warning("[FederationRouter] a source timed out")
        {acc_results, [%{source: :unknown, error: :timeout} | acc_errors]}
    end)
  end

  # ── Per-source dispatch ─────────────────────────────────────────────────────

  @spec query_source(atom(), String.t()) ::
          {:ok, list(map())}
          | {:not_implemented, atom()}
          | {:error, term()}

  defp query_source(:claude_mem, query), do: query_claude_mem(query)
  defp query_source(:viki, query), do: query_viki(query)
  defp query_source(:serena, _query), do: {:not_implemented, :serena}

  defp query_source(unknown, _query) do
    Logger.warning("[FederationRouter] unknown source: #{inspect(unknown)}")
    {:error, {:unknown_source, unknown}}
  end

  # ── claude-mem (SQLite FTS) ─────────────────────────────────────────────────

  @spec query_claude_mem(String.t()) :: {:ok, list(map())} | {:error, term()}
  defp query_claude_mem(query) do
    case Code.ensure_loaded(@sqlite3) do
      {:module, _} ->
        db_path = Path.expand(@db_path)

        if File.exists?(db_path) do
          do_sqlite_fts(db_path, query)
        else
          {:error, {:db_not_found, db_path}}
        end

      {:error, _} ->
        {:error, :exqlite_not_available}
    end
  end

  @spec do_sqlite_fts(String.t(), String.t()) :: {:ok, list(map())} | {:error, term()}
  defp do_sqlite_fts(db_path, query) do
    with {:ok, db} <- apply(@sqlite3, :open, [db_path, [:readonly]]),
         sql =
           "SELECT id, content, created_at, session_id, narrative " <>
             "FROM observations " <>
             "WHERE content LIKE ? " <>
             "ORDER BY created_at DESC LIMIT 50",
         {:ok, stmt} <- apply(@sqlite3, :prepare, [db, sql]),
         :ok <- apply(@sqlite3, :bind, [db, stmt, ["%#{query}%"]]),
         {:ok, rows} <- fetch_all_rows(db, stmt) do
      apply(@sqlite3, :release, [db, stmt])
      apply(@sqlite3, :close, [db])
      mapped = Enum.map(rows, &to_claude_mem_result/1)
      {:ok, mapped}
    else
      {:error, reason} -> {:error, {:sqlite, reason}}
    end
  end

  @spec to_claude_mem_result(list()) :: map()
  defp to_claude_mem_result([id, content, ts, session_id, narrative]) do
    %{
      source: :claude_mem,
      score: 1.0,
      text: content,
      ts: ts,
      session_id: session_id,
      narrative: narrative,
      id: id
    }
  end

  defp to_claude_mem_result(row) when is_list(row) do
    %{
      source: :claude_mem,
      score: 1.0,
      text: List.first(row),
      ts: nil,
      session_id: nil,
      narrative: nil,
      id: nil
    }
  end

  @spec fetch_all_rows(term(), term()) :: {:ok, list(list())} | {:error, term()}
  defp fetch_all_rows(db, stmt), do: fetch_all_rows(db, stmt, [])

  defp fetch_all_rows(db, stmt, acc) do
    case apply(@sqlite3, :step, [db, stmt]) do
      {:row, row} -> fetch_all_rows(db, stmt, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, {:sqlite_step, reason}}
    end
  end

  # ── VIKI HTTP ──────────────────────────────────────────────────────────────

  @spec query_viki(String.t()) :: {:ok, list(map())} | {:error, term()}
  defp query_viki(query) do
    viki_url = Application.get_env(:apm, :viki_url, "http://localhost:4010")
    viki_token = Application.get_env(:apm, :viki_token, "")

    url = ~c"#{viki_url}/api/search"
    body = Jason.encode!(%{query: query, limit: 50})

    headers = [
      {~c"Content-Type", ~c"application/json"},
      {~c"Authorization", ~c"Bearer #{viki_token}"}
    ]

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_vsn, status, _reason}, _hdrs, resp_body}} when status in 200..299 ->
        decode_viki_response(resp_body)

      {:ok, {{_vsn, status, _reason}, _hdrs, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @spec decode_viki_response(iodata()) :: {:ok, list(map())} | {:error, term()}
  defp decode_viki_response(body) do
    raw = if is_list(body), do: :erlang.list_to_binary(body), else: body

    case Jason.decode(raw) do
      {:ok, %{"results" => items}} when is_list(items) ->
        mapped = Enum.map(items, &to_viki_result/1)
        {:ok, mapped}

      {:ok, items} when is_list(items) ->
        mapped = Enum.map(items, &to_viki_result/1)
        {:ok, mapped}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  @spec to_viki_result(map()) :: map()
  defp to_viki_result(item) do
    %{
      source: :viki,
      score: Map.get(item, "score") || Map.get(item, "similarity") || 0.0,
      text: Map.get(item, "text") || Map.get(item, "content") || "",
      ts: Map.get(item, "created_at") || Map.get(item, "ts"),
      conversation_id: Map.get(item, "conversation_id")
    }
  end
end
