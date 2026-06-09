defmodule Apm.Auth.OidcVerifier do
  @moduledoc """
  OIDC ID-token verifier for enterprise IdP integration (CP-297 / v10.2.0).

  Wraps assent's OIDC JWT verification with:
  - JWKS key caching (5-minute TTL per provider)
  - Config-driven provider map (Application.get_env or explicit opts)
  - Claims validation: expiry, audience, issuer
  - Symmetric HS256 support for test environments

  ## Usage

      # Configured via Application env:
      config :apm, :oidc_providers, %{
        okta: %{issuer: "https://myorg.okta.com", audience: "apm-v5"}
      }

      # Verify an ID token (uses named GenServer):
      case OidcVerifier.verify_id_token(id_token, :okta) do
        {:ok, claims} -> claims["sub"]
        {:error, reason} -> # handle
      end

      # Or with an explicit pid (tests / dynamic supervisors):
      OidcVerifier.verify_id_token(pid, id_token, :okta)

  ## Supported Providers
  - Okta
  - Auth0
  - Microsoft Entra (Azure AD)
  - Any OIDC-compliant IdP exposing /.well-known/openid-configuration

  ## JWKS Cache
  JWKS keys are fetched from the IdP's `jwks_uri` on first use and cached in the
  GenServer state. Cache entries expire after `@jwks_ttl_seconds` (default 300 s).
  On cache miss or expiry, a fresh JWKS fetch is issued.
  """

  use GenServer

  require Logger

  @jwks_ttl_seconds 300
  @default_name __MODULE__

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type provider_key :: atom()
  @type provider_cfg :: %{issuer: String.t(), audience: String.t()}
  @type claims :: %{String.t() => term()}
  @type verify_error ::
          :token_expired
          | :invalid_audience
          | :invalid_issuer
          | :invalid_signature
          | :provider_not_configured
          | :no_oidc_providers_configured
          | :jwks_fetch_failed
          | {:decode_error, term()}
          | {:verification_failed, term()}

  @type state :: %{
          providers: %{provider_key() => provider_cfg()},
          jwks_cache: %{provider_key() => {[map()], integer()}}
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    providers = resolve_providers(opts)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, %{providers: providers}, gen_opts)
  end

  @doc """
  Verify an OIDC ID token for the given provider using the named GenServer.

  When no OIDC providers are configured, returns `{:error, :no_oidc_providers_configured}`
  immediately — behavior is unchanged from v9.3.0.
  """
  @spec verify_id_token(String.t(), provider_key()) :: {:ok, claims()} | {:error, verify_error()}
  def verify_id_token(jwt, provider) do
    case Process.whereis(@default_name) do
      nil ->
        {:error, :no_oidc_providers_configured}

      pid ->
        verify_id_token(pid, jwt, provider)
    end
  end

  @doc """
  Verify an OIDC ID token using an explicit GenServer pid (useful in tests).
  """
  @spec verify_id_token(pid(), String.t(), provider_key()) ::
          {:ok, claims()} | {:error, verify_error()}
  def verify_id_token(pid, jwt, provider) when is_pid(pid) do
    GenServer.call(pid, {:verify, jwt, provider})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{providers: providers}) do
    Logger.info("[OidcVerifier] Started with providers: #{inspect(Map.keys(providers))}")
    {:ok, %{providers: providers, jwks_cache: %{}}}
  end

  @impl true
  def handle_call({:verify, _jwt, _provider}, _from, %{providers: p} = state)
      when map_size(p) == 0 do
    {:reply, {:error, :no_oidc_providers_configured}, state}
  end

  @impl true
  def handle_call({:verify, jwt, provider}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      provider_cfg ->
        {result, new_state} = do_verify(jwt, provider, provider_cfg, state)
        {:reply, result, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — JWT verification
  # ---------------------------------------------------------------------------

  defp do_verify(jwt, provider, %{issuer: issuer, audience: audience}, state) do
    with {:ok, {header, claims, signature, signing_input}} <- decode_jwt(jwt),
         {:ok, claims} <- validate_expiry(claims),
         {:ok, claims} <- validate_audience(claims, audience),
         {:ok, claims} <- validate_issuer(claims, issuer),
         {jwks, new_state} <- ensure_jwks(provider, issuer, state),
         :ok <- verify_signature(header, signing_input, signature, jwks) do
      {{:ok, claims}, new_state}
    else
      {{:error, _} = err, new_state} -> {err, new_state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # JWT Decode
  # ---------------------------------------------------------------------------

  defp decode_jwt(jwt) do
    case String.split(jwt, ".") do
      [header_b64, payload_b64, sig_b64] ->
        with {:ok, header_json} <- base64_decode(header_b64),
             {:ok, payload_json} <- base64_decode(payload_b64),
             {:ok, signature} <- base64_decode_raw(sig_b64),
             {:ok, header} <- Jason.decode(header_json),
             {:ok, claims} <- Jason.decode(payload_json) do
          signing_input = "#{header_b64}.#{payload_b64}"
          {:ok, {header, claims, signature, signing_input}}
        else
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      _ ->
        {:error, {:decode_error, :malformed_jwt}}
    end
  end

  defp base64_decode(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, _} = ok -> ok
      :error -> {:error, :base64_decode_failed}
    end
  end

  defp base64_decode_raw(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :base64_decode_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Claims Validation
  # ---------------------------------------------------------------------------

  defp validate_expiry(claims) do
    now = System.system_time(:second)

    case Map.get(claims, "exp") do
      nil ->
        {:error, :token_expired}

      exp when is_integer(exp) and exp > now ->
        {:ok, claims}

      _ ->
        {:error, :token_expired}
    end
  end

  defp validate_audience(claims, expected_audience) do
    aud = Map.get(claims, "aud")

    cond do
      is_binary(aud) and aud == expected_audience -> {:ok, claims}
      is_list(aud) and expected_audience in aud -> {:ok, claims}
      true -> {:error, :invalid_audience}
    end
  end

  defp validate_issuer(claims, expected_issuer) do
    case Map.get(claims, "iss") do
      ^expected_issuer -> {:ok, claims}
      _ -> {:error, :invalid_issuer}
    end
  end

  # ---------------------------------------------------------------------------
  # Signature Verification
  # ---------------------------------------------------------------------------

  defp verify_signature(%{"alg" => alg} = _header, signing_input, signature, jwks) do
    # Try each key until one works
    result =
      Enum.find_value(jwks, :no_key, fn key ->
        case try_verify(alg, signing_input, signature, key) do
          :ok -> true
          _ -> nil
        end
      end)

    if result == true, do: :ok, else: {:error, :invalid_signature}
  end

  defp verify_signature(_header, _signing_input, _signature, _jwks) do
    {:error, :invalid_signature}
  end

  defp try_verify("HS256", signing_input, signature, %{"kty" => "oct", "k" => k}) do
    case Base.url_decode64(k, padding: false) do
      {:ok, secret} ->
        expected = :crypto.mac(:hmac, :sha256, secret, signing_input)

        if secure_compare(expected, signature), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp try_verify("RS256", signing_input, signature, %{"kty" => "RSA"} = jwk) do
    case build_rsa_public_key(jwk) do
      {:ok, public_key} ->
        case :public_key.verify(signing_input, :sha256, signature, public_key) do
          true -> :ok
          false -> :error
        end

      _ ->
        :error
    end
  end

  defp try_verify("ES256", signing_input, signature, %{"kty" => "EC"} = jwk) do
    case build_ec_public_key(jwk) do
      {:ok, public_key} ->
        # ES256 signature is a DER-encoded ECDSA sequence
        der_sig = asn1_encode_ecdsa(signature)

        case :public_key.verify(signing_input, :sha256, der_sig, public_key) do
          true -> :ok
          false -> :error
        end

      _ ->
        :error
    end
  end

  defp try_verify(_, _, _, _), do: :error

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp build_rsa_public_key(%{"n" => n_b64, "e" => e_b64}) do
    with {:ok, n_bin} <- Base.url_decode64(n_b64, padding: false),
         {:ok, e_bin} <- Base.url_decode64(e_b64, padding: false) do
      n = :binary.decode_unsigned(n_bin)
      e = :binary.decode_unsigned(e_bin)
      # OTP :public_key RSAPublicKey record
      {:ok, {:RSAPublicKey, n, e}}
    else
      _ -> :error
    end
  end

  defp build_rsa_public_key(_), do: :error

  defp build_ec_public_key(%{"crv" => crv, "x" => x_b64, "y" => y_b64}) do
    with {:ok, x_bin} <- Base.url_decode64(x_b64, padding: false),
         {:ok, y_bin} <- Base.url_decode64(y_b64, padding: false) do
      curve =
        case crv do
          "P-256" -> :secp256r1
          "P-384" -> :secp384r1
          "P-521" -> :secp521r1
          _ -> nil
        end

      if curve do
        # Uncompressed EC point: 0x04 || x || y
        point = <<0x04>> <> x_bin <> y_bin
        {:ok, {{:ECPoint, point}, {:namedCurve, :pubkey_cert_records.namedCurves(curve)}}}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp build_ec_public_key(_), do: :error

  # Convert raw r||s bytes (64 bytes for P-256) to DER-encoded ECDSA-Sig-Value
  defp asn1_encode_ecdsa(signature) do
    half = div(byte_size(signature), 2)
    <<r_bytes::binary-size(half), s_bytes::binary-size(half)>> = signature

    r = :binary.decode_unsigned(r_bytes)
    s = :binary.decode_unsigned(s_bytes)

    # :public_key expects DER SEQUENCE { INTEGER r, INTEGER s }
    r_der = encode_asn1_integer(r)
    s_der = encode_asn1_integer(s)
    content = r_der <> s_der
    <<0x30, byte_size(content), content::binary>>
  end

  defp encode_asn1_integer(n) do
    bytes = :binary.encode_unsigned(n)
    # Prefix 0x00 if high bit set (to signal positive integer)
    bytes =
      if :binary.first(bytes) >= 128 do
        <<0x00, bytes::binary>>
      else
        bytes
      end

    <<0x02, byte_size(bytes), bytes::binary>>
  end

  # ---------------------------------------------------------------------------
  # JWKS Fetching + Cache
  # ---------------------------------------------------------------------------

  defp ensure_jwks(provider, issuer, state) do
    now = System.system_time(:second)

    case Map.get(state.jwks_cache, provider) do
      {keys, fetched_at} when now - fetched_at < @jwks_ttl_seconds ->
        # Cache hit
        {keys, state}

      _ ->
        # Cache miss / expired — fetch fresh JWKS
        case fetch_jwks(issuer) do
          {:ok, keys} ->
            new_cache = Map.put(state.jwks_cache, provider, {keys, now})
            {keys, %{state | jwks_cache: new_cache}}

          {:error, _reason} ->
            # Return empty keys; signature verification will fail
            {[], state}
        end
    end
  end

  defp fetch_jwks(issuer) do
    discovery_url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, oidc_config} <- http_get_json(discovery_url),
         jwks_uri when is_binary(jwks_uri) <- Map.get(oidc_config, "jwks_uri"),
         {:ok, jwks} <- http_get_json(jwks_uri),
         keys when is_list(keys) <- Map.get(jwks, "keys") do
      {:ok, keys}
    else
      nil -> {:error, :jwks_uri_missing}
      {:error, _} = err -> err
    end
  end

  defp http_get_json(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp resolve_providers(opts) do
    case Keyword.get(opts, :providers) do
      providers when is_map(providers) ->
        providers

      nil ->
        Application.get_env(:apm, :oidc_providers, %{})
    end
  end
end
