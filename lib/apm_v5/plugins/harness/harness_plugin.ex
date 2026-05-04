defmodule ApmV5.Plugins.Harness.HarnessPlugin do
  @moduledoc """
  APM plugin for the Claude Code harness runtime.

  Exposes session state, hook telemetry, harness-mem health, plans lifecycle,
  and settings diff between global and project-scoped Claude Code configs.
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.Plugins.Harness.HarnessMonitor
  alias ApmV5.Plugins.Harness.HookTelemetryBuffer

  require Logger

  @plugin_version "1.0.0"
  @global_settings_path "~/.claude/settings.json"
  @project_settings_path "~/Developer/ccem/.claude/settings.json"
  @plans_dir "~/.claude/plans/"

  # ── Identity ──────────────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "harness"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Claude Code harness runtime monitor — session state, hook telemetry, harness-mem health, plans lifecycle"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :ccem
  def plugin_scope, do: :ccem

  # ── Configuration ─────────────────────────────────────────────────────────────

  @impl true
  @spec config_schema() :: map()
  def config_schema do
    %{
      poll_interval_ms: "integer",
      max_hook_buffer: "integer",
      notify_on_mem_down: "boolean"
    }
  end

  @impl true
  @spec default_config() :: map()
  def default_config do
    %{
      poll_interval_ms: 15_000,
      max_hook_buffer: 500,
      notify_on_mem_down: true
    }
  end

  # ── Endpoints ─────────────────────────────────────────────────────────────────

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "health",
        description: "Full harness health map including harness-mem status",
        params: %{}
      },
      %{
        action: "hook_telemetry",
        description: "Recent hook fire events from the ring buffer",
        params: %{limit: "integer (optional, default 50)"}
      },
      %{
        action: "session_state",
        description: "Current harness monitor state snapshot",
        params: %{}
      },
      %{
        action: "plans_status",
        description: "Scan ~/.claude/plans/ directory for plan files",
        params: %{}
      },
      %{
        action: "settings_diff",
        description: "Keys present in global vs project-scoped Claude Code settings.json",
        params: %{}
      }
    ]
  end

  # ── Action Dispatch ───────────────────────────────────────────────────────────

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  def handle_action("health", _params, _opts) do
    case safe_call(fn -> HarnessMonitor.health_check() end) do
      {:ok, health} -> {:ok, health}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("hook_telemetry", params, _opts) do
    limit =
      (Map.get(params, "limit") || Map.get(params, :limit) || 50)
      |> parse_integer(50)

    case safe_call(fn -> HookTelemetryBuffer.recent(limit) end) do
      {:ok, events} -> {:ok, %{events: events, count: length(events)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("session_state", _params, _opts) do
    case safe_call(fn -> HarnessMonitor.current_state() end) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("plans_status", _params, _opts) do
    plans_path = Path.expand(@plans_dir)

    case File.ls(plans_path) do
      {:ok, files} ->
        {:ok, %{plans: files, count: length(files), exists: true}}

      {:error, :enoent} ->
        {:ok, %{plans: [], count: 0, exists: false}}

      {:error, reason} ->
        Logger.warning("[HarnessPlugin] plans_status ls error: #{inspect(reason)}")
        {:error, {:fs_error, reason}}
    end
  end

  def handle_action("settings_diff", _params, _opts) do
    global_keys = read_settings_keys(@global_settings_path)
    project_keys = read_settings_keys(@project_settings_path)

    global_set = MapSet.new(global_keys)
    project_set = MapSet.new(project_keys)

    {:ok,
     %{
       global_keys: global_keys,
       project_keys: project_keys,
       in_project_only: project_set |> MapSet.difference(global_set) |> MapSet.to_list(),
       in_global_only: global_set |> MapSet.difference(project_set) |> MapSet.to_list()
     }}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Optional Callbacks ────────────────────────────────────────────────────────

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children do
    [
      ApmV5.Plugins.Harness.HarnessMonitor,
      ApmV5.Plugins.Harness.HookTelemetryBuffer
    ]
  end

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"Harness", "/plugins/harness", "hero-cpu-chip"}]
  end

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "harness_health",
        name: "Harness Health",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 15_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "harness",
        version: @plugin_version,
        description: "Claude Code harness health — harness-mem, hooks, session state"
      }
    ]
  end

  @impl true
  @spec plugin_live_module() :: module()
  def plugin_live_module, do: ApmV5Web.HarnessLive

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # ── Private Helpers ───────────────────────────────────────────────────────────

  # Wraps calls to supervised GenServers so a not-yet-started process doesn't
  # crash the plugin action dispatcher.
  @spec safe_call((() -> term())) :: {:ok, term()} | {:error, term()}
  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    e in [ArgumentError, RuntimeError] ->
      Logger.warning("[HarnessPlugin] safe_call rescued: #{inspect(e)}")
      {:error, {:process_unavailable, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[HarnessPlugin] safe_call exit: #{inspect(reason)}")
      {:error, {:process_exit, reason}}
  end

  @spec read_settings_keys(String.t()) :: [String.t()]
  defp read_settings_keys(path) do
    expanded = Path.expand(path)

    with {:ok, contents} <- File.read(expanded),
         {:ok, decoded} <- Jason.decode(contents),
         true <- is_map(decoded) do
      Map.keys(decoded)
    else
      _ -> []
    end
  end

  @spec parse_integer(term(), integer()) :: integer()
  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
