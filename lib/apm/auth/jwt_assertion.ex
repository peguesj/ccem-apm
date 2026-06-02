defmodule Apm.Auth.JwtAssertion do
  @moduledoc """
  RFC 7523 JWT Bearer Assertion — Ed25519 (EdDSA) signed agent identity tokens.

  ## v10.0.0 LINCHPIN

  Before v10.0.0, `agent_id` was a plain string trusted from hook payloads with
  zero cryptographic verification. This module makes agent identity
  **cryptographically bound** via Ed25519-signed JWT assertions per RFC 7523.

  ## Design decision: NO `joken` dependency

  Implementation uses pure OTP `:crypto` + `Base.url_encode64` (~80 LOC).
  Rationale (DRTW gap 1 in `docs/drtw-governance/01-authorization.md`):

  - `joken` is a heavyweight dep (~5 transitive packages) for a use case where
    we sign with a single algorithm (EdDSA / Ed25519) controlled by our own
    `Apm.Identity.KeyStore`.
  - OTP 24+ ships native EdDSA in `:crypto.sign/4` and `:crypto.verify/5`.
  - Consistent with v9.4.0 identity-foundation discipline (KeyStore, DIDProvider,
    ArtifactAttestation all dep-free).

  ## Token format

      <base64url(header)>.<base64url(payload)>.<base64url(signature)>

  Where:

  - **header** = `%{"alg" => "EdDSA", "typ" => "JWT"}`
  - **payload** = claims merged with `iat`, `exp`, `jti`
  - **signature** = Ed25519 over `header_b64 <> "." <> payload_b64`

  ## Claims schema

  - `agent_id`        — required, the verified agent identity
  - `formation_id`    — optional formation membership
  - `invoked_by`      — optional user/parent
  - `parent_agent_id` — optional parent agent in delegation chain
  - `session_id`      — optional session correlator
  - `iat`             — issued-at (UNIX seconds, set by signer)
  - `exp`             — expires-at (UNIX seconds, `iat + ttl_seconds`)
  - `jti`             — unique JWT ID (UUID v4)

  ## Usage

      jwt = JwtAssertion.sign_assertion(%{agent_id: "lead-1", session_id: "s1"})
      {:ok, claims} = JwtAssertion.verify_assertion(jwt)
      claims["agent_id"]  # => "lead-1"  (now cryptographically trusted)

  ## RFC 7523 alignment

  Per RFC 7523 §3, the assertion functions as a Bearer token. APIs accepting
  these tokens should pull from the `Authorization: Bearer <jwt>` header.
  """

  alias Apm.Identity.KeyStore

  @type claims :: %{optional(atom() | String.t()) => any()}
  @type sign_opts :: [keystore: GenServer.server(), ttl_seconds: integer()]
  @type verify_opts :: [keystore: GenServer.server()]
  @type verify_error :: :malformed_token | :invalid_signature | :token_expired | :unsupported_alg

  @default_ttl_seconds 3_600

  @header %{"alg" => "EdDSA", "typ" => "JWT"}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Signs a claims map and returns a JWT Bearer assertion string.

  ## Options
    * `:keystore` — `KeyStore` server (default: `Apm.Identity.KeyStore`)
    * `:ttl_seconds` — token lifetime in seconds (default: `3600`)

  Always adds `iat`, `exp`, and `jti` to the payload.
  """
  @spec sign_assertion(claims(), sign_opts()) :: binary()
  def sign_assertion(claims, opts \\ []) when is_map(claims) do
    keystore = Keyword.get(opts, :keystore, KeyStore)
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    now = System.system_time(:second)
    exp = now + ttl

    payload =
      claims
      |> stringify_keys()
      |> Map.put("iat", now)
      |> Map.put("exp", exp)
      |> Map.put("jti", uuid_v4())

    header_b64 = encode_segment(@header)
    payload_b64 = encode_segment(payload)
    signing_input = header_b64 <> "." <> payload_b64

    signature = KeyStore.sign(keystore, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    signing_input <> "." <> sig_b64
  end

  @doc """
  Verifies a JWT Bearer assertion. Returns `{:ok, claims}` or `{:error, reason}`.

  ## Options
    * `:keystore` — `KeyStore` server to source the verification public key
      (default: `Apm.Identity.KeyStore`)

  Verification steps:
  1. Parse 3 base64url segments → `{header, payload, signature}`.
  2. Validate header `alg == "EdDSA"`, `typ == "JWT"`.
  3. Verify Ed25519 signature over `header_b64.payload_b64` using KeyStore.public_key.
  4. Check `exp` has not passed.

  Errors are tagged tuples — never raises on malformed input.
  """
  @spec verify_assertion(binary(), verify_opts()) ::
          {:ok, map()} | {:error, verify_error()}
  def verify_assertion(jwt, opts \\ []) when is_binary(jwt) do
    keystore = Keyword.get(opts, :keystore, KeyStore)

    with {:ok, header_b64, payload_b64, sig_b64} <- split_segments(jwt),
         {:ok, header} <- decode_segment(header_b64),
         :ok <- check_header(header),
         {:ok, payload} <- decode_segment(payload_b64),
         {:ok, signature} <- url_decode(sig_b64),
         signing_input = header_b64 <> "." <> payload_b64,
         pub = KeyStore.public_key(keystore),
         true <- KeyStore.verify(keystore, signing_input, signature, pub) || :invalid_sig,
         :ok <- check_expiration(payload) do
      {:ok, payload}
    else
      :invalid_sig -> {:error, :invalid_signature}
      {:error, _} = err -> err
      _ -> {:error, :malformed_token}
    end
  end

  @doc """
  Convenience extractor for the `Authorization: Bearer <jwt>` header value.

  Returns `{:ok, jwt}` when the header has the `Bearer ` prefix, otherwise
  `{:error, :no_bearer}`.
  """
  @spec extract_bearer(binary() | nil) :: {:ok, binary()} | {:error, :no_bearer}
  def extract_bearer("Bearer " <> jwt) when byte_size(jwt) > 0, do: {:ok, jwt}
  def extract_bearer(_), do: {:error, :no_bearer}

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec encode_segment(map()) :: binary()
  defp encode_segment(map) do
    map
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @spec decode_segment(binary()) :: {:ok, map()} | {:error, :malformed_token}
  defp decode_segment(segment) do
    with {:ok, json} <- url_decode(segment),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed_token}
    end
  end

  @spec url_decode(binary()) :: {:ok, binary()} | {:error, :malformed_token}
  defp url_decode(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed_token}
    end
  end

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

  @spec check_header(map()) :: :ok | {:error, :unsupported_alg | :malformed_token}
  defp check_header(%{"alg" => "EdDSA", "typ" => "JWT"}), do: :ok
  defp check_header(%{"alg" => alg}) when is_binary(alg), do: {:error, :unsupported_alg}
  defp check_header(_), do: {:error, :malformed_token}

  @spec check_expiration(map()) :: :ok | {:error, :token_expired | :malformed_token}
  defp check_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    if now < exp, do: :ok, else: {:error, :token_expired}
  end

  defp check_expiration(_), do: {:error, :malformed_token}

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # UUID v4 — pure OTP, no uuid dep.
  @spec uuid_v4() :: binary()
  defp uuid_v4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
  end
end
