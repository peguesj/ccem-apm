defmodule Apm.Auth.DelegationToken do
  @moduledoc """
  Parent→child capability delegation token — Ed25519-signed.

  ## v10.0.0 / s2 — OWASP MCP02 fix (CP-290)

  Before v10.0.0, parent agents could register child agents with permissions
  exceeding their own ceiling. This is OWASP MCP02 (Tool / Capability Scope
  Creep): privileged sub-agents that escape parent constraints.

  `DelegationToken` enforces the rule **mathematically at issuance**:

      child.allowed_tools     ⊆  parent.allowed_tools
      child.max_risk_ceiling  ≤  parent.max_risk_ceiling

  Issuance that violates either invariant returns `{:error, :exceeds_parent_ceiling}`.

  ## Token structure

  Encoded as a plain struct (not a JWT) — small surface, easy to inspect.
  Signed via `Apm.Identity.KeyStore.sign/2` over a canonical payload.

  ## Risk ordering

      :none < :low < :medium < :high < :critical

  Used by `risk_rank/1` and `enforce_ceiling/3`.

  ## DelegationChain integration (forward-looking)

  When `ralph/v9.4.0-prov-w3` lands `DelegationChain`, `issue/3` will gain
  `:include_in_chain` to publish issuance events. For now, the `parent_agent_id`
  field on the token is the chain pointer.

  ## DRTW

  GAP 2 in `docs/drtw-governance/01-authorization.md`. Pure OTP `:crypto` — no
  new deps. Symmetric with `JwtAssertion` discipline.
  """

  alias Apm.Identity.KeyStore

  @type risk_level :: :none | :low | :medium | :high | :critical

  @type t :: %__MODULE__{
          parent_agent_id: String.t() | nil,
          child_agent_id: String.t(),
          allowed_tools: [String.t()],
          max_risk_ceiling: risk_level(),
          issued_at: integer(),
          expires_at: integer(),
          signature: binary()
        }

  defstruct [
    :parent_agent_id,
    :child_agent_id,
    :allowed_tools,
    :max_risk_ceiling,
    :issued_at,
    :expires_at,
    :signature
  ]

  @default_ttl_seconds 3_600

  @risk_ranks %{
    none: 0,
    low: 1,
    medium: 2,
    high: 3,
    critical: 4
  }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns the ordinal rank of a risk level. Higher = riskier.

      :none < :low < :medium < :high < :critical
  """
  @spec risk_rank(risk_level()) :: 0..4
  def risk_rank(level) when is_atom(level), do: Map.fetch!(@risk_ranks, level)

  @doc """
  Issues a delegation token to `child_agent_id`.

  ## Options
    * `:allowed_tools` — list of tool name strings (required)
    * `:max_risk_ceiling` — risk level atom (required)
    * `:ttl_seconds` — token lifetime (default 3600)
    * `:keystore` — `KeyStore` server (default `Apm.Identity.KeyStore`)

  ## Behavior
  - If `parent_token` is `nil`, issues an unconstrained root token.
  - If `parent_token` is given, enforces:
    - `child.allowed_tools ⊆ parent.allowed_tools`
    - `child.max_risk_ceiling ≤ parent.max_risk_ceiling`
    - Parent token must not be expired.
  """
  @spec issue(t() | nil, String.t(), keyword()) ::
          {:ok, t()} | {:error, :exceeds_parent_ceiling | :parent_expired | :invalid_parent}
  def issue(parent_token, child_agent_id, opts) when is_binary(child_agent_id) do
    allowed_tools = Keyword.fetch!(opts, :allowed_tools)
    max_risk_ceiling = Keyword.fetch!(opts, :max_risk_ceiling)
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    keystore = Keyword.get(opts, :keystore, KeyStore)

    with :ok <- check_parent_alive(parent_token, keystore),
         :ok <- check_subset(parent_token, allowed_tools, max_risk_ceiling) do
      now = System.system_time(:second)

      token = %__MODULE__{
        parent_agent_id: parent_agent_id_of(parent_token),
        child_agent_id: child_agent_id,
        allowed_tools: Enum.sort(allowed_tools),
        max_risk_ceiling: max_risk_ceiling,
        issued_at: now,
        expires_at: now + ttl,
        signature: nil
      }

      signing_payload = canonical_payload(token)
      sig = KeyStore.sign(keystore, signing_payload)

      {:ok, %{token | signature: sig}}
    end
  end

  @doc """
  Verifies a delegation token: Ed25519 signature + expiration.
  """
  @spec verify(t(), keyword()) ::
          :ok | {:error, :invalid_signature | :token_expired}
  def verify(%__MODULE__{} = token, opts \\ []) do
    keystore = Keyword.get(opts, :keystore, KeyStore)

    payload = canonical_payload(token)
    pub = KeyStore.public_key(keystore)

    cond do
      not KeyStore.verify(keystore, payload, token.signature, pub) ->
        {:error, :invalid_signature}

      System.system_time(:second) >= token.expires_at ->
        {:error, :token_expired}

      true ->
        :ok
    end
  end

  @doc """
  Gates a single tool call against a delegation token.

  Returns:
    * `:ok` — tool is in `allowed_tools` and `requested_risk_level ≤ max_risk_ceiling`
    * `{:error, :tool_not_allowed}` — tool absent from `allowed_tools`
    * `{:error, :risk_exceeds_ceiling}` — risk exceeds token's ceiling
    * `{:error, :token_expired}` — token expired

  Note: does NOT re-verify signature. Call `verify/2` once at session start and
  trust the in-memory token thereafter (signature already protects against
  tamper in transit).
  """
  @spec enforce_ceiling(t(), String.t(), risk_level()) ::
          :ok
          | {:error, :tool_not_allowed | :risk_exceeds_ceiling | :token_expired}
  def enforce_ceiling(%__MODULE__{} = token, tool_name, requested_risk) do
    cond do
      System.system_time(:second) >= token.expires_at ->
        {:error, :token_expired}

      tool_name not in token.allowed_tools ->
        {:error, :tool_not_allowed}

      risk_rank(requested_risk) > risk_rank(token.max_risk_ceiling) ->
        {:error, :risk_exceeds_ceiling}

      true ->
        :ok
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec check_parent_alive(t() | nil, GenServer.server()) ::
          :ok | {:error, :parent_expired | :exceeds_parent_ceiling}
  defp check_parent_alive(nil, _keystore), do: :ok

  defp check_parent_alive(%__MODULE__{} = parent, keystore) do
    case verify(parent, keystore: keystore) do
      :ok -> :ok
      # An expired parent has no scope to delegate from — treat as ceiling violation.
      {:error, :token_expired} -> {:error, :exceeds_parent_ceiling}
      {:error, _} -> {:error, :exceeds_parent_ceiling}
    end
  end

  @spec check_subset(t() | nil, [String.t()], risk_level()) ::
          :ok | {:error, :exceeds_parent_ceiling}
  defp check_subset(nil, _, _), do: :ok

  defp check_subset(%__MODULE__{} = parent, child_tools, child_ceiling) do
    tools_subset? = Enum.all?(child_tools, &(&1 in parent.allowed_tools))
    risk_within? = risk_rank(child_ceiling) <= risk_rank(parent.max_risk_ceiling)

    if tools_subset? and risk_within? do
      :ok
    else
      {:error, :exceeds_parent_ceiling}
    end
  end

  @spec parent_agent_id_of(t() | nil) :: String.t() | nil
  defp parent_agent_id_of(nil), do: nil
  defp parent_agent_id_of(%__MODULE__{child_agent_id: id}), do: id

  # Canonical payload for signing — deterministic ordering, no signature field.
  @spec canonical_payload(t()) :: binary()
  defp canonical_payload(%__MODULE__{} = token) do
    Jason.encode!(%{
      "parent_agent_id" => token.parent_agent_id,
      "child_agent_id" => token.child_agent_id,
      "allowed_tools" => Enum.sort(token.allowed_tools),
      "max_risk_ceiling" => Atom.to_string(token.max_risk_ceiling),
      "issued_at" => token.issued_at,
      "expires_at" => token.expires_at
    })
  end
end
