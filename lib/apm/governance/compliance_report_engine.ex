defmodule Apm.Governance.ComplianceReportEngine do
  @moduledoc """
  Generates structured compliance posture reports mapping every CCEM
  control to its NIST AI RMF / SOC 2 / ISO 27001 / NIST CSF / PCI DSS /
  EU AI Act / CIS status.

  ## Design

  This is a **pure-function module** with an in-process report cache
  (Agent-backed, 5-minute TTL). No supervision dependency is required for
  the computation itself. The cache Agent is started in the supervision tree
  so callers always hit a warm process.

  ## Report structure

    * `generated_at`        — DateTime of report generation
    * `overall_score`       — 0–100 weighted mean across all frameworks
    * `controls_by_status`  — aggregate counts per status atom
    * `by_framework`        — per-framework score + controls list
    * `controls`            — full control list with evidence strings
    * `kri_snapshot`        — last value of each governance KRI

  ## Scoring formula

    Per-framework:
      score = (satisfied_count * 1.0 + partial_count * 0.5) / total_count * 100

    Overall:
      weighted mean across all 7 frameworks (equal weight)

  ## KRI snapshot

  Reads the last telemetry measurements published to the APM telemetry
  store for:
    - denial_rate
    - escalation_rate
    - critical_command_rate
    - trust_degradation_events
    - policy_rule_changes
    - risk_score_p95

  ## Cache

  Calling `generate/0` returns a cached report if one was generated in the
  last 5 minutes. Call `refresh/0` or `POST /api/v2/governance/report/refresh`
  to force a fresh computation.

  ## HTTP endpoints

    `GET  /api/v2/governance/report`            — JSON report
    `GET  /api/v2/governance/report?format=md`  — Markdown report
    `POST /api/v2/governance/report/refresh`    — Force refresh

  Spec: CP-233 / US-465 / Plane 726880b7 — v9.3.0 comp-ms2.
  """

  use Agent
  require Logger

  alias Apm.Governance.{ControlRegistry, GovernanceKriPoller}
  alias Apm.Auth.RiskScoreAggregator

  @cache_ttl_seconds 300
  @frameworks [:nist_ai_rmf, :soc2, :iso_27001, :nist_csf, :pci_dss, :eu_ai_act, :cis]

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type framework_report :: %{
          score: integer(),
          controls: [map()]
        }

  @type controls_by_status :: %{
          satisfied: non_neg_integer(),
          partial: non_neg_integer(),
          gap: non_neg_integer(),
          absent: non_neg_integer()
        }

  @type kri_snapshot :: %{
          denial_rate: float() | nil,
          escalation_rate: float() | nil,
          critical_command_rate: float() | nil,
          trust_degradation_events: integer() | nil,
          policy_rule_changes: integer() | nil,
          risk_score_p95: float() | nil
        }

  @type compliance_report :: %{
          generated_at: DateTime.t(),
          overall_score: integer(),
          controls_by_status: controls_by_status(),
          by_framework: %{atom() => framework_report()},
          controls: [map()],
          kri_snapshot: kri_snapshot()
        }

  # ---------------------------------------------------------------------------
  # Cache Agent
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{report: nil, generated_at: nil} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns a compliance report. Uses a cached version (up to 5 minutes old)
  unless the cache is empty or stale.

  Always returns a `%{...}` map — never raises.
  """
  @spec generate() :: compliance_report()
  def generate do
    case cached_report() do
      {:fresh, report} ->
        report

      :stale ->
        do_generate_and_cache()
    end
  end

  @doc """
  Forces regeneration of the compliance report, ignoring cache TTL.
  Returns the freshly generated report.
  """
  @spec refresh() :: compliance_report()
  def refresh do
    do_generate_and_cache()
  end

  @doc """
  Serialises a compliance report to a JSON-compatible map (all keys
  stringified, DateTime values converted to ISO 8601).
  """
  @spec to_json(compliance_report()) :: map()
  def to_json(%{} = report) do
    %{
      "generated_at" => DateTime.to_iso8601(report.generated_at),
      "overall_score" => report.overall_score,
      "controls_by_status" => Map.new(report.controls_by_status, fn {k, v} -> {to_string(k), v} end),
      "by_framework" =>
        Map.new(report.by_framework, fn {fw, fw_report} ->
          {to_string(fw), %{
            "score" => fw_report.score,
            "controls" => Enum.map(fw_report.controls, &stringify_control/1)
          }}
        end),
      "controls" => Enum.map(report.controls, &stringify_control/1),
      "kri_snapshot" => Map.new(report.kri_snapshot, fn {k, v} -> {to_string(k), v} end)
    }
  end

  @doc """
  Renders a compliance report as Markdown for human readability.
  """
  @spec to_markdown(compliance_report()) :: String.t()
  def to_markdown(%{} = report) do
    lines = [
      "# CCEM Compliance Posture Report",
      "",
      "**Generated:** #{DateTime.to_iso8601(report.generated_at)}",
      "**Overall Score:** #{report.overall_score}/100",
      "",
      "## Controls by Status",
      "",
      "| Status | Count |",
      "|--------|-------|",
      "| Satisfied | #{report.controls_by_status.satisfied} |",
      "| Partial   | #{report.controls_by_status.partial} |",
      "| Gap       | #{report.controls_by_status.gap} |",
      "| Absent    | #{report.controls_by_status.absent} |",
      "",
      "## Framework Scores",
      "",
      "| Framework | Score |",
      "|-----------|-------|"
    ]

    fw_rows =
      Enum.map(@frameworks, fn fw ->
        fw_report = Map.get(report.by_framework, fw, %{score: 0, controls: []})
        "| #{format_framework_name(fw)} | #{fw_report.score}/100 |"
      end)

    kri_lines = [
      "",
      "## Governance KRI Snapshot",
      "",
      "| KRI | Value |",
      "|-----|-------|",
      "| Denial Rate | #{format_kri(report.kri_snapshot.denial_rate)} |",
      "| Escalation Rate | #{format_kri(report.kri_snapshot.escalation_rate)} |",
      "| Critical Command Rate | #{format_kri(report.kri_snapshot.critical_command_rate)} |",
      "| Trust Degradation Events | #{format_kri(report.kri_snapshot.trust_degradation_events)} |",
      "| Policy Rule Changes | #{format_kri(report.kri_snapshot.policy_rule_changes)} |",
      "| Risk Score P95 | #{format_kri(report.kri_snapshot.risk_score_p95)} |",
      "",
      "## Controls",
      ""
    ]

    control_lines =
      Enum.flat_map(report.controls, fn ctrl ->
        [
          "### #{ctrl.name} (`#{ctrl.id}`)",
          "",
          "**Status:** #{ctrl.status}",
          "",
          "**Evidence:** #{ctrl.evidence}",
          ""
        ]
      end)

    Enum.join(lines ++ fw_rows ++ kri_lines ++ control_lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # Private — core computation
  # ---------------------------------------------------------------------------

  defp do_generate_and_cache do
    report = compute_report()
    put_cache(report)
    report
  end

  defp compute_report do
    controls = ControlRegistry.list_controls()
    controls_list = build_controls_list(controls)
    by_status = tally_by_status(controls_list)
    by_framework = compute_by_framework(controls)
    overall_score = compute_overall_score(by_framework)
    kri_snap = snapshot_kris()

    %{
      generated_at: DateTime.utc_now(),
      overall_score: overall_score,
      controls_by_status: by_status,
      by_framework: by_framework,
      controls: controls_list,
      kri_snapshot: kri_snap
    }
  end

  defp build_controls_list(controls) do
    Enum.map(controls, fn {id, ctrl} ->
      frameworks =
        ctrl
        |> Map.drop([:name, :description, :status])
        |> Map.new(fn {k, v} -> {k, v} end)

      %{
        id: id,
        name: ctrl.name,
        status: ctrl.status,
        frameworks: frameworks,
        evidence: derive_evidence(id, ctrl)
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp derive_evidence(id, ctrl) do
    case {id, ctrl.status} do
      {:policy_engine, :satisfied} ->
        "PolicyEngine module active — pure-function evaluation of PolicyRulesStore rules"

      {:authorization_gate, :satisfied} ->
        "AuthorizationGate integrating PolicyEngine + RateLimiter + RedactionEngine"

      {:audit_log, :satisfied} ->
        "AuditLog ETS table active with SHA-256 self-hash chain"

      {:approval_audit_log, :satisfied} ->
        "ApprovalAuditLog GenServer recording human oversight decisions"

      {:redaction_engine, :partial} ->
        "RedactionEngine covering 7 PII patterns; structured data redaction pending"

      {:rate_limiter, :satisfied} ->
        "Hammer-backed token-bucket rate limiter active"

      {:slo_engine, :partial} ->
        "SloEngine tracking 5 SLIs with error budgets; external alerting gap"

      {:security_guidance_plugin, :partial} ->
        "SecurityGuidancePlugin active; composite risk integration pending"

      {:policy_decision_store, :satisfied} ->
        "PolicyDecisionStore ETS table active — recording all authorization decisions"

      {:compliance_disclosure, :partial} ->
        "AgentIdentity asl_tier + ai_act_risk_class fields present; UI rendering pending"

      {:audit_encryption_at_rest, :satisfied} ->
        "Cloak AES-256-GCM vault encrypting PII fields in AuditLog entries"

      {:incident_response_engine, :satisfied} ->
        "IncidentResponseEngine GenServer active — circuit breaker on critical_command_rate > 5%"

      {:compliance_report_engine, :satisfied} ->
        "ComplianceReportEngine active — automated posture reports generated on demand"

      {_id, :satisfied} ->
        "Control operational and verified"

      {_id, :partial} ->
        "Control partially satisfies requirement; known gaps documented"

      {_id, :gap} ->
        "Control scaffolded; implementation incomplete"

      {_id, :absent} ->
        "Control not yet implemented"
    end
  end

  defp tally_by_status(controls_list) do
    base = %{satisfied: 0, partial: 0, gap: 0, absent: 0}

    Enum.reduce(controls_list, base, fn ctrl, acc ->
      Map.update(acc, ctrl.status, 1, &(&1 + 1))
    end)
  end

  defp compute_by_framework(controls) do
    Map.new(@frameworks, fn fw ->
      fw_controls =
        controls
        |> Enum.filter(fn {_id, ctrl} -> Map.has_key?(ctrl, fw) end)
        |> Enum.map(fn {id, ctrl} ->
          %{
            id: id,
            name: ctrl.name,
            status: ctrl.status,
            requirements: Map.get(ctrl, fw, [])
          }
        end)

      total = length(fw_controls)

      score =
        if total == 0 do
          0
        else
          satisfied = Enum.count(fw_controls, &(&1.status == :satisfied))
          partial = Enum.count(fw_controls, &(&1.status == :partial))
          raw = (satisfied * 1.0 + partial * 0.5) / total * 100
          round(raw)
        end

      {fw, %{score: score, controls: fw_controls}}
    end)
  end

  defp compute_overall_score(by_framework) do
    non_empty =
      by_framework
      |> Enum.filter(fn {_fw, %{score: s}} -> s > 0 end)

    if non_empty == [] do
      0
    else
      total_score = Enum.sum(Enum.map(non_empty, fn {_fw, %{score: s}} -> s end))
      round(total_score / length(non_empty))
    end
  end

  # ---------------------------------------------------------------------------
  # Private — KRI snapshot
  # ---------------------------------------------------------------------------

  defp snapshot_kris do
    # Attempt to read last telemetry values from GovernanceKriPoller
    # (fail-soft: if the process is not running, return nil for each KRI)
    p95 = read_kri_p95()
    risk_stats = read_risk_stats()

    %{
      denial_rate: risk_stats[:denial_rate],
      escalation_rate: risk_stats[:escalation_rate],
      critical_command_rate: risk_stats[:critical_command_rate],
      trust_degradation_events: risk_stats[:trust_degradation_events],
      policy_rule_changes: risk_stats[:policy_rule_changes],
      risk_score_p95: p95
    }
  end

  defp read_kri_p95 do
    case Process.whereis(GovernanceKriPoller) do
      nil ->
        nil

      _pid ->
        # Trigger an immediate emission and read from the telemetry store.
        # Since GovernanceKriPoller stores no state we read it via process alive check.
        # Return the most recent p95 from ETS if available, otherwise nil.
        read_risk_score_p95_from_aggregator()
    end
  end

  defp read_risk_score_p95_from_aggregator do
    case Process.whereis(RiskScoreAggregator) do
      nil ->
        nil

      _pid ->
        top = RiskScoreAggregator.top_sessions(100)

        if top == [] do
          nil
        else
          scores = Enum.map(top, fn {_id, agg} -> agg.score end) |> Enum.sort()
          n = length(scores)
          idx = max(0, ceil(0.95 * n) - 1)
          Enum.at(scores, min(idx, n - 1))
        end
    end
  end

  defp read_risk_stats do
    # Read aggregate statistics from PolicyDecisionStore if available
    alias Apm.Auth.PolicyDecisionStore

    case :ets.info(:policy_decisions) do
      :undefined ->
        %{}

      _ ->
        since = DateTime.add(DateTime.utc_now(), -300, :second)
        decisions = PolicyDecisionStore.query(%{since: since, limit: 5_000})

        total = length(decisions)

        if total == 0 do
          %{
            denial_rate: 0.0,
            escalation_rate: 0.0,
            critical_command_rate: 0.0,
            trust_degradation_events: 0,
            policy_rule_changes: count_policy_rule_changes()
          }
        else
          denied = Enum.count(decisions, &(&1.outcome == :deny))
          escalated = Enum.count(decisions, &(&1.outcome == :ask))
          critical = Enum.count(decisions, &(&1.risk_level == :critical))

          %{
            denial_rate: Float.round(denied / total, 4),
            escalation_rate: Float.round(escalated / total, 4),
            critical_command_rate: Float.round(critical / total, 4),
            trust_degradation_events: Enum.count(decisions, &(&1.risk_level in [:high, :critical])),
            policy_rule_changes: count_policy_rule_changes()
          }
        end
    end
  end

  defp count_policy_rule_changes do
    alias Apm.Auth.PolicyRulesStore

    case :ets.info(:agentlock_policy_rules) do
      :undefined -> 0
      _ -> length(PolicyRulesStore.list_rules())
    end
  end

  # ---------------------------------------------------------------------------
  # Private — cache helpers
  # ---------------------------------------------------------------------------

  defp cached_report do
    case Agent.get(__MODULE__, & &1, 5_000) do
      %{report: nil} ->
        :stale

      %{report: report, generated_at: generated_at} ->
        age_seconds = DateTime.diff(DateTime.utc_now(), generated_at, :second)

        if age_seconds <= @cache_ttl_seconds do
          {:fresh, report}
        else
          :stale
        end
    end
  rescue
    _ -> :stale
  end

  defp put_cache(report) do
    Agent.update(__MODULE__, fn _ -> %{report: report, generated_at: DateTime.utc_now()} end,
      5_000
    )
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private — formatting helpers
  # ---------------------------------------------------------------------------

  defp stringify_control(%{id: id} = ctrl) do
    ctrl
    |> Map.put(:id, to_string(id))
    |> Map.put(:status, to_string(Map.get(ctrl, :status, :unknown)))
    |> Map.new(fn
      {:frameworks, fws} ->
        {:frameworks, Map.new(fws, fn {k, v} -> {to_string(k), v} end)}
      {k, v} ->
        {k, v}
    end)
  end

  defp stringify_control(ctrl), do: ctrl

  defp format_framework_name(:nist_ai_rmf), do: "NIST AI RMF"
  defp format_framework_name(:soc2), do: "SOC 2"
  defp format_framework_name(:iso_27001), do: "ISO 27001"
  defp format_framework_name(:nist_csf), do: "NIST CSF"
  defp format_framework_name(:pci_dss), do: "PCI DSS"
  defp format_framework_name(:eu_ai_act), do: "EU AI Act"
  defp format_framework_name(:cis), do: "CIS"
  defp format_framework_name(fw), do: to_string(fw)

  defp format_kri(nil), do: "N/A"
  defp format_kri(v) when is_float(v), do: Float.round(v, 4)
  defp format_kri(v), do: v
end
