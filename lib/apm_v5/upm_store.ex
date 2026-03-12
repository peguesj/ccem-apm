defmodule ApmV5.UpmStore do
  @moduledoc """
  GenServer managing UPM (Unified Project Management) execution state.

  Tracks UPM sessions, story-agent mappings, wave progress, and lifecycle events
  so the APM dashboard can visualize UPM execution in real time.
  """

  use GenServer

  @sessions_table :upm_sessions
  @events_table :upm_events
  @formations_table :upm_formations

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new UPM execution session. Returns the generated session ID."
  @spec register_session(map()) :: {:ok, String.t()}
  def register_session(params) do
    GenServer.call(__MODULE__, {:register_session, params})
  end

  @doc "Register an agent with a work-item binding in a UPM session."
  @spec register_agent(map()) :: :ok
  def register_agent(params) do
    GenServer.call(__MODULE__, {:register_agent, params})
  end

  @doc "Record a UPM lifecycle event."
  @spec record_event(map()) :: :ok
  def record_event(params) do
    GenServer.call(__MODULE__, {:record_event, params})
  end

  @doc "Get the current UPM execution status (most recent active session)."
  @spec get_status() :: map()
  def get_status do
    sessions =
      :ets.tab2list(@sessions_table)
      |> Enum.map(fn {_id, s} -> s end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    case sessions do
      [active | _] ->
        events = get_events(active.id)

        %{
          active: true,
          session: active,
          events: events
        }

      [] ->
        %{active: false, session: nil, events: []}
    end
  end

  @doc "Get a UPM session by ID."
  @spec get_session(String.t()) :: map() | nil
  def get_session(session_id) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] -> session
      [] -> nil
    end
  end

  @doc "List all UPM sessions."
  @spec list_sessions() :: [map()]
  def list_sessions do
    :ets.tab2list(@sessions_table)
    |> Enum.map(fn {_id, s} -> s end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  # --- Formation API ---

  @doc "Register a formation manifest."
  @spec register_formation(map()) :: {:ok, String.t()}
  def register_formation(params) do
    id = params["id"] || "formation-#{System.unique_integer([:positive, :monotonic])}"
    now = DateTime.utc_now()

    formation = %{
      id: id,
      name: params["name"] || id,
      squadrons: params["squadrons"] || [],
      status: "registered",
      upm_session_id: params["upm_session_id"],
      events: [],
      registered_at: now,
      updated_at: now
    }

    :ets.insert(@formations_table, {id, formation})
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:formation_registered, formation})
    {:ok, id}
  end

  @doc "Get a formation by ID."
  @spec get_formation(String.t()) :: map() | nil
  def get_formation(formation_id) do
    case :ets.lookup(@formations_table, formation_id) do
      [{^formation_id, f}] -> f
      [] -> nil
    end
  end

  @doc "Get the most recently registered active formation."
  @spec get_active_formation() :: map() | nil
  def get_active_formation do
    :ets.tab2list(@formations_table)
    |> Enum.map(fn {_id, f} -> f end)
    |> Enum.filter(&(&1.status in ["registered", "running"]))
    |> Enum.sort_by(& &1.registered_at, {:desc, DateTime})
    |> List.first()
  end

  @doc "List all formations."
  @spec list_formations() :: [map()]
  def list_formations do
    :ets.tab2list(@formations_table)
    |> Enum.map(fn {_id, f} -> f end)
    |> Enum.sort_by(& &1.registered_at, {:desc, DateTime})
  end

  @doc "Update a formation's fields."
  @spec update_formation(String.t(), map()) :: :ok | {:error, :not_found}
  def update_formation(formation_id, fields) do
    case :ets.lookup(@formations_table, formation_id) do
      [{^formation_id, f}] ->
        updated = Map.merge(f, fields) |> Map.put(:updated_at, DateTime.utc_now())
        :ets.insert(@formations_table, {formation_id, updated})
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:formation_updated, updated})
        :ok
      [] -> {:error, :not_found}
    end
  end

  @doc "Append an event to a formation's event log."
  @spec add_formation_event(String.t(), map()) :: :ok | {:error, :not_found}
  def add_formation_event(formation_id, event) do
    case :ets.lookup(@formations_table, formation_id) do
      [{^formation_id, f}] ->
        evt = Map.put(event, :timestamp, DateTime.utc_now())
        updated = %{f | events: f.events ++ [evt], updated_at: DateTime.utc_now()}
        :ets.insert(@formations_table, {formation_id, updated})
        :ok
      [] -> {:error, :not_found}
    end
  end

  @doc "Get events for a UPM session."
  @spec get_events(String.t()) :: [map()]
  def get_events(session_id) do
    :ets.tab2list(@events_table)
    |> Enum.map(fn {_id, e} -> e end)
    |> Enum.filter(&(&1.upm_session_id == session_id))
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@sessions_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@events_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@formations_table, [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{event_counter: 0}}
  end

  @impl true
  def handle_call({:register_session, params}, _from, state) do
    id = "upm-#{System.unique_integer([:positive, :monotonic])}"
    now = DateTime.utc_now()

    stories =
      (params["stories"] || [])
      |> Enum.map(fn story ->
        cond do
          is_binary(story) -> %{id: story, status: "pending", agent_id: nil}
          is_map(story) -> %{
            id: story["id"] || story["story_id"],
            title: story["title"],
            status: "pending",
            agent_id: nil,
            plane_issue_id: story["plane_issue_id"]
          }
          true -> %{id: inspect(story), status: "pending", agent_id: nil}
        end
      end)

    session = %{
      id: id,
      stories: stories,
      total_waves: params["waves"] || 1,
      current_wave: 0,
      status: "registered",
      prd_branch: params["prd_branch"],
      plane_project_id: params["plane_project_id"],
      started_at: now,
      updated_at: now
    }

    :ets.insert(@sessions_table, {id, session})

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:upm_session_registered, session})

    {:reply, {:ok, id}, state}
  end

  def handle_call({:register_agent, params}, _from, state) do
    session_id = params["upm_session_id"]
    story_id = params["story_id"]
    agent_id = params["agent_id"]

    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        # Update story-agent mapping
        stories =
          Enum.map(session.stories, fn story ->
            if story.id == story_id do
              %{story | agent_id: agent_id, status: "in_progress"}
            else
              story
            end
          end)

        updated = %{session | stories: stories, updated_at: DateTime.utc_now()}
        :ets.insert(@sessions_table, {session_id, updated})

        # Also register with AgentRegistry with work-item fields
        wave = params["wave"]
        title = params["title"]
        plane_issue_id = params["plane_issue_id"]

        if agent_id do
          metadata = %{
            name: agent_id,
            status: "active",
            story_id: story_id,
            plane_issue_id: plane_issue_id,
            wave: wave,
            work_item_title: title,
            upm_session_id: session_id,
            agent_type: "individual"
          }

          ApmV5.AgentRegistry.register_agent(agent_id, metadata)
        end

        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:upm_agent_registered, params})

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:record_event, params}, _from, state) do
    counter = state.event_counter + 1
    session_id = params["upm_session_id"]
    event_type = params["event_type"]
    data = params["data"] || %{}
    now = DateTime.utc_now()

    event = %{
      id: counter,
      upm_session_id: session_id,
      event_type: event_type,
      data: data,
      timestamp: now
    }

    :ets.insert(@events_table, {counter, event})

    # Update session state based on event type
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        updated =
          case event_type do
            "wave_start" ->
              wave = data["wave"] || session.current_wave + 1
              %{session | current_wave: wave, status: "running", updated_at: now}

            "wave_complete" ->
              %{session | status: "running", updated_at: now}

            "story_pass" ->
              story_id = data["story_id"]
              stories = Enum.map(session.stories, fn s ->
                if s.id == story_id, do: %{s | status: "passed"}, else: s
              end)
              %{session | stories: stories, updated_at: now}

            "story_fail" ->
              story_id = data["story_id"]
              stories = Enum.map(session.stories, fn s ->
                if s.id == story_id, do: %{s | status: "failed"}, else: s
              end)
              %{session | stories: stories, updated_at: now}

            "verify_start" ->
              %{session | status: "verifying", updated_at: now}

            "verify_complete" ->
              %{session | status: "verified", updated_at: now}

            "ship" ->
              %{session | status: "shipped", updated_at: now}

            _ ->
              %{session | updated_at: now}
          end

        :ets.insert(@sessions_table, {session_id, updated})

      [] ->
        :ok
    end

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:upm_event, event})

    {:reply, :ok, %{state | event_counter: counter}}
  end
end
