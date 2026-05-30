defmodule Apm.Plugins.Formations.FormationsPlugin do
  @moduledoc """
  APM Plugin wrapping the formation and UPM execution tracking layer.

  Delegates to `Apm.UpmStore` and `Apm.AgentRegistry` for all data operations.
  Exposes the following actions:
    - "list_formations"   — list all registered formations
    - "get_formation"     — get a single formation by ID, including its agents
    - "create_formation"  — register a new formation
    - "update_formation"  — update an existing formation's attributes
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.UpmStore
  alias Apm.AgentRegistry

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "formations"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Formation and UPM execution tracking — list, create, update formations and inspect agent membership"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  def config_schema do
    %{
      auto_refresh: "boolean",
      refresh_interval_ms: "integer",
      show_ghost_agents: "boolean",
      graph_layout: "enum:tree,radial,force"
    }
  end

  @impl true
  def default_config do
    %{auto_refresh: true, refresh_interval_ms: 5_000, show_ghost_agents: false, graph_layout: "tree"}
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_formations",
        description: "List all registered formations with their status and metadata",
        params: %{}
      },
      %{
        action: "get_formation",
        description: "Get a single formation by ID, including its registered agents",
        params: %{id: "string (required — formation ID)"}
      },
      %{
        action: "create_formation",
        description: "Register a new formation with the given attributes",
        params: %{
          formation_id: "string (optional — generated if omitted)",
          project: "string (required)",
          role: "string (optional — e.g. orchestrator)",
          task_subject: "string (optional)"
        }
      },
      %{
        action: "update_formation",
        description: "Update attributes of an existing formation by ID",
        params: %{id: "string (required)", status: "string (optional)", metadata: "map (optional)"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_formations", _params, _opts) do
    formations = UpmStore.list_formations()
    {:ok, %{formations: formations, count: length(formations)}}
  end

  def handle_action("get_formation", %{"id" => id}, _opts) do
    case UpmStore.get_formation(id) do
      nil ->
        {:error, {:not_found, "Formation #{id} not found"}}

      formation ->
        agents = AgentRegistry.list_formation(id)
        {:ok, Map.put(formation, :agents, agents)}
    end
  end

  def handle_action("get_formation", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("create_formation", params, _opts) do
    {:ok, id} = UpmStore.register_formation(params)
    formation = UpmStore.get_formation(id)
    {:ok, formation || %{id: id}}
  end

  def handle_action("update_formation", %{"id" => id} = params, _opts) do
    attrs = Map.drop(params, ["id"])

    case UpmStore.update_formation(id, attrs) do
      :ok ->
        formation = UpmStore.get_formation(id)
        {:ok, formation || %{id: id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("update_formation", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
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

  @impl true
  @spec orchestration_topology() :: map()
  def orchestration_topology do
    %{
      steps: [
        %{id: "deploy", name: "Deploy Formation", type: :action, config: %{}},
        %{id: "register_agents", name: "Register Agents", type: :action, config: %{}},
        %{id: "wave_gate", name: "Wave Gate", type: :gate, config: %{gate_type: :compile}},
        %{id: "next_wave", name: "Next Wave", type: :action, config: %{}},
        %{id: "complete", name: "Complete", type: :terminal, config: %{}}
      ],
      edges: [
        %{from: "deploy", to: "register_agents", condition: nil},
        %{from: "register_agents", to: "wave_gate", condition: nil},
        %{from: "wave_gate", to: "next_wave", condition: "pass"},
        %{from: "wave_gate", to: "complete", condition: "last_wave"},
        %{from: "next_wave", to: "wave_gate", condition: nil}
      ],
      gates: [
        %{after_step: "wave_gate", type: :compile_gate}
      ]
    }
  end
end
