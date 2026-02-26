defmodule ApmV4.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:apm_v4, :server_start_time, System.monotonic_time(:second))

    children = [
      ApmV4Web.Telemetry,
      {DNSCluster, query: Application.get_env(:apm_v4, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ApmV4.PubSub},
      ApmV4.ConfigLoader,
      ApmV4.DashboardStore,
      ApmV4.ApiKeyStore,
      ApmV4.AuditLog,
      ApmV4.ProjectStore,
      ApmV4.AgentRegistry,
      ApmV4.UpmStore,
      ApmV4.SkillTracker,
      ApmV4.AlertRulesEngine,
      ApmV4.MetricsCollector,
      ApmV4.SloEngine,
      ApmV4.EventStream,
      ApmV4.AgentDiscovery,
      ApmV4.EnvironmentScanner,
      ApmV4.CommandRunner,
      ApmV4.DocsStore,
      ApmV4.PortManager,
      ApmV4.WorkflowSchemaStore,
      ApmV4.SkillHookDeployer,
      # Start to serve requests, typically the last entry
      ApmV4Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ApmV4.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ApmV4Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
