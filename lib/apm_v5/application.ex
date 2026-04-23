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
      # Boot reporter -- must start BEFORE StatusCache so it captures apm:boot events
      ApmV5.Telemetry.BootReporter,
      # Status cache -- 1s TTL ETS cache for /api/status + /api/health hot paths
      ApmV5.StatusCache,
      # Dashboard snapshot cache -- 2s TTL preloaded mount data (US-603)
      ApmV5.DashboardData,
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
      ApmV5.ConversationReader,
      ApmV5.PluginScanner,
      ApmV5.BackfillStore,
      ApmV5.SkillsRegistryStore,
      ApmV5.ShowcaseDataStore,
      # --- APM-001 Phase 1: Safe re-enables (pure ETS/supervisor init, no I/O) ---
      ApmV5.Supervisors.AgUiSupervisorGroup,
      ApmV5.ClaudeUsageStore,
      ApmV5.NamespaceResolver,
      ApmV5.Plugins.PluginSupervisor,
      ApmV5.Integrations.IntegrationSupervisor,
      ApmV5.AgUi.AgentContextStore,
      ApmV5.Upm.DecisionGate,
      ApmV5.Supervisors.AuthSupervisor,
      ApmV5.WorktreeStore,
      ApmV5.Architectures.ArchitectureStore,
      ApmV5.HookRegistry,
      ApmV5.Proxy.Supervisor,
      # --- APM-001 Phase 2: Deferred I/O (filesystem scans, module loading) ---
      ApmV5.Skills.SkillAnalyzer,
      ApmV5.Skills.SkillHealthScorer,
      ApmV5.Showcases.ShowcaseManager,
      ApmV5.Plugins.ClaudeCodePluginBridge,
      ApmV5.Plugins.PluginRepositoryStore,
      ApmV5.Plugins.PluginConfigStore,
      ApmV5.Plugins.PluginRegistry,
      ApmV5.Integrations.IntegrationRegistry,
      ApmV5.WidgetRegistry,
      ApmV5.LayoutStore,
      ApmV5.WidgetConfigStore,
      ApmV5.DashboardScopeEngine,
      # --- APM-001: Still disabled (boot-blocking or heavy external I/O) ---
      ApmV5.SessionManager,        # Re-enabled: deferred poll + exit-safe enrichment (APM-001)
      # ApmV5.PlanePmAlign,        # Blocking Plane API HTTP calls on init
      # ApmV5.LibraryStore,        # CPU/I/O intensive full-ecosystem scan
      # --- End APM-001 ---
      # Outbound relay tunnel -- dials Azure relay when TUNNEL_RELAY_URL is set (v8.5.0)
      ApmV5.Tunnel.Supervisor,
      # Orchestration system (v9.1.1)
      ApmV5.WorkflowRegistry,
      ApmV5.Orchestration.OrchestrationManager,
      ApmV5.Orchestration.OrchestrationRunStore,
      # Memory plugin workers (claude-mem integration)
      ApmV5.Plugins.Memory.MemoryClientBridge,
      ApmV5.Plugins.Memory.ObservationCache,
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
