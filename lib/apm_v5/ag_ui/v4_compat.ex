defmodule ApmV5.AgUi.V4Compat do
  @moduledoc """
  V4 compatibility shim for legacy PubSub consumers.

  Subscribes to EventBus topics and re-broadcasts events on legacy PubSub topics
  ('apm:agents', 'apm:notifications', 'dashboard:updates') so existing LiveViews
  continue working during migration.

  Controlled by :apm_v5, :ag_ui_native_events config toggle.
  When true, this shim is disabled (events flow only through EventBus).
  When false (default), events flow through both EventBus and legacy PubSub.

  ## US-007 Acceptance Criteria (DoD):
  - GenServer starts in supervision tree
  - Subscribes to EventBus 'lifecycle:*' -> re-broadcasts as {:agent_registered/_updated} on 'apm:agents'
  - Subscribes to EventBus 'special:custom' -> re-broadcasts as {:notification_added} on 'apm:notifications'
  - Subscribes to EventBus 'state:*' -> re-broadcasts as {:ag_ui_dashboard} on 'dashboard:updates'
  - All existing LiveViews continue receiving events without modification
  - mix compile --warnings-as-errors passes

  ## US-009 Acceptance Criteria (DoD):
  - :apm_v5, :ag_ui_native_events defaults to false (legacy mode)
  - When false: V4Compat shim is active
  - When true: V4Compat shim is disabled
  - POST /api/config/reload accepts ag_ui_native_events toggle
  - ConfigLoader reads the toggle from apm_config.json on startup
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  @pubsub ApmV5.PubSub

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns whether the V4 compatibility shim is active."
  @spec active?() :: boolean()
  def active? do
    not Application.get_env(:apm_v5, :ag_ui_native_events, false)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if active?() do
      # Subscribe to EventBus topics for re-broadcasting
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
      ApmV5.AgUi.EventBus.subscribe("special:custom")
      ApmV5.AgUi.EventBus.subscribe("state:*")
      ApmV5.AgUi.EventBus.subscribe("tool:*")
      ApmV5.AgUi.EventBus.subscribe("activity:*")
      Logger.info("V4Compat shim active: re-broadcasting AG-UI events to legacy PubSub topics")
    else
      Logger.info("V4Compat shim disabled: ag_ui_native_events=true")
    end

    {:ok, %{rebroadcast_count: 0}}
  end

  @impl true
  def handle_info({:event_bus, topic, event}, state) do
    unless active?() do
      {:noreply, state}
    else
      rebroadcast(topic, event)
      {:noreply, %{state | rebroadcast_count: state.rebroadcast_count + 1}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Re-broadcast Logic -----------------------------------------------------

  defp rebroadcast("lifecycle:" <> _sub, %{type: type, data: data}) do
    agent_id = data[:agent_id]

    case type do
      t when t in ["RUN_STARTED"] ->
        agent = build_agent_map(agent_id, data, "active")
        Phoenix.PubSub.broadcast(@pubsub, "apm:agents", {:agent_registered, agent})

      t when t in ["RUN_FINISHED"] ->
        agent = build_agent_map(agent_id, data, "completed")
        Phoenix.PubSub.broadcast(@pubsub, "apm:agents", {:agent_updated, agent})

      t when t in ["RUN_ERROR"] ->
        agent = build_agent_map(agent_id, data, "error")
        Phoenix.PubSub.broadcast(@pubsub, "apm:agents", {:agent_updated, agent})

      t when t in ["STEP_STARTED", "STEP_FINISHED"] ->
        agent = build_agent_map(agent_id, data, "active")
        Phoenix.PubSub.broadcast(@pubsub, "apm:agents", {:agent_updated, agent})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp rebroadcast("special:custom", %{data: data}) do
    notif = %{
      title: get_in(data, [:value, :title]) || data[:name] || "AG-UI Event",
      message: get_in(data, [:value, :message]) || "",
      level: get_in(data, [:value, :level]) || "info",
      category: get_in(data, [:value, :category]) || "ag-ui",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Phoenix.PubSub.broadcast(@pubsub, "apm:notifications", {:notification_added, notif})
  rescue
    _ -> :ok
  end

  defp rebroadcast("state:" <> _sub, %{type: type, data: data}) do
    event_type =
      case type do
        "STATE_SNAPSHOT" -> :state_snapshot
        "STATE_DELTA" -> :state_delta
        _ -> :state_update
      end

    Phoenix.PubSub.broadcast(@pubsub, "dashboard:updates", {:ag_ui_dashboard, event_type, data})
  rescue
    _ -> :ok
  end

  defp rebroadcast(_topic, _event), do: :ok

  # -- Helpers ----------------------------------------------------------------

  defp build_agent_map(agent_id, data, status) do
    %{
      agent_id: agent_id,
      status: status,
      last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: data[:metadata],
      project: get_in(data, [:metadata, :project]),
      role: get_in(data, [:metadata, :role]) || get_in(data, [:metadata, :formation_role])
    }
  end
end
