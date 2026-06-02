defmodule Apm.Plugins.Memory.MemoryClientBridge do
  @moduledoc """
  GenServer that communicates with the claude-mem worker service.

  ## Transport modes

  - `:http` — Primary path. POSTs JSON to the claude-mem worker on
    `http://localhost:37777`. Uses Erlang's built-in `:httpc` so no
    external HTTP dependency is needed.
  - `:sqlite` — Fallback path. Reads `~/.claude-mem/claude-mem.db`
    directly via `Exqlite` when the HTTP worker is unreachable and
    `Exqlite` is available.
  - `:unavailable` — Neither transport is accessible. All API functions
    return `{:error, :unreachable}`.

  Mode is detected on `init/1` and re-evaluated every 60 seconds via a
  scheduled `:health_check` message.
  """

  use GenServer
  require Logger

  @worker_base_url "http://localhost:37777"
  @db_path "~/.claude-mem/claude-mem.db"
  @health_interval_ms 60_000

  # ── Types ──────────────────────────────────────────────────────────────────

  @type mode :: :http | :sqlite | :unavailable

  @type state :: %{
          mode: mode(),
          last_check: DateTime.t()
        }

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Search observations by a free-text query string."
  @spec search(String.t()) :: {:ok, list(map())} | {:error, term()}
  def search(query) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  @doc "Fetch specific observations by a list of IDs."
  @spec get_observations([String.t()]) :: {:ok, list(map())} | {:error, term()}
  def get_observations(ids) when is_list(ids) do
    GenServer.call(__MODULE__, {:get_observations, ids})
  end

  @doc """
  Get observations within an optional date range.

  Options:
  - `:from` — `DateTime.t()` lower bound (inclusive).
  - `:to`   — `DateTime.t()` upper bound (inclusive).
  """
  @spec timeline(keyword()) :: {:ok, list(map())} | {:error, term()}
  def timeline(opts \\ []) do
    GenServer.call(__MODULE__, {:timeline, opts})
  end

  @doc "Returns `:ok` if the bridge can reach a backend, else `{:error, :unreachable}`."
  @spec health_check() :: :ok | {:error, :unreachable}
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :inets.start(:httpc, profile: :ccem_memory)

    mode = detect_mode()
    schedule_health_check()

    Logger.info("[MemoryClientBridge] initialized in mode=#{mode}")

    {:ok, %{mode: mode, last_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_call({:search, query}, _from, state) do
    result = do_search(state.mode, query)
    {:reply, result, state}
  end

  def handle_call({:get_observations, ids}, _from, state) do
    result = do_get_observations(state.mode, ids)
    {:reply, result, state}
  end

  def handle_call({:timeline, opts}, _from, state) do
    result = do_timeline(state.mode, opts)
    {:reply, result, state}
  end

  def handle_call(:health_check, _from, state) do
    reply = if state.mode == :unavailable, do: {:error, :unreachable}, else: :ok
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_mode = detect_mode()

    if new_mode != state.mode do
      Logger.info("[MemoryClientBridge] mode changed #{state.mode} -> #{new_mode}")
    end

    schedule_health_check()
    {:noreply, %{state | mode: new_mode, last_check: DateTime.utc_now()}}
  end

  def handle_info(msg, state) do
    Logger.debug("[MemoryClientBridge] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Mode detection ─────────────────────────────────────────────────────────

  @spec detect_mode() :: mode()
  defp detect_mode do
    cond do
      http_reachable?() -> :http
      sqlite_available?() -> :sqlite
      true -> :unavailable
    end
  end

  @spec http_reachable?() :: boolean()
  defp http_reachable? do
    url = ~c"#{@worker_base_url}/health"

    case :httpc.request(:get, {url, []}, [{:timeout, 2_000}], []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        true

      _ ->
        false
    end
  end

  @spec sqlite_available?() :: boolean()
  defp sqlite_available? do
    case Code.ensure_loaded(Exqlite.Sqlite3) do
      {:module, _} ->
        db_path = Path.expand(@db_path)
        File.exists?(db_path)

      _ ->
        false
    end
  end

  # ── HTTP transport ─────────────────────────────────────────────────────────

  @spec do_search(mode(), String.t()) :: {:ok, list(map())} | {:error, term()}
  defp do_search(:http, query) do
    # claude-mem worker: GET /api/search?query=...
    # Returns MCP-style {content: [{type: "text", text: "..."}]} — not structured data.
    # Fall through to observations with search as a filter for now.
    case http_get("/api/observations?limit=200") do
      {:ok, %{"items" => items}} when is_list(items) ->
        q = String.downcase(query)

        filtered =
          Enum.filter(items, fn obs ->
            searchable =
              [obs["title"], obs["subtitle"], obs["narrative"], obs["text"]]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" ")
              |> String.downcase()

            String.contains?(searchable, q)
          end)

        {:ok, filtered}

      {:ok, _other} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp do_search(:sqlite, query), do: sqlite_search(query)
  defp do_search(:unavailable, _query), do: {:error, :unreachable}

  @spec do_get_observations(mode(), [String.t()]) :: {:ok, list(map())} | {:error, term()}
  defp do_get_observations(:http, ids) do
    # claude-mem worker: GET /api/observations — fetch all then filter by ID
    case http_get("/api/observations?limit=500") do
      {:ok, %{"items" => items}} when is_list(items) ->
        id_set = MapSet.new(ids, &to_string/1)
        matched = Enum.filter(items, fn obs -> to_string(obs["id"]) in id_set end)
        {:ok, matched}

      {:ok, _other} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp do_get_observations(:sqlite, ids), do: sqlite_get_observations(ids)
  defp do_get_observations(:unavailable, _ids), do: {:error, :unreachable}

  @spec do_timeline(mode(), keyword()) :: {:ok, list(map())} | {:error, term()}
  defp do_timeline(:http, _opts) do
    # claude-mem worker: GET /api/observations — sorted by created_at
    case http_get("/api/observations?limit=500") do
      {:ok, %{"items" => items}} when is_list(items) ->
        sorted = Enum.sort_by(items, & &1["created_at"], :asc)
        {:ok, sorted}

      {:ok, _other} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp do_timeline(:sqlite, opts), do: sqlite_timeline(opts)
  defp do_timeline(:unavailable, _opts), do: {:error, :unreachable}

  @spec http_get(String.t()) :: {:ok, map() | list()} | {:error, term()}
  defp http_get(path) do
    url = ~c"#{@worker_base_url}#{path}"

    case :httpc.request(:get, {url, []}, [{:timeout, 5_000}], []) do
      {:ok, {{_vsn, status, _reason}, _headers, resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:ok, {{_vsn, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ── SQLite transport ───────────────────────────────────────────────────────

  # All Exqlite calls go through apply/3 so the compiler never emits
  # "undefined module" warnings when Exqlite is not in mix.exs.
  @sqlite3 Exqlite.Sqlite3

  @spec sqlite_search(String.t()) :: {:ok, list(map())} | {:error, term()}
  defp sqlite_search(query) do
    with {:ok, db} <- open_db(),
         sql = "SELECT * FROM observations WHERE content LIKE ? ORDER BY created_at DESC LIMIT 100",
         {:ok, stmt} <- apply(@sqlite3, :prepare, [db, sql]),
         :ok <- apply(@sqlite3, :bind, [db, stmt, ["%#{query}%"]]),
         {:ok, rows} <- fetch_all_rows(db, stmt) do
      apply(@sqlite3, :release, [db, stmt])
      apply(@sqlite3, :close, [db])
      {:ok, rows}
    end
  end

  @spec sqlite_get_observations([String.t()]) :: {:ok, list(map())} | {:error, term()}
  defp sqlite_get_observations([]), do: {:ok, []}

  defp sqlite_get_observations(ids) do
    placeholders = Enum.map_join(1..length(ids), ", ", fn _ -> "?" end)

    with {:ok, db} <- open_db(),
         sql = "SELECT * FROM observations WHERE id IN (#{placeholders})",
         {:ok, stmt} <- apply(@sqlite3, :prepare, [db, sql]),
         :ok <- apply(@sqlite3, :bind, [db, stmt, ids]),
         {:ok, rows} <- fetch_all_rows(db, stmt) do
      apply(@sqlite3, :release, [db, stmt])
      apply(@sqlite3, :close, [db])
      {:ok, rows}
    end
  end

  @spec sqlite_timeline(keyword()) :: {:ok, list(map())} | {:error, term()}
  defp sqlite_timeline(opts) do
    from_dt = Keyword.get(opts, :from)
    to_dt = Keyword.get(opts, :to)

    {conditions, bindings} =
      []
      |> add_condition(from_dt, "created_at >= ?", from_dt && DateTime.to_iso8601(from_dt))
      |> add_condition(to_dt, "created_at <= ?", to_dt && DateTime.to_iso8601(to_dt))
      |> Enum.unzip()

    where_clause =
      case conditions do
        [] -> ""
        clauses -> " WHERE " <> Enum.join(clauses, " AND ")
      end

    sql = "SELECT * FROM observations#{where_clause} ORDER BY created_at ASC"

    with {:ok, db} <- open_db(),
         {:ok, stmt} <- apply(@sqlite3, :prepare, [db, sql]),
         :ok <- apply(@sqlite3, :bind, [db, stmt, bindings]),
         {:ok, rows} <- fetch_all_rows(db, stmt) do
      apply(@sqlite3, :release, [db, stmt])
      apply(@sqlite3, :close, [db])
      {:ok, rows}
    end
  end

  @spec open_db() :: {:ok, term()} | {:error, term()}
  defp open_db do
    db_path = Path.expand(@db_path)
    apply(@sqlite3, :open, [db_path])
  end

  @spec fetch_all_rows(term(), term()) :: {:ok, list(map())} | {:error, term()}
  defp fetch_all_rows(db, stmt) do
    fetch_all_rows(db, stmt, [])
  end

  defp fetch_all_rows(db, stmt, acc) do
    case apply(@sqlite3, :step, [db, stmt]) do
      {:row, row} ->
        fetch_all_rows(db, stmt, [row_to_map(row) | acc])

      :done ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, {:sqlite_step, reason}}
    end
  end

  @spec row_to_map(list()) :: map()
  defp row_to_map(row) do
    keys = [:id, :content, :created_at, :updated_at, :metadata]

    keys
    |> Enum.zip(row)
    |> Map.new()
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec schedule_health_check() :: reference()
  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_interval_ms)
  end

  @spec add_condition(list(), term(), String.t(), term()) :: list()
  defp add_condition(acc, nil, _clause, _binding), do: acc
  defp add_condition(acc, _value, clause, binding), do: [{clause, binding} | acc]
end
