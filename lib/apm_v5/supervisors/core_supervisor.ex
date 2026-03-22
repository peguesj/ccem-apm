defmodule ApmV5.Supervisors.CoreSupervisor do
  @moduledoc """
  Supervises core infrastructure GenServers: configuration loading,
  dashboard state, audit logging, project/agent/UPM registries,
  port management, and documentation store.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.ConfigLoader,
      ApmV5.DashboardStore,
      ApmV5.AuditLog,
      ApmV5.ProjectStore,
      ApmV5.AgentRegistry,
      ApmV5.UpmStore,
      ApmV5.PortManager,
      ApmV5.DocsStore
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
