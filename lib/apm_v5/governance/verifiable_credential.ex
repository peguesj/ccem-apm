defmodule ApmV5.Governance.VerifiableCredential do
  @moduledoc """
  W3C Verifiable Credentials Data Model 2.0 — JWT-VC issuance for CCEM agents.

  ## Purpose

  Issues cryptographically signed Verifiable Credentials (VCs) documenting
  what an agent IS AUTHORIZED TO DO (capabilities), complementing the JWT
  identity token from v10.0.0 which documents WHO the agent IS (identity).

  ## Format: JWT-VC (W3C VC 2.0)

  A JWT-VC is a standard JWS compact serialization where:

  - **Header**: `{"alg": "EdDSA", "typ": "JWT", "kid": "<issuer DID URI>"}`
  - **Payload**: outer JWT claims (`iss`, `sub`, `jti`, `nbf`, `exp`) PLUS a
    `"vc"` claim containing the full W3C VC document
  - **Signature**: Ed25519 over `<header_b64>.<payload_b64>` via KeyStore

  The `"vc"` claim structure follows W3C VC Data Model 2.0 §4:

  ```json
  {
    "@context": ["https://www.w3.org/ns/credentials/v2"],
    "id": "urn:uuid:...",
    "type": ["VerifiableCredential", "CCEMAgentCredential"],
    "issuer": "did:key:z6Mk...",
    "validFrom": "2026-05-28T...",
    "validUntil": "2027-05-28T...",
    "credentialSubject": {
      "id": "did:key:z6Mk...",
      "agent_id": "...",
      "formation_id": "...",
      "invoked_by": "...",
      "capabilities": ["tool:Write", "tool:Bash"],
      "risk_level": "medium",
      "session_id": "..."
    }
  }
  ```

  ## Revocation

  Revoked credential IDs are stored in an ETS table (`:vc_revocations`).
  `verify_credential/2` checks this table after signature verification.

  ## DRTW

  All crypto: OTP `:crypto` (EdDSA). No `joken` dependency — consistent with
  v9.4.0 identity-foundation and v10.0.0 `JwtAssertion` disciplines.
  See `docs/drtw-governance/08-provenance.md` §Wave 1.

  ## EU AI Act Article 13 + 52

  The VC's `credentialSubject.capabilities` field provides machine-readable
  disclosure of what the agent is authorized to do, directly satisfying
  Article 13 (transparency) and Article 52 (disclosure for AI systems
  interacting with humans) of the EU AI Act (enforcement Aug 2, 2026).

  Spec: CP-300 / comp-v10.3-s2 / UPM upm-1020
  """

  alias ApmV5.Identity.{KeyStore, DIDProvider}

  @vc_revocations_table :vc_revocations

  @default_valid_seconds 365 * 24 * 3_600

  @type agent_identity :: %{did: String.t(), agent_id: String.t()}
  @type credential_subject :: %{String.t() => any()}
  @type issue_opts :: [keystore: GenServer.server(), valid_seconds: integer()]
  @type verify_opts :: [keystore: GenServer.server()]
  @type verify_error ::
          :malformed_token
          | :invalid_signature
          | :credential_expired
          | :credential_revoked
          | :unsupported_alg
          | :missing_vc_claim

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Issues a W3C VC in JWT-VC format for an agent.

  `agent_identity` must contain `:did` (the agent's `did:key` DID) and `:agent_id`.
  `credential_subject` is a map of additional claims (capabilities, risk_level, etc.).

  ## Options
    * `:keystore` — `KeyStore` server (default: `ApmV5.Identity.KeyStore`)
    * `:valid_seconds` — validity window in seconds (default: 365 days)

  Returns a JWT-VC compact serialization string.
  """
  @spec issue_agent_credential(agent_identity(), credential_subject(), issue_opts()) :: binary()
  def issue_agent_credential(agent_identity, credential_subject, opts \\ []) do
    keystore = Keyword.get(opts, :keystore, KeyStore)
    valid_seconds = Keyword.get(opts, :valid_seconds, @default_valid_seconds)

    pub = KeyStore.public_key(keystore)
    issuer_did = DIDProvider.did_for_public_key(pub)

    now = System.system_time(:second)
    valid_from_dt = DateTime.from_unix!(now)
    valid_until_dt = DateTime.from_unix!(now + valid_seconds)

    cred_id = "urn:uuid:#{uuid_v4()}"

    vc_document = %{
      "@context" => ["https://www.w3.org/ns/credentials/v2"],
      "id" => cred_id,
      "type" => ["VerifiableCredential", "CCEMAgentCredential"],
      "issuer" => issuer_did,
      "validFrom" => DateTime.to_iso8601(valid_from_dt),
      "validUntil" => DateTime.to_iso8601(valid_until_dt),
      "credentialSubject" =>
        credential_subject
        |> stringify_keys()
        |> Map.put("id", agent_identity.did)
    }

    # JWT outer claims per W3C VC 2.0 §6.3 (JWT encoding rules)
    jwt_payload = %{
      "iss" => issuer_did,
      "sub" => agent_identity.did,
      "jti" => cred_id,
      "nbf" => now,
      "exp" => now + valid_seconds,
      "vc" => vc_document
    }

    # JWT-VC header per W3C VC 2.0 §6.3.1
    kid = issuer_did <> "#" <> String.replace_prefix(issuer_did, "did:key:", "")

    header = %{
      "alg" => "EdDSA",
      "typ" => "JWT",
      "kid" => kid
    }

    sign_jwt(header, jwt_payload, keystore)
  end

  @doc """
  Verifies a JWT-VC string.

  Returns `{:ok, vc_document}` where `vc_document` is the W3C VC claim (not
  the outer JWT payload), or `{:error, reason}`.

  Verification steps:
  1. Parse 3 base64url segments.
  2. Validate header `alg == "EdDSA"`.
  3. Verify Ed25519 signature over `header_b64.payload_b64`.
  4. Check JWT `exp` (outer expiry).
  5. Check `validUntil` in the inner VC document.
  6. Check revocation list in `:vc_revocations` ETS table.
  """
  @spec verify_credential(binary(), verify_opts()) ::
          {:ok, map()} | {:error, verify_error()}
  def verify_credential(jwt, opts \\ []) when is_binary(jwt) do
    keystore = Keyword.get(opts, :keystore, KeyStore)

    with {:ok, header_b64, payload_b64, sig_b64} <- split_segments(jwt),
         {:ok, header} <- decode_segment(header_b64),
         :ok <- check_header(header),
         {:ok, payload} <- decode_segment(payload_b64),
         {:ok, signature} <- url_decode64(sig_b64),
         signing_input = header_b64 <> "." <> payload_b64,
         pub = KeyStore.public_key(keystore),
         true <- KeyStore.verify(keystore, signing_input, signature, pub) || :invalid_sig,
         :ok <- check_jwt_expiration(payload),
         {:ok, vc_doc} <- extract_vc(payload),
         :ok <- check_vc_validity(vc_doc),
         :ok <- check_revocation(vc_doc) do
      {:ok, vc_doc}
    else
      :invalid_sig -> {:error, :invalid_signature}
      {:error, _} = err -> err
      false -> {:error, :invalid_signature}
      _ -> {:error, :malformed_token}
    end
  end

  @doc """
  Revokes a credential by its ID (the `urn:uuid:...` string).

  Inserts the credential ID into the `:vc_revocations` ETS table. Idempotent.
  """
  @spec revoke_credential(String.t()) :: :ok
  def revoke_credential(credential_id) when is_binary(credential_id) do
    ensure_revocations_table()
    :ets.insert(@vc_revocations_table, {credential_id, System.system_time(:second)})
    :ok
  end

  @doc """
  Returns `true` if the credential ID is in the revocation list.
  """
  @spec revoked?(String.t()) :: boolean()
  def revoked?(credential_id) when is_binary(credential_id) do
    ensure_revocations_table()

    case :ets.lookup(@vc_revocations_table, credential_id) do
      [{_, _}] -> true
      [] -> false
    end
  end

  # ── Private: JWT construction ────────────────────────────────────────────────

  @spec sign_jwt(map(), map(), GenServer.server()) :: binary()
  defp sign_jwt(header, payload, keystore) do
    header_b64 = encode_segment(header)
    payload_b64 = encode_segment(payload)
    signing_input = header_b64 <> "." <> payload_b64
    signature = KeyStore.sign(keystore, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)
    signing_input <> "." <> sig_b64
  end

  # ── Private: JWT parsing ─────────────────────────────────────────────────────

  @spec split_segments(binary()) ::
          {:ok, binary(), binary(), binary()} | {:error, :malformed_token}
  defp split_segments(jwt) do
    case String.split(jwt, ".") do
      [h, p, s] when byte_size(h) > 0 and byte_size(p) > 0 and byte_size(s) > 0 ->
        {:ok, h, p, s}

      _ ->
        {:error, :malformed_token}
    end
  end

  @spec encode_segment(map()) :: binary()
  defp encode_segment(map) do
    map |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  @spec decode_segment(binary()) :: {:ok, map()} | {:error, :malformed_token}
  defp decode_segment(segment) do
    with {:ok, json} <- url_decode64(segment),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed_token}
    end
  end

  @spec url_decode64(binary()) :: {:ok, binary()} | {:error, :malformed_token}
  defp url_decode64(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed_token}
    end
  end

  # ── Private: Verification checks ────────────────────────────────────────────

  @spec check_header(map()) :: :ok | {:error, :unsupported_alg | :malformed_token}
  defp check_header(%{"alg" => "EdDSA"}), do: :ok
  defp check_header(%{"alg" => alg}) when is_binary(alg), do: {:error, :unsupported_alg}
  defp check_header(_), do: {:error, :malformed_token}

  @spec check_jwt_expiration(map()) :: :ok | {:error, :credential_expired | :malformed_token}
  defp check_jwt_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    if now < exp, do: :ok, else: {:error, :credential_expired}
  end

  defp check_jwt_expiration(_), do: {:error, :malformed_token}

  @spec extract_vc(map()) :: {:ok, map()} | {:error, :missing_vc_claim}
  defp extract_vc(%{"vc" => vc}) when is_map(vc), do: {:ok, vc}
  defp extract_vc(_), do: {:error, :missing_vc_claim}

  @spec check_vc_validity(map()) :: :ok | {:error, :credential_expired | :malformed_token}
  defp check_vc_validity(%{"validUntil" => valid_until}) when is_binary(valid_until) do
    case DateTime.from_iso8601(valid_until) do
      {:ok, dt, _} ->
        now = DateTime.utc_now()

        if DateTime.compare(now, dt) == :lt do
          :ok
        else
          {:error, :credential_expired}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp check_vc_validity(_), do: {:error, :malformed_token}

  @spec check_revocation(map()) :: :ok | {:error, :credential_revoked}
  defp check_revocation(%{"id" => cred_id}) when is_binary(cred_id) do
    if revoked?(cred_id), do: {:error, :credential_revoked}, else: :ok
  end

  defp check_revocation(_), do: :ok

  # ── Private: ETS revocations table ──────────────────────────────────────────

  @spec ensure_revocations_table() :: :ok
  defp ensure_revocations_table do
    if :ets.whereis(@vc_revocations_table) == :undefined do
      :ets.new(@vc_revocations_table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  rescue
    # Table already created by another process — safe to ignore
    ArgumentError -> :ok
  end

  # ── Private: UUID v4 (pure OTP) ─────────────────────────────────────────────

  @spec uuid_v4() :: binary()
  defp uuid_v4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
  end

  # ── Private: helpers ─────────────────────────────────────────────────────────

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
