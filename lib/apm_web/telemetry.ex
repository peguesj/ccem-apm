defmodule ApmWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor that attaches Phoenix and VM metrics reporters.

  Configures Telemetry.Metrics and attaches them to the Phoenix.LiveDashboard
  metrics reporter for real-time performance monitoring.

  ## Prometheus reporter (obs-s2 / CP-217)

  `Apm.Metrics` is started here as a supervised `Peep` reporter child.
  The peep ETS storage backing `:ccem_apm_metrics` is scraped via
  `Peep.Plug` mounted at `/metrics` in the router.

  ## Governance KRI metrics (comp-ms1 / CP-232 / US-464)

  Six `ccem_governance_*` counters and a last_value metric are declared below.
  They correspond to `:telemetry.execute/3` call sites in:

    - `Apm.Auth.AuthorizationGate`   — denial_rate, escalation_rate
    - `Apm.Auth.PolicyEngine`        — critical_command_rate
    - `Apm.Auth.ContextTracker`      — trust_degradation_events
    - `Apm.Auth.PolicyRulesStore`    — policy_rule_changes
    - `Apm.Governance.GovernanceKriPoller` — risk_score_p95 (60s periodic)

  These metrics flow through Peep and are exposed at `/metrics`.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller — periodic VM measurements every 10 s.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Peep Prometheus reporter — serves ccem_apm_* metrics at /metrics.
      # Named :ccem_apm_metrics so Peep.Plug can resolve it by name.
      Apm.Metrics.child_spec()
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # ── Governance KRI metrics (comp-ms1 / CP-232 / US-464) ─────────────────
      # Counter: total policy denials across the lifetime of the node.
      counter("apm.governance.denial_rate",
        event_name: [:apm, :governance, :denial_rate],
        measurement: :count,
        description: "ccem_governance_denial_rate — tool-call denials by PolicyEngine",
        tags: [:tool_name, :agent_id]
      ),

      # Counter: total escalations queued for human approval.
      counter("apm.governance.escalation_rate",
        event_name: [:apm, :governance, :escalation_rate],
        measurement: :count,
        description: "ccem_governance_escalation_rate — approvals queued (no auto-policy match)",
        tags: [:tool_name, :agent_id]
      ),

      # Counter: total Bash commands classified as :critical risk.
      counter("apm.governance.critical_command_rate",
        event_name: [:apm, :governance, :critical_command_rate],
        measurement: :count,
        description:
          "ccem_governance_critical_command_rate — destructive / :critical Bash commands",
        tags: [:tool_name, :agent_id]
      ),

      # Counter: total trust degradation events across all sessions.
      counter("apm.governance.trust_degradation_events",
        event_name: [:apm, :governance, :trust_degradation_events],
        measurement: :count,
        description:
          "ccem_governance_trust_degradation_events — session trust ceiling downgrades",
        tags: [:session_id]
      ),

      # Counter: total policy rule create/update/delete mutations.
      counter("apm.governance.policy_rule_changes",
        event_name: [:apm, :governance, :policy_rule_changes],
        measurement: :count,
        description: "ccem_governance_policy_rule_changes — PolicyRulesStore mutations",
        tags: [:tool_name, :change_type]
      ),

      # Last value: p95 risk severity score (0.0 – 4.0), updated every 60s.
      last_value("apm.governance.risk_score_p95",
        event_name: [:apm, :governance, :risk_score_p95],
        measurement: :value,
        description:
          "ccem_governance_risk_score_p95 — p95 risk severity across PolicyDecisionStore (60s window)"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {ApmWeb, :count_users, []}
    ]
  end
end
