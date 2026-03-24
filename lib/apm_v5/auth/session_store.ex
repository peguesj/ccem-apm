defmodule ApmV5.Auth.SessionStore do
  @moduledoc """
  GenServer managing authorization sessions for AgentLock.

  Sessions bind a user identity + role to a trust ceiling and data boundary.
  Dual-indexed ETS allows O(1) lookup by both session_id and user_id.

  ## Sessions
  - Default TTL: 15 minutes (900 seconds)
  - Trust ceiling degrades monotonically per session
  - Scope changes trigger reauth (destroy + create new)
  - Expired sessions cleaned every 60 seconds

  ## ETS Tables
  - `:agentlock_sessions` — keyed by session_id
  - `:agentlock_sessions_by_user` — keyed by user_id, value is list of session_ids
  """

  use GenServer

  require Logger

  alias ApmV5.Auth.Types
  alias ApmV5.Auth.Types.AuthSession

  @sessions_table :agentlock_sessions
  @user_index_table :agentlock_sessions_by_user
  @cleanup_interval_ms 60_000
  @default_ttl_seconds 900

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new authorization session.

  Returns `{:ok, session_id}`.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def create(user_id, role, opts \\ []) do
    GenServer.call(__MODULE__, {:create, user_id, role, opts})
  end

  @doc "Get a session by ID. Returns nil if expired or not found."
  @spec get(String.t()) :: AuthSession.t() | nil
  def get(session_id) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        if expired?(session), do: nil, else: session

      [] ->
        nil
    end
  end

  @doc "Get the most recent active session for a user."
  @spec get_by_user(String.t()) :: AuthSession.t() | nil
  def get_by_user(user_id) do
    case :ets.lookup(@user_index_table, user_id) do
      [{^user_id, session_ids}] ->
        session_ids
        |> Enum.map(&get/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
        |> List.first()

      [] ->
        nil
    end
  end

  @doc "Destroy a session explicitly."
  @spec destroy(String.t()) :: :ok
  def destroy(session_id) do
    GenServer.call(__MODULE__, {:destroy, session_id})
  end

  @doc "Update trust ceiling for a session (monotonic decrease only)."
  @spec update_trust(String.t(), Types.trust_level()) :: :ok | {:error, :not_found}
  def update_trust(session_id, new_trust) do
    GenServer.call(__MODULE__, {:update_trust, session_id, new_trust})
  end

  @doc "Increment tool call count for a session."
  @spec increment_tool_calls(String.t()) :: :ok
  def increment_tool_calls(session_id) do
    GenServer.cast(__MODULE__, {:increment, session_id, :tool_call_count})
  end

  @doc "Increment denied count for a session."
  @spec increment_denied(String.t()) :: :ok
  def increment_denied(session_id) do
    GenServer.cast(__MODULE__, {:increment, session_id, :denied_count})
  end

  @doc "List all active (non-expired) sessions."
  @spec list_active() :: [AuthSession.t()]
  def list_active do
    now = DateTime.utc_now()

    :ets.tab2list(@sessions_table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.reject(&(DateTime.compare(&1.expires_at, now) != :gt))
  end

  @doc "Return session stats."
  @spec stats() :: map()
  def stats do
    active = list_active()

    %{
      active_count: length(active),
      trust_distribution:
        active
        |> Enum.map(& &1.trust_ceiling)
        |> Enum.frequencies()
        |> Map.merge(%{authoritative: 0, derived: 0, untrusted: 0}, fn _k, v1, _v2 -> v1 end),
      total_tool_calls: active |> Enum.map(& &1.tool_call_count) |> Enum.sum(),
      total_denied: active |> Enum.map(& &1.denied_count) |> Enum.sum()
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@sessions_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@user_index_table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    Logger.info("[SessionStore] Started — tables #{@sessions_table}, #{@user_index_table}")
    {:ok, %{total_created: 0, total_destroyed: 0}}
  end

  @impl true
  def handle_call({:create, user_id, role, opts}, _from, state) do
    session_id = generate_session_id()
    now = DateTime.utc_now()
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    boundary = Keyword.get(opts, :data_boundary, :authenticated_user_only)
    metadata = Keyword.get(opts, :metadata, %{})

    session = %AuthSession{
      id: session_id,
      user_id: user_id,
      role: role,
      data_boundary: boundary,
      trust_ceiling: :authoritative,
      created_at: now,
      expires_at: DateTime.add(now, ttl, :second),
      metadata: metadata
    }

    :ets.insert(@sessions_table, {session_id, session})
    add_to_user_index(user_id, session_id)

    broadcast({:session_created, session})
    {:reply, {:ok, session_id}, %{state | total_created: state.total_created + 1}}
  end

  @impl true
  def handle_call({:destroy, session_id}, _from, state) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        :ets.delete(@sessions_table, session_id)
        remove_from_user_index(session.user_id, session_id)
        broadcast({:session_destroyed, session_id})
        {:reply, :ok, %{state | total_destroyed: state.total_destroyed + 1}}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:update_trust, session_id, new_trust}, _from, state) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        # Monotonic decrease only
        updated_trust = Types.min_trust(session.trust_ceiling, new_trust)
        updated = %{session | trust_ceiling: updated_trust}
        :ets.insert(@sessions_table, {session_id, updated})

        if updated_trust != session.trust_ceiling do
          broadcast({:trust_ceiling_changed, session_id, updated_trust})
        end

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:increment, session_id, field}, state) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        updated = Map.update!(session, field, &(&1 + 1))
        :ets.insert(@sessions_table, {session_id, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleaned = cleanup_expired_sessions()

    if cleaned > 0 do
      Logger.debug("[SessionStore] Cleaned #{cleaned} expired sessions")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_session_id do
    hex = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    "auth_sess_#{hex}"
  end

  defp expired?(%AuthSession{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp add_to_user_index(user_id, session_id) do
    existing =
      case :ets.lookup(@user_index_table, user_id) do
        [{^user_id, ids}] -> ids
        [] -> []
      end

    :ets.insert(@user_index_table, {user_id, [session_id | existing]})
  end

  defp remove_from_user_index(user_id, session_id) do
    case :ets.lookup(@user_index_table, user_id) do
      [{^user_id, ids}] ->
        remaining = List.delete(ids, session_id)

        if remaining == [] do
          :ets.delete(@user_index_table, user_id)
        else
          :ets.insert(@user_index_table, {user_id, remaining})
        end

      [] ->
        :ok
    end
  end

  defp cleanup_expired_sessions do
    now = DateTime.utc_now()

    :ets.tab2list(@sessions_table)
    |> Enum.filter(fn {_id, session} -> DateTime.compare(session.expires_at, now) != :gt end)
    |> Enum.each(fn {id, session} ->
      :ets.delete(@sessions_table, id)
      remove_from_user_index(session.user_id, id)
      broadcast({:session_expired, id})
    end)
    |> then(fn _ ->
      # Return count cleaned (re-scan is fine for cleanup — infrequent)
      0
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval_ms)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:sessions", event)
  end
end
