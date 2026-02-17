defmodule ApmV4.AgentRegistry do
  @moduledoc """
  GenServer managing agent fleet state, sessions, and notifications via ETS.

  Ported from the Python APM's global AGENTS dict, _notifications list,
  and session tracking with threading locks → GenServer + ETS.
  """

  use GenServer

  @agents_table :apm_agents
  @sessions_table :apm_sessions
  @notifications_table :apm_notifications

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register or update an agent with metadata."
  @spec register_agent(String.t(), map()) :: :ok
  def register_agent(agent_id, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register_agent, agent_id, metadata})
  end

  @doc "Get a single agent by ID. Returns nil if not found."
  @spec get_agent(String.t()) :: map() | nil
  def get_agent(agent_id) do
    case :ets.lookup(@agents_table, agent_id) do
      [{^agent_id, agent}] -> agent
      [] -> nil
    end
  end

  @doc "List all registered agents as a list of maps."
  @spec list_agents() :: [map()]
  def list_agents do
    :ets.tab2list(@agents_table)
    |> Enum.map(fn {_id, agent} -> agent end)
  end

  @doc "Update an agent's status. Returns :ok or {:error, :not_found}."
  @spec update_status(String.t(), String.t()) :: :ok | {:error, :not_found}
  def update_status(agent_id, status) do
    GenServer.call(__MODULE__, {:update_status, agent_id, status})
  end

  # --- Session API ---

  @doc "Register a session with metadata."
  @spec register_session(map()) :: :ok
  def register_session(session_data) do
    GenServer.call(__MODULE__, {:register_session, session_data})
  end

  @doc "Get a session by ID. Returns nil if not found."
  @spec get_session(String.t()) :: map() | nil
  def get_session(session_id) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] -> session
      [] -> nil
    end
  end

  @doc "List all registered sessions."
  @spec list_sessions() :: [map()]
  def list_sessions do
    :ets.tab2list(@sessions_table)
    |> Enum.map(fn {_id, session} -> session end)
  end

  # --- Notification API ---

  @doc "Add a notification to the queue. Returns the notification ID."
  @spec add_notification(map()) :: integer()
  def add_notification(notification) do
    GenServer.call(__MODULE__, {:add_notification, notification})
  end

  @doc "Get all notifications, most recent first."
  @spec get_notifications() :: [map()]
  def get_notifications do
    :ets.tab2list(@notifications_table)
    |> Enum.map(fn {_id, notif} -> notif end)
    |> Enum.sort_by(& &1.id, :desc)
  end

  @doc "Clear all notifications."
  @spec clear_notifications() :: :ok
  def clear_notifications do
    GenServer.call(__MODULE__, :clear_notifications)
  end

  @doc "Clear all agents, sessions, and notifications. Resets notification counter."
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@agents_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@sessions_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@notifications_table, [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{notification_counter: 0}}
  end

  @impl true
  def handle_call({:register_agent, agent_id, metadata}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    agent =
      %{
        id: agent_id,
        name: Map.get(metadata, :name, agent_id),
        tier: Map.get(metadata, :tier, 1),
        status: Map.get(metadata, :status, "idle"),
        deps: Map.get(metadata, :deps, []),
        metadata: Map.get(metadata, :metadata, %{}),
        registered_at: now,
        last_seen: now
      }

    :ets.insert(@agents_table, {agent_id, agent})
    {:reply, :ok, state}
  end

  def handle_call({:update_status, agent_id, status}, _from, state) do
    case :ets.lookup(@agents_table, agent_id) do
      [{^agent_id, agent}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{agent | status: status, last_seen: now}
        :ets.insert(@agents_table, {agent_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:register_session, session_data}, _from, state) do
    session_id = Map.get(session_data, :session_id, Map.get(session_data, "session_id"))

    unless session_id do
      {:reply, {:error, :missing_session_id}, state}
    else
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      session =
        %{
          session_id: session_id,
          project: Map.get(session_data, :project, Map.get(session_data, "project", "default")),
          status: Map.get(session_data, :status, Map.get(session_data, "status", "active")),
          registered_at: now,
          last_seen: now
        }

      :ets.insert(@sessions_table, {session_id, session})
      {:reply, :ok, state}
    end
  end

  def handle_call({:add_notification, notification}, _from, state) do
    counter = state.notification_counter + 1
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    notif =
      %{
        id: counter,
        title: Map.get(notification, :title, Map.get(notification, "title", "Notification")),
        message: Map.get(notification, :message, Map.get(notification, "message", "")),
        level: Map.get(notification, :level, Map.get(notification, "level", "info")),
        timestamp: now,
        read: false
      }

    :ets.insert(@notifications_table, {counter, notif})

    # Cap at 200 notifications (matching Python behavior)
    all_ids =
      :ets.tab2list(@notifications_table)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.sort()

    if length(all_ids) > 200 do
      to_delete = Enum.take(all_ids, length(all_ids) - 200)
      Enum.each(to_delete, &:ets.delete(@notifications_table, &1))
    end

    {:reply, counter, %{state | notification_counter: counter}}
  end

  def handle_call(:clear_notifications, _from, state) do
    :ets.delete_all_objects(@notifications_table)
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, _state) do
    :ets.delete_all_objects(@agents_table)
    :ets.delete_all_objects(@sessions_table)
    :ets.delete_all_objects(@notifications_table)
    {:reply, :ok, %{notification_counter: 0}}
  end
end
