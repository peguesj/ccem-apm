defmodule ApmV5.Orchestration.FormationPersistenceStore do
  @moduledoc """
  SQLite WAL-backed event store for formation lifecycle durability.

  Persists formation events to disk so that in-flight formations survive
  APM restarts.  On `GenServer.init/1`, `replay/0` is called to restore
  ETS-resident formation state in `ApmV5.UpmStore` from the persisted log.

  ## Database

  Stored at `~/.claude/ccem/apm/formations.db` (WAL journal mode).

  ### Schema

      formation_events(
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        formation_id  TEXT NOT NULL,
        event_type    TEXT NOT NULL,
        payload       TEXT NOT NULL,   -- JSON
        inserted_at   TEXT NOT NULL
      )

      INDEX idx_formation_events_formation_id ON formation_events(formation_id)

  ## WAL mode

  `PRAGMA journal_mode=WAL;` is executed on open so multiple readers and
  a single writer can proceed concurrently — crucial for a dashboard that
  polls formation state while writes are in flight.

  ## Hooked event boundaries

  Wire `UpmStore` boundaries to call `append_event/3`:

  - `:formation_registered`
  - `:squadron_started`
  - `:swarm_spawned`
  - `:worker_result`
  - `:squadron_complete`
  - `:formation_complete`
  """

  use GenServer

  require Logger

  alias Exqlite.Sqlite3

  @default_db_path "~/.claude/ccem/apm/formations.db"

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Append a formation lifecycle event to the SQLite log.

  - `formation_id`  — the formation identifier string
  - `event_type`    — one of `:formation_registered`, `:squadron_started`,
    `:swarm_spawned`, `:worker_result`, `:squadron_complete`, `:formation_complete`
  - `payload`       — any serialisable map/term (encoded as JSON)

  Returns `:ok`.
  """
  @spec append_event(String.t(), atom() | String.t(), map() | term()) :: :ok
  def append_event(formation_id, event_type, payload) do
    GenServer.call(__MODULE__, {:append_event, formation_id, event_type, payload})
  end

  @doc """
  Return all persisted events for a formation, in insertion order.

  Each event is a map with `:event_type`, `:payload`, `:inserted_at` keys.
  """
  @spec events_for(String.t()) :: [map()]
  def events_for(formation_id) do
    GenServer.call(__MODULE__, {:events_for, formation_id})
  end

  @doc """
  Replay all persisted events to rebuild ETS-resident formation state.

  Called automatically on `init/1`.  Can be called manually after a
  cold-start to restore state without restarting the GenServer.
  """
  @spec replay() :: :ok
  def replay do
    GenServer.call(__MODULE__, :replay, 30_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, @default_db_path) |> Path.expand()
    db_dir = Path.dirname(db_path)

    # Ensure directory exists
    File.mkdir_p!(db_dir)

    case Sqlite3.open(db_path) do
      {:ok, conn} ->
        :ok = setup_schema(conn)
        Logger.info("[FormationPersistenceStore] Opened #{db_path}")

        state = %{conn: conn, db_path: db_path}

        # Defer replay until after init/1 returns so that UpmStore calls
        # (which re-enter this module via persist_event) don't deadlock.
        send(self(), :replay_on_boot)

        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "[FormationPersistenceStore] Failed to open SQLite DB at #{db_path}: #{inspect(reason)}"
        )

        {:stop, {:db_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:append_event, formation_id, event_type, payload}, _from, state) do
    event_type_str = to_string(event_type)
    payload_json = Jason.encode!(payload)
    inserted_at = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    INSERT INTO formation_events (formation_id, event_type, payload, inserted_at)
    VALUES (?1, ?2, ?3, ?4)
    """

    result =
      with {:ok, stmt} <- Sqlite3.prepare(state.conn, sql),
           :ok <- Sqlite3.bind(stmt, [formation_id, event_type_str, payload_json, inserted_at]),
           :done <- Sqlite3.step(state.conn, stmt) do
        :ok
      else
        {:error, reason} ->
          Logger.error(
            "[FormationPersistenceStore] append_event failed for #{formation_id}: #{inspect(reason)}"
          )

          {:error, reason}

        unexpected ->
          Logger.error(
            "[FormationPersistenceStore] unexpected step result: #{inspect(unexpected)}"
          )

          {:error, :unexpected_step_result}
      end

    {:reply, result, state}
  end

  def handle_call({:events_for, formation_id}, _from, state) do
    events = fetch_events_for(state.conn, formation_id)
    {:reply, events, state}
  end

  def handle_call(:replay, _from, state) do
    do_replay(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:replay_on_boot, state) do
    do_replay(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Sqlite3.close(conn)
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp setup_schema(conn) do
    # Enable WAL mode for concurrent read + write access
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS formation_events (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        formation_id TEXT NOT NULL,
        event_type   TEXT NOT NULL,
        payload      TEXT NOT NULL,
        inserted_at  TEXT NOT NULL
      );
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE INDEX IF NOT EXISTS idx_formation_events_formation_id
        ON formation_events(formation_id);
      """)

    :ok
  end

  defp fetch_events_for(conn, formation_id) do
    sql = """
    SELECT event_type, payload, inserted_at
    FROM formation_events
    WHERE formation_id = ?1
    ORDER BY id ASC
    """

    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        :ok = Sqlite3.bind(stmt, [formation_id])
        collect_rows(conn, stmt, [])

      {:error, reason} ->
        Logger.error("[FormationPersistenceStore] events_for query failed: #{inspect(reason)}")
        []
    end
  end

  defp collect_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, [event_type, payload_json, inserted_at]} ->
        payload =
          case Jason.decode(payload_json) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{raw: payload_json}
          end

        event = %{
          event_type: event_type,
          payload: payload,
          inserted_at: inserted_at
        }

        collect_rows(conn, stmt, [event | acc])

      :done ->
        Enum.reverse(acc)

      {:error, reason} ->
        Logger.error("[FormationPersistenceStore] row fetch error: #{inspect(reason)}")
        Enum.reverse(acc)
    end
  end

  defp do_replay(%{conn: conn}) do
    sql = """
    SELECT DISTINCT formation_id FROM formation_events ORDER BY id ASC
    """

    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        formation_ids = collect_column(conn, stmt, [])

        Logger.info(
          "[FormationPersistenceStore] Replaying #{length(formation_ids)} formations from disk"
        )

        Enum.each(formation_ids, fn formation_id ->
          events = fetch_events_for(conn, formation_id)
          apply_events_to_upm(formation_id, events)
        end)

      {:error, reason} ->
        Logger.error("[FormationPersistenceStore] replay query failed: #{inspect(reason)}")
    end
  end

  defp collect_column(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, [value]} ->
        collect_column(conn, stmt, [value | acc])

      :done ->
        Enum.reverse(acc)

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp apply_events_to_upm(formation_id, events) do
    # Determine final status from the last event
    last_event = List.last(events)

    if is_nil(last_event) do
      :ok
    else
      status =
        case last_event.event_type do
          "formation_complete" -> "complete"
          "formation_registered" -> "registered"
          _ -> "running"
        end

      # Reconstruct minimal formation from the registration event payload.
      # Use restore_formation/1 (direct ETS insert) to avoid circular
      # persist_event calls.
      first_event = List.first(events)
      payload = Map.get(first_event || %{}, :payload, %{})

      now = DateTime.utc_now()

      formation = %{
        id: formation_id,
        name: Map.get(payload, "name", formation_id),
        squadrons: Map.get(payload, "squadrons", []),
        status: status,
        upm_session_id: Map.get(payload, "upm_session_id"),
        events: [],
        registered_at: now,
        updated_at: now
      }

      # Direct ETS restore — bypasses persist_event to avoid circular calls
      ApmV5.UpmStore.restore_formation(formation)
    end
  end
end
