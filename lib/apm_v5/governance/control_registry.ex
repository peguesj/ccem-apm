defmodule ApmV5.Governance.ControlRegistry do
  @moduledoc """
  Static registry mapping CCEM controls to compliance framework identifiers.

  ## What is a control?

  A "control" in CCEM terms is an existing subsystem (GenServer, module, or
  plug) that satisfies one or more requirements from external governance
  frameworks such as NIST AI RMF, SOC 2, ISO 27001, NIST CSF, and the EU
  AI Act. This module is the single source of truth for which CCEM component
  satisfies which framework requirement.

  ## Design

  This is a **static module** — no GenServer, no ETS. Controls are declared at
  compile time via the `@controls` module attribute. Consumers call
  `list_controls/0`, `get_control/1`, or `controls_by_framework/2` at runtime.
  Because the data never changes between deploys, an in-process map is the
  correct OTP primitive (zero overhead, no supervision dependency).

  ## Status values

    * `:satisfied` — the control fully meets the referenced framework requirement
    * `:partial`   — the control provides meaningful coverage but has known gaps
    * `:gap`       — the control is scaffolded or planned but not yet implemented

  ## Adding a control

  Add a new entry to `@controls`. Rebuild with `mix compile`. The HTTP endpoint
  at `GET /api/v2/governance/controls` picks it up automatically.

  ## Framework identifiers used

  | Framework    | Format examples                              |
  |--------------|----------------------------------------------|
  | NIST AI RMF  | `"GV-1.1"`, `"MAP-1.5"`, `"MG-1.1"`        |
  | SOC 2        | `"CC6.1"`, `"CC6.2"`, `"CC7.1"`            |
  | ISO 27001    | `"A.9"`, `"A.8.15"`, `"A.5.9"`             |
  | NIST CSF     | `"PROTECT"`, `"DETECT"`, `"RESPOND"`        |
  | PCI DSS      | `"Req 10"`                                  |
  | EU AI Act    | `"Article 13"`, `"Article 14"`              |
  | CIS          | `"CIS-3"`                                   |

  Spec: CP-229 / US-461 / Plane df4af43a
  """

  @type framework :: :nist_ai_rmf | :soc2 | :iso_27001 | :nist_csf | :pci_dss | :eu_ai_act | :cis

  @type control_id :: atom()

  @type control :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:status) => :satisfied | :partial | :gap,
          optional(:nist_ai_rmf) => [String.t()],
          optional(:soc2) => [String.t()],
          optional(:iso_27001) => [String.t()],
          optional(:nist_csf) => [String.t()],
          optional(:pci_dss) => [String.t()],
          optional(:eu_ai_act) => [String.t()],
          optional(:cis) => [String.t()]
        }

  # ---------------------------------------------------------------------------
  # Control declarations
  # ---------------------------------------------------------------------------

  @controls %{
    policy_engine: %{
      name: "PolicyEngine",
      description:
        "Pure-function policy evaluation pipeline. Evaluates tool-call authorization " <>
          "requests against rule sets stored in PolicyRulesStore. Covers " <>
          "GOVERN (NIST AI RMF), access control (SOC 2 CC6.1), and access " <>
          "management policy (ISO 27001 A.9).",
      status: :satisfied,
      nist_ai_rmf: ["GV-1.1", "GV-2.1"],
      soc2: ["CC6.1"],
      iso_27001: ["A.9"]
    },
    authorization_gate: %{
      name: "AuthorizationGate",
      description:
        "Runtime enforcement point for tool-call authorization. Integrates " <>
          "PolicyEngine, RateLimiter, and RedactionEngine into a single decision " <>
          "path. Satisfies logical access controls across SOC 2 CC6.x and the " <>
          "NIST CSF PROTECT function.",
      status: :satisfied,
      soc2: ["CC6.1", "CC6.2", "CC6.3"],
      nist_csf: ["PROTECT"]
    },
    audit_log: %{
      name: "AuditLog",
      description:
        "Append-only ETS audit log with SHA-256 self-hash chain (v9.2.1). " <>
          "Provides tamper-evident event history for all authorization decisions. " <>
          "Satisfies ISO 27001 A.8.15 (logging), SOC 2 CC7.1 (monitoring), and " <>
          "PCI DSS Requirement 10 (audit trails).",
      status: :satisfied,
      iso_27001: ["A.8.15"],
      soc2: ["CC7.1"],
      pci_dss: ["Req 10"]
    },
    approval_audit_log: %{
      name: "ApprovalAuditLog",
      description:
        "Dedicated audit log for human-in-the-loop approval decisions. " <>
          "Captures approver identity, decision rationale, and timestamps. " <>
          "Satisfies EU AI Act Article 14 (human oversight of AI systems) and " <>
          "NIST AI RMF MG-1.1 (manage AI risks with human review).",
      status: :satisfied,
      eu_ai_act: ["Article 14"],
      nist_ai_rmf: ["MG-1.1"]
    },
    redaction_engine: %{
      name: "RedactionEngine",
      description:
        "PII detection and redaction for tool parameters and outputs. " <>
          "Currently covers 7 PII patterns (SSN, email, phone, credit card, " <>
          "IP address, date of birth, passport). Partially satisfies CIS Control 3 " <>
          "(data protection). Gaps: structured data redaction, format-preserving " <>
          "encryption, and coverage of non-English PII patterns.",
      status: :partial,
      cis: ["CIS-3"]
    },
    rate_limiter: %{
      name: "RateLimiter",
      description:
        "Token-bucket rate limiter for tool-call authorization requests. " <>
          "Migrated to Hammer (v9.2.0). Provides anomaly detection signal for " <>
          "the NIST CSF DETECT function. Fully operational post-Hammer migration.",
      status: :satisfied,
      nist_csf: ["DETECT"]
    },
    slo_engine: %{
      name: "SloEngine",
      description:
        "Tracks 5 Service Level Indicators (error rate, latency p95, " <>
          "availability, throughput, saturation) with error budget calculation. " <>
          "Partially satisfies NIST CSF DETECT. Gaps: SLO breach alerting to " <>
          "external channels (PagerDuty/Slack) and compliance KRI export.",
      status: :partial,
      nist_csf: ["DETECT"]
    },
    security_guidance_plugin: %{
      name: "SecurityGuidancePlugin",
      description:
        "Plugin that surfaces AI safety guidance and blocks high-risk hook " <>
          "patterns detected by the pre-tool-use security hook. Partially " <>
          "satisfies NIST AI RMF MAP (risk categorization). Gaps: integration " <>
          "with the composite risk score aggregator (MAP-2, not yet built).",
      status: :partial,
      nist_ai_rmf: ["MAP-1.5", "MAP-2.1"]
    },
    policy_decision_store: %{
      name: "PolicyDecisionStore",
      description:
        "GenServer that persists every authorization decision with full " <>
          "context (agent_id, tool_name, decision, policy_rule, timestamp). " <>
          "Provides GOVERN-phase evidence for NIST AI RMF audits — records " <>
          "demonstrate that policy controls are operational and consistently " <>
          "applied. Added in v9.3.0 auth-s1 (CP-227).",
      status: :satisfied,
      nist_ai_rmf: ["GV-1.1", "GV-6.1"]
    },
    compliance_disclosure: %{
      name: "ComplianceDisclosure",
      description:
        "Governance fields on AgentIdentity — `asl_tier`, `ai_act_risk_class`, " <>
          "and `disclosure_text` — allow each registered agent to declare its " <>
          "Anthropic RSP capability ceiling (ASL-1/2/3) and its EU AI Act " <>
          "Article 6 / Annex III risk classification. The `disclosure_text` " <>
          "field carries the Article 52 transparency notice surfaced to end " <>
          "users. Fields are propagated to the A2A AgentCard `metadata.governance` " <>
          "key. Gap: runtime enforcement of disclosure presentation is not yet " <>
          "wired into the frontend (pending v9.4.0 AgentCard LiveComponent).",
      status: :partial,
      eu_ai_act: ["Article 13", "Article 52"],
      nist_ai_rmf: ["MAP-1.5"]
    },
    audit_encryption_at_rest: %{
      name: "AuditEncryptionAtRest",
      description:
        "AES-256-GCM encryption of PII and sensitive fields in the AuditLog via " <>
          "Cloak vault (comp-mg2 / CP-235). Fields keyed `:pii`, `:sensitive`, or " <>
          "carrying `__cloak__: true` are encrypted before canonical event " <>
          "composition, ensuring the SHA-256 self-hash chain covers only ciphertext. " <>
          "Decrypt-on-demand available to admin callers via `include_decrypted: true` " <>
          "query option. Key rotation requires CCEM_CLOAK_KEY env var update and " <>
          "re-index of affected log entries (gap: automated rotation not yet built).",
      status: :satisfied,
      iso_27001: ["A.8.24"]
    }
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns all controls as a list of `{control_id, control}` tuples.

  ## Examples

      iex> controls = ApmV5.Governance.ControlRegistry.list_controls()
      iex> Enum.any?(controls, fn {id, _} -> id == :audit_log end)
      true
  """
  @spec list_controls() :: [{control_id(), control()}]
  def list_controls, do: Map.to_list(@controls)

  @doc """
  Returns the control map for `id`, or `nil` if not found.

  ## Examples

      iex> ApmV5.Governance.ControlRegistry.get_control(:audit_log)
      %{name: "AuditLog", status: :satisfied, soc2: ["CC7.1"], iso_27001: ["A.8.15"], pci_dss: ["Req 10"], description: _}
  """
  @spec get_control(control_id()) :: control() | nil
  def get_control(id), do: Map.get(@controls, id)

  @doc """
  Returns all CCEM control IDs that reference a given framework requirement.

  `framework` is one of `:nist_ai_rmf | :soc2 | :iso_27001 | :nist_csf |
  :pci_dss | :eu_ai_act | :cis`.

  `requirement` is the framework-specific identifier string, e.g. `"CC6.1"`,
  `"GV-1.1"`, `"A.8.15"`.

  Returns `[]` if no controls reference the given requirement.

  ## Examples

      iex> ApmV5.Governance.ControlRegistry.controls_by_framework(:soc2, "CC6.1")
      [:policy_engine, :authorization_gate]
  """
  @spec controls_by_framework(framework(), String.t()) :: [control_id()]
  def controls_by_framework(framework, requirement) do
    @controls
    |> Enum.filter(fn {_id, ctrl} ->
      reqs = Map.get(ctrl, framework, [])
      requirement in reqs
    end)
    |> Enum.map(fn {id, _} -> id end)
  end

  @doc """
  Returns a summary map grouped by framework, listing which control IDs
  satisfy each referenced requirement. Used by the HTTP endpoint.

  Structure:
  ```json
  {
    "nist_ai_rmf": {"GV-1.1": ["policy_engine", "policy_decision_store"], ...},
    "soc2": {"CC6.1": ["policy_engine", "authorization_gate"], ...},
    ...
  }
  ```
  """
  @spec framework_index() :: %{String.t() => %{String.t() => [String.t()]}}
  def framework_index do
    frameworks = [:nist_ai_rmf, :soc2, :iso_27001, :nist_csf, :pci_dss, :eu_ai_act, :cis]

    Map.new(frameworks, fn fw ->
      reqs_index =
        @controls
        |> Enum.reduce(%{}, fn {ctrl_id, ctrl}, acc ->
          reqs = Map.get(ctrl, fw, [])

          Enum.reduce(reqs, acc, fn req, inner ->
            Map.update(inner, req, [to_string(ctrl_id)], &[to_string(ctrl_id) | &1])
          end)
        end)

      {to_string(fw), reqs_index}
    end)
  end
end
