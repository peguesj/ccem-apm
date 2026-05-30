defmodule Apm.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:apm, :server_start_time, System.monotonic_time(:second))
    :inets.start()
    :ssl.start()

    # Attach default telemetry logger handlers (v8.12.1)
    _ = Apm.Instrumentation.attach_default_handlers()

    # v9.3.0 Observability: wire OTel instrumentation for Bandit + Phoenix
    # Must run BEFORE the endpoint supervisor child starts accepting connections.
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)

    # Initialize LifecycleMapper ETS tables before supervision tree starts
    Apm.AgUi.LifecycleMapper.init_tables()

    # Initialize artifact attestation ETS ring buffer before AuditLog starts
    Apm.Provenance.ArtifactAttestation.init_table()

    # Initialize WebAuthn credentials ETS (v10.3.0 auth-v10.3-s1 / CP-298)
    Apm.Auth.WebAuthnAttestation.init_table()

    children = [
      # PlugAttack ETS storage -- must start before the endpoint to ensure the
      # table exists when the first request hits ApmWeb.Plugs.RateLimit.
      {PlugAttack.Storage.Ets, name: Apm.RateLimit.ETS, clean_period: 60_000},
      # auth-v10.2-s1 (CP-296): Explicit ETS backend submodule (always started regardless of backend config)
      Apm.RateLimit.EtsBackend,
      ApmWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:apm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Apm.PubSub},
      # coord-v10.0-d2 (CP-289) [BREAKING]: libcluster topology supervisor
      # Starts the configured cluster strategy (DNS/Gossip/etc.). Default topology
      # is [] (no-op) so existing single-node deployments are unaffected.
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: Apm.ClusterSupervisor]]},
      # coord-v10.0-d2 (CP-289): Horde.Registry as a SIBLING to AgentRegistry (ETS).
      # Does NOT replace Apm.AgentRegistry. Both run concurrently.
      # Config flag :agent_registry_backend selects which backend the public API uses.
      # Full ETS→Horde migration is a separate breaking story for the v10.0.0 ship.
      Apm.AgentRegistry.Horde,
      # Unified concurrency layer -- supervised fire-and-forget task pool (v8.12.1)
      Apm.ConcurrencyLayer,
      # Priority job queue with exponential backoff retry (v8.12.1)
      Apm.JobQueue,
      # Sub-supervisor: core infrastructure (ConfigLoader, DashboardStore, AuditLog, etc.)
      Apm.Supervisors.CoreSupervisor,
      # Boot reporter -- must start BEFORE StatusCache so it captures apm:boot events
      Apm.Telemetry.BootReporter,
      # Status cache -- 1s TTL ETS cache for /api/status + /api/health hot paths
      Apm.StatusCache,
      # Dashboard snapshot cache -- 2s TTL preloaded mount data (US-603)
      Apm.DashboardData,
      # Remaining top-level GenServers (no logical grouping)
      Apm.SkillTracker,
      Apm.MetricsCollector,
      Apm.SloEngine,
      Apm.AgentDiscovery,
      Apm.EnvironmentScanner,
      Apm.IntakeSupervisor,
      Apm.WorkflowSchemaStore,
      Apm.SkillHookDeployer,
      Apm.VerifyStore,
      Apm.BackgroundTasksStore,
      Apm.ProjectScanner,
      # UPM module GenServers (upm-module-ccem-apm): PM/VCS integrations, work items, sync
      Apm.UPM.ProjectRegistry,
      Apm.UPM.PMIntegrationStore,
      Apm.UPM.VCSIntegrationStore,
      Apm.UPM.WorkItemStore,
      Apm.UPM.SyncEngine,
      Apm.ActionEngine,
      Apm.AnalyticsStore,
      Apm.HealthCheckRunner,
      Apm.ConversationWatcher,
      Apm.ConversationReader,
      Apm.PluginScanner,
      Apm.BackfillStore,
      Apm.SkillsRegistryStore,
      Apm.ShowcaseDataStore,
      # --- APM-001 Phase 1: Safe re-enables (pure ETS/supervisor init, no I/O) ---
      Apm.Supervisors.AgUiSupervisorGroup,
      Apm.ClaudeUsageStore,
      Apm.NamespaceResolver,
      Apm.Plugins.PluginSupervisor,
      Apm.Integrations.IntegrationSupervisor,
      Apm.AgUi.AgentContextStore,
      Apm.Upm.DecisionGate,
      Apm.Supervisors.AuthSupervisor,
      Apm.WorktreeStore,
      Apm.Architectures.ArchitectureStore,
      Apm.HookRegistry,
      Apm.Proxy.Supervisor,
      # --- APM-001 Phase 2: Deferred I/O (filesystem scans, module loading) ---
      Apm.Skills.SkillAnalyzer,
      Apm.Skills.SkillHealthScorer,
      Apm.Showcases.ShowcaseManager,
      Apm.Plugins.ClaudeCodePluginBridge,
      Apm.Plugins.PluginRepositoryStore,
      Apm.Plugins.PluginConfigStore,
      Apm.Plugins.PluginRegistry,
      Apm.Integrations.IntegrationRegistry,
      Apm.WidgetRegistry,
      Apm.LayoutStore,
      Apm.WidgetConfigStore,
      Apm.DashboardScopeEngine,
      # --- APM-001: Still disabled (boot-blocking or heavy external I/O) ---
      Apm.SessionManager,        # Re-enabled: deferred poll + exit-safe enrichment (APM-001)
      # Apm.PlanePmAlign,        # Blocking Plane API HTTP calls on init
      # Apm.LibraryStore,        # CPU/I/O intensive full-ecosystem scan
      # --- End APM-001 ---
      # Outbound relay tunnel -- dials Azure relay when TUNNEL_RELAY_URL is set (v8.5.0)
      Apm.Tunnel.Supervisor,
      # Orchestration system (v9.1.1)
      Apm.WorkflowRegistry,
      Apm.Orchestration.OrchestrationManager,
      Apm.Orchestration.OrchestrationRunStore,
      # Formation WAL persistence store (wf-s3)
      Apm.Orchestration.FormationPersistenceStore,
      # Coalesce subsystem — DecisionGateStore + CoalesceOrchestrator
      Apm.Coalesce.CoalesceSupervisor,
      # Memory plugin workers (claude-mem integration)
      Apm.Plugins.Memory.MemoryClientBridge,
      Apm.Plugins.Memory.ObservationCache,
      # Harness plugin workers (Claude Code harness runtime monitor)
      Apm.Plugins.Harness.HarnessMonitor,
      Apm.Plugins.Harness.HookTelemetryBuffer,
      # LFG BTAU plugin — ref-counted sparsebundle mount manager
      Apm.Plugins.LfgBtau.MountManager,
      # Hook repair v2 workers (ActionRunStore + HookHealthMonitor)
      {Task.Supervisor, name: Apm.ActionRunStore.TaskSupervisor},
      Apm.ActionRunStore,
      Apm.HookHealthMonitor,
      # Cloak AES-256-GCM vault — audit PII encryption at rest (comp-mg2 / CP-235)
      Apm.Governance.Vault,
      # Governance KRI poller — emits risk_score_p95 telemetry every 60s (comp-ms1 / CP-232)
      Apm.Governance.GovernanceKriPoller,
      # ComplianceReportEngine cache Agent — 5-min TTL posture reports (comp-ms2 / CP-233)
      Apm.Governance.ComplianceReportEngine,
      # IncidentResponseEngine — circuit breaker on policy risk bursts (comp-mg1 / CP-234)
      Apm.Governance.IncidentResponseEngine,
      # A2A artifact CAS store (coord-c3)
      Apm.A2A.ArtifactVersionStore,
      # A2A pessimistic file lock registry (coord-c2)
      Apm.A2A.FileLockRegistry,
      # Identity: Ed25519 KeyStore — persists APM signing keypair (prov-w1-s1 / CP-275)
      Apm.Identity.KeyStore,
      # Identity: AgentRoleIndex — deterministic UUID v5 role identity (prov-w2-s5 / CP-279)
      Apm.Identity.AgentRoleIndex,
      # Provenance: LineageTracker — wasDerivedFrom edges via tool-call hashes (prov-w2-s6 / CP-280)
      Apm.Provenance.LineageTracker,
      # Start to serve requests, typically the last entry
      ApmWeb.Endpoint
    ]

    # Install fuse circuit breakers before supervision tree starts --
    # fuse uses ETS internally so this is a synchronous, side-effect-free
    # operation that must complete before the endpoint begins handling requests.
    install_circuit_breakers()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Apm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Install fuse circuit breakers for hot-path API endpoints.
  #
  # Thresholds (generous to avoid false trips on legitimate agent formations):
  #   :apm_register_fuse  — 500 failures / 10 s window, reset after 30 s
  #   :apm_heartbeat_fuse — 1000 failures / 10 s window, reset after 15 s
  #   :apm_notify_fuse    — 300 failures / 10 s window, reset after 30 s
  defp install_circuit_breakers do
    :fuse.install(:apm_register_fuse, {{:standard, 500, 10_000}, {:reset, 30_000}})
    :fuse.install(:apm_heartbeat_fuse, {{:standard, 1000, 10_000}, {:reset, 15_000}})
    :fuse.install(:apm_notify_fuse, {{:standard, 300, 10_000}, {:reset, 30_000}})
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ApmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
