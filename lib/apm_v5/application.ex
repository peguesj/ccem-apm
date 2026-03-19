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

    # Initialize LifecycleMapper ETS tables before supervision tree starts
    ApmV5.AgUi.LifecycleMapper.init_tables()

    children = [
      ApmV5Web.Telemetry,
      {DNSCluster, query: Application.get_env(:apm_v5, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ApmV5.PubSub},
      ApmV5.ConfigLoader,
      ApmV5.DashboardStore,
      ApmV5.AuditLog,
      ApmV5.ProjectStore,
      ApmV5.AgentRegistry,
      ApmV5.UpmStore,
      ApmV5.SkillTracker,
      ApmV5.MetricsCollector,
      ApmV5.SloEngine,
      ApmV5.AgentDiscovery,
      ApmV5.EnvironmentScanner,
      ApmV5.IntakeSupervisor,
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
      ApmV5.ShowcaseDataStore,
      ApmV5.AgUiSupervisor,
      ApmV5.AgUi.StateManager,
      # Wave 2: Tool call lifecycle (US-010)
      ApmV5.AgUi.ToolCallTracker,
      # Wave 2: Dashboard state sync (US-015)
      ApmV5.AgUi.DashboardStateSync,
      # Wave 2: Activity tracking (US-016)
      ApmV5.AgUi.ActivityTracker,
      # Activity log ring buffer (showcase Activity tab)
      ApmV5.AgentActivityLog,
      # Wave 2: Metrics bridge (US-039)
      ApmV5.AgUi.MetricsBridge,
      # Wave 2: Audit bridge (US-040)
      ApmV5.AgUi.AuditBridge,
      # Wave 2: EventBus health (US-041)
      ApmV5.AgUi.EventBusHealth,
      # Wave 3: Generative UI registry (US-022)
      ApmV5.AgUi.GenerativeUI.Registry,
      # Wave 3: Approval gate (US-026)
      ApmV5.AgUi.ApprovalGate,
      # Wave 4: A2A messaging router (US-031)
      ApmV5.AgUi.A2A.Router,
      ApmV5.ChatStore,
      # Claude usage tracking (US-042)
      ApmV5.ClaudeUsageStore,
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
