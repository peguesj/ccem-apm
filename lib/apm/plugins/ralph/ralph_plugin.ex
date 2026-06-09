defmodule Apm.Plugins.Ralph.RalphPlugin do
  @moduledoc """
  APM Plugin wrapping the Ralph PRD reader and D3.js flowchart generator.

  Delegates to `Apm.Ralph` for all data operations.
  Exposes the following actions:
    - "start_loop"  — read a prd.json and return parsed Ralph data
    - "stop_loop"   — no-op stub (Ralph is stateless; kept for API symmetry)
    - "status"      — returns `:ok` with current Ralph module availability
    - "list_runs"   — lists recently scanned PRD paths from ConfigLoader
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Ralph
  alias Apm.ConfigLoader

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "ralph"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do:
      "Ralph PRD reader and D3.js flowchart generator — load prd.json, build flowcharts, list runs"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  def config_schema do
    %{
      prd_path: "string",
      max_iterations: "integer",
      backpressure_threshold: "integer",
      auto_commit: "boolean",
      log_level: "enum:debug,info,warn,error"
    }
  end

  @impl true
  def default_config do
    %{
      prd_path: ".claude/ralph/prd.json",
      max_iterations: 50,
      backpressure_threshold: 10,
      auto_commit: true,
      log_level: "info"
    }
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "start_loop",
        description:
          "Load a prd.json file and return parsed Ralph data with flowchart nodes/edges",
        params: %{path: "string (optional — path to prd.json; uses config default if omitted)"}
      },
      %{
        action: "stop_loop",
        description: "No-op stub for API symmetry. Ralph loops are stateless.",
        params: %{}
      },
      %{
        action: "status",
        description: "Returns the Ralph module availability and config PRD path",
        params: %{}
      },
      %{
        action: "list_runs",
        description: "Returns recently known PRD paths from the APM config",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("start_loop", params, _opts) do
    path = Map.get(params, "path", default_prd_path())

    case Ralph.load(path) do
      {:ok, data} ->
        {:ok, %{status: "loaded", path: path, data: data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("stop_loop", _params, _opts) do
    {:ok, %{status: "stopped", message: "Ralph is stateless — no active loop to stop"}}
  end

  def handle_action("status", _params, _opts) do
    path = default_prd_path()
    exists = if is_binary(path) and path != "", do: File.exists?(path), else: false

    {:ok,
     %{
       module: "Apm.Ralph",
       available: true,
       default_prd_path: path,
       prd_file_exists: exists
     }}
  end

  def handle_action("list_runs", _params, _opts) do
    paths = prd_paths_from_config()
    {:ok, %{runs: paths, count: length(paths)}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"PRD", "/plugins/ralph", "hero-document-text"}]
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec default_prd_path() :: String.t() | nil
  defp default_prd_path do
    config = ConfigLoader.get_config()
    Map.get(config, "prd_path")
  rescue
    _ -> nil
  end

  @spec prd_paths_from_config() :: [String.t()]
  defp prd_paths_from_config do
    config = ConfigLoader.get_config()

    case Map.get(config, "project_root") do
      nil ->
        []

      root ->
        candidate = Path.join(root, "prd.json")
        if File.exists?(candidate), do: [candidate], else: []
    end
  rescue
    _ -> []
  end

  @impl true
  @spec orchestration_topology() :: map()
  def orchestration_topology do
    %{
      steps: [
        %{id: "write_prd", name: "Write PRD", type: :action, config: %{}},
        %{id: "pick_story", name: "Pick Story", type: :action, config: %{}},
        %{id: "implement", name: "Implement", type: :action, config: %{}},
        %{
          id: "quality_check",
          name: "Quality Check",
          type: :gate,
          config: %{gate_type: :compile}
        },
        %{id: "commit", name: "Commit", type: :action, config: %{}},
        %{id: "update_prd", name: "Update PRD", type: :action, config: %{}},
        %{id: "more_stories", name: "More Stories?", type: :decision, config: %{}}
      ],
      edges: [
        %{from: "write_prd", to: "pick_story", condition: nil},
        %{from: "pick_story", to: "implement", condition: nil},
        %{from: "implement", to: "quality_check", condition: nil},
        %{from: "quality_check", to: "commit", condition: "pass"},
        %{from: "commit", to: "update_prd", condition: nil},
        %{from: "update_prd", to: "more_stories", condition: nil},
        %{from: "more_stories", to: "pick_story", condition: "yes"},
        %{from: "more_stories", to: nil, condition: "no"}
      ],
      gates: [
        %{after_step: "quality_check", type: :compile_gate}
      ]
    }
  end
end
