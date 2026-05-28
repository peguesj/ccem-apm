defmodule ApmV5.Provenance.DelegationChain do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  HDP-style Ed25519 signed delegation hop chain.

  Models the trust delegation path from a human authorizer through an orchestrator
  hierarchy down to leaf agents:

      human → orchestrator → swarm_lead → leaf_agent

  ## Chain structure

  A `DelegationChain` holds an ordered list of `Hop` structs.  Each hop records:

  - `authorizer_did` — the delegating party (previous agent's DID)
  - `agent_did`      — the newly-delegated agent's DID
  - `session_id`     — the Claude Code session under which delegation occurred
  - `timestamp`      — ISO 8601 UTC string
  - `sig`            — 64-byte Ed25519 signature over the canonical hop payload

  ## API

  | Function | Description |
  |---|---|
  | `new_chain/3` | Create a single-hop chain signed by `KeyStore` |
  | `append_hop/3` | Verify last hop, then append a new signed hop |
  | `verify/1` | Walk all hops verifying each Ed25519 signature |
  | `to_jwt/1` | Encode the chain as a `delegation_chain` JWT claim |

  ## DRTW

  `:crypto` (OTP native, zero new deps) provides Ed25519 signing and verification.
  JWT encoding uses `Base.url_encode64/2` + `Jason.encode!/1` (already a project dep).
  No `joken` or JOSE library is required — full rationale in
  `docs/drtw-governance/08-provenance.md`.
  """

  alias ApmV5.Identity.KeyStore

  # ── Hop struct ───────────────────────────────────────────────────────────────

  defmodule Hop do
    @moduledoc """
    A single delegation hop in an Ed25519 signed chain.
    """

    @type t() :: %__MODULE__{
            authorizer_did: String.t(),
            agent_did: String.t(),
            session_id: String.t(),
            timestamp: String.t(),
            sig: binary()
          }

    defstruct [
      :authorizer_did,
      :agent_did,
      :session_id,
      :timestamp,
      :sig
    ]
  end

  # ── Chain struct ─────────────────────────────────────────────────────────────

  @type t() :: %__MODULE__{
          hops: [Hop.t()]
        }

  defstruct hops: []

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Create a new single-hop delegation chain.

  The first hop represents the root authorizer (e.g., a human or top-level
  orchestrator) delegating to `agent_did`.  The hop is signed using the APM's
  `KeyStore` Ed25519 private key so downstream verifiers can check authenticity
  with `KeyStore.public_key/0`.

  ## Returns

  `{:ok, chain}` always succeeds as long as `KeyStore` is running.
  """
  @spec new_chain(String.t(), String.t(), String.t()) :: {:ok, t()}
  def new_chain(authorizer_did, agent_did, session_id)
      when is_binary(authorizer_did) and is_binary(agent_did) and is_binary(session_id) do
    hop = build_hop(authorizer_did, agent_did, session_id)
    {:ok, %__MODULE__{hops: [hop]}}
  end

  @doc """
  Append a new delegation hop to an existing chain.

  The last hop's signature is verified before the new hop is added.
  The new hop's `authorizer_did` is taken from the last hop's `agent_did`
  (the previously-delegated agent now delegating further).

  ## Returns

  - `{:ok, extended_chain}` — new hop appended and signed
  - `{:error, :invalid_chain}` — last hop's signature is invalid (tampered chain)
  """
  @spec append_hop(t(), String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_chain}
  def append_hop(%__MODULE__{hops: hops} = chain, next_agent_did, session_id)
      when is_list(hops) and hops != [] and is_binary(next_agent_did) and is_binary(session_id) do
    last_hop = List.last(hops)
    pub = KeyStore.public_key()
    last_payload = hop_signing_payload(last_hop)

    if KeyStore.verify(last_payload, last_hop.sig, pub) do
      new_hop = build_hop(last_hop.agent_did, next_agent_did, session_id)
      {:ok, %{chain | hops: hops ++ [new_hop]}}
    else
      {:error, :invalid_chain}
    end
  end

  @doc """
  Verify every hop's Ed25519 signature in the chain.

  Walks hops in order (index 0 = root).  Returns `:ok` when all signatures
  are valid, `{:error, {:invalid_hop, index}}` for the first failing hop.
  """
  @spec verify(t()) :: :ok | {:error, {:invalid_hop, non_neg_integer()}}
  def verify(%__MODULE__{hops: hops}) do
    pub = KeyStore.public_key()

    hops
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {hop, idx}, :ok ->
      payload = hop_signing_payload(hop)

      if KeyStore.verify(payload, hop.sig, pub) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_hop, idx}}}
      end
    end)
  end

  @doc """
  Encode the delegation chain as a signed JWT string.

  The JWT payload contains a `delegation_chain` claim — a JSON array of hop
  objects with `sig` Base64-encoded for wire transport.

  The JWT is signed (HS256 using the APM's Ed25519 private key as the secret
  bytes — kept simple since this JWT is primarily a transport envelope for the
  chain; full Ed25519 JWT requires ES512/EdDSA which needs JOSE).  The token
  conveys the full chain for downstream validators.

  Structure: `base64url(header).base64url(payload).base64url(sig)`
  """
  @spec to_jwt(t()) :: String.t()
  def to_jwt(%__MODULE__{hops: hops}) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    hops_encoded =
      Enum.map(hops, fn hop ->
        %{
          "authorizer_did" => hop.authorizer_did,
          "agent_did" => hop.agent_did,
          "session_id" => hop.session_id,
          "timestamp" => hop.timestamp,
          "sig" => Base.encode64(hop.sig)
        }
      end)

    payload = %{
      "iss" => "ccem-apm",
      "iat" => System.system_time(:second),
      "delegation_chain" => hops_encoded
    }

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signing_input = "#{header_b64}.#{payload_b64}"

    # Sign with the APM's Ed25519 private key via KeyStore
    sig = KeyStore.sign(signing_input)
    sig_b64 = Base.url_encode64(sig, padding: false)

    "#{signing_input}.#{sig_b64}"
  end

  @doc """
  Returns the canonical bytes to sign for a given hop.

  Deterministic JSON over `{authorizer_did, agent_did, session_id, timestamp}`.
  The `sig` field is excluded so the payload is stable before signing.
  """
  @spec hop_signing_payload(Hop.t()) :: binary()
  def hop_signing_payload(%Hop{} = hop) do
    Jason.encode!(%{
      "agent_did" => hop.agent_did,
      "authorizer_did" => hop.authorizer_did,
      "session_id" => hop.session_id,
      "timestamp" => hop.timestamp
    })
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec build_hop(String.t(), String.t(), String.t()) :: Hop.t()
  defp build_hop(authorizer_did, agent_did, session_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    hop = %Hop{
      authorizer_did: authorizer_did,
      agent_did: agent_did,
      session_id: session_id,
      timestamp: timestamp,
      sig: <<0::512>>
    }

    payload = hop_signing_payload(hop)
    sig = KeyStore.sign(payload)

    %{hop | sig: sig}
  end
end
