defmodule ApmV5.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:apm_v5, :server_start_time, System.monotonic_time(:second))
    :inets.start()
    :ssl.start()

    children = [
      ApmV5Web.Telemetry,
      {DNSCluster, query: Application.get_env(:apm_v5, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ApmV5.PubSub},
      ApmV5.ConfigLoader,
      ApmV5.DashboardStore,
      ApmV5.ApiKeyStore,
      ApmV5.AuditLog,
      ApmV5.ProjectStore,
      ApmV5.AgentRegistry,
      ApmV5.UpmStore,
      ApmV5.SkillTracker,
      ApmV5.AlertRulesEngine,
      ApmV5.MetricsCollector,
      ApmV5.SloEngine,
      ApmV5.EventStream,
      ApmV5.AgentDiscovery,
      ApmV5.EnvironmentScanner,
      ApmV5.CommandRunner,
      ApmV5.DocsStore,
      ApmV5.PortManager,
      ApmV5.WorkflowSchemaStore,
      ApmV5.SkillHookDeployer,
      ApmV5.VerifyStore,
      ApmV5.BackgroundTasksStore,
      ApmV5.ProjectScanner,
      ApmV5.ActionEngine,
      ApmV5.AnalyticsStore,
      ApmV5.HealthCheckRunner,
      ApmV5.ConversationWatcher,
      ApmV5.PluginScanner,
      ApmV5.BackfillStore,
      ApmV5.SkillsRegistryStore,
      ApmV5.AgUi.StateManager,
      ApmV5.AgUi.EventRouter,
      ApmV5.ChatStore,
      {ApmV5.Intake.Store, []},
      ApmV5.UatRunner,
      # Start to serve requests, typically the last entry
      ApmV5Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ApmV5.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ApmV5Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
