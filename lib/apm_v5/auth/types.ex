defmodule ApmV5.Auth.Types do
  @moduledoc """
  Shared type definitions for the AgentLock authorization layer.

  Provides structs for authorization decisions, execution tokens,
  sessions, context entries, and redaction results used across
  all auth modules.

  ## AgentLock Protocol Reference
  Based on github.com/webpro255/agentlock (Apache 2.0, v1.1)
  Three-layer enforcement: Agent → AuthorizationGate → ToolExecution
  """

  # ---------------------------------------------------------------------------
  # Risk Levels
  # ---------------------------------------------------------------------------

  @type risk_level :: :none | :low | :medium | :high | :critical

  @risk_levels [:none, :low, :medium, :high, :critical]

  @doc "All valid risk levels in ascending severity order."
  @spec risk_levels() :: [risk_level()]
  def risk_levels, do: @risk_levels

  @doc "Returns true if the given atom is a valid risk level."
  @spec valid_risk_level?(atom()) :: boolean()
  def valid_risk_level?(level), do: level in @risk_levels

  @doc "Numeric severity for a risk level (0-4)."
  @spec risk_severity(risk_level()) :: non_neg_integer()
  def risk_severity(:none), do: 0
  def risk_severity(:low), do: 1
  def risk_severity(:medium), do: 2
  def risk_severity(:high), do: 3
  def risk_severity(:critical), do: 4

  # ---------------------------------------------------------------------------
  # Trust Levels (v1.1 — monotonically decreasing per session)
  # ---------------------------------------------------------------------------

  @type trust_level :: :authoritative | :derived | :untrusted

  @doc "Numeric trust value (higher = more trusted)."
  @spec trust_value(trust_level()) :: non_neg_integer()
  def trust_value(:authoritative), do: 2
  def trust_value(:derived), do: 1
  def trust_value(:untrusted), do: 0

  @doc "Returns the lower of two trust levels (monotonic decrease)."
  @spec min_trust(trust_level(), trust_level()) :: trust_level()
  def min_trust(a, b) do
    if trust_value(a) <= trust_value(b), do: a, else: b
  end

  # ---------------------------------------------------------------------------
  # Context Sources (v1.1)
  # ---------------------------------------------------------------------------

  @type context_source ::
          :user_message
          | :system_prompt
          | :tool_output
          | :agent_reasoning
          | :web_content
          | :file_content
          | :agent_memory
          | :peer_agent

  @doc "Maps a context source to its default trust level."
  @spec source_trust(context_source()) :: trust_level()
  def source_trust(:user_message), do: :authoritative
  def source_trust(:system_prompt), do: :authoritative
  def source_trust(:tool_output), do: :derived
  def source_trust(:agent_reasoning), do: :derived
  def source_trust(:file_content), do: :derived
  def source_trust(:agent_memory), do: :derived
  def source_trust(:peer_agent), do: :derived
  def source_trust(:web_content), do: :untrusted

  # ---------------------------------------------------------------------------
  # Persistence Levels (v1.1 — memory gate)
  # ---------------------------------------------------------------------------

  @type persistence_level :: :none | :session | :cross_session

  # ---------------------------------------------------------------------------
  # Data Boundaries
  # ---------------------------------------------------------------------------

  @type data_boundary :: :authenticated_user_only | :team | :organization

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  defmodule AuthTool do
    @moduledoc "Registered tool with AgentLock permissions."
    @type t :: %__MODULE__{
            name: String.t(),
            risk_level: ApmV5.Auth.Types.risk_level(),
            requires_auth: boolean(),
            allowed_roles: [String.t()],
            data_boundary: ApmV5.Auth.Types.data_boundary(),
            max_records: non_neg_integer(),
            rate_limit: %{max_calls: non_neg_integer(), window_seconds: non_neg_integer()} | nil,
            registered_at: DateTime.t()
          }
    defstruct [
      :name,
      :risk_level,
      requires_auth: true,
      allowed_roles: [],
      data_boundary: :authenticated_user_only,
      max_records: 100,
      rate_limit: nil,
      registered_at: nil
    ]
  end

  defmodule ExecutionToken do
    @moduledoc "Single-use, time-limited execution token (atk_ prefix)."
    @type t :: %__MODULE__{
            token_id: String.t(),
            agent_id: String.t(),
            session_id: String.t(),
            tool_name: String.t(),
            params_hash: String.t(),
            status: :active | :used | :expired | :revoked,
            issued_at: DateTime.t(),
            expires_at: DateTime.t(),
            consumed_at: DateTime.t() | nil
          }
    defstruct [
      :token_id,
      :agent_id,
      :session_id,
      :tool_name,
      :params_hash,
      status: :active,
      issued_at: nil,
      expires_at: nil,
      consumed_at: nil
    ]
  end

  defmodule AuthSession do
    @moduledoc "Authorization session with TTL and trust tracking."
    @type t :: %__MODULE__{
            id: String.t(),
            user_id: String.t(),
            role: String.t(),
            data_boundary: ApmV5.Auth.Types.data_boundary(),
            trust_ceiling: ApmV5.Auth.Types.trust_level(),
            created_at: DateTime.t(),
            expires_at: DateTime.t(),
            tool_call_count: non_neg_integer(),
            denied_count: non_neg_integer(),
            metadata: map()
          }
    defstruct [
      :id,
      :user_id,
      :role,
      data_boundary: :authenticated_user_only,
      trust_ceiling: :authoritative,
      created_at: nil,
      expires_at: nil,
      tool_call_count: 0,
      denied_count: 0,
      metadata: %{}
    ]
  end

  defmodule PolicyDecision do
    @moduledoc "Result of a PolicyEngine evaluation."
    @type t :: %__MODULE__{
            allowed: boolean(),
            risk_level: ApmV5.Auth.Types.risk_level(),
            reason: atom() | nil,
            detail: String.t(),
            needs_approval: boolean(),
            constraints: map()
          }
    defstruct [
      allowed: false,
      risk_level: :none,
      reason: nil,
      detail: "",
      needs_approval: false,
      constraints: %{}
    ]
  end

  defmodule ContextEntry do
    @moduledoc "Context provenance record for trust tracking (v1.1)."
    @type t :: %__MODULE__{
            id: String.t(),
            session_id: String.t(),
            agent_id: String.t(),
            source: ApmV5.Auth.Types.context_source(),
            trust_level: ApmV5.Auth.Types.trust_level(),
            content_hash: String.t(),
            timestamp: DateTime.t()
          }
    defstruct [:id, :session_id, :agent_id, :source, :trust_level, :content_hash, :timestamp]
  end

  defmodule RedactionResult do
    @moduledoc "Result of applying redaction patterns to text."
    @type t :: %__MODULE__{
            redacted_text: String.t(),
            redactions: [map()],
            mode: :auto | :manual | :none,
            had_redactions: boolean()
          }
    defstruct [
      redacted_text: "",
      redactions: [],
      mode: :auto,
      had_redactions: false
    ]
  end
end
