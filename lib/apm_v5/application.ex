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

    # Attach default telemetry logger handlers (v8.12.1)
    _ = ApmV5.Instrumentation.attach_default_handlers()

    # Initialize LifecycleMapper ETS tables before supervision tree starts
    ApmV5.AgUi.LifecycleMapper.init_tables()

    children = [
      ApmV5Web.Telemetry,
      {DNSCluster, query: Application.get_env(:apm_v5, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ApmV5.PubSub},
      # Unified concurrency layer -- supervised fire-and-forget task pool (v8.12.1)
      ApmV5.ConcurrencyLayer,
      # Priority job queue with exponential backoff retry (v8.12.1)
      ApmV5.JobQueue,
      # Sub-supervisor: core infrastructure (ConfigLoader, DashboardStore, AuditLog, etc.)
      ApmV5.Supervisors.CoreSupervisor,
      # Status cache -- 1s TTL ETS cache for /api/status + /api/health hot paths
      ApmV5.StatusCache,
      # Remaining top-level GenServers (no logical grouping)
      ApmV5.SkillTracker,
      ApmV5.MetricsCollector,
      ApmV5.SloEngine,
      ApmV5.AgentDiscovery,
      ApmV5.EnvironmentScanner,
      ApmV5.IntakeSupervisor,
      ApmV5.WorkflowSchemaStore,
      ApmV5.SkillHookDeployer,
      ApmV5.VerifyStore,
      ApmV5.BackgroundTasksStore,
      ApmV5.ProjectScanner,
      # UPM module GenServers (upm-module-ccem-apm): PM/VCS integrations, work items, sync
      ApmV5.UPM.ProjectRegistry,
      ApmV5.UPM.PMIntegrationStore,
      ApmV5.UPM.VCSIntegrationStore,
      ApmV5.UPM.WorkItemStore,
      ApmV5.UPM.SyncEngine,
      ApmV5.ActionEngine,
      ApmV5.AnalyticsStore,
      ApmV5.HealthCheckRunner,
      ApmV5.ConversationWatcher,
      ApmV5.PluginScanner,
      ApmV5.BackfillStore,
      ApmV5.SkillsRegistryStore,
      ApmV5.ShowcaseDataStore,
      # Skill dependency analyzer -- scans ~/.claude/skills/ and ./commands/ (Phase 1: v1.0.0)
      ApmV5.Skills.SkillAnalyzer,
      # Skill health scorer -- 5-dimension health assessment (Phase 2: v1.0.0)
      ApmV5.Skills.SkillHealthScorer,
      # Showcase Manager -- discover/manage project showcases, integrate with UPM/Plane/Auth
      ApmV5.Showcases.ShowcaseManager,
      # Sub-supervisor: AG-UI protocol layer
      ApmV5.Supervisors.AgUiSupervisorGroup,
      # Claude usage tracking (US-042)
      ApmV5.ClaudeUsageStore,
      # Session Manager -- polls session JSON files, enriches with agents/ports/plugins
      ApmV5.SessionManager,
      # Namespace Resolver -- human-readable labels for agents/sessions/gates (v8.5.0)
      ApmV5.NamespaceResolver,
      # CC plugin bridge + repository store -- before PluginSupervisor/Registry
      ApmV5.Plugins.ClaudeCodePluginBridge,
      ApmV5.Plugins.PluginRepositoryStore,
      # Plugin Engine (v8.0.0) -- supervisor before registry
      ApmV5.Plugins.PluginSupervisor,
      ApmV5.Plugins.PluginRegistry,
      # Integration Engine (v8.0.0) -- supervisor before registry
      ApmV5.Integrations.IntegrationSupervisor,
      ApmV5.Integrations.IntegrationRegistry,
      # Agent context store -- real-time AG-UI context per agent (v8.4.0)
      ApmV5.AgUi.AgentContextStore,
      # UPM decision gate -- blocking human-in-the-loop approval (v8.4.0)
      ApmV5.Upm.DecisionGate,
      # Sub-supervisor: AgentLock authorization layer (v7.0.0)
      ApmV5.Supervisors.AuthSupervisor,
      # Persistent Plane-PM alignment agent -- polls Plane every 5min, broadcasts plane:sync (US-018)
      ApmV5.PlanePmAlign,
      # Library catalog -- scans skills/agents/commands/MCP/hooks/patterns/learnings (v8.10.1)
      ApmV5.LibraryStore,
      # Dashboard widget system -- WidgetRegistry + LayoutStore (widget-system)
      ApmV5.WidgetRegistry,
      ApmV5.LayoutStore,
      # Outbound relay tunnel -- dials Azure relay when TUNNEL_RELAY_URL is set (v8.5.0)
      ApmV5.Tunnel.Supervisor,
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
