defmodule ApmV5.Auth.ContextTracker do
  @moduledoc """
  GenServer tracking context provenance for trust degradation (AgentLock v1.1).

  Records context writes (file edits, web content, memory mutations) and
  maintains a monotonically decreasing trust ceiling per session. Once
  untrusted content enters context, trust can never rise within that session.

  ## Trust Degradation
  - USER_MESSAGE, SYSTEM_PROMPT → AUTHORITATIVE
  - TOOL_OUTPUT, AGENT_REASONING, FILE_CONTENT, AGENT_MEMORY, PEER_AGENT → DERIVED
  - WEB_CONTENT → UNTRUSTED

  ## ETS Table
  `:agentlock_context` — keyed by `{session_id, sequence}` tuple
  """

  use GenServer

  require Logger

  alias ApmV5.Auth.Types
  alias ApmV5.Auth.Types.ContextEntry

  @table :agentlock_context
  @max_entries_per_session 200

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a context write and update trust ceiling.

  Returns `{:ok, %ContextEntry{}}` with the recorded entry.
  Broadcasts `{:trust_ceiling_changed, session_id, level}` if trust degrades.
  """
  @spec record_write(String.t(), String.t(), Types.context_source(), String.t()) ::
          {:ok, ContextEntry.t()}
  def record_write(session_id, agent_id, source, content_hash) do
    GenServer.call(__MODULE__, {:record_write, session_id, agent_id, source, content_hash})
  end

  @doc "Get the current trust ceiling for a session."
  @spec get_trust_ceiling(String.t()) :: Types.trust_level()
  def get_trust_ceiling(session_id) do
    GenServer.call(__MODULE__, {:get_trust_ceiling, session_id})
  end

  @doc "Get the provenance log for a session."
  @spec get_provenance_log(String.t(), keyword()) :: [ContextEntry.t()]
  def get_provenance_log(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    :ets.tab2list(@table)
    |> Enum.filter(fn {{sid, _seq}, _entry} -> sid == session_id end)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc "Get all trust ceilings."
  @spec all_trust_ceilings() :: map()
  def all_trust_ceilings do
    GenServer.call(__MODULE__, :all_trust_ceilings)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    Logger.info("[ContextTracker] Started — ETS table #{@table}")
    # State: %{session_id => %{ceiling: trust_level, seq: integer}}
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:record_write, session_id, agent_id, source, content_hash}, _from, state) do
    session_state = Map.get(state.sessions, session_id, %{ceiling: :authoritative, seq: 0})
    new_seq = session_state.seq + 1
    source_trust = Types.source_trust(source)

    entry = %ContextEntry{
      id: "ctx_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}",
      session_id: session_id,
      agent_id: agent_id,
      source: source,
      trust_level: source_trust,
      content_hash: content_hash,
      timestamp: DateTime.utc_now()
    }

    # Insert into ETS
    :ets.insert(@table, {{session_id, new_seq}, entry})

    # Enforce max entries per session (ring buffer behavior)
    if new_seq > @max_entries_per_session do
      :ets.delete(@table, {session_id, new_seq - @max_entries_per_session})
    end

    # Monotonic trust degradation
    new_ceiling = Types.min_trust(session_state.ceiling, source_trust)
    new_session_state = %{ceiling: new_ceiling, seq: new_seq}

    if new_ceiling != session_state.ceiling do
      broadcast({:trust_ceiling_changed, session_id, new_ceiling})

      # Also update SessionStore if available
      try do
        ApmV5.Auth.SessionStore.update_trust(session_id, new_ceiling)
      rescue
        _ -> :ok
      end
    end

    broadcast({:context_recorded, entry})

    updated_sessions = Map.put(state.sessions, session_id, new_session_state)
    {:reply, {:ok, entry}, %{state | sessions: updated_sessions}}
  end

  @impl true
  def handle_call({:get_trust_ceiling, session_id}, _from, state) do
    ceiling =
      case Map.get(state.sessions, session_id) do
        %{ceiling: c} -> c
        nil -> :authoritative
      end

    {:reply, ceiling, state}
  end

  @impl true
  def handle_call(:all_trust_ceilings, _from, state) do
    ceilings =
      state.sessions
      |> Enum.map(fn {session_id, %{ceiling: c}} -> {session_id, c} end)
      |> Map.new()

    {:reply, ceilings, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:trust", event)
  end
end
