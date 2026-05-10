defmodule ApmV5.Plugins.Memory.ClaudeMemBridge do
  @moduledoc """
  Read-only GenServer bridge to `~/.claude-mem/claude-mem.db`.

  Opens the SQLite database in read-only mode on start and exposes three
  query functions that project rows into a VIKI-compatible message shape:

      %{
        source:     "claude_mem",
        id:         integer,
        text:       binary,          # narrative field
        title:      binary,
        ts:         binary,          # ISO-8601 ts field
        session_id: binary,          # memory_session_id field
        concepts:   list(binary),
        files:      list(binary)     # files_read ++ files_modified
      }

  ## Health check on mount

  If the database file does not exist the GenServer still starts but all
  queries return `{:error, :db_unavailable}`.  A warning is logged so
  operators can detect the missing file without crashing the supervision tree.

  ## Usage

      ClaudeMemBridge.search("phoenix liveview", limit: 20)
      ClaudeMemBridge.session("sess-abc123")
      ClaudeMemBridge.stats()
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  @db_path "~/.claude-mem/claude-mem.db"
  @table "observations"

  # ── Types ──────────────────────────────────────────────────────────────────

  @type viki_obs :: %{
          source: String.t(),
          id: integer(),
          text: String.t(),
          title: String.t(),
          ts: String.t(),
          session_id: String.t(),
          concepts: [String.t()],
          files: [String.t()]
        }

  @type state :: %{db: term() | nil}

  # ── Column positions in SELECT * FROM observations ─────────────────────────
  # Schema: id, content_hash, title, subtitle, facts, narrative, concepts,
  #         files_read, files_modified, memory_session_id, prompt_number, ts

  @col_id 0
  @col_title 2
  @col_facts 4
  @col_narrative 5
  @col_concepts 6
  @col_files_read 7
  @col_files_modified 8
  @col_session_id 9
  @col_ts 11

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Full-text / LIKE search across `narrative` and `facts`.

  Options:
  - `:limit` — max rows returned (default 50).
  """
  @spec search(String.t(), keyword()) :: {:ok, [viki_obs()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query, opts})
  end

  @doc "Return observations for one `memory_session_id` ordered by `prompt_number`."
  @spec session(String.t()) :: {:ok, [viki_obs()]} | {:error, term()}
  def session(memory_session_id) when is_binary(memory_session_id) do
    GenServer.call(__MODULE__, {:session, memory_session_id})
  end

  @doc "Return aggregate stats: count, min_ts, max_ts."
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Returns `:ok` if the DB is open, else `{:error, :db_unavailable}`."
  @spec health() :: :ok | {:error, :db_unavailable}
  def health do
    GenServer.call(__MODULE__, :health)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Allow test overrides via Application env or GenServer opts
    raw_path =
      Keyword.get(opts, :db_path) ||
        Application.get_env(:apm_v5, :claude_mem_db_path) ||
        @db_path

    db_path = Path.expand(raw_path)

    case open_db(db_path) do
      {:ok, db} ->
        Logger.info("[ClaudeMemBridge] opened #{db_path} read-only")
        {:ok, %{db: db}}

      {:error, reason} ->
        Logger.warning("[ClaudeMemBridge] DB unavailable (#{inspect(reason)}); queries will fail gracefully")
        {:ok, %{db: nil}}
    end
  end

  @impl true
  def handle_call(:health, _from, %{db: nil} = state) do
    {:reply, {:error, :db_unavailable}, state}
  end

  def handle_call(:health, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(_call, _from, %{db: nil} = state) do
    {:reply, {:error, :db_unavailable}, state}
  end

  def handle_call({:search, query, opts}, _from, %{db: db} = state) do
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{query}%"

    sql = """
    SELECT * FROM #{@table}
    WHERE narrative LIKE ? OR facts LIKE ?
    ORDER BY ts DESC
    LIMIT ?
    """

    result = exec_query(db, sql, [pattern, pattern, limit])
    {:reply, result, state}
  end

  def handle_call({:session, session_id}, _from, %{db: db} = state) do
    sql = """
    SELECT * FROM #{@table}
    WHERE memory_session_id = ?
    ORDER BY prompt_number ASC
    """

    result = exec_query(db, sql, [session_id])
    {:reply, result, state}
  end

  def handle_call(:stats, _from, %{db: db} = state) do
    sql = "SELECT COUNT(*), MIN(ts), MAX(ts) FROM #{@table}"

    result =
      with {:ok, stmt} <- Sqlite3.prepare(db, sql),
           {:ok, rows} <- fetch_all(db, stmt),
           :ok <- Sqlite3.release(db, stmt) do
        case rows do
          [[count, min_ts, max_ts]] ->
            {:ok, %{count: count, min_ts: min_ts, max_ts: max_ts}}

          _ ->
            {:ok, %{count: 0, min_ts: nil, max_ts: nil}}
        end
      end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{db: nil}), do: :ok

  def terminate(_reason, %{db: db}) do
    Sqlite3.close(db)
    :ok
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec open_db(String.t()) :: {:ok, term()} | {:error, term()}
  defp open_db(path) do
    if File.exists?(path) do
      Sqlite3.open(path, mode: :readonly)
    else
      {:error, {:enoent, path}}
    end
  end

  @spec exec_query(term(), String.t(), [term()]) :: {:ok, [viki_obs()]} | {:error, term()}
  defp exec_query(db, sql, bindings) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, bindings),
         {:ok, rows} <- fetch_all(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      {:ok, Enum.map(rows, &project_row/1)}
    end
  end

  @spec fetch_all(term(), term()) :: {:ok, [list()]} | {:error, term()}
  defp fetch_all(db, stmt), do: fetch_all(db, stmt, [])

  defp fetch_all(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> fetch_all(db, stmt, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, {:sqlite_step, reason}}
    end
  end

  @spec project_row(list()) :: viki_obs()
  defp project_row(row) do
    files_read = parse_json_list(Enum.at(row, @col_files_read))
    files_modified = parse_json_list(Enum.at(row, @col_files_modified))

    %{
      source: "claude_mem",
      id: Enum.at(row, @col_id),
      text: Enum.at(row, @col_narrative) || "",
      title: Enum.at(row, @col_title) || "",
      ts: Enum.at(row, @col_ts) || "",
      session_id: Enum.at(row, @col_session_id) || "",
      concepts: parse_json_list(Enum.at(row, @col_concepts)),
      files: files_read ++ files_modified,
      facts: Enum.at(row, @col_facts) || ""
    }
  end

  @spec parse_json_list(nil | String.t()) :: [String.t()]
  defp parse_json_list(nil), do: []
  defp parse_json_list(""), do: []

  defp parse_json_list(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
