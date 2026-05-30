defmodule Apm.Plugins.Devops.DevopsPlugin do
  @moduledoc """
  APM Plugin wrapping BackgroundTasksStore, ProjectScanner, and ActionEngine.

  Exposes the following actions:
    - "list_tasks"    — list background tasks
    - "get_task"      — get a specific background task by ID
    - "stop_task"     — stop a running background task
    - "scan_projects" — scan developer directories for projects
    - "scan_results"  — get last scan results
    - "scan_status"   — get project scanner status
    - "list_actions"  — list available ActionEngine actions
    - "run_action"    — run an ActionEngine action
    - "list_runs"     — list recent ActionEngine runs
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.BackgroundTasksStore
  alias Apm.ProjectScanner
  alias Apm.ActionEngine

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "devops"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "DevOps tools — background tasks, project scanner, and action engine orchestration"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  def config_schema do
    %{
      health_check_interval_ms: "integer",
      port_scan_enabled: "boolean",
      log_tail_lines: "integer"
    }
  end

  @impl true
  def default_config do
    %{health_check_interval_ms: 30_000, port_scan_enabled: true, log_tail_lines: 100}
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_tasks",
        description: "List all background tasks",
        params: %{}
      },
      %{
        action: "get_task",
        description: "Get a specific background task by ID",
        params: %{id: "string"}
      },
      %{
        action: "stop_task",
        description: "Stop a running background task by ID",
        params: %{id: "string"}
      },
      %{
        action: "scan_projects",
        description: "Trigger a scan of developer directories",
        params: %{base_path: "string (optional)"}
      },
      %{
        action: "scan_results",
        description: "Get the latest project scan results",
        params: %{}
      },
      %{
        action: "scan_status",
        description: "Get the project scanner status",
        params: %{}
      },
      %{
        action: "list_actions",
        description: "List available ActionEngine action types",
        params: %{}
      },
      %{
        action: "run_action",
        description: "Run an ActionEngine action",
        params: %{action_type: "string", project_path: "string", params: "map (optional)"}
      },
      %{
        action: "list_runs",
        description: "List recent ActionEngine runs",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_tasks", params, _opts) do
    filter = Map.get(params, "filter", %{})
    tasks = BackgroundTasksStore.list_tasks(filter)
    {:ok, %{tasks: tasks, count: length(tasks)}}
  end

  def handle_action("get_task", %{"id" => id}, _opts) do
    case BackgroundTasksStore.get_task(id) do
      {:ok, task} -> {:ok, %{task: task}}
      {:error, :not_found} -> {:error, {:not_found, id}}
    end
  end

  def handle_action("get_task", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("stop_task", %{"id" => id}, _opts) do
    BackgroundTasksStore.stop_task(id)
    {:ok, %{status: "stopped", id: id}}
  end

  def handle_action("stop_task", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("scan_projects", params, _opts) do
    base_path = Map.get(params, "base_path")
    ProjectScanner.scan(base_path)
    {:ok, %{status: "scan_started"}}
  end

  def handle_action("scan_results", _params, _opts) do
    results = ProjectScanner.get_results()
    {:ok, %{results: results, count: length(results)}}
  end

  def handle_action("scan_status", _params, _opts) do
    status = ProjectScanner.get_status()
    {:ok, %{status: status}}
  end

  def handle_action("list_actions", _params, _opts) do
    catalog = ActionEngine.list_catalog()
    {:ok, %{actions: catalog, count: length(catalog)}}
  end

  def handle_action("run_action", %{"action_type" => action_type, "project_path" => project_path} = params, _opts) do
    action_params = Map.get(params, "params", %{})

    case ActionEngine.run_action(action_type, project_path, action_params) do
      {:ok, run_id} -> {:ok, %{status: "started", run_id: run_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("run_action", _params, _opts) do
    {:error, {:missing_param, "action_type and project_path are required"}}
  end

  def handle_action("list_runs", _params, _opts) do
    runs = ActionEngine.list_runs()
    {:ok, %{runs: runs, count: length(runs)}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true
end
