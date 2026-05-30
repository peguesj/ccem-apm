defmodule Apm.WidgetConfigStore do
  @moduledoc """
  GenServer + ETS store for per-session widget configuration overrides and pinned widget state.

  This is the canonical store for the widgetization engine's runtime state.
  LayoutStore.save_widget_config/3 delegates to this store for broadcast consistency.

  ## ETS Schema

  Key patterns:
  - `{session_id, widget_id}` -> config map (widget config override)
  - `{:pinned, session_id}` -> widget_id string (pinned scope source)

  ## PubSub Topics

  - `"dashboard:scope:{session_id}"` — broadcasts `{:scope_changed, scope_type, scope_value}` and
    `{:pinned_widget_changed, widget_id | nil}`
  - `"dashboard:session:{session_id}"` — broadcasts `{:widget_config_updated, widget_id, config}`

  ## Usage

      Apm.WidgetConfigStore.put_config("sess_123", "agent_fleet", %{show_sparkline: false})
      Apm.WidgetConfigStore.get_config("sess_123", "agent_fleet")
      Apm.WidgetConfigStore.get_all_configs("sess_123")
      Apm.WidgetConfigStore.set_pinned("sess_123", "projects")
      Apm.WidgetConfigStore.get_pinned("sess_123")
      Apm.WidgetConfigStore.clear_session("sess_123")
  """

  use GenServer

  require Logger

  @table :widget_config_store

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store a widget config override for a session. Broadcasts :widget_config_updated."
  @spec put_config(String.t(), String.t(), map()) :: :ok
  def put_config(session_id, widget_id, config)
      when is_binary(session_id) and is_binary(widget_id) and is_map(config) do
    :ets.insert(@table, {{session_id, widget_id}, config})
    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:session:#{session_id}",
      {:widget_config_updated, widget_id, config}
    )
    :ok
  end

  @doc "Retrieve a widget config override for a session. Returns nil if not set."
  @spec get_config(String.t(), String.t()) :: map() | nil
  def get_config(session_id, widget_id)
      when is_binary(session_id) and is_binary(widget_id) do
    case :ets.lookup(@table, {session_id, widget_id}) do
      [{_key, config}] -> config
      [] -> nil
    end
  end

  @doc "Retrieve all widget config overrides for a session as a map of widget_id => config."
  @spec get_all_configs(String.t()) :: %{String.t() => map()}
  def get_all_configs(session_id) when is_binary(session_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{^session_id, _widget_id}, _config} -> true
      _ -> false
    end)
    |> Enum.into(%{}, fn {{_sess, widget_id}, config} -> {widget_id, config} end)
  end

  @doc """
  Pin a widget as the scope source for a session.
  Pass nil to unpin. Broadcasts :pinned_widget_changed on dashboard:scope PubSub.
  """
  @spec set_pinned(String.t(), String.t() | nil) :: :ok
  def set_pinned(session_id, widget_id) when is_binary(session_id) do
    key = {:pinned, session_id}

    if is_nil(widget_id) do
      :ets.delete(@table, key)
    else
      :ets.insert(@table, {key, widget_id})
    end

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:scope:#{session_id}",
      {:pinned_widget_changed, widget_id}
    )

    :ok
  end

  @doc "Get the currently pinned widget id for a session, or nil if none pinned."
  @spec get_pinned(String.t()) :: String.t() | nil
  def get_pinned(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, {:pinned, session_id}) do
      [{_key, widget_id}] -> widget_id
      [] -> nil
    end
  end

  @doc "Clear all stored state for a session (configs + pinned). Called on session end."
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    # Delete all widget config entries for this session
    :ets.tab2list(@table)
    |> Enum.each(fn
      {{^session_id, _widget_id} = key, _val} -> :ets.delete(@table, key)
      {{:pinned, ^session_id} = key, _val} -> :ets.delete(@table, key)
      _ -> :ok
    end)

    Logger.debug("[WidgetConfigStore] Cleared all state for session #{session_id}")
    :ok
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.debug("[WidgetConfigStore] ETS table #{@table} initialized")
    {:ok, %{table: table}}
  end
end
