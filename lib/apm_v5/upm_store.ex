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

  @doc "Update referential fields on a story (todo_ref, task_id, commit_sha, worktree_ref, branch_ref)."
  @spec update_story(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_story(session_id, story_id, attrs) do
    GenServer.call(__MODULE__, {:update_story, session_id, story_id, attrs})
  end

  @doc "Return the 5 referential fields for a story."
  @spec get_story_refs(String.t(), String.t()) :: map() | {:error, term()}
  def get_story_refs(session_id, story_id) do
    GenServer.call(__MODULE__, {:get_story_refs, session_id, story_id})
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

  @doc """
  List all formations from all sources: UpmStore registrations, live agents in
  AgentRegistry that carry a formation_id, and notification-derived formations
  (for agents that sent notifications but never called /api/register).

  Returns a flat list of formation maps with a `:source` key indicating origin
  (`:upm`, `:agents`, or `:notifications`).
  """
  @spec list_all_formations() :: [map()]
  def list_all_formations do
    upm = list_formations()
    upm_ids = MapSet.new(upm, & &1.id)

    # Live agents grouped by formation_id — surface formations not in UpmStore
    agent_only =
      ApmV5.AgentRegistry.list_agents()
      |> Enum.filter(&(Map.get(&1, :formation_id) not in [nil, ""]))
      |> Enum.group_by(&Map.get(&1, :formation_id))
      |> Enum.reject(fn {fid, _} -> MapSet.member?(upm_ids, fid) end)
      |> Enum.map(fn {formation_id, agents} ->
        %{
          id: formation_id,
          name: formation_id,
          agent_count: length(agents),
          status: "active",
          registered_at: agents |> Enum.map(&Map.get(&1, :registered_at)) |> Enum.min(fn -> nil end),
          source: :agents
        }
      end)

    agent_ids = MapSet.new(agent_only, & &1.id)
    all_known = MapSet.union(upm_ids, agent_ids)

    # Notification-derived formations — for agents that only posted notifications
    notif_only =
      ApmV5.AgentRegistry.get_notifications()
      |> Enum.filter(&(Map.get(&1, :formation_id) not in [nil, ""]))
      |> Enum.group_by(&Map.get(&1, :formation_id))
      |> Enum.reject(fn {fid, _} -> MapSet.member?(all_known, fid) end)
      |> Enum.map(fn {formation_id, notifs} ->
        last_notif = List.first(notifs)

        status =
          cond do
            Enum.any?(notifs, &String.contains?(Map.get(&1, :title, ""), "Complete")) -> "complete"
            Enum.any?(notifs, &(&1.type == "error")) -> "error"
            true -> "active"
          end

        %{
          id: formation_id,
          name: formation_id,
          agent_count: 0,
          status: status,
          registered_at: Map.get(last_notif || %{}, :timestamp),
          source: :notifications
        }
      end)

    (upm ++ agent_only ++ notif_only)
    |> Enum.sort_by(& &1.name)
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

  @doc "Built-in testmaxxing formation template with 20 agents, 5 squadrons, 17 channels."
  @spec testmaxxing_template(String.t() | nil) :: map()
  def testmaxxing_template(date \\ nil) do
    date = date || Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")
    fmt_id = "fmt-#{date}-live-integration-testing"

    %{
      "id" => fmt_id,
      "name" => "Testmaxxing Formation",
      "template" => "testmaxxing",
      "sizing" => "MAX",
      "status" => "staged",
      "total_waves" => 2,
      "squadrons" => [
        %{
          "name" => "alpha", "wave" => 1, "role" => "Public Pages",
          "agents" => [
            %{"id" => "#{fmt_id}-alpha-w1", "name" => "nextjs-developer", "role" => "Route verification", "publishes" => ["alpha.w1.results"]},
            %{"id" => "#{fmt_id}-alpha-w2", "name" => "accessibility-tester", "role" => "A11y audit", "publishes" => ["alpha.w2.results"]},
            %{"id" => "#{fmt_id}-alpha-w3", "name" => "performance-optimizer", "role" => "Core Web Vitals", "publishes" => ["alpha.w3.results"]}
          ],
          "lead" => %{"id" => "#{fmt_id}-alpha-lead", "subscribes" => ["alpha.w1.results", "alpha.w2.results", "alpha.w3.results"], "publishes" => ["alpha.results"]}
        },
        %{
          "name" => "bravo", "wave" => 1, "role" => "Auth & RBAC",
          "agents" => [
            %{"id" => "#{fmt_id}-bravo-w4", "name" => "security-auditor", "publishes" => ["bravo.w4.results"]},
            %{"id" => "#{fmt_id}-bravo-w5", "name" => "penetration-tester", "publishes" => ["bravo.w5.results"]},
            %{"id" => "#{fmt_id}-bravo-w6", "name" => "qa-expert", "publishes" => ["bravo.w6.results"]}
          ],
          "lead" => %{"id" => "#{fmt_id}-bravo-lead", "subscribes" => ["bravo.w4.results", "bravo.w5.results", "bravo.w6.results"], "publishes" => ["bravo.results"], "exports" => ["auth_session_cookie"]}
        },
        %{
          "name" => "echo", "wave" => 1, "role" => "Infrastructure",
          "agents" => [
            %{"id" => "#{fmt_id}-echo-w13", "name" => "sre-engineer", "publishes" => ["echo.w13.results"]},
            %{"id" => "#{fmt_id}-echo-w14", "name" => "error-detective", "publishes" => ["echo.w14.results"]}
          ],
          "lead" => %{"id" => "#{fmt_id}-echo-lead", "subscribes" => ["echo.w13.results", "echo.w14.results"], "publishes" => ["echo.results"]}
        },
        %{
          "name" => "charlie", "wave" => 2, "role" => "Core Features", "depends_on" => ["bravo"],
          "agents" => [
            %{"id" => "#{fmt_id}-charlie-w7", "name" => "frontend-developer", "publishes" => ["charlie.w7.results"]},
            %{"id" => "#{fmt_id}-charlie-w8", "name" => "fullstack-developer", "publishes" => ["charlie.w8.results"]},
            %{"id" => "#{fmt_id}-charlie-w9", "name" => "ui-designer", "publishes" => ["charlie.w9.results"]}
          ],
          "lead" => %{"id" => "#{fmt_id}-charlie-lead", "subscribes" => ["charlie.w7.results", "charlie.w8.results", "charlie.w9.results"], "publishes" => ["charlie.results"], "imports" => ["auth_session_cookie"]}
        },
        %{
          "name" => "delta", "wave" => 2, "role" => "Admin & Org Portals", "depends_on" => ["bravo"],
          "agents" => [
            %{"id" => "#{fmt_id}-delta-w10", "name" => "code-reviewer", "publishes" => ["delta.w10.results"]},
            %{"id" => "#{fmt_id}-delta-w11", "name" => "qa-expert", "publishes" => ["delta.w11.results"]},
            %{"id" => "#{fmt_id}-delta-w12", "name" => "database-optimizer", "publishes" => ["delta.w12.results"]}
          ],
          "lead" => %{"id" => "#{fmt_id}-delta-lead", "subscribes" => ["delta.w10.results", "delta.w11.results", "delta.w12.results"], "publishes" => ["delta.results"], "imports" => ["auth_session_cookie"]}
        }
      ],
      "orchestrator" => %{
        "id" => "#{fmt_id}-orch",
        "subscribes" => ["alpha.results", "bravo.results", "charlie.results", "delta.results", "echo.results"],
        "publishes" => ["formation.complete"]
      },
      "exports" => %{"bravo" => %{"keys" => ["auth_session_cookie"], "targets" => ["charlie", "delta"]}},
      "channels" => [
        "alpha.w1.results", "alpha.w2.results", "alpha.w3.results", "alpha.results",
        "bravo.w4.results", "bravo.w5.results", "bravo.w6.results", "bravo.results",
        "echo.w13.results", "echo.w14.results", "echo.results",
        "charlie.w7.results", "charlie.w8.results", "charlie.w9.results", "charlie.results",
        "delta.w10.results", "delta.w11.results", "delta.w12.results", "delta.results",
        "formation.complete"
      ]
    }
  end

  @doc "Create a formation from a named built-in template."
  @spec create_from_template(String.t(), map()) :: {:ok, String.t()} | {:error, :unknown_template}
  def create_from_template(template_name, opts \\ %{})

  def create_from_template("testmaxxing", opts) do
    template = testmaxxing_template(opts[:date])
    register_formation(template)
  end

  def create_from_template(_unknown, _opts), do: {:error, :unknown_template}

  @doc """
  Parse a design handoff README.md into waves, components, tokens, and wireframe coverage.

  Returns `{:ok, parsed}` where `parsed` contains:
  - `waves` — list of `%{step: integer, title: string, file: string}` maps from Implementation Order
  - `components` — list of component name strings from Component Inventory
  - `tokens` — list of CSS custom property strings from Design Tokens section
  - `wireframes` — list of wireframe description strings from Wireframe Coverage

  Returns `{:error, :invalid_readme}` when `readme` is not a binary.
  Returns `{:error, :no_implementation_order}` when the README lacks an Implementation Order section.
  """
  @spec parse_design_handoff_readme(term()) ::
          {:ok, map()} | {:error, :invalid_readme | :no_implementation_order}
  def parse_design_handoff_readme(readme) when not is_binary(readme),
    do: {:error, :invalid_readme}

  def parse_design_handoff_readme(readme) do
    with {:ok, waves} <- extract_implementation_order(readme) do
      {:ok, %{
        waves: waves,
        components: extract_list_section(readme, "Component Inventory"),
        tokens: extract_list_section(readme, "Design Tokens"),
        wireframes: extract_list_section(readme, "Wireframe Coverage")
      }}
    end
  end

  @doc """
  Create a UPM session from a design handoff ZIP README.

  Accepts params map with:
  - `"readme_content"` (required) — raw README.md string from the design handoff
  - `"project"` — project name
  - `"prd_branch"` — git branch
  - `"plane_project_id"` — Plane project UUID

  The session is created with `input_type: :design_handoff` and stories derived from
  the Implementation Order in the README (one story per ordered step).

  Returns `{:ok, session_id}` or `{:error, reason}`.
  """
  @spec create_session_from_design_handoff(map()) ::
          {:ok, String.t()} | {:error, :missing_readme | :no_implementation_order}
  def create_session_from_design_handoff(params) do
    readme = params["readme_content"]

    cond do
      is_nil(readme) or not is_binary(readme) ->
        {:error, :missing_readme}

      true ->
        case parse_design_handoff_readme(readme) do
          {:error, reason} ->
            {:error, reason}

          {:ok, parsed} ->
            stories =
              Enum.map(parsed.waves, fn wave ->
                id = "DH-#{String.pad_leading(to_string(wave.step), 3, "0")}"
                %{"id" => id, "title" => wave.title}
              end)

            session_params = %{
              "stories" => stories,
              "waves" => length(parsed.waves),
              "prd_branch" => params["prd_branch"],
              "plane_project_id" => params["plane_project_id"],
              "input_type" => "design_handoff",
              "handoff_metadata" => %{
                "components" => parsed.components,
                "tokens" => parsed.tokens,
                "wireframes" => parsed.wireframes
              }
            }

            GenServer.call(__MODULE__, {:register_session_design_handoff, session_params, parsed})
        end
    end
  end

  # --- Private Helpers for Design Handoff Parsing ---

  @spec extract_implementation_order(String.t()) ::
          {:ok, [map()]} | {:error, :no_implementation_order}
  defp extract_implementation_order(readme) do
    # Match the "## Implementation Order" section (up to the next ##)
    case Regex.run(
           ~r/##\s+Implementation Order\s*\n((?:(?!##).)+)/si,
           readme
         ) do
      [_, section] ->
        waves =
          Regex.scan(~r/^\s*(\d+)\.\s+(.+?)(?:\s+[-—]\s+(.+?))?$/m, section)
          |> Enum.map(fn
            [_, step_str, file, desc] ->
              step = String.to_integer(String.trim(step_str))
              title = "#{String.trim(file)} — #{String.trim(desc)}"
              %{step: step, title: title, file: String.trim(file)}

            [_, step_str, file] ->
              step = String.to_integer(String.trim(step_str))
              %{step: step, title: String.trim(file), file: String.trim(file)}
          end)
          |> Enum.filter(&(map_size(&1) > 0))

        if Enum.empty?(waves) do
          {:error, :no_implementation_order}
        else
          {:ok, waves}
        end

      nil ->
        {:error, :no_implementation_order}
    end
  end

  @spec extract_list_section(String.t(), String.t()) :: [String.t()]
  defp extract_list_section(readme, section_name) do
    case Regex.run(
           ~r/##\s+#{Regex.escape(section_name)}\s*\n((?:(?!##).)+)/si,
           readme
         ) do
      [_, section] ->
        Regex.scan(~r/^\s*[-*]\s+(.+?)$/m, section)
        |> Enum.map(fn [_, item] -> String.trim(item) end)

      nil ->
        []
    end
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
  def handle_call({:register_session_design_handoff, params, parsed}, _from, state) do
    id = "upm-#{System.unique_integer([:positive, :monotonic])}"
    now = DateTime.utc_now()

    stories =
      (params["stories"] || [])
      |> Enum.map(&normalize_story/1)

    handoff_meta_raw = params["handoff_metadata"] || %{}

    handoff_metadata = %{
      components: handoff_meta_raw["components"] || parsed.components,
      tokens: handoff_meta_raw["tokens"] || parsed.tokens,
      wireframes: handoff_meta_raw["wireframes"] || parsed.wireframes
    }

    session = %{
      id: id,
      stories: stories,
      total_waves: length(parsed.waves),
      current_wave: 0,
      status: "registered",
      prd_branch: params["prd_branch"],
      plane_project_id: params["plane_project_id"],
      input_type: :design_handoff,
      handoff_metadata: handoff_metadata,
      started_at: now,
      updated_at: now
    }

    :ets.insert(@sessions_table, {id, session})

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:upm", {:upm_session_registered, session})

    {:reply, {:ok, id}, state}
  end

  def handle_call({:register_session, params}, _from, state) do
    id = "upm-#{System.unique_integer([:positive, :monotonic])}"
    now = DateTime.utc_now()

    # Normalize raw stories or wave-group objects into flat story structs.
    # Callers may pass either a flat list of story maps or a list of wave
    # group maps (each with a nested "stories" key). Both shapes are accepted.
    stories =
      (params["stories"] || [])
      |> Enum.flat_map(fn item ->
        cond do
          is_map(item) && is_list(item["stories"]) ->
            # Wave group — flatten nested stories
            Enum.map(item["stories"], &normalize_story/1)

          true ->
            [normalize_story(item)]
        end
      end)

    # total_waves may be a count integer or a list of wave group objects.
    total_waves =
      case params["waves"] do
        waves when is_list(waves) -> length(waves)
        n when is_integer(n) -> n
        _ -> 1
      end

    session = %{
      id: id,
      stories: stories,
      total_waves: total_waves,
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
            agent_type: "individual",
            todo_ref: params["todo_ref"],
            task_id: params["task_id"],
            worktree_ref: params["worktree_ref"],
            branch_ref: params["branch_ref"],
            commit_sha: params["commit_sha"]
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

  def handle_call({:update_story, session_id, story_id, attrs}, _from, state) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        stories =
          Enum.map(session.stories, fn story ->
            if story.id == story_id do
              Map.merge(story, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end))
            else
              story
            end
          end)

        updated = %{session | stories: stories, updated_at: DateTime.utc_now()}
        :ets.insert(@sessions_table, {session_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:get_story_refs, session_id, story_id}, _from, state) do
    case :ets.lookup(@sessions_table, session_id) do
      [{^session_id, session}] ->
        case Enum.find(session.stories, &(&1.id == story_id)) do
          nil ->
            {:reply, {:error, :story_not_found}, state}

          story ->
            refs = Map.take(story, [:todo_ref, :task_id, :worktree_ref, :branch_ref, :commit_sha])
            {:reply, refs, state}
        end

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  # --- Private Helpers ---

  @spec normalize_story(term()) :: map()
  defp normalize_story(story) do
    cond do
      is_binary(story) ->
        %{id: story, title: nil, status: "pending", agent_id: nil, plane_issue_id: nil}

      is_map(story) ->
        %{
          id: story["id"] || story["story_id"],
          title: story["title"],
          status: "pending",
          agent_id: nil,
          plane_issue_id: story["plane_issue_id"],
          todo_ref: story["todo_ref"],
          task_id: story["task_id"],
          worktree_ref: story["worktree_ref"],
          branch_ref: story["branch_ref"],
          commit_sha: story["commit_sha"]
        }

      true ->
        %{id: inspect(story), title: nil, status: "pending", agent_id: nil, plane_issue_id: nil}
    end
  end
end
