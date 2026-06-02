defmodule Apm.Supervisors.CoreSupervisor do
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
      Apm.ConfigLoader,
      Apm.DashboardStore,
      Apm.AuditLog,
      Apm.ProjectStore,
      Apm.AgentRegistry,
      Apm.UpmStore,
      Apm.PortManager,
      Apm.DocsStore
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
