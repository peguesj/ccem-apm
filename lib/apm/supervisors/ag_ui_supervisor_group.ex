defmodule Apm.Supervisors.AgUiSupervisorGroup do
  @moduledoc """
  Supervises all AG-UI related GenServers: the existing AgUiSupervisor,
  state management, tool call tracking, dashboard sync, activity tracking,
  metrics/audit bridges, event bus health, generative UI, approval gate,
  A2A routing, and chat storage.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Apm.AgUiSupervisor,
      Apm.AgUi.StateManager,
      Apm.AgUi.ToolCallTracker,
      Apm.AgUi.DashboardStateSync,
      Apm.AgUi.ActivityTracker,
      Apm.AgentActivityLog,
      Apm.AgUi.MetricsBridge,
      Apm.AgUi.AuditBridge,
      Apm.AgUi.EventBusHealth,
      Apm.AgUi.GenerativeUI.Registry,
      Apm.AgUi.ApprovalGate,
      Apm.AgUi.A2A.TopicRegistry,
      Apm.AgUi.A2A.Router,
      # A2A v0.3.0 task lifecycle state machine (coord-b1)
      Apm.AgUi.A2A.TaskStore,
      # AG-UI lifecycle → A2A task state bridge (coord-b2)
      Apm.AgUi.A2A.TaskBridge,
      Apm.ChatStore
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
