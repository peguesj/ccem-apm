defmodule ApmV5.Plugins.Orchestration.OrchestrationPlugin do
  @moduledoc """
  APM Plugin for the Orchestration System.

  Exposes orchestration actions via the PluginBehaviour interface and
  registers a dashboard widget for orchestration summary.

  Actions:
    - "start_run"     — start a new orchestration run
    - "get_status"    — get a run's current status
    - "replay_run"    — replay a historical run
    - "dry_run"       — preview execution plan for a workflow
    - "list_history"  — list completed runs
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "orchestration"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "DAG-based workflow orchestration engine — start runs, advance steps, replay history"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec plugin_scope() :: :orchestration
  def plugin_scope, do: :orchestration

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "start_run",
        description: "Start a new orchestration run for a workflow",
        params: %{workflow_id: "string (required)", dry_run: "boolean (optional)"}
      },
      %{
        action: "get_status",
        description: "Get the current status of an orchestration run",
        params: %{run_id: "string (required)"}
      },
      %{
        action: "replay_run",
        description: "Replay a historical run with optional parameter overrides",
        params: %{run_id: "string (required)", params: "map (optional)"}
      },
      %{
        action: "dry_run",
        description: "Preview the execution plan for a workflow without executing",
        params: %{workflow_id: "string (required)"}
      },
      %{
        action: "list_history",
        description: "List historical orchestration runs",
        params: %{workflow_id: "string (optional)", limit: "integer (optional)"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("start_run", %{"workflow_id" => wid} = params, _opts) do
    run_params = Map.drop(params, ["workflow_id"])

    case OrchestrationManager.start_run(wid, run_params) do
      {:ok, run} -> {:ok, %{run_id: run.id, status: run.status, workflow_id: wid}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("start_run", _params, _opts),
    do: {:error, {:missing_param, "workflow_id is required"}}

  def handle_action("get_status", %{"run_id" => run_id}, _opts) do
    case OrchestrationManager.get_run(run_id) do
      nil ->
        case OrchestrationRunStore.get_run(run_id) do
          nil -> {:error, {:not_found, run_id}}
          run -> {:ok, %{run_id: run.id, status: run.status, archived: true}}
        end

      run ->
        next = OrchestrationManager.next_steps(run_id)
        total = map_size(run.steps)
        done = Enum.count(run.steps, fn {_id, s} -> s.status in [:completed, :skipped] end)

        {:ok,
         %{
           run_id: run.id,
           status: run.status,
           progress: "#{done}/#{total}",
           next_steps: next,
           workflow_id: run.workflow_id
         }}
    end
  end

  def handle_action("get_status", _params, _opts),
    do: {:error, {:missing_param, "run_id is required"}}

  def handle_action("replay_run", %{"run_id" => run_id} = params, _opts) do
    extra = Map.get(params, "params", %{})

    case OrchestrationRunStore.replay_run(run_id, extra) do
      {:ok, new_run} -> {:ok, %{new_run_id: new_run.id, replayed_from: run_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("replay_run", _params, _opts),
    do: {:error, {:missing_param, "run_id is required"}}

  def handle_action("dry_run", %{"workflow_id" => wid}, _opts) do
    case OrchestrationManager.start_run(wid, %{dry_run: true}) do
      {:ok, result} -> {:ok, %{workflow_id: wid, execution_order: result[:execution_order]}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("dry_run", _params, _opts),
    do: {:error, {:missing_param, "workflow_id is required"}}

  def handle_action("list_history", params, _opts) do
    opts =
      []
      |> maybe_opt(:workflow_id, Map.get(params, "workflow_id"))
      |> maybe_opt(:limit, parse_limit(Map.get(params, "limit")))

    runs = OrchestrationRunStore.list_runs(opts)

    {:ok,
     %{
       runs: Enum.map(runs, fn r -> %{id: r.id, workflow_id: r.workflow_id, status: r.status} end),
       count: length(runs)
     }}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"Orchestration", "/orchestration", "hero-arrow-path-rounded-square"}]
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "orchestration_summary",
        name: "Orchestration",
        description: "Active run count, last run status, total runs today",
        category: :workflow,
        source_module: ApmV5.Orchestration.OrchestrationManager,
        refresh_interval: 5_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "orchestration",
        version: "1.0.0",
        pinnable: true,
        editable: false
      }
    ]
  end

  @impl true
  @spec orchestration_topology() :: map()
  def orchestration_topology do
    %{
      steps: [
        %{id: "parse_request", name: "Parse Request", type: :action, config: %{}},
        %{id: "decompose", name: "Decompose", type: :action, config: %{}},
        %{id: "assign_squadrons", name: "Assign Squadrons", type: :action, config: %{}},
        %{id: "monitor", name: "Monitor Execution", type: :action, config: %{}},
        %{id: "aggregate", name: "Aggregate Results", type: :action, config: %{}},
        %{id: "report", name: "Report", type: :terminal, config: %{}}
      ],
      edges: [
        %{from: "parse_request", to: "decompose", condition: nil},
        %{from: "decompose", to: "assign_squadrons", condition: nil},
        %{from: "assign_squadrons", to: "monitor", condition: nil},
        %{from: "monitor", to: "aggregate", condition: nil},
        %{from: "aggregate", to: "report", condition: nil}
      ],
      gates: []
    }
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, val), do: [{key, val} | opts]

  defp parse_limit(nil), do: nil
  defp parse_limit(n) when is_integer(n), do: n
  defp parse_limit(s) when is_binary(s), do: String.to_integer(s)
  defp parse_limit(_), do: nil
end
