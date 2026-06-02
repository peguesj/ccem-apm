defmodule Apm.DashboardScopeEngine do
  @moduledoc """
  GenServer that manages per-session context pinning and scope broadcasting for the
  Dashboard Widgetization Engine.

  When a widget is "pinned" as a scope source (e.g. the Projects widget), selecting
  an item in that widget sets the active scope for all non-user-level widgets on the
  dashboard. This allows, for example, selecting a project to scope all monitoring
  widgets to that project's agents and sessions.

  ## Scope Types

  - `:global` — no filter, show all data (default)
  - `:project` — filter to a specific project name
  - `:formation` — filter to a specific formation id
  - `:agent` — filter to a specific agent id

  ## PubSub

  Broadcasts `{:scope_changed, scope_type, scope_value}` on topic
  `"dashboard:scope:{session_id}"` whenever scope changes.

  Also broadcasts `{:pinned_widget_changed, widget_id | nil}` when the pinned widget changes.

  ## ETS Schema

  - `{:scope, session_id}` -> `{scope_type, scope_value}`
  - `{:pin, session_id}` -> widget_id string

  ## Usage

      Apm.DashboardScopeEngine.pin_scope_source("sess_123", "projects")
      Apm.DashboardScopeEngine.broadcast_scope("sess_123", :project, "ccem")
      Apm.DashboardScopeEngine.get_active_scope("sess_123")
      Apm.DashboardScopeEngine.unpin("sess_123")
  """

  use GenServer

  require Logger

  @table :dashboard_scope_engine

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pin a widget as the scope source for a session.
  When pinned, user interactions with this widget will drive scope for all other widgets.
  """
  @spec pin_scope_source(String.t(), String.t()) :: :ok
  def pin_scope_source(session_id, widget_id)
      when is_binary(session_id) and is_binary(widget_id) do
    :ets.insert(@table, {{:pin, session_id}, widget_id})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:scope:#{session_id}",
      {:pinned_widget_changed, widget_id}
    )

    Logger.debug("[DashboardScopeEngine] Session #{session_id} pinned widget #{widget_id}")
    :ok
  end

  @doc """
  Unpin the current scope source for a session.
  Resets scope to :global and broadcasts.
  """
  @spec unpin(String.t()) :: :ok
  def unpin(session_id) when is_binary(session_id) do
    :ets.delete(@table, {:pin, session_id})
    :ets.insert(@table, {{:scope, session_id}, {:global, nil}})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:scope:#{session_id}",
      {:pinned_widget_changed, nil}
    )

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:scope:#{session_id}",
      {:scope_changed, :global, nil}
    )

    Logger.debug("[DashboardScopeEngine] Session #{session_id} unpinned — scope reset to :global")
    :ok
  end

  @doc """
  Broadcast a scope change for a session.
  Called by the pinned widget when the user selects an item.
  scope_type: :global | :project | :formation | :agent
  scope_value: nil (for :global) or a string identifier
  """
  @spec broadcast_scope(String.t(), atom(), String.t() | nil) :: :ok
  def broadcast_scope(session_id, scope_type, scope_value)
      when is_binary(session_id) and is_atom(scope_type) do
    :ets.insert(@table, {{:scope, session_id}, {scope_type, scope_value}})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "dashboard:scope:#{session_id}",
      {:scope_changed, scope_type, scope_value}
    )

    Logger.debug(
      "[DashboardScopeEngine] Session #{session_id} scope -> #{scope_type}:#{scope_value}"
    )

    :ok
  end

  @doc "Get the active scope for a session. Returns {scope_type, scope_value} or {:global, nil}."
  @spec get_active_scope(String.t()) :: {atom(), String.t() | nil}
  def get_active_scope(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, {:scope, session_id}) do
      [{_key, scope}] -> scope
      [] -> {:global, nil}
    end
  end

  @doc "Get the currently pinned widget id for a session, or nil if none pinned."
  @spec get_pinned_widget(String.t()) :: String.t() | nil
  def get_pinned_widget(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, {:pin, session_id}) do
      [{_key, widget_id}] -> widget_id
      [] -> nil
    end
  end

  @doc "Clear all scope engine state for a session."
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    :ets.delete(@table, {:scope, session_id})
    :ets.delete(@table, {:pin, session_id})
    :ok
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.debug("[DashboardScopeEngine] ETS table #{@table} initialized")
    {:ok, %{table: table}}
  end
end
