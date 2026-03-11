defmodule ApmV4Web.ApiController do
  @moduledoc """
  JSON API endpoints for CCEM APM v4.

  Provides full v3-compatible REST API plus v4 extensions.
  All 19 v3 endpoints + v4-only /api/projects endpoint.
  """

  use ApmV4Web, :controller

  alias ApmV4.AgentRegistry
  alias ApmV4.ConfigLoader
  alias ApmV4.ProjectStore
  alias ApmV4.Ralph
  alias ApmV4.SkillTracker
  alias ApmV4.AgentDiscovery
  alias ApmV4.EnvironmentScanner
  alias ApmV4.CommandRunner
  alias ApmV4.AgUi.HookBridge

  @server_version "5.0.0"

  # ============================
  # GET Endpoints
  # ============================

  @doc "GET /health -- v3-compatible health check"
  def health(conn, _params) do
    start_time = Application.get_env(:apm_v4, :server_start_time, System.monotonic_time(:second))
    uptime = System.monotonic_time(:second) - start_time
    config = safe_get_config()
    projects = Map.get(config, "projects", [])

    project_summaries =
      Enum.map(projects, fn p ->
        name = p["name"]
        agent_count = length(AgentRegistry.list_agents(name))
        session_count = length(Map.get(p, "sessions", []))

        %{
          name: name,
          status: p["status"] || "active",
          agent_count: agent_count,
          session_count: session_count
        }
      end)

    json(conn, %{
      status: "ok",
      uptime: uptime,
      server_version: @server_version,
      total_projects: length(projects),
      active_project: Map.get(config, "active_project"),
      projects: project_summaries
    })
  end

  @doc "GET /api/status -- existing v4 status endpoint"
  def status(conn, _params) do
    start_time = Application.get_env(:apm_v4, :server_start_time, System.monotonic_time(:second))
    uptime = System.monotonic_time(:second) - start_time
    agents = AgentRegistry.list_agents()
    sessions = AgentRegistry.list_sessions()

    session_id =
      case sessions do
        [s | _] -> s.session_id
        [] -> "none"
      end

    json(conn, %{
      status: "ok",
      uptime: uptime,
      agent_count: length(agents),
      session_id: session_id,
      server_version: @server_version
    })
  end

  @doc "GET /api/data -- master data aggregation (v3-compatible)"
  def data(conn, params) do
    project_name = params["project"] || active_project_name()
    agents = AgentRegistry.list_agents(project_name)
    notifications = AgentRegistry.get_notifications()
    tasks = ProjectStore.get_tasks(project_name || "_global")
    commands = ProjectStore.get_commands(project_name || "_global")
    input_requests = ProjectStore.get_pending_inputs()

    ralph_data =
      case get_ralph_for_project(project_name) do
        {:ok, data} -> data
        {:error, _} -> %{}
      end

    # Build edges from agent deps
    agent_ids = MapSet.new(Enum.map(agents, & &1.id))

    edges =
      agents
      |> Enum.flat_map(fn agent ->
        (agent.deps || [])
        |> Enum.filter(&MapSet.member?(agent_ids, &1))
        |> Enum.map(fn dep_id -> %{source: dep_id, target: agent.id} end)
      end)

    summary = %{
      total: length(agents),
      active: Enum.count(agents, &(&1.status == "active")),
      idle: Enum.count(agents, &(&1.status == "idle")),
      error: Enum.count(agents, &(&1.status == "error")),
      completed: Enum.count(agents, &(&1.status == "completed")),
      discovered: Enum.count(agents, &(&1.status == "discovered"))
    }

    json(conn, %{
      agents: agents,
      summary: summary,
      edges: edges,
      tasks: tasks,
      notifications: Enum.take(notifications, 50),
      ralph: ralph_data,
      commands: commands,
      input_requests: input_requests
    })
  end

  @doc "GET /api/notifications -- list notifications with optional filters"
  def notifications(conn, params) do
    filters =
      []
      |> maybe_add_filter(:category, params["category"])
      |> maybe_add_filter(:project_name, params["project"])
      |> maybe_add_filter(:namespace, params["namespace"])
      |> maybe_add_filter(:type, params["type"])

    limit = parse_limit(params["limit"], 100)

    notifs =
      AgentRegistry.get_notifications(filters)
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> Enum.take(limit)

    json(conn, %{notifications: notifs, count: length(notifs), limit: limit})
  end

  @doc "GET /api/ralph -- Ralph methodology data for active project"
  def ralph(conn, params) do
    project_name = params["project"] || active_project_name()

    case get_ralph_for_project(project_name) do
      {:ok, data} -> json(conn, data)
      {:error, _} -> json(conn, %{})
    end
  end

  @doc "GET /api/ralph/flowchart -- D3.js-compatible flowchart data"
  def ralph_flowchart(conn, params) do
    project_name = params["project"] || active_project_name()

    case get_ralph_for_project(project_name) do
      {:ok, %{stories: stories}} ->
        json(conn, Ralph.flowchart(stories))

      _ ->
        json(conn, %{nodes: [], edges: []})
    end
  end

  @doc "GET /api/commands -- slash commands for active project"
  def commands(conn, params) do
    project_name = params["project"] || active_project_name() || "_global"
    cmds = ProjectStore.get_commands(project_name)
    json(conn, cmds)
  end

  @doc "GET /api/agents/discover -- trigger discovery scan"
  def discover_agents(conn, _params) do
    discovered = AgentDiscovery.discover_now()
    json(conn, %{discovered: discovered, count: length(discovered)})
  end

  @doc "GET /api/agents -- list all agents"
  def agents(conn, params) do
    project_name = params["project"]
    agent_list = AgentRegistry.list_agents(project_name)
    json(conn, %{agents: agent_list})
  end

  @doc "GET /api/input/pending -- pending input requests"
  def pending_input(conn, _params) do
    pending = ProjectStore.get_pending_inputs()
    json(conn, pending)
  end

  @doc "GET /api/skills -- list tracked skills with optional filters"
  def skills(conn, params) do
    case {params["session_id"], params["project"]} do
      {sid, _} when is_binary(sid) and sid != "" ->
        json(conn, %{skills: SkillTracker.get_session_skills(sid)})

      {_, proj} when is_binary(proj) and proj != "" ->
        json(conn, %{skills: SkillTracker.get_project_skills(proj)})

      _ ->
        json(conn, %{
          catalog: SkillTracker.get_skill_catalog(),
          co_occurrence: SkillTracker.get_co_occurrence() |> Enum.map(fn {{a, b}, count} ->
            %{skill_a: a, skill_b: b, count: count}
          end)
        })
    end
  end

  @doc "POST /api/skills/track -- track a skill invocation"
  def track_skill(conn, params) do
    session_id = params["session_id"]
    skill = params["skill"]

    if is_nil(session_id) or session_id == "" or is_nil(skill) or skill == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required fields: session_id, skill"})
    else
      project = params["project"]
      args = params["args"]
      SkillTracker.track_skill(session_id, skill, project, args)
      json(conn, %{ok: true, session_id: session_id, skill: skill})
    end
  end

  @doc "GET /api/projects -- list all projects with agent counts (v4-only)"
  def projects(conn, _params) do
    config = safe_get_config()
    project_list = Map.get(config, "projects", [])

    projects =
      Enum.map(project_list, fn p ->
        name = p["name"]

        %{
          name: name,
          root: p["root"],
          status: p["status"] || "active",
          tasks_dir: p["tasks_dir"],
          prd_json: p["prd_json"],
          agent_count: length(AgentRegistry.list_agents(name)),
          session_count: length(Map.get(p, "sessions", []))
        }
      end)

    json(conn, %{
      active_project: Map.get(config, "active_project"),
      projects: projects
    })
  end

  @doc "PATCH /api/projects -- update project fields in config"
  def update_project(conn, params) do
    case ConfigLoader.update_project(params) do
      {:ok, config} ->
        Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:config", {:config_reloaded, config})
        json(conn, %{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{status: "error", reason: reason})
    end
  end

  # ============================
  # POST Endpoints
  # ============================

  @doc "POST /api/register -- register agent (existing v4 endpoint)"
  def register(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      project_name = params["project_name"] || params["project"]

      metadata = %{
        name: params["name"] || agent_id,
        tier: params["tier"] || 1,
        status: params["status"] || "idle",
        deps: params["deps"] || [],
        metadata: params["metadata"] || %{},
        namespace: params["namespace"],
        agent_type: params["agent_type"] || "individual",
        path: params["path"],
        member_count: params["member_count"],
        # Formation hierarchy fields
        parent_id: params["parent_id"],
        formation_id: params["formation_id"],
        squadron: params["squadron"],
        swarm: params["swarm"],
        cluster: params["cluster"],
        role: params["role"],
        # UPM work-item fields
        story_id: params["story_id"],
        plane_issue_id: params["plane_issue_id"],
        wave: params["wave"],
        wave_number: params["wave_number"],
        wave_total: params["wave_total"],
        work_item_title: params["work_item_title"],
        upm_session_id: params["upm_session_id"]
      }

      :ok = AgentRegistry.register_agent(agent_id, metadata, project_name)

      # Emit AG-UI RUN_STARTED event via HookBridge
      Task.start(fn -> HookBridge.translate_register(params) end)

      conn
      |> put_status(201)
      |> json(%{ok: true, agent_id: agent_id})
    end
  end

  @doc "POST /api/heartbeat -- update agent status (existing v4 endpoint)"
  def heartbeat(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      status = params["status"] || "active"

      case AgentRegistry.update_status(agent_id, status) do
        :ok ->
          # Emit AG-UI STEP event via HookBridge
          Task.start(fn -> HookBridge.translate_heartbeat(params) end)
          json(conn, %{ok: true, agent_id: agent_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{error: "Agent not found", agent_id: agent_id})
      end
    end
  end

  @doc "POST /api/notify -- add notification with optional scoped fields"
  def notify(conn, params) do
    # deploy_agents category carries wave-specific metadata
    wave_fields =
      if params["category"] == "deploy_agents" do
        %{
          wave_number: params["wave_number"],
          wave_total: params["wave_total"],
          wave_status: params["wave_status"]
        }
      else
        %{}
      end

    notification =
      %{
        title: params["title"] || "Notification",
        message: params["message"] || params["body"] || "",
        type: params["type"] || params["level"] || "info",
        category: params["category"],
        project_name: params["project_name"] || params["project"],
        namespace: params["namespace"],
        formation_id: params["formation_id"],
        squadron_id: params["squadron_id"],
        agent_id: params["agent_id"],
        story_id: params["story_id"]
      }
      |> Map.merge(wave_fields)

    id = AgentRegistry.add_notification(notification)

    # Broadcast to PubSub for real-time toast delivery
    Phoenix.PubSub.broadcast(
      ApmV4.PubSub,
      "apm:notifications",
      {:notification_added, Map.put(notification, :id, id)}
    )

    # Emit AG-UI CUSTOM event via HookBridge
    Task.start(fn -> HookBridge.translate_notification(params) end)

    json(conn, %{ok: true, id: id})
  end

  @doc "POST /api/notifications/add -- v3-compatible notification add"
  def add_notification(conn, params) do
    notification = %{
      title: params["title"] || "Notification",
      message: params["body"] || params["message"] || "",
      level: params["category"] || params["level"] || "info"
    }

    id = AgentRegistry.add_notification(notification)
    json(conn, %{ok: true, id: id})
  end

  @doc "POST /api/notifications/read-all -- mark all as read"
  def read_all_notifications(conn, _params) do
    :ok = AgentRegistry.mark_all_read()
    json(conn, %{ok: true})
  end

  @doc "POST /api/agents/update -- full agent update (v3-compatible)"
  def update_agent(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      case AgentRegistry.update_agent(agent_id, params) do
        :ok ->
          json(conn, %{ok: true, agent_id: agent_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{error: "Agent not found", agent_id: agent_id})
      end
    end
  end

  @doc "POST /api/input/request -- create input request"
  def request_input(conn, params) do
    id = ProjectStore.add_input_request(params)
    json(conn, %{ok: true, id: id})
  end

  @doc "POST /api/input/respond -- respond to input request"
  def respond_input(conn, params) do
    id = params["id"]
    choice = params["choice"] || params["response"]

    if is_nil(id) do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: id"})
    else
      # Coerce string IDs to integer (ETS keys are integers)
      id = if is_binary(id), do: String.to_integer(id), else: id

      case ProjectStore.respond_to_input(id, choice) do
        :ok ->
          json(conn, %{ok: true, id: id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{error: "Input request not found", id: id})
      end
    end
  end

  @doc "POST /api/tasks/sync -- replace active project's task list"
  def sync_tasks(conn, params) do
    project_name = params["project"] || active_project_name() || "_global"
    tasks = params["tasks"] || []
    :ok = ProjectStore.sync_tasks(project_name, tasks)
    json(conn, %{ok: true, count: length(tasks)})
  end

  @doc "POST /api/config/reload -- trigger config reload"
  def reload_config(conn, _params) do
    :ok = ConfigLoader.reload()
    json(conn, %{ok: true})
  end

  @doc "POST /api/plane/update -- update Plane PM context"
  def update_plane(conn, params) do
    project_name = params["project"] || active_project_name() || "_global"
    plane_data = Map.drop(params, ["project"])
    :ok = ProjectStore.update_plane(project_name, plane_data)
    json(conn, %{ok: true})
  end

  @doc "POST /api/commands -- register slash commands"
  def register_commands(conn, params) do
    project_name = params["project"] || active_project_name() || "_global"

    commands =
      cond do
        is_list(params["commands"]) -> params["commands"]
        is_map(params["name"]) -> [params]
        is_binary(params["name"]) -> [params]
        true -> []
      end

    :ok = ProjectStore.register_commands(project_name, commands)
    json(conn, %{ok: true, count: length(commands)})
  end

  # ============================
  # CCEM Environment Endpoints
  # ============================

  @doc "GET /api/environments -- list all CC environments"
  def environments(conn, _params) do
    envs = EnvironmentScanner.list_environments()

    json(conn, %{
      environments:
        Enum.map(envs, fn e ->
          %{
            name: e.name,
            path: e.path,
            stack: e.stack,
            has_claude_md: e.has_claude_md,
            has_git: e.has_git,
            session_count: e.session_count,
            last_session_date: e.last_session_date,
            last_modified: e.last_modified
          }
        end),
      count: length(envs)
    })
  end

  @doc "GET /api/environments/:name -- full environment detail"
  def environment_detail(conn, %{"name" => name}) do
    case EnvironmentScanner.get_environment(name) do
      {:ok, env} ->
        json(conn, env)

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Environment not found", name: name})
    end
  end

  @doc "POST /api/environments/:name/exec -- execute command in environment"
  def exec_command(conn, %{"name" => name} = params) do
    command = params["command"]
    timeout = params["timeout"]

    if is_nil(command) or command == "" do
      conn |> put_status(400) |> json(%{error: "Missing required field: command"})
    else
      opts = if timeout, do: [timeout: min(timeout * 1000, 120_000)], else: []

      case CommandRunner.exec(name, command, opts) do
        {:ok, result} ->
          json(conn, result)

        {:error, :environment_not_found} ->
          conn |> put_status(404) |> json(%{error: "Environment not found", name: name})

        {:error, :dangerous_command} ->
          conn |> put_status(403) |> json(%{error: "Command rejected as dangerous"})
      end
    end
  end

  @doc "POST /api/environments/:name/session/start -- launch CC session"
  def start_session(conn, %{"name" => name} = params) do
    with_ccem = params["with_ccem"] != false

    case EnvironmentScanner.get_environment(name) do
      {:ok, env} ->
        safe_path = env.path

        # Validate path contains no shell metacharacters
        if String.match?(safe_path, ~r/^[a-zA-Z0-9\/_\-\.@~ ]+$/) do
          args =
            if with_ccem,
              do: ["--dangerously-skip-permissions"],
              else: ["--dangerously-skip-permissions", "--no-hooks"]

          # Launch detached using spawn_executable (no shell injection)
          spawn(fn ->
            System.cmd("nohup", ["claude" | args],
              cd: safe_path,
              stderr_to_stdout: true,
              into: File.stream!("/dev/null")
            )
          end)

          json(conn, %{ok: true, environment: name, with_ccem: with_ccem})
        else
          conn |> put_status(400) |> json(%{error: "Invalid environment path"})
        end

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Environment not found", name: name})
    end
  end

  @doc "POST /api/environments/:name/session/stop -- kill CC session"
  def stop_session(conn, %{"name" => name}) do
    case EnvironmentScanner.get_environment(name) do
      {:ok, env} ->
        # Use pgrep safely with exact argument matching (no shell interpolation)
        {output, _} = System.cmd("pgrep", ["-f", "claude.*#{env.path}"],
          stderr_to_stdout: true)

        pids =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.match?(&1, ~r/^\d+$/))

        Enum.each(pids, fn pid ->
          System.cmd("kill", [pid], stderr_to_stdout: true)
        end)

        json(conn, %{ok: true, environment: name, killed: length(pids)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Environment not found", name: name})
    end
  end

  # ============================
  # Private Helpers
  # ============================

  defp active_project_name do
    config = safe_get_config()
    Map.get(config, "active_project")
  end

  defp get_ralph_for_project(project_name) do
    project = if project_name, do: safe_get_project(project_name)
    prd_path = if project, do: project["prd_json"]
    Ralph.load(prd_path)
  end

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end

  defp safe_get_project(name) do
    try do
      ConfigLoader.get_project(name)
    catch
      :exit, _ -> nil
    end
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, _key, ""), do: filters
  defp maybe_add_filter(filters, key, value), do: [{key, value} | filters]

  defp parse_limit(nil, default), do: default
  defp parse_limit(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> min(max(n, 1), 1000)
      :error -> default
    end
  end
  defp parse_limit(val, _default) when is_integer(val), do: min(max(val, 1), 1000)
  defp parse_limit(_, default), do: default

  # ============================
  # UPM Endpoints
  # ============================

  alias ApmV4.UpmStore

  @doc "POST /api/upm/register -- register a UPM execution session"
  def upm_register(conn, params) do
    {:ok, session_id} = UpmStore.register_session(params)

    conn
    |> put_status(201)
    |> json(%{ok: true, upm_session_id: session_id})
  end

  @doc "POST /api/upm/agent -- register an agent with work-item binding"
  def upm_agent(conn, params) do
    case UpmStore.register_agent(params) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :session_not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "UPM session not found", upm_session_id: params["upm_session_id"]})
    end
  end

  @doc "POST /api/upm/event -- report a UPM lifecycle event"
  def upm_event(conn, params) do
    :ok = UpmStore.record_event(params)
    json(conn, %{ok: true})
  end

  @doc "GET /api/upm/status -- current UPM execution state"
  def upm_status(conn, _params) do
    status = UpmStore.get_status()
    json(conn, status)
  end

  # ============================
  # Export / Import Endpoints
  # ============================

  @doc "GET /api/v2/export -- export APM data as JSON or CSV"
  def export(conn, params) do
    case Map.get(params, "format") do
      "csv" ->
        section = params |> Map.get("section", "agents") |> String.to_existing_atom()

        case ApmV4.ExportManager.export_csv(section) do
          {:error, reason} ->
            conn |> put_status(400) |> json(%{error: to_string(reason)})

          csv when is_binary(csv) ->
            conn
            |> put_resp_content_type("text/csv")
            |> put_resp_header("content-disposition", "attachment; filename=\"#{section}.csv\"")
            |> send_resp(200, csv)
        end

      _ ->
        opts = build_export_opts(params)
        data = ApmV4.ExportManager.export(opts)
        json(conn, data)
    end
  end

  @doc "POST /api/v2/import -- import APM data from JSON"
  def import_data(conn, params) do
    case ApmV4.ExportManager.import(params) do
      {:ok, summary} ->
        json(conn, %{status: "ok", summary: summary})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  defp build_export_opts(params) do
    opts = []

    opts =
      case Map.get(params, "sections") do
        nil -> opts
        sections when is_list(sections) ->
          Keyword.put(opts, :sections, Enum.map(sections, &String.to_existing_atom/1))
        _ -> opts
      end

    opts =
      case Map.get(params, "since") do
        nil -> opts
        since_str ->
          case DateTime.from_iso8601(since_str) do
            {:ok, dt, _} -> Keyword.put(opts, :since, dt)
            _ -> opts
          end
      end

    case Map.get(params, "agent_ids") do
      nil -> opts
      ids when is_list(ids) -> Keyword.put(opts, :agent_ids, ids)
      _ -> opts
    end
  end

  # --- Port Management ---

  def ports(conn, _params) do
    port_map = ApmV4.PortManager.get_port_map()
    ranges = ApmV4.PortManager.get_port_ranges()
    clashes = ApmV4.PortManager.detect_clashes()

    json(conn, %{
      ok: true,
      ports: port_map,
      ranges: Enum.into(ranges, %{}, fn {k, r} -> {k, %{first: r.first, last: r.last}} end),
      clashes: clashes
    })
  end

  def scan_ports(conn, _params) do
    active = ApmV4.PortManager.scan_active_ports()
    json(conn, %{ok: true, active_ports: active})
  end

  def assign_port(conn, %{"namespace" => ns}) do
    atom_ns = String.to_existing_atom(ns)
    case ApmV4.PortManager.assign_port(atom_ns) do
      {:ok, port} -> json(conn, %{ok: true, port: port})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  rescue
    ArgumentError -> conn |> put_status(400) |> json(%{ok: false, error: "invalid namespace"})
  end

  def assign_port(conn, %{"project" => project}) do
    case ApmV4.PortManager.assign_port(project) do
      {:ok, port} -> json(conn, %{ok: true, port: port})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  end

  def port_clashes(conn, _params) do
    clashes = ApmV4.PortManager.detect_clashes()
    json(conn, %{ok: true, clashes: clashes})
  end

  def set_primary_port(conn, %{"project" => project, "port" => port} = params) do
    ownership = Map.get(params, "ownership", "shared")

    if ownership not in ["exclusive", "shared", "reserved"] do
      conn |> put_status(400) |> json(%{ok: false, error: "invalid ownership: must be exclusive, shared, or reserved"})
    else
      case ApmV4.PortManager.set_primary_port(project, port, ownership) do
        :ok ->
          json(conn, %{ok: true, project: project, primary_port: port, port_ownership: ownership})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
      end
    end
  end

  def set_primary_port(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "required: project, port"})
  end

  # --- Hook deployment ---

  def deploy_hooks(conn, %{"skill" => skill, "project_root" => project_root} = params) do
    hooks = Map.get(params, "hooks", :all)
    hooks = if hooks == "all" or is_nil(hooks), do: :all, else: hooks

    case ApmV4.SkillHookDeployer.deploy_hooks(project_root, skill, hooks) do
      {:ok, result} ->
        json(conn, %{ok: true, deployed: result.deployed, skipped: result.skipped})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{ok: false, error: reason})
    end
  end

  def deploy_hooks(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "required: skill, project_root"})
  end

  # --- Background Tasks ---

  def list_bg_tasks(conn, params) do
    filter =
      %{}
      |> then(fn f -> if params["status"], do: Map.put(f, :status, params["status"]), else: f end)
      |> then(fn f -> if params["project"], do: Map.put(f, :project, params["project"]), else: f end)

    tasks = ApmV4.BackgroundTasksStore.list_tasks(filter)
    json(conn, %{tasks: tasks})
  end

  def register_bg_task(conn, params) do
    case ApmV4.BackgroundTasksStore.register_task(params) do
      {:ok, task} -> json(conn, %{task: task})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  def get_bg_task(conn, %{"id" => id}) do
    case ApmV4.BackgroundTasksStore.get_task(id) do
      {:ok, task} -> json(conn, %{task: task})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def get_bg_task_logs(conn, %{"id" => id} = params) do
    lines = params["lines"] |> then(fn v -> if is_binary(v), do: String.to_integer(v), else: 50 end)

    case ApmV4.BackgroundTasksStore.get_task_logs(id, lines) do
      {:ok, log_lines} ->
        log_path =
          case ApmV4.BackgroundTasksStore.get_task(id) do
            {:ok, task} -> Map.get(task, :log_path)
            _ -> nil
          end

        json(conn, %{lines: log_lines, log_path: log_path, count: length(log_lines)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "cannot read log: #{reason}"})
    end
  end

  def update_bg_task(conn, %{"id" => id} = params) do
    allowed = ~w(agent_name agent_definition invoking_process log_path runtime_ms status)
    attrs = Map.take(params, allowed)

    case ApmV4.BackgroundTasksStore.update_task(id, attrs) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def stop_bg_task(conn, %{"id" => id}) do
    case ApmV4.BackgroundTasksStore.get_task(id) do
      {:ok, task} ->
        if task.os_pid do
          System.cmd("kill", ["-TERM", to_string(task.os_pid)], stderr_to_stdout: true)
        end

        ApmV4.BackgroundTasksStore.update_task(id, %{"status" => "stopping"})
        json(conn, %{status: "stopping"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete_bg_task(conn, %{"id" => id}) do
    ApmV4.BackgroundTasksStore.delete_task(id)
    json(conn, %{ok: true})
  end

  # --- Project Scanner ---

  def scanner_scan(conn, params) do
    base_path = params["base_path"]
    case ApmV4.ProjectScanner.scan(base_path) do
      {:ok, results} -> json(conn, %{results: results, count: length(results)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def scanner_results(conn, _params) do
    results = ApmV4.ProjectScanner.get_results()
    json(conn, %{results: results, count: length(results)})
  end

  def scanner_status(conn, _params) do
    status = ApmV4.ProjectScanner.get_status()
    json(conn, status)
  end

  # --- Actions Engine ---

  def list_actions(conn, _params) do
    catalog = ApmV4.ActionEngine.list_catalog()
    json(conn, %{actions: catalog})
  end

  def run_action(conn, params) do
    action_type = params["action_type"]
    project_path = params["project_path"] || ""
    action_params = params["params"] || %{}

    case ApmV4.ActionEngine.run_action(action_type, project_path, action_params) do
      {:ok, run_id} -> json(conn, %{run_id: run_id})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  def list_action_runs(conn, _params) do
    runs = ApmV4.ActionEngine.list_runs()
    json(conn, %{runs: runs})
  end

  def get_action_run(conn, %{"id" => id}) do
    case ApmV4.ActionEngine.get_run(id) do
      {:ok, run} -> json(conn, %{run: run})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  # ============================
  # Intake Endpoints
  # ============================

  @doc "POST /api/intake -- submit an intake event"
  def intake_submit(conn, params) do
    case ApmV4.Intake.Store.submit(params) do
      {:ok, event} ->
        json(conn, %{ok: true, id: event.id, received_at: DateTime.to_iso8601(event.received_at)})
      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{ok: false, error: to_string(reason)})
    end
  end

  @doc "GET /api/intake -- list intake events with optional filters"
  def intake_list(conn, params) do
    opts =
      [
        source: params["source"],
        event_type: params["event_type"],
        limit: parse_limit(params["limit"], 50)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    events = ApmV4.Intake.Store.list(opts)
    json(conn, %{ok: true, events: Enum.map(events, &intake_event_json/1), count: length(events)})
  end

  @doc "GET /api/intake/watchers -- list registered intake watchers"
  def intake_watchers(conn, _params) do
    watchers = ApmV4.Intake.Store.watchers()
    json(conn, %{
      ok: true,
      watchers: Enum.map(watchers, fn m ->
        %{name: m.name(), event_types: m.event_types(), sources: m.sources(), enabled: m.enabled?()}
      end)
    })
  end

  defp intake_event_json(event) do
    %{
      id: event.id,
      source: event.source,
      event_type: event.event_type,
      severity: event.severity,
      project: event.project,
      environment: event.environment,
      payload: event.payload,
      received_at: DateTime.to_iso8601(event.received_at)
    }
  end

  # --- Agent Telemetry (time-bucketed, last hour) ---

  def telemetry(conn, _params) do
    now = DateTime.utc_now()
    agents = AgentRegistry.list_agents()

    buckets =
      for i <- 11..0//-1 do
        bucket_start = DateTime.add(now, -(i + 1) * 5 * 60, :second)
        bucket_end = DateTime.add(now, -i * 5 * 60, :second)

        bucket_agents =
          Enum.filter(agents, fn agent ->
            registered =
              case Map.get(agent, :registered_at) || Map.get(agent, "registered_at") do
                nil -> nil
                ts when is_binary(ts) ->
                  case DateTime.from_iso8601(ts) do
                    {:ok, dt, _} -> dt
                    _ -> nil
                  end
                _ -> nil
              end

            case registered do
              nil ->
                false

              dt ->
                DateTime.compare(dt, bucket_start) != :lt &&
                  DateTime.compare(dt, bucket_end) == :lt
            end
          end)

        started = length(bucket_agents)

        completed =
          bucket_agents
          |> Enum.filter(fn a ->
            (Map.get(a, :status) || Map.get(a, "status", "")) in ["completed", "done", "success"]
          end)
          |> length()

        failed =
          bucket_agents
          |> Enum.filter(fn a ->
            (Map.get(a, :status) || Map.get(a, "status", "")) == "failed"
          end)
          |> length()

        %{
          bucket: DateTime.to_iso8601(bucket_start),
          display_time: Calendar.strftime(bucket_start, "%H:%M"),
          agents_started: started,
          agents_completed: completed,
          agents_failed: failed
        }
      end

    total_started = Enum.sum(Enum.map(buckets, & &1.agents_started))
    total_completed = Enum.sum(Enum.map(buckets, & &1.agents_completed))
    total_failed = Enum.sum(Enum.map(buckets, & &1.agents_failed))

    active_now =
      agents
      |> Enum.filter(fn a ->
        (Map.get(a, :status) || Map.get(a, "status", "")) == "active"
      end)
      |> length()

    json(conn, %{
      data_points: buckets,
      summary: %{
        total_started: total_started,
        total_completed: total_completed,
        total_failed: total_failed,
        active_now: active_now
      }
    })
  end
end
