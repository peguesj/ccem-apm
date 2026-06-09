defmodule Apm.LayoutStore do
  @moduledoc """
  GenServer + ETS store for dashboard layout presets and per-session user layouts.

  Built-in presets are loaded on init from `priv/dashboard/presets.json`.
  User layouts are stored in ETS (session-scoped, not persisted across restarts).

  ## Layout Preset Schema

      %{
        id: String.t(),               # snake_case identifier
        name: String.t(),             # human display name
        description: String.t(),
        columns: 12,                  # always 12-column grid
        rows: integer(),              # suggested row count
        placements: [placement()]
      }

  ## Placement Schema

      %{
        widget_id: String.t(),
        col_start: integer(),   # 1-based, 1..12
        col_end: integer(),     # 1-based, 1..13 (exclusive)
        row_start: integer(),   # 1-based
        row_end: integer()      # 1-based (exclusive)
      }

  ## Usage

      Apm.LayoutStore.list_presets()
      Apm.LayoutStore.get_preset("default")
      Apm.LayoutStore.save_user_layout("session_123", %{preset_id: "default", placements: [...]})
      Apm.LayoutStore.get_user_layout("session_123")
  """

  use GenServer
  require Logger

  @table :layout_store

  @builtin_presets [
    %{
      id: "default",
      name: "Default",
      description: "Standard monitoring dashboard — agent fleet, notifications, UPM status",
      columns: 12,
      rows: 6,
      placements: [
        %{widget_id: "agent_fleet", col_start: 1, col_end: 5, row_start: 1, row_end: 3},
        %{widget_id: "usage_summary", col_start: 5, col_end: 9, row_start: 1, row_end: 3},
        %{widget_id: "session_overview", col_start: 9, col_end: 13, row_start: 1, row_end: 3},
        %{widget_id: "notifications", col_start: 1, col_end: 5, row_start: 3, row_end: 7},
        %{widget_id: "background_tasks", col_start: 5, col_end: 9, row_start: 3, row_end: 7},
        %{widget_id: "upm_workflow", col_start: 9, col_end: 13, row_start: 3, row_end: 7}
      ]
    },
    %{
      id: "formation_monitor",
      name: "Formation Monitor",
      description: "Formation-focused view — live graph, agent fleet, wave progress",
      columns: 12,
      rows: 8,
      placements: [
        %{widget_id: "formation_graph", col_start: 1, col_end: 9, row_start: 1, row_end: 6},
        %{widget_id: "agent_fleet", col_start: 9, col_end: 13, row_start: 1, row_end: 4},
        %{widget_id: "notifications", col_start: 9, col_end: 13, row_start: 4, row_end: 7},
        %{widget_id: "background_tasks", col_start: 1, col_end: 7, row_start: 6, row_end: 9},
        %{widget_id: "session_overview", col_start: 7, col_end: 13, row_start: 7, row_end: 9}
      ]
    },
    %{
      id: "auth_security",
      name: "Auth & Security",
      description: "AgentLock-focused view — pending decisions, audit log, policy status",
      columns: 12,
      rows: 7,
      placements: [
        %{widget_id: "pending_decisions", col_start: 1, col_end: 5, row_start: 1, row_end: 5},
        %{widget_id: "auth_audit", col_start: 5, col_end: 13, row_start: 1, row_end: 5},
        %{widget_id: "notifications", col_start: 1, col_end: 7, row_start: 5, row_end: 8},
        %{widget_id: "agent_fleet", col_start: 7, col_end: 13, row_start: 5, row_end: 8}
      ]
    },
    %{
      id: "workflow",
      name: "Workflow",
      description: "Project workflow view — Plane board, UPM, usage, background tasks",
      columns: 12,
      rows: 7,
      placements: [
        %{widget_id: "upm_workflow", col_start: 1, col_end: 5, row_start: 1, row_end: 5},
        %{widget_id: "plane_board", col_start: 5, col_end: 13, row_start: 1, row_end: 5},
        %{widget_id: "usage_summary", col_start: 1, col_end: 5, row_start: 5, row_end: 8},
        %{widget_id: "background_tasks", col_start: 5, col_end: 9, row_start: 5, row_end: 8},
        %{widget_id: "notifications", col_start: 9, col_end: 13, row_start: 5, row_end: 8}
      ]
    },
    %{
      id: "minimal",
      name: "Minimal",
      description: "Clean view — just agent fleet and notifications side by side",
      columns: 12,
      rows: 4,
      placements: [
        %{widget_id: "agent_fleet", col_start: 1, col_end: 7, row_start: 1, row_end: 5},
        %{widget_id: "notifications", col_start: 7, col_end: 13, row_start: 1, row_end: 5}
      ]
    }
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all available layout presets."
  @spec list_presets() :: [map()]
  def list_presets do
    case :ets.lookup(@table, :presets) do
      [{:presets, presets}] -> presets
      [] -> @builtin_presets
    end
  end

  @doc "Get a single layout preset by id."
  @spec get_preset(String.t()) :: map() | nil
  def get_preset(id) do
    list_presets() |> Enum.find(&(&1.id == id))
  end

  @doc "Save a user layout for a session (session-scoped, in-memory only)."
  @spec save_user_layout(String.t(), map()) :: :ok
  def save_user_layout(session_id, layout) when is_binary(session_id) and is_map(layout) do
    :ets.insert(@table, {"user_layout:#{session_id}", layout})
    :ok
  end

  @doc "Retrieve a user's saved layout for a session."
  @spec get_user_layout(String.t()) :: map() | nil
  def get_user_layout(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, "user_layout:#{session_id}") do
      [{_key, layout}] -> layout
      [] -> nil
    end
  end

  @doc "Delete a user layout."
  @spec delete_user_layout(String.t()) :: :ok
  def delete_user_layout(session_id) when is_binary(session_id) do
    :ets.delete(@table, "user_layout:#{session_id}")
    :ok
  end

  @doc "Save a widget config override for a session. Broadcasts :widget_config_updated via PubSub."
  @spec save_widget_config(String.t(), String.t(), map()) :: :ok
  def save_widget_config(session_id, widget_id, config)
      when is_binary(session_id) and is_binary(widget_id) and is_map(config) do
    :ets.insert(@table, {"widget_config:#{session_id}:#{widget_id}", config})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:session:#{session_id}",
      {:widget_config_updated, widget_id, config}
    )

    :ok
  end

  @doc "Retrieve a widget config override for a session."
  @spec get_widget_config(String.t(), String.t()) :: map() | nil
  def get_widget_config(session_id, widget_id)
      when is_binary(session_id) and is_binary(widget_id) do
    case :ets.lookup(@table, "widget_config:#{session_id}:#{widget_id}") do
      [{_key, config}] -> config
      [] -> nil
    end
  end

  @doc "Set the pinned widget for a session. Pass nil to unpin. Broadcasts :pinned_widget_changed via PubSub."
  @spec set_pinned_widget(String.t(), String.t() | nil) :: :ok
  def set_pinned_widget(session_id, widget_id) when is_binary(session_id) do
    key = "pinned_widget:#{session_id}"

    if is_nil(widget_id) do
      :ets.delete(@table, key)
    else
      :ets.insert(@table, {key, widget_id})
    end

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:session:#{session_id}",
      {:pinned_widget_changed, widget_id}
    )

    :ok
  end

  @doc "Get the currently pinned widget id for a session, or nil if none."
  @spec get_pinned_widget(String.t()) :: String.t() | nil
  def get_pinned_widget(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, "pinned_widget:#{session_id}") do
      [{_key, widget_id}] -> widget_id
      [] -> nil
    end
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    presets = load_presets()
    :ets.insert(table, {:presets, presets})
    Logger.debug("[LayoutStore] Loaded #{length(presets)} layout presets")
    {:ok, %{table: table}}
  end

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp load_presets do
    path = Path.join(:code.priv_dir(:apm), "dashboard/presets.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, presets} when is_list(presets) ->
            Logger.debug("[LayoutStore] Loaded #{length(presets)} presets from #{path}")
            # Merge with builtins — file presets take priority by id
            merge_presets(@builtin_presets, presets)

          _ ->
            Logger.warning("[LayoutStore] Could not parse #{path}, using built-in presets")
            @builtin_presets
        end

      _ ->
        Logger.debug("[LayoutStore] No presets.json found, using built-in presets")
        @builtin_presets
    end
  end

  defp merge_presets(builtins, from_file) do
    file_ids = MapSet.new(from_file, & &1.id)

    kept_builtins = Enum.reject(builtins, &MapSet.member?(file_ids, &1.id))
    kept_builtins ++ from_file
  end
end
