defmodule ApmV5.AgentRegistry do
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
    GenServer.call(__MODULE__, {:register_agent, agent_id, metadata, nil})
  end

  @doc "Register or update an agent with metadata, scoped to a project."
  @spec register_agent(String.t(), map(), String.t() | nil) :: :ok
  def register_agent(agent_id, metadata, project_name) do
    GenServer.call(__MODULE__, {:register_agent, agent_id, metadata, project_name})
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

  @doc "List agents filtered by project name."
  @spec list_agents(String.t() | nil) :: [map()]
  def list_agents(nil), do: list_agents()

  def list_agents(project_name) do
    :ets.tab2list(@agents_table)
    |> Enum.map(fn {_id, agent} -> agent end)
    |> Enum.filter(fn agent ->
      pn = Map.get(agent, :project_name)
      pn == project_name || is_nil(pn)
    end)
  end

  @doc "Return wave progress for a formation. Returns a map with current_wave, total_waves, agents_in_wave, agents_complete."
  @spec wave_progress(String.t()) :: map()
  def wave_progress(formation_id) do
    agents =
      :ets.tab2list(@agents_table)
      |> Enum.map(fn {_id, a} -> a end)
      |> Enum.filter(fn a -> Map.get(a, :formation_id) == formation_id end)

    wave_numbers = agents |> Enum.map(&Map.get(&1, :wave_number)) |> Enum.reject(&is_nil/1)
    wave_totals = agents |> Enum.map(&Map.get(&1, :wave_total)) |> Enum.reject(&is_nil/1)
    current_wave = if wave_numbers == [], do: 0, else: Enum.max(wave_numbers)
    total_waves = if wave_totals == [], do: 0, else: Enum.max(wave_totals)
    agents_in_wave = Enum.count(agents, &(Map.get(&1, :wave_number) == current_wave))
    agents_complete = Enum.count(agents, &(Map.get(&1, :wave_number) == current_wave and Map.get(&1, :status) in ["idle", "completed", "done"]))

    %{current_wave: current_wave, total_waves: total_waves, agents_in_wave: agents_in_wave, agents_complete: agents_complete}
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

  @doc "List sessions filtered by project name."
  @spec list_sessions(String.t() | nil) :: [map()]
  def list_sessions(nil), do: list_sessions()

  def list_sessions(project_name) do
    :ets.tab2list(@sessions_table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.filter(fn session -> Map.get(session, :project) == project_name end)
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

  @doc "Get notifications with optional keyword filters (category, project_name, namespace, type)."
  @spec get_notifications(keyword()) :: [map()]
  def get_notifications(filters) when is_list(filters) do
    get_notifications()
    |> filter_notifications(filters)
  end

  @doc "Mark all notifications as read."
  @spec mark_all_read() :: :ok
  def mark_all_read do
    GenServer.call(__MODULE__, :mark_all_read)
  end

  @doc "Update a full agent record (for v3-compatible /api/agents/update)."
  @spec update_agent(String.t(), map()) :: :ok | {:error, :not_found}
  def update_agent(agent_id, fields) do
    GenServer.call(__MODULE__, {:update_agent, agent_id, fields})
  end

  @doc "Mark a single notification as read by id."
  @spec mark_read(integer()) :: :ok
  def mark_read(id) do
    GenServer.call(__MODULE__, {:mark_read, id})
  end

  @doc "Mark all notifications as read (alias for mark_all_read/0)."
  @spec mark_all_notifications_read() :: :ok
  def mark_all_notifications_read, do: mark_all_read()

  @doc "Dismiss (delete) a single notification by id."
  @spec dismiss_notification(integer()) :: :ok
  def dismiss_notification(id) do
    GenServer.call(__MODULE__, {:dismiss_notification, id})
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
  def handle_call({:register_agent, agent_id, metadata, project_name}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    agent =
      %{
        id: agent_id,
        name: Map.get(metadata, :name, agent_id),
        tier: Map.get(metadata, :tier, 1),
        status: Map.get(metadata, :status, "idle"),
        deps: Map.get(metadata, :deps, []),
        metadata: Map.get(metadata, :metadata, %{}),
        project_name: project_name,
        namespace: Map.get(metadata, :namespace, nil),
        agent_type: Map.get(metadata, :agent_type, "individual"),
        path: Map.get(metadata, :path, nil),
        member_count: Map.get(metadata, :member_count, nil),
        # Formation hierarchy fields
        parent_id: Map.get(metadata, :parent_id, nil),
        formation_id: Map.get(metadata, :formation_id, nil),
        squadron: Map.get(metadata, :squadron, nil),
        swarm: Map.get(metadata, :swarm, nil),
        cluster: Map.get(metadata, :cluster, nil),
        role: Map.get(metadata, :role, nil),
        # UPM work-item fields
        story_id: Map.get(metadata, :story_id, nil),
        plane_issue_id: Map.get(metadata, :plane_issue_id, nil),
        wave: Map.get(metadata, :wave, nil),
        wave_number: Map.get(metadata, :wave_number, nil),
        wave_total: Map.get(metadata, :wave_total, nil),
        work_item_title: Map.get(metadata, :work_item_title, nil),
        upm_session_id: Map.get(metadata, :upm_session_id, nil),
        registered_at: now,
        last_seen: now
      }

    :ets.insert(@agents_table, {agent_id, agent})

    # Emit AG-UI RUN_STARTED event if EventStream is running
    if Process.whereis(ApmV5.EventStream) do
      ApmV5.EventStream.emit_run_started(agent_id, Map.get(metadata, :metadata, %{}))
    end

    # Broadcast agent registration to LiveView clients
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:agents", {:agent_registered, agent})

    {:reply, :ok, state}
  end

  def handle_call({:update_status, agent_id, status}, _from, state) do
    case :ets.lookup(@agents_table, agent_id) do
      [{^agent_id, agent}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{agent | status: status, last_seen: now}
        :ets.insert(@agents_table, {agent_id, updated})

        # Emit AG-UI events for status transitions
        if Process.whereis(ApmV5.EventStream) do
          if status in ["completed", "finished"] do
            run_id = Map.get(agent.metadata, "run_id", "run-#{agent_id}")
            ApmV5.EventStream.emit_run_finished(agent_id, run_id)
          end
        end

        # Broadcast status change to LiveView clients
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:agents", {:agent_updated, updated})

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

    # Backward compat: normalize :level to :type, accept both atom and string keys
    type =
      get_any(notification, [:type, "type", :level, "level"]) || "info"

    notif =
      %{
        id: counter,
        title: get_any(notification, [:title, "title"]) || "Notification",
        message: get_any(notification, [:message, "message"]) || "",
        type: to_string(type),
        level: to_string(type),
        category: get_any(notification, [:category, "category"]),
        project_name: get_any(notification, [:project_name, "project_name", :project, "project"]),
        namespace: get_any(notification, [:namespace, "namespace"]),
        formation_id: get_any(notification, [:formation_id, "formation_id"]),
        squadron_id: get_any(notification, [:squadron_id, "squadron_id"]),
        swarm_id: get_any(notification, [:swarm_id, "swarm_id"]),
        session_id: get_any(notification, [:session_id, "session_id"]),
        agent_id: get_any(notification, [:agent_id, "agent_id"]),
        story_id: get_any(notification, [:story_id, "story_id"]),
        wave_number: get_any(notification, [:wave_number, "wave_number", :wave, "wave"]),
        wave_total: get_any(notification, [:wave_total, "wave_total"]),
        upm_context: get_any(notification, [:upm_context, "upm_context"]),
        timestamp: now,
        read: false
      }

    :ets.insert(@notifications_table, {counter, notif})

    # Broadcast notification to LiveView clients
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:notifications", {:notification_added, notif})

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

  def handle_call({:dismiss_notification, id}, _from, state) do
    :ets.delete(@notifications_table, id)
    {:reply, :ok, state}
  end

  def handle_call({:mark_read, id}, _from, state) do
    case :ets.lookup(@notifications_table, id) do
      [{^id, notif}] ->
        :ets.insert(@notifications_table, {id, %{notif | read: true}})
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:notifications", :notifications_read)
      [] -> :ok
    end
    {:reply, :ok, state}
  end

  def handle_call(:mark_all_read, _from, state) do
    :ets.tab2list(@notifications_table)
    |> Enum.each(fn {id, notif} ->
      :ets.insert(@notifications_table, {id, %{notif | read: true}})
    end)

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:notifications", :notifications_read)
    {:reply, :ok, state}
  end

  def handle_call({:update_agent, agent_id, fields}, _from, state) do
    case :ets.lookup(@agents_table, agent_id) do
      [{^agent_id, agent}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated =
          agent
          |> maybe_put(fields, "status", :status)
          |> maybe_put(fields, "name", :name)
          |> maybe_put(fields, "tier", :tier)
          |> maybe_put(fields, "deps", :deps)
          |> maybe_put(fields, "metadata", :metadata)
          |> maybe_put(fields, "project_name", :project_name)
          |> maybe_put(fields, "namespace", :namespace)
          |> maybe_put(fields, "agent_type", :agent_type)
          |> maybe_put(fields, "path", :path)
          |> maybe_put(fields, "member_count", :member_count)
          |> maybe_put(fields, "story_id", :story_id)
          |> maybe_put(fields, "plane_issue_id", :plane_issue_id)
          |> maybe_put(fields, "wave", :wave)
          |> maybe_put(fields, "work_item_title", :work_item_title)
          |> maybe_put(fields, "upm_session_id", :upm_session_id)
          |> maybe_put(fields, "parent_id", :parent_id)
          |> maybe_put(fields, "formation_id", :formation_id)
          |> maybe_put(fields, "squadron", :squadron)
          |> maybe_put(fields, "swarm", :swarm)
          |> maybe_put(fields, "cluster", :cluster)
          |> maybe_put(fields, "role", :role)
          |> Map.put(:last_seen, now)

        :ets.insert(@agents_table, {agent_id, updated})
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:agents", {:agent_updated, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear_all, _from, _state) do
    :ets.delete_all_objects(@agents_table)
    :ets.delete_all_objects(@sessions_table)
    :ets.delete_all_objects(@notifications_table)
    {:reply, :ok, %{notification_counter: 0}}
  end

  @doc "List agents belonging to a formation."
  @spec list_formation(String.t()) :: [map()]
  def list_formation(formation_id) do
    :ets.tab2list(@agents_table)
    |> Enum.map(fn {_id, agent} -> agent end)
    |> Enum.filter(&(&1.formation_id == formation_id))
  end

  @doc "List agents in a specific squadron within a formation."
  @spec list_squadron(String.t(), String.t()) :: [map()]
  def list_squadron(formation_id, squadron) do
    list_formation(formation_id)
    |> Enum.filter(&(&1.squadron == squadron))
  end

  @doc "Get the hierarchy tree for an agent (walk up parent_id chain)."
  @spec get_hierarchy(String.t()) :: [map()]
  def get_hierarchy(agent_id) do
    case get_agent(agent_id) do
      nil -> []
      agent -> walk_hierarchy(agent, [agent])
    end
  end

  defp walk_hierarchy(%{parent_id: nil}, acc), do: Enum.reverse(acc)
  defp walk_hierarchy(%{parent_id: pid}, acc) do
    case get_agent(pid) do
      nil -> Enum.reverse(acc)
      parent -> walk_hierarchy(parent, [parent | acc])
    end
  end

  defp maybe_put(map, fields, string_key, atom_key) do
    case Map.get(fields, string_key, Map.get(fields, atom_key)) do
      nil -> map
      value -> Map.put(map, atom_key, value)
    end
  end

  defp get_any(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp filter_notifications(notifications, []), do: notifications

  defp filter_notifications(notifications, filters) do
    Enum.filter(notifications, fn n ->
      Enum.all?(filters, fn
        {:category, val} -> to_string(Map.get(n, :category)) == to_string(val)
        {:project_name, val} -> to_string(Map.get(n, :project_name)) == to_string(val)
        {:namespace, val} -> to_string(Map.get(n, :namespace)) == to_string(val)
        {:type, val} -> to_string(Map.get(n, :type, Map.get(n, :level))) == to_string(val)
        _other -> true
      end)
    end)
  end
end
