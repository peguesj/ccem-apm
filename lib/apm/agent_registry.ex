defmodule Apm.AgentRegistry do
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

  @doc "Get a single notification by id. Returns `{:ok, notif}` or `{:error, :not_found}`."
  @spec get_notification(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_notification(id) do
    case :ets.lookup(@notifications_table, id) do
      [{^id, notif}] -> {:ok, notif}
      [] -> {:error, :not_found}
    end
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
    formation_id =
      Map.get(metadata, :formation_id, Map.get(metadata, "formation_id"))

    agent_name = Map.get(metadata, :agent_name, Map.get(metadata, "agent_name"))
    agent_description = Map.get(metadata, :agent_description, Map.get(metadata, "agent_description"))
    agent_version = Map.get(metadata, :agent_version, Map.get(metadata, "agent_version"))

    span_opts =
      [provider_name: "ccem"]
      |> maybe_add_opt(:agent_name, agent_name)
      |> maybe_add_opt(:agent_description, agent_description)
      |> maybe_add_opt(:agent_version, agent_version)

    result =
      Apm.Tracing.with_agent_span(agent_id, formation_id, fn ->
        do_register_agent(agent_id, metadata, project_name)
      end, span_opts)

    # Issue a W3C Verifiable Credential alongside registration (CP-300 / comp-v10.3-s2).
    # Fire-and-forget so VC issuance never blocks the registration reply.
    # Look up the freshly-registered agent for its identity_map.
    spawn(fn ->
      identity_map =
        case :ets.lookup(@agents_table, agent_id) do
          [{^agent_id, agent}] -> agent
          [] -> %{}
        end
      maybe_issue_vc(agent_id, identity_map, metadata)
    end)

    {:reply, result, state}
  end

  def handle_call({:update_status, agent_id, status}, _from, state) do
    result =
      case :ets.lookup(@agents_table, agent_id) do
        [{^agent_id, agent}] ->
          formation_id = Map.get(agent, :formation_id)

          Apm.Tracing.with_agent_span(agent_id, formation_id, fn ->
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            updated = %{agent | status: status, last_seen: now}
            :ets.insert(@agents_table, {agent_id, updated})

            # Emit AG-UI events for status transitions
            if Process.whereis(Apm.EventStream) do
              if status in ["completed", "finished"] do
                run_id = Map.get(agent.metadata, "run_id", "run-#{agent_id}")
                Apm.EventStream.emit_run_finished(agent_id, run_id)
              end
            end

            # Broadcast status change to LiveView clients
            Phoenix.PubSub.broadcast(Apm.PubSub, "apm:agents", {:agent_updated, updated})

            :ok
          end, provider_name: "ccem")

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
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
        # Rich referential integrity fields (v7.1+)
        refs: build_refs(notification),
        trace: build_trace(notification),
        metadata: atomize_metadata(get_any(notification, [:metadata, "metadata"]) || %{}),
        actions: normalize_actions(get_any(notification, [:actions, "actions"]) || []),
        channel: get_any(notification, [:channel, "channel"]),
        source: get_any(notification, [:source, "source"]),
        timestamp: now,
        read: false
      }

    :ets.insert(@notifications_table, {counter, notif})

    # Broadcast notification to LiveView clients
    Phoenix.PubSub.broadcast(Apm.PubSub, "apm:notifications", {:notification_added, notif})

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
        Phoenix.PubSub.broadcast(Apm.PubSub, "apm:notifications", :notifications_read)
      [] -> :ok
    end
    {:reply, :ok, state}
  end

  def handle_call(:mark_all_read, _from, state) do
    :ets.tab2list(@notifications_table)
    |> Enum.each(fn {id, notif} ->
      :ets.insert(@notifications_table, {id, %{notif | read: true}})
    end)

    Phoenix.PubSub.broadcast(Apm.PubSub, "apm:notifications", :notifications_read)
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
          |> maybe_put(fields, "agent_name", :agent_name)
          |> maybe_put(fields, "agent_definition", :agent_definition)
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
          |> maybe_merge_trace_context(fields)
          |> Map.put(:last_seen, now)

        :ets.insert(@agents_table, {agent_id, updated})
        Phoenix.PubSub.broadcast(Apm.PubSub, "apm:agents", {:agent_updated, updated})
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

  @impl true
  def terminate(_reason, _state) do
    :ets.delete(@agents_table)
    :ets.delete(@sessions_table)
    :ets.delete(@notifications_table)
    :ok
  end

  # Core agent registration logic, extracted so it can be wrapped in an OTel
  # span by handle_call({:register_agent, ...}) (prov-w3-s8 / CP-282).
  @spec do_register_agent(String.t(), map(), String.t() | nil) :: :ok
  defp do_register_agent(agent_id, metadata, project_name) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Build canonical identity via AgentIdentity (OTel gen_ai.agent.* + CCEM extensions)
    params_with_project = Map.put(metadata, :project_name, project_name || Map.get(metadata, :project_name))
    identity = Apm.AgentIdentity.build(agent_id, params_with_project)
    identity_map = Apm.AgentIdentity.to_map(identity)

    # Extract optional W3C trace context (obs-s3 / CP-218).
    trace_context = build_trace_context(metadata)

    # Build delegation chain when parent_agent_id is present (prov-w3-s7 / CP-281).
    parent_agent_id =
      Map.get(metadata, :parent_agent_id, Map.get(metadata, "parent_agent_id"))

    session_id =
      Map.get(metadata, :session_id, Map.get(metadata, "session_id", "unknown"))

    delegation_chain = build_delegation_chain(agent_id, parent_agent_id, session_id)

    agent =
      identity_map
      |> Map.merge(%{
        id: agent_id,
        tier: Map.get(metadata, :tier, Map.get(metadata, "tier", 1)),
        status: Map.get(metadata, :status, Map.get(metadata, "status", "idle")),
        deps: Map.get(metadata, :deps, Map.get(metadata, "deps", [])),
        metadata: Map.get(metadata, :metadata, Map.get(metadata, "metadata", %{})),
        namespace: Map.get(metadata, :namespace, Map.get(metadata, "namespace", nil)),
        member_count: Map.get(metadata, :member_count, Map.get(metadata, "member_count", nil)),
        wave_total: Map.get(metadata, :wave_total, Map.get(metadata, "wave_total", nil)),
        trace_context: trace_context,
        delegation_chain: delegation_chain,
        registered_at: now,
        last_seen: now
      })

    :ets.insert(@agents_table, {agent_id, agent})

    # Emit AG-UI RUN_STARTED event if EventStream is running
    if Process.whereis(Apm.EventStream) do
      Apm.EventStream.emit_run_started(agent_id, Map.get(metadata, :metadata, %{}))
    end

    # Broadcast agent registration to LiveView clients
    Phoenix.PubSub.broadcast(Apm.PubSub, "apm:agents", {:agent_registered, agent})

    :ok
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

  # Merge trace_context from update fields without overwriting an existing value
  # with nil (allows partial updates to preserve existing trace attribution).
  defp maybe_merge_trace_context(agent, fields) do
    new_tc = build_trace_context(fields)
    if is_nil(new_tc), do: agent, else: Map.put(agent, :trace_context, new_tc)
  end

  # Build a normalized trace_context map from incoming registration metadata.
  # Accepts the W3C `traceparent` string plus explicit field overrides.
  # Returns nil if no trace information is present so JSON serialization stays clean.
  @spec build_trace_context(map()) :: map() | nil
  defp build_trace_context(metadata) do
    raw = Map.get(metadata, :trace_context, Map.get(metadata, "trace_context"))

    traceparent =
      Map.get(metadata, :traceparent, Map.get(metadata, "traceparent")) ||
        (is_map(raw) && (Map.get(raw, :traceparent) || Map.get(raw, "traceparent")))

    trace_id =
      (is_map(raw) && (Map.get(raw, :trace_id) || Map.get(raw, "trace_id"))) ||
        Map.get(metadata, :trace_id, Map.get(metadata, "trace_id")) ||
        extract_trace_id_from_traceparent(traceparent)

    span_id =
      (is_map(raw) && (Map.get(raw, :span_id) || Map.get(raw, "span_id"))) ||
        Map.get(metadata, :span_id, Map.get(metadata, "span_id"))

    parent_span_id =
      (is_map(raw) && (Map.get(raw, :parent_span_id) || Map.get(raw, "parent_span_id"))) ||
        Map.get(metadata, :parent_span_id, Map.get(metadata, "parent_span_id"))

    if is_nil(trace_id) && is_nil(traceparent) do
      nil
    else
      %{
        trace_id: trace_id,
        span_id: span_id,
        parent_span_id: parent_span_id,
        traceparent: traceparent
      }
    end
  end

  # Parse trace_id from a W3C traceparent string: "00-<trace_id>-<span_id>-<flags>"
  defp extract_trace_id_from_traceparent(nil), do: nil
  defp extract_trace_id_from_traceparent(tp) when is_binary(tp) do
    case String.split(tp, "-") do
      [_ver, trace_id | _rest] when byte_size(trace_id) == 32 -> trace_id
      _ -> nil
    end
  end
  defp extract_trace_id_from_traceparent(_), do: nil

  defp maybe_put(map, fields, string_key, atom_key) do
    case Map.get(fields, string_key, Map.get(fields, atom_key)) do
      nil -> map
      "" -> map
      value -> Map.put(map, atom_key, value)
    end
  end

  defp get_any(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  # Normalize string-keyed metadata maps to atom keys so LiveView templates
  # can access fields consistently via bracket notation (e.g., notif[:metadata][:tool_name]).
  # This fixes the "unknown" display bug where JSON-decoded metadata has string keys
  # but templates expect atom keys.
  defp atomize_metadata(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    # If any key isn't an existing atom, fall back to safe conversion
    ArgumentError ->
      Map.new(meta, fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} -> {k, v}
      end)
  end
  defp atomize_metadata(other), do: other

  # Build refs map: merges explicit `refs` key with top-level shorthand fields.
  # Callers may pass either `refs: %{agent_id: "..."}` or top-level `agent_id: "..."`.
  defp build_refs(notification) do
    raw = get_any(notification, [:refs, "refs"]) || %{}

    raw
    |> atomize_safe()
    |> Map.merge(
         %{
           agent_id:     get_any(notification, [:agent_id, "agent_id"]),
           formation_id: get_any(notification, [:formation_id, "formation_id"]),
           session_id:   get_any(notification, [:session_id, "session_id"]),
           project:      get_any(notification, [:project_name, "project_name", :project, "project"]),
           wave:         get_any(notification, [:wave_number, "wave_number", :wave, "wave"]),
           task_id:      get_any(notification, [:task_id, "task_id"]),
           event_id:     get_any(notification, [:event_id, "event_id"]),
           issue_id:     get_any(notification, [:issue_id, "issue_id"]),
           checkpoint:   get_any(notification, [:checkpoint, "checkpoint"])
         },
         fn _k, existing, fallback -> existing || fallback end
       )
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp build_trace(notification) do
    case get_any(notification, [:trace, "trace"]) do
      nil -> nil
      t when is_map(t) -> t |> atomize_safe() |> Map.reject(fn {_, v} -> is_nil(v) end)
      _ -> nil
    end
  end

  defp normalize_actions(actions) when is_list(actions) do
    Enum.map(actions, fn a ->
      %{
        label:  Map.get(a, :label,  Map.get(a, "label",  "")),
        href:   Map.get(a, :href,   Map.get(a, "href",   "#")),
        method: Map.get(a, :method, Map.get(a, "method", "navigate"))
      }
    end)
  end
  defp normalize_actions(_), do: []

  # Build a JWT-encoded delegation chain for a new agent.
  # When parent_agent_id is present, looks up the parent's existing chain and
  # appends a new hop.  If the parent has no chain or cannot be found, a fresh
  # 1-hop chain is created with the parent's DID as authorizer.
  # Returns nil when no parent is specified.
  @spec build_delegation_chain(String.t(), String.t() | nil, String.t()) :: String.t() | nil
  defp build_delegation_chain(_agent_id, nil, _session_id), do: nil

  defp build_delegation_chain(agent_id, parent_agent_id, session_id) do
    parent_did = "did:key:ccem-" <> parent_agent_id
    agent_did = "did:key:ccem-" <> agent_id

    # Resolve the chain to extend: prefer the persistent_term-stored struct from
    # a previously registered parent, fall back to fresh single-hop chain.
    {:ok, chain} =
      case :persistent_term.get({__MODULE__, :delegation_chain, parent_agent_id}, nil) do
        nil ->
          # No parent chain stored yet — start a fresh 1-hop chain
          Apm.Provenance.DelegationChain.new_chain(parent_did, agent_did, session_id)

        existing_chain ->
          # Extend the parent's chain; fall back to fresh chain if tampered
          case Apm.Provenance.DelegationChain.append_hop(existing_chain, agent_did, session_id) do
            {:ok, _} = ok ->
              ok

            {:error, _} ->
              # Parent chain is tampered — start fresh from parent DID
              Apm.Provenance.DelegationChain.new_chain(parent_did, agent_did, session_id)
          end
      end

    jwt = Apm.Provenance.DelegationChain.to_jwt(chain)
    # Store the struct under this agent's key so its children can extend the chain.
    :persistent_term.put({__MODULE__, :delegation_chain, agent_id}, chain)
    jwt
  rescue
    _ -> nil
  end

  # Append `{key, value}` to a keyword list only when value is non-nil.
  @spec maybe_add_opt(keyword(), atom(), term()) :: keyword()
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp atomize_safe(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          _ -> {k, v}
        end
      {k, v} -> {k, v}
    end)
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

  # ── Verifiable Credential issuance on registration (CP-300) ─────────────────

  # Fire-and-forget VC issuance. Runs in its own process so KeyStore latency
  # never delays the :register_agent reply. The issued JWT-VC is broadcast on
  # `apm:agents` for LiveView consumers that track VC issuance.
  defp maybe_issue_vc(agent_id, identity_map, metadata) do
    if Code.ensure_loaded?(Apm.Governance.VerifiableCredential) and
         Process.whereis(Apm.Identity.KeyStore) != nil do
      try do
        did = Map.get(identity_map, :did, Map.get(identity_map, "did"))

        agent_identity = %{
          did: did || "did:key:unknown",
          agent_id: agent_id
        }

        credential_subject = %{
          "agent_id" => agent_id,
          "formation_id" => Map.get(metadata, :formation_id, Map.get(metadata, "formation_id")),
          "invoked_by" => Map.get(metadata, :invoked_by, Map.get(metadata, "invoked_by")),
          "capabilities" =>
            Map.get(metadata, :capabilities, Map.get(metadata, "capabilities", [])),
          "risk_level" =>
            Map.get(metadata, :risk_level, Map.get(metadata, "risk_level", "low")),
          "session_id" =>
            Map.get(metadata, :session_id, Map.get(metadata, "session_id"))
        }

        jwt_vc =
          Apm.Governance.VerifiableCredential.issue_agent_credential(
            agent_identity,
            credential_subject
          )

        Phoenix.PubSub.broadcast(
          Apm.PubSub,
          "apm:agents",
          {:agent_vc_issued, %{agent_id: agent_id, jwt_vc: jwt_vc}}
        )
      rescue
        err ->
          require Logger
          Logger.warning("[AgentRegistry] VC issuance failed for #{agent_id}: #{inspect(err)}")
      end
    end
  end
end
