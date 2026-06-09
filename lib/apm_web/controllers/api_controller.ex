defmodule ApmWeb.ApiController do
  @moduledoc """
  JSON API endpoints for CCEM APM.

  Provides full v3-compatible REST API plus v4 extensions.
  All 19 v3 endpoints + v4-only /api/projects endpoint.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema
  alias Apm.AgentRegistry
  alias Apm.ConfigLoader
  alias Apm.ProjectStore
  alias Apm.Ralph
  alias Apm.SkillTracker
  alias Apm.AgentDiscovery
  alias Apm.EnvironmentScanner
  alias Apm.CommandRunner
  alias Apm.AgUi.HookBridge
  alias Apm.StatusCache
  alias Apm.StatusPayloadBuilder

  # ============================
  # OpenApiSpex annotations (api-s7 Wave 2b / CP-288)
  # ============================

  operation(:health,
    summary: "Legacy health check",
    description: "Returns APM server health status (legacy v3-compatible endpoint).",
    tags: ["Health"],
    responses: [
      ok: {"Health status", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:status,
    summary: "APM server status",
    description: "Returns full server status including agent counts, project, and version.",
    tags: ["Health"],
    responses: [
      ok: {"Status response", "application/json", Schemas.StatusResponse}
    ]
  )

  operation(:agents,
    summary: "List agents (v1)",
    description: "Lists all registered agents. Optional `project` filter.",
    tags: ["Agents"],
    parameters: [
      project: [in: :query, type: :string, required: false, description: "Filter by project name"]
    ],
    responses: [
      ok: {"Agent list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:register,
    summary: "Register agent (v1)",
    description: "Registers a new agent or upserts an existing one.",
    tags: ["Agents"],
    request_body:
      {"Agent registration payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Registered", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:register_session,
    summary: "Register session",
    description: "Persists a Claude Code session to disk and notifies SessionManager.",
    tags: ["Sessions"],
    request_body: {"Session payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      created: {"Session registered", "application/json", Schemas.OkResponse},
      bad_request: {"Missing session_id", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:heartbeat,
    summary: "Agent heartbeat",
    description: "Updates the last_heartbeat timestamp for an agent.",
    tags: ["Agents"],
    request_body:
      {"Heartbeat payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Heartbeat recorded", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:notify,
    summary: "Push notification",
    description: "Posts a notification to the APM notification bus.",
    tags: ["Notifications"],
    request_body:
      {"Notification payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Notification queued", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:activity_log,
    summary: "Agent activity log",
    description:
      "Returns recent agent activity log entries. Optional `agent_id` and `limit` filters.",
    tags: ["Agents"],
    parameters: [
      agent_id: [in: :query, type: :string, required: false, description: "Filter by agent ID"],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Max entries (default 50, max 200)"
      ]
    ],
    responses: [
      ok: {"Activity log entries", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:discover_agents,
    summary: "Trigger agent discovery",
    description: "Runs AgentDiscovery.discover_now/0 and returns discovered agents.",
    tags: ["Agents"],
    responses: [
      ok: {"Discovered agents", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:notifications,
    summary: "List notifications",
    description:
      "Returns recent notifications with optional category/project/namespace/type filters.",
    tags: ["Notifications"],
    parameters: [
      category: [in: :query, type: :string, required: false, description: "Filter by category"],
      project: [in: :query, type: :string, required: false, description: "Filter by project"],
      namespace: [in: :query, type: :string, required: false, description: "Filter by namespace"],
      type: [in: :query, type: :string, required: false, description: "Filter by type"],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Max results (default 100)"
      ]
    ],
    responses: [
      ok: {"Notification list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:get_notification,
    summary: "Get notification",
    description:
      "Returns a single notification by ID with full refs, trace, metadata, and actions.",
    tags: ["Notifications"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Notification ID"]
    ],
    responses: [
      ok: {"Notification detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:add_notification,
    summary: "Add notification (alias)",
    description: "POST alias for notify — adds a notification to the bus.",
    tags: ["Notifications"],
    request_body:
      {"Notification payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Queued", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:read_all_notifications,
    summary: "Mark all notifications read",
    description: "Sets read=true on all existing notifications.",
    tags: ["Notifications"],
    responses: [
      ok: {"Marked read", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:data,
    summary: "Master data aggregation",
    description:
      "Returns agents, edges, tasks, notifications, ralph data, commands, and input requests for the active project.",
    tags: ["Data"],
    parameters: [
      project: [
        in: :query,
        type: :string,
        required: false,
        description: "Project name (defaults to active)"
      ]
    ],
    responses: [
      ok: {"Aggregated APM state", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:ralph,
    summary: "Ralph methodology data",
    description:
      "Returns the current Ralph methodology data (stories, flowchart nodes) for a project.",
    tags: ["Ralph"],
    parameters: [
      project: [in: :query, type: :string, required: false, description: "Project name"]
    ],
    responses: [
      ok: {"Ralph data", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:ralph_flowchart,
    summary: "Ralph flowchart",
    description:
      "Returns D3.js-compatible flowchart nodes and edges for the active Ralph session.",
    tags: ["Ralph"],
    parameters: [
      project: [in: :query, type: :string, required: false, description: "Project name"]
    ],
    responses: [
      ok: {"Flowchart data", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:commands,
    summary: "List slash commands",
    description: "Returns all registered slash commands for the active project.",
    tags: ["Commands"],
    parameters: [
      project: [in: :query, type: :string, required: false, description: "Project name"]
    ],
    responses: [
      ok: {"Command list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:register_commands,
    summary: "Register slash commands",
    description: "Registers or replaces the slash command set for a project.",
    tags: ["Commands"],
    request_body:
      {"Commands payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Commands registered", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:sync_tasks,
    summary: "Sync tasks",
    description: "Synchronizes tasks from an external source (e.g. Plane) into ProjectStore.",
    tags: ["Tasks"],
    request_body: {"Tasks payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Tasks synced", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:pending_input,
    summary: "Get pending input requests",
    description: "Returns all unresolved human-input requests waiting for a response.",
    tags: ["Tasks"],
    responses: [
      ok: {"Pending inputs", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:request_input,
    summary: "Request human input",
    description: "Creates a new human-input request and broadcasts it via PubSub.",
    tags: ["Tasks"],
    request_body:
      {"Input request payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Input requested", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:respond_input,
    summary: "Respond to input request",
    description: "Resolves a pending human-input request with the provided response.",
    tags: ["Tasks"],
    request_body:
      {"Input response payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Input resolved", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:projects,
    summary: "List projects",
    description: "Returns all configured projects from the APM config.",
    tags: ["Projects"],
    responses: [
      ok: {"Project list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:update_project,
    summary: "Update active project",
    description: "Updates the active project name in the APM config.",
    tags: ["Projects"],
    request_body:
      {"Project update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Project updated", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:reload_config,
    summary: "Reload APM config",
    description: "Reloads apm_config.json from disk and propagates changes.",
    tags: ["Config"],
    responses: [
      ok: {"Config reloaded", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:update_plane,
    summary: "Update Plane PM config",
    description: "Pushes a status update to the configured Plane workspace.",
    tags: ["Projects"],
    request_body:
      {"Plane update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Plane updated", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:export,
    summary: "Export APM data",
    description: "Exports the full APM data set as a JSON snapshot.",
    tags: ["Export"],
    responses: [
      ok: {"APM export", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:import_data,
    summary: "Import APM data",
    description: "Imports a previously exported APM snapshot.",
    tags: ["Export"],
    request_body: {"Import payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Import result", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:ports,
    summary: "List ports",
    description: "Returns all registered ports and their assignments.",
    tags: ["Ports"],
    responses: [
      ok: {"Port list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:scan_ports,
    summary: "Scan ports",
    description: "Triggers a live port scan and updates the port registry.",
    tags: ["Ports"],
    responses: [
      ok: {"Scan results", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:assign_port,
    summary: "Assign port",
    description: "Assigns a port to a service/agent.",
    tags: ["Ports"],
    request_body:
      {"Port assignment payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Port assigned", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:port_clashes,
    summary: "Port clash report",
    description: "Returns a list of port conflicts across registered services.",
    tags: ["Ports"],
    responses: [
      ok: {"Clash report", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:set_primary_port,
    summary: "Set primary port",
    description: "Designates a port as the primary port for a service.",
    tags: ["Ports"],
    request_body:
      {"Port designation payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Primary port set", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:environments,
    summary: "List environments",
    description: "Returns all CCEM-managed environments.",
    tags: ["Environments"],
    responses: [
      ok: {"Environment list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:environment_detail,
    summary: "Get environment",
    description: "Returns details for a single named environment.",
    tags: ["Environments"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Environment name"]
    ],
    responses: [
      ok: {"Environment detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:exec_command,
    summary: "Execute command in environment",
    description: "Runs a shell command in the named environment.",
    tags: ["Environments"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Environment name"]
    ],
    request_body: {"Command payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Execution result", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:start_session,
    summary: "Start environment session",
    description: "Starts a long-running session in the named environment.",
    tags: ["Environments"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Environment name"]
    ],
    responses: [
      ok: {"Session started", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:stop_session,
    summary: "Stop environment session",
    description: "Terminates the running session for the named environment.",
    tags: ["Environments"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Environment name"]
    ],
    responses: [
      ok: {"Session stopped", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:deploy_hooks,
    summary: "Deploy hooks",
    description: "Deploys the latest hook scripts to all configured project directories.",
    tags: ["Config"],
    responses: [
      ok: {"Hooks deployed", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:list_bg_tasks,
    summary: "List background tasks",
    description: "Returns all registered background tasks.",
    tags: ["Tasks"],
    responses: [
      ok: {"Task list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:register_bg_task,
    summary: "Register background task",
    description: "Registers a new background task and starts tracking it.",
    tags: ["Tasks"],
    request_body: {"Task payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      created: {"Task registered", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:get_bg_task,
    summary: "Get background task",
    description: "Returns a single background task by ID.",
    tags: ["Tasks"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Task ID"]
    ],
    responses: [
      ok: {"Task detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:get_bg_task_logs,
    summary: "Get background task logs",
    description: "Returns log output for a background task.",
    tags: ["Tasks"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Task ID"]
    ],
    responses: [
      ok: {"Task logs", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:update_bg_task,
    summary: "Update background task",
    description: "Updates status or metadata for a background task.",
    tags: ["Tasks"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Task ID"]
    ],
    request_body: {"Update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Task updated", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:stop_bg_task,
    summary: "Stop background task",
    description: "Terminates a running background task.",
    tags: ["Tasks"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Task ID"]
    ],
    responses: [
      ok: {"Task stopped", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:delete_bg_task,
    summary: "Delete background task",
    description: "Removes a background task record.",
    tags: ["Tasks"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Task ID"]
    ],
    responses: [
      ok: {"Task deleted", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:scanner_scan,
    summary: "Run project scanner",
    description: "Scans configured project directories for changes.",
    tags: ["Projects"],
    responses: [
      ok: {"Scan initiated", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:scanner_results,
    summary: "Get scanner results",
    description: "Returns the most recent scan results.",
    tags: ["Projects"],
    responses: [
      ok: {"Scan results", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:scanner_status,
    summary: "Get scanner status",
    description: "Returns the current scanner run status.",
    tags: ["Projects"],
    responses: [
      ok: {"Scanner status", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:list_actions,
    summary: "List available actions",
    description: "Returns all actions registered in the ActionEngine catalog.",
    tags: ["Actions"],
    responses: [
      ok: {"Action catalog", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:run_action,
    summary: "Run action",
    description: "Executes a named action from the ActionEngine catalog.",
    tags: ["Actions"],
    request_body:
      {"Action run payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Action result", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:list_action_runs,
    summary: "List action runs",
    description: "Returns history of all action executions.",
    tags: ["Actions"],
    responses: [
      ok: {"Action run history", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:get_action_run,
    summary: "Get action run",
    description: "Returns the result of a single action execution by ID.",
    tags: ["Actions"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Action run ID"]
    ],
    responses: [
      ok: {"Action run detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:telemetry,
    summary: "Get telemetry data",
    description: "Returns raw telemetry metrics from the BEAM VM.",
    tags: ["Health"],
    responses: [
      ok: {"Telemetry data", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:intake_submit,
    summary: "Submit intake item",
    description: "Submits a new work item to the UPM intake queue.",
    tags: ["Tasks"],
    request_body: {"Intake payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Intake accepted", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:intake_list,
    summary: "List intake items",
    description: "Returns all items in the intake queue.",
    tags: ["Tasks"],
    responses: [
      ok: {"Intake queue", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:intake_watchers,
    summary: "List intake watchers",
    description: "Returns all registered intake watchers.",
    tags: ["Tasks"],
    responses: [
      ok: {"Watcher list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:skills,
    summary: "List skills (v1 alias)",
    description: "Returns all tracked skills from SkillTracker.",
    tags: ["Skills"],
    responses: [
      ok: {"Skills list", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:track_skill,
    summary: "Track skill invocation",
    description: "Records a skill invocation event in SkillTracker.",
    tags: ["Skills"],
    request_body:
      {"Skill tracking payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Skill tracked", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:update_agent,
    summary: "Full agent update (v3-compat)",
    description: "Replaces all fields of a registered agent (v3 compatibility alias).",
    tags: ["Agents"],
    request_body: {"Agent payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Agent updated", "application/json", Schemas.OkResponse}
    ]
  )

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  # ============================
  # GET Endpoints
  # ============================

  @doc "GET /health -- v3-compatible health check"
  def health(conn, _params) do
    payload = StatusCache.fetch(:health_payload, &StatusPayloadBuilder.build_health_payload/0)
    json(conn, payload)
  end

  @doc "GET /api/status -- existing v4 status endpoint (includes project data for CCEMHelper)"
  def status(conn, _params) do
    payload = StatusCache.fetch(:status_payload, &StatusPayloadBuilder.build_status_payload/0)
    json(conn, payload)
  end

  # NOTE: payload builders live in Apm.StatusPayloadBuilder so that
  # StatusCache can warm them eagerly at boot, before the first HTTP request.

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

  @doc "GET /api/notifications/:id -- single notification with full refs/trace/metadata/actions"
  def get_notification(conn, %{"id" => id}) do
    case AgentRegistry.get_notification(id) do
      {:ok, notif} -> json(conn, %{notification: notif})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
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

  @doc "GET /api/agents/activity-log -- recent agent activity log entries"
  def activity_log(conn, params) do
    limit = Map.get(params, "limit", "50") |> String.to_integer() |> min(200)
    agent_id = Map.get(params, "agent_id")

    entries =
      if agent_id do
        Apm.AgentActivityLog.get_agent_log(agent_id, limit)
      else
        Apm.AgentActivityLog.list_recent(limit)
      end

    json(conn, %{entries: entries, total: length(entries)})
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

  @doc "POST /api/sessions/register -- register a Claude Code session and persist to disk"
  def register_session(conn, params) do
    session_id = params["session_id"]

    if is_nil(session_id) or session_id == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required field: session_id"})
    else
      payload = %{
        "session_id" => session_id,
        "project" => params["project"] || "unknown",
        "git_branch" => params["git_branch"] || "unknown",
        "working_dir" => params["working_dir"] || "",
        "timestamp" => params["timestamp"] || DateTime.utc_now() |> DateTime.to_iso8601()
      }

      sessions_dir = Path.expand("~/Developer/ccem/apm/sessions")
      :ok = File.mkdir_p(sessions_dir)
      file_path = Path.join(sessions_dir, "#{session_id}.json")

      case Jason.encode(payload, pretty: true) do
        {:ok, json_str} ->
          File.write!(file_path, json_str)
          # Trigger SessionManager to pick up the new file on next poll cycle
          if pid = Process.whereis(Apm.SessionManager), do: send(pid, :poll)
          json(conn, %{ok: true, session_id: session_id, file: file_path})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to encode session: #{inspect(reason)}"})
      end
    end
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
          co_occurrence:
            SkillTracker.get_co_occurrence()
            |> Enum.map(fn {{a, b}, count} ->
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
        Phoenix.PubSub.broadcast(Apm.PubSub, "apm:config", {:config_reloaded, config})
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
    case :fuse.ask(:apm_register_fuse, :sync) do
      :blown ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "30")
        |> json(%{error: "circuit_open", fuse: "apm_register_fuse"})

      :ok ->
        do_register(conn, params)
    end
  end

  defp do_register(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      project_name = params["project_name"] || params["project"]

      # Pass all params as-is; AgentRegistry delegates to AgentIdentity.build/2
      # which normalizes OTel gen_ai.agent.* fields + CCEM provenance extensions.
      # New callers can supply: agent_name, invoked_by, definition_path, agent_version,
      # agent_description, risk_level, trust_level in addition to existing fields.
      metadata = %{
        name: params["name"] || agent_id,
        agent_name: params["agent_name"] || params["name"],
        agent_type: params["agent_type"] || params["formation_role"] || "individual",
        agent_definition: params["agent_definition"] || params["role"] || "",
        agent_description:
          params["agent_description"] || params["agent_definition"] || params["role"],
        agent_version: params["agent_version"],
        # Provenance (new OTel-aligned fields)
        invoked_by: params["invoked_by"],
        definition_path: params["definition_path"] || params["path"],
        parent_agent_id: params["parent_agent_id"] || params["parent_id"],
        session_id: params["session_id"],
        # AgentLock context hints
        risk_level: params["risk_level"],
        trust_level: params["trust_level"],
        tier: params["tier"] || 1,
        status: params["status"] || "idle",
        deps: params["deps"] || [],
        metadata: params["metadata"] || %{},
        namespace: params["namespace"],
        path: params["path"],
        member_count: params["member_count"],
        # Formation hierarchy
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
        upm_session_id: params["upm_session_id"],
        # Pub/sub topology fields (for formation tree edge generation)
        publishes: params["publishes"] || [],
        subscribes: params["subscribes"] || [],
        exports: params["exports"] || [],
        imports: params["imports"] || []
      }

      :ok = AgentRegistry.register_agent(agent_id, metadata, project_name)

      # Emit AG-UI RUN_STARTED event via HookBridge
      Task.start(fn -> HookBridge.translate_register(params) end)

      # Return enriched identity fields so callers can confirm normalization
      registered = AgentRegistry.get_agent(agent_id)

      display_name =
        if registered, do: Map.get(registered, :display_name, agent_id), else: agent_id

      resolved_name =
        if registered, do: Map.get(registered, :agent_name, agent_id), else: agent_id

      # v10.0.0/s1 (CP-289): RFC 7523 JWT Bearer Assertion — issue identity token.
      # Caller is expected to attach it as `Authorization: Bearer <token>` on
      # subsequent calls so AuthorizationGate can cryptographically verify
      # agent_id rather than trust the payload-supplied string.
      identity_token =
        try do
          Apm.Auth.JwtAssertion.sign_assertion(%{
            agent_id: agent_id,
            formation_id: metadata.formation_id,
            invoked_by: metadata.invoked_by,
            parent_agent_id: metadata.parent_agent_id,
            session_id: metadata.session_id
          })
        rescue
          # Backward-compat: if KeyStore isn't running (test env, etc.) skip.
          _ -> nil
        catch
          :exit, _ -> nil
        end

      response = %{
        ok: true,
        agent_id: agent_id,
        agent_name: resolved_name,
        display_name: display_name
      }

      response =
        if identity_token, do: Map.put(response, :identity_token, identity_token), else: response

      conn
      |> put_status(201)
      |> json(response)
    end
  end

  @doc "POST /api/heartbeat -- update agent status (upsert: auto-registers unknown agents)"
  def heartbeat(conn, params) do
    case :fuse.ask(:apm_heartbeat_fuse, :sync) do
      :blown ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "15")
        |> json(%{error: "circuit_open", fuse: "apm_heartbeat_fuse"})

      :ok ->
        do_heartbeat(conn, params)
    end
  end

  defp do_heartbeat(conn, params) do
    agent_id = params["agent_id"] || params["id"]

    if is_nil(agent_id) or agent_id == "" do
      conn
      |> put_status(400)
      |> json(%{error: "Missing required field: agent_id"})
    else
      status = params["status"] || "active"

      case AgentRegistry.update_status(agent_id, status) do
        :ok ->
          :ok

        {:error, :not_found} ->
          # Auto-register unknown agents on heartbeat (upsert pattern)
          metadata = %{
            status: status,
            name: params["name"] || agent_id,
            formation_id: params["formation_id"],
            role: params["role"] || "individual",
            project_name: params["project"],
            wave_number: params["wave"],
            metadata:
              Map.drop(params, [
                "agent_id",
                "id",
                "status",
                "name",
                "formation_id",
                "role",
                "project",
                "wave"
              ])
          }

          AgentRegistry.register_agent(agent_id, metadata, params["project"])
      end

      # Emit AG-UI STEP event via HookBridge
      Task.start(fn -> HookBridge.translate_heartbeat(params) end)
      json(conn, %{ok: true, agent_id: agent_id})
    end
  end

  @doc "POST /api/notify -- add notification with optional scoped fields"
  def notify(conn, params) do
    case :fuse.ask(:apm_notify_fuse, :sync) do
      :blown ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "30")
        |> json(%{error: "circuit_open", fuse: "apm_notify_fuse"})

      :ok ->
        do_notify(conn, params)
    end
  end

  defp do_notify(conn, params) do
    # Parse upm_context — may arrive as JSON string or already-decoded map
    upm_context =
      case params["upm_context"] do
        nil ->
          nil

        ctx when is_map(ctx) ->
          ctx

        ctx when is_binary(ctx) ->
          case Jason.decode(ctx) do
            {:ok, decoded} -> decoded
            _ -> nil
          end

        _ ->
          nil
      end

    type = params["type"] || params["level"] || "info"
    category = params["category"]

    upm_workflow_action = %{
      "label" => "View Workflow",
      "url" => "/workflow/upm",
      "target" => "_self"
    }

    is_upm_notification =
      (is_binary(type) and String.starts_with?(type, "upm:")) or category == "upm"

    raw_actions =
      case params["actions"] do
        nil ->
          []

        acts when is_list(acts) ->
          acts

        acts when is_binary(acts) ->
          case Jason.decode(acts) do
            {:ok, decoded} when is_list(decoded) -> decoded
            _ -> []
          end

        _ ->
          []
      end

    actions =
      if is_upm_notification do
        already_has_workflow =
          Enum.any?(raw_actions, fn a ->
            is_map(a) and Map.get(a, "url") == "/workflow/upm"
          end)

        if already_has_workflow, do: raw_actions, else: raw_actions ++ [upm_workflow_action]
      else
        raw_actions
      end

    notification =
      %{
        title: params["title"] || "Notification",
        message: params["message"] || params["body"] || "",
        type: type,
        category: category,
        project_name: params["project_name"] || params["project"],
        namespace: params["namespace"],
        formation_id: params["formation_id"],
        squadron_id: params["squadron_id"],
        swarm_id: params["swarm_id"],
        session_id: params["session_id"],
        agent_id: params["agent_id"],
        story_id: params["story_id"],
        wave_number: params["wave_number"] || params["wave"],
        wave_total: params["wave_total"],
        upm_context: upm_context,
        actions: actions,
        metadata: params["metadata"],
        channel: params["channel"],
        source: params["source"]
      }

    id = AgentRegistry.add_notification(notification)

    # Broadcast to PubSub for real-time toast delivery
    Phoenix.PubSub.broadcast(
      Apm.PubSub,
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
        {output, _} = System.cmd("pgrep", ["-f", "claude.*#{env.path}"], stderr_to_stdout: true)

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
  # Export / Import Endpoints
  # ============================

  @doc "GET /api/v2/export -- export APM data as JSON or CSV"
  def export(conn, params) do
    case Map.get(params, "format") do
      "csv" ->
        section = params |> Map.get("section", "agents") |> String.to_existing_atom()

        case Apm.ExportManager.export_csv(section) do
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
        data = Apm.ExportManager.export(opts)
        json(conn, data)
    end
  end

  @doc "POST /api/v2/import -- import APM data from JSON"
  def import_data(conn, params) do
    case Apm.ExportManager.import(params) do
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
        nil ->
          opts

        sections when is_list(sections) ->
          Keyword.put(opts, :sections, Enum.map(sections, &String.to_existing_atom/1))

        _ ->
          opts
      end

    opts =
      case Map.get(params, "since") do
        nil ->
          opts

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
    port_map = Apm.PortManager.get_port_map()
    ranges = Apm.PortManager.get_port_ranges()
    clashes = Apm.PortManager.detect_clashes()

    json(conn, %{
      ok: true,
      ports: port_map,
      ranges: Enum.into(ranges, %{}, fn {k, r} -> {k, %{first: r.first, last: r.last}} end),
      clashes: clashes
    })
  end

  def scan_ports(conn, _params) do
    active = Apm.PortManager.scan_active_ports()
    json(conn, %{ok: true, active_ports: active})
  end

  def assign_port(conn, %{"namespace" => ns}) do
    atom_ns = String.to_existing_atom(ns)

    case Apm.PortManager.assign_port(atom_ns) do
      {:ok, port} -> json(conn, %{ok: true, port: port})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  rescue
    ArgumentError -> conn |> put_status(400) |> json(%{ok: false, error: "invalid namespace"})
  end

  def assign_port(conn, %{"project" => project}) do
    case Apm.PortManager.assign_port(project) do
      {:ok, port} -> json(conn, %{ok: true, port: port})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  end

  def port_clashes(conn, _params) do
    clashes = Apm.PortManager.detect_clashes()
    json(conn, %{ok: true, clashes: clashes})
  end

  def set_primary_port(conn, %{"project" => project, "port" => port} = params) do
    ownership = Map.get(params, "ownership", "shared")

    if ownership not in ["exclusive", "shared", "reserved"] do
      conn
      |> put_status(400)
      |> json(%{ok: false, error: "invalid ownership: must be exclusive, shared, or reserved"})
    else
      case Apm.PortManager.set_primary_port(project, port, ownership) do
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

    case Apm.SkillHookDeployer.deploy_hooks(project_root, skill, hooks) do
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
      |> then(fn f ->
        if params["project"], do: Map.put(f, :project, params["project"]), else: f
      end)

    tasks = Apm.BackgroundTasksStore.list_tasks(filter)
    json(conn, %{tasks: tasks})
  end

  def register_bg_task(conn, params) do
    case Apm.BackgroundTasksStore.register_task(params) do
      {:ok, task} -> json(conn, %{task: task})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  def get_bg_task(conn, %{"id" => id}) do
    case Apm.BackgroundTasksStore.get_task(id) do
      {:ok, task} -> json(conn, %{task: task})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def get_bg_task_logs(conn, %{"id" => id} = params) do
    lines =
      params["lines"] |> then(fn v -> if is_binary(v), do: String.to_integer(v), else: 50 end)

    case Apm.BackgroundTasksStore.get_task_logs(id, lines) do
      {:ok, log_lines} ->
        log_path =
          case Apm.BackgroundTasksStore.get_task(id) do
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

    case Apm.BackgroundTasksStore.update_task(id, attrs) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def stop_bg_task(conn, %{"id" => id}) do
    case Apm.BackgroundTasksStore.get_task(id) do
      {:ok, task} ->
        if task.os_pid do
          System.cmd("kill", ["-TERM", to_string(task.os_pid)], stderr_to_stdout: true)
        end

        Apm.BackgroundTasksStore.update_task(id, %{"status" => "stopping"})
        json(conn, %{status: "stopping"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete_bg_task(conn, %{"id" => id}) do
    Apm.BackgroundTasksStore.delete_task(id)
    json(conn, %{ok: true})
  end

  # --- Project Scanner ---

  def scanner_scan(conn, params) do
    base_path = params["base_path"]

    case Apm.ProjectScanner.scan(base_path) do
      {:ok, results} -> json(conn, %{results: results, count: length(results)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def scanner_results(conn, _params) do
    results = Apm.ProjectScanner.get_results()
    json(conn, %{results: results, count: length(results)})
  end

  def scanner_status(conn, _params) do
    status = Apm.ProjectScanner.get_status()
    json(conn, status)
  end

  # --- Actions Engine ---

  def list_actions(conn, _params) do
    catalog = Apm.ActionEngine.list_catalog()
    json(conn, %{actions: catalog})
  end

  def run_action(conn, params) do
    action_type = params["action_type"]
    project_path = params["project_path"] || ""
    action_params = params["params"] || %{}

    case Apm.ActionEngine.run_action(action_type, project_path, action_params) do
      {:ok, run_id} -> json(conn, %{run_id: run_id})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  def list_action_runs(conn, _params) do
    runs = Apm.ActionEngine.list_runs()
    json(conn, %{runs: runs})
  end

  def get_action_run(conn, %{"id" => id}) do
    case Apm.ActionEngine.get_run(id) do
      {:ok, run} -> json(conn, %{run: run})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  # ============================
  # Intake Endpoints
  # ============================

  @doc "POST /api/intake -- submit an intake event"
  def intake_submit(conn, params) do
    case Apm.Intake.Store.submit(params) do
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

    events = Apm.Intake.Store.list(opts)
    json(conn, %{ok: true, events: Enum.map(events, &intake_event_json/1), count: length(events)})
  end

  @doc "GET /api/intake/watchers -- list registered intake watchers"
  def intake_watchers(conn, _params) do
    watchers = Apm.Intake.Store.watchers()

    json(conn, %{
      ok: true,
      watchers:
        Enum.map(watchers, fn m ->
          %{
            name: m.name(),
            event_types: m.event_types(),
            sources: m.sources(),
            enabled: m.enabled?()
          }
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
                nil ->
                  nil

                ts when is_binary(ts) ->
                  case DateTime.from_iso8601(ts) do
                    {:ok, dt, _} -> dt
                    _ -> nil
                  end

                _ ->
                  nil
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
