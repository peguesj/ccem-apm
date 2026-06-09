defmodule Apm.Plugins.Orchestration.OrchestrationPlugin do
  @moduledoc """
  APM Plugin for the orchestration system.

  Exposes actions for listing orchestration runs, starting new runs,
  querying the WorkflowRegistry, and enumerating supported orchestration
  types with their semantic constraints.

  ## Scope
  `:orchestration` — registered in the orchestration category.

  ## Actions
  - `list_runs`    — List all active runs from OrchestrationManager
  - `get_run`      — Get a single run by id
  - `list_types`   — Enumerate all 6 orchestration types with metadata
  - `list_workflows` — List all registered workflow templates
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Orchestration.OrchestrationManager
  alias Apm.WorkflowRegistry

  require Logger

  @plugin_version "1.0.0"

  @orchestration_types [
    %{
      type: :pipeline,
      description: "Linear sequence with no loops; strict ordering (CI/CD style).",
      required_params: []
    },
    %{
      type: :workflow,
      description: "DAG with conditional branches and gates (default type).",
      required_params: []
    },
    %{
      type: :maintenance,
      description: "Scheduled/recurring health-check driven with auto-remediation.",
      required_params: [:schedule]
    },
    %{
      type: :sync,
      description: "Bidirectional state reconciliation between two sources.",
      required_params: [:source, :target]
    },
    %{
      type: :formation,
      description: "Multi-wave agent deployment following the formation pattern.",
      required_params: []
    },
    %{
      type: :autonomous,
      description: "Self-directing orchestration with decision loops (Ralph pattern).",
      required_params: []
    }
  ]

  # ---------------------------------------------------------------------------
  # PluginBehaviour
  # ---------------------------------------------------------------------------

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "orchestration"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Orchestration engine — typed DAG runs, workflow templates, and type registry"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :orchestration
  def plugin_scope, do: :orchestration

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_runs",
        description: "List all active orchestration runs",
        params: %{}
      },
      %{
        action: "get_run",
        description: "Get a single run by id",
        params: %{id: "string (required)"}
      },
      %{
        action: "list_types",
        description:
          "Enumerate all supported orchestration types with semantics and required params",
        params: %{}
      },
      %{
        action: "list_workflows",
        description: "List all registered workflow templates from WorkflowRegistry",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_runs", _params, _opts) do
    runs = OrchestrationManager.list_runs()
    {:ok, %{runs: runs, count: length(runs)}}
  end

  def handle_action("get_run", %{"id" => id}, _opts) do
    case OrchestrationManager.get_run(id) do
      {:ok, run} -> {:ok, %{run: run}}
      {:error, :not_found} -> {:error, {:not_found, "run #{id} not found"}}
    end
  end

  def handle_action("list_types", _params, _opts) do
    {:ok, %{types: @orchestration_types}}
  end

  def handle_action("list_workflows", _params, _opts) do
    workflows = WorkflowRegistry.list_workflows()
    {:ok, %{workflows: workflows, count: length(workflows)}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  def supervisor_children do
    [
      Apm.Orchestration.OrchestrationRunStore,
      Apm.Orchestration.OrchestrationManager
    ]
  end

  @impl true
  def nav_items do
    [{"Orchestration", "/orchestration", "hero-cpu-chip"}]
  end

  @impl true
  def plugin_live_module, do: ApmWeb.OrchestrationLive

  @impl true
  def dashboard_widgets do
    [
      %{
        id: "orchestration_summary",
        name: "Orchestration Runs",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 10_000,
        min_width: 4,
        min_height: 2,
        config_schema: %{},
        plugin: "orchestration",
        version: @plugin_version,
        description: "Active orchestration run summary with type breakdown"
      }
    ]
  end
end
