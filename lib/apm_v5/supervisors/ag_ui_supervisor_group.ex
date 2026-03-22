defmodule ApmV5.Supervisors.AgUiSupervisorGroup do
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
      ApmV5.AgUiSupervisor,
      ApmV5.AgUi.StateManager,
      ApmV5.AgUi.ToolCallTracker,
      ApmV5.AgUi.DashboardStateSync,
      ApmV5.AgUi.ActivityTracker,
      ApmV5.AgentActivityLog,
      ApmV5.AgUi.MetricsBridge,
      ApmV5.AgUi.AuditBridge,
      ApmV5.AgUi.EventBusHealth,
      ApmV5.AgUi.GenerativeUI.Registry,
      ApmV5.AgUi.ApprovalGate,
      ApmV5.AgUi.A2A.Router,
      ApmV5.ChatStore
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
