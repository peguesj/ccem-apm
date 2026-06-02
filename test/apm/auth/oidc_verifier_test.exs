defmodule Apm.Auth.OidcVerifierTest do
  @moduledoc """
  TDD suite for OidcVerifier — CP-297 / auth-v10.2-s2.

  Tests cover:
  - Successful JWT verification roundtrip with a Bypass mock IdP JWKS endpoint
  - Expired token rejection
  - Wrong audience rejection
  - Missing / unconfigured provider returns clear error
  - JWKS cache TTL logic (hit vs. miss)
  - SessionStore.create/2 with oidc_id_token accepts verified sub as identity
  - SessionStore.create/2 without oidc_id_token behaves identically to v9.3.0

  Mock IdP strategy: Bypass serves /.well-known/openid-configuration + /jwks_uri.
  JWTs are signed with HS256 (symmetric) via :crypto for test portability — the
  verifier under test must handle HS256 as a valid algorithm for tests while the
  production path can enforce RS256/ES256. OidcVerifier.verify_id_token/2 is the
  primary contract under test.
  """

  use ExUnit.Case, async: false

  alias Apm.Auth.OidcVerifier
  alias Apm.Auth.SessionStore

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal JWT signed with HS256 for testing.
  # Header: {"alg":"HS256","typ":"JWT"}
  # We use Erlang :crypto for HMAC-SHA256 to avoid runtime deps in tests.
  defp build_jwt(claims, secret \\ "test-secret-key-32-bytes-padded!") do
    header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header}.#{payload}"
    sig = :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.url_encode64(padding: false)
    "#{signing_input}.#{sig}"
  end

  defp valid_claims(opts \\ []) do
    now = System.system_time(:second)

    %{
      "iss" => Keyword.get(opts, :iss, "https://test-idp.example.com"),
      "sub" => Keyword.get(opts, :sub, "agent-oidc-001"),
      "aud" => Keyword.get(opts, :aud, "apm-v5-test"),
      "iat" => now - 10,
      "exp" => Keyword.get(opts, :exp, now + 300)
    }
  end

  defp bypass_jwks_response do
    # HMAC symmetric key exposed as a "oct" JWK for test only.
    # Real providers use RSA/EC, but for unit tests HS256 is sufficient.
    %{
      "keys" => [
        %{
          "kty" => "oct",
          "k" => Base.url_encode64("test-secret-key-32-bytes-padded!", padding: false),
          "alg" => "HS256",
          "use" => "sig"
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Setup: start OidcVerifier under test supervision
  # ---------------------------------------------------------------------------

  setup do
    bypass = Bypass.open()
    issuer = "http://localhost:#{bypass.port}"

    # Mock .well-known/openid-configuration
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      body =
        Jason.encode!(%{
          "issuer" => issuer,
          "jwks_uri" => "#{issuer}/jwks"
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    # Mock /jwks
    Bypass.stub(bypass, "GET", "/jwks", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(bypass_jwks_response()))
    end)

    # Configure a test OIDC provider dynamically
    provider_cfg = %{issuer: issuer, audience: "apm-v5-test"}

    # Start a fresh verifier for each test (isolated state)
    {:ok, pid} =
      start_supervised(
        {OidcVerifier, providers: %{test_idp: provider_cfg}, name: nil}
      )

    %{bypass: bypass, issuer: issuer, verifier: pid}
  end

  # ---------------------------------------------------------------------------
  # verify_id_token/2 — happy path
  # ---------------------------------------------------------------------------

  describe "verify_id_token/2 happy path" do
    test "verifies a valid JWT and returns {:ok, claims}", %{verifier: pid, issuer: issuer} do
      jwt = build_jwt(valid_claims(iss: issuer))

      assert {:ok, claims} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
      assert claims["sub"] == "agent-oidc-001"
      assert claims["aud"] == "apm-v5-test"
    end

    test "sub claim is present in returned claims", %{verifier: pid, issuer: issuer} do
      jwt = build_jwt(valid_claims(iss: issuer, sub: "enterprise-agent-xyz"))
      assert {:ok, claims} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
      assert claims["sub"] == "enterprise-agent-xyz"
    end
  end

  # ---------------------------------------------------------------------------
  # verify_id_token/2 — rejection cases
  # ---------------------------------------------------------------------------

  describe "verify_id_token/2 rejection" do
    test "rejects an expired token", %{verifier: pid, issuer: issuer} do
      expired_claims = valid_claims(iss: issuer, exp: System.system_time(:second) - 60)
      jwt = build_jwt(expired_claims)

      assert {:error, reason} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
      assert reason == :token_expired or match?({:token_expired, _}, reason)
    end

    test "rejects a token with wrong audience", %{verifier: pid, issuer: issuer} do
      wrong_aud_claims = valid_claims(iss: issuer, aud: "some-other-service")
      jwt = build_jwt(wrong_aud_claims)

      assert {:error, reason} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
      assert reason == :invalid_audience or match?({:invalid_audience, _}, reason)
    end

    test "rejects a tampered JWT (bad signature)", %{verifier: pid, issuer: issuer} do
      jwt = build_jwt(valid_claims(iss: issuer), "wrong-secret-key-32-bytes-paddd!")
      assert {:error, _reason} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
    end

    test "rejects a malformed JWT string", %{verifier: pid} do
      assert {:error, _reason} = OidcVerifier.verify_id_token(pid, "not.a.jwt", :test_idp)
    end
  end

  # ---------------------------------------------------------------------------
  # Missing provider configuration
  # ---------------------------------------------------------------------------

  describe "missing provider config" do
    test "returns {:error, :provider_not_configured} for unknown provider", %{verifier: pid} do
      jwt = build_jwt(valid_claims())

      assert {:error, :provider_not_configured} =
               OidcVerifier.verify_id_token(pid, jwt, :nonexistent_provider)
    end
  end

  # ---------------------------------------------------------------------------
  # No providers configured (default module name, Application.get_env path)
  # ---------------------------------------------------------------------------

  describe "no providers configured" do
    test "returns {:error, :no_oidc_providers_configured} when env is empty" do
      # Start a verifier with no providers — simulates unconfigured state
      {:ok, pid} = start_supervised({OidcVerifier, providers: %{}, name: nil}, id: :no_providers)

      jwt = build_jwt(valid_claims())
      assert {:error, :no_oidc_providers_configured} = OidcVerifier.verify_id_token(pid, jwt, :any)
    end
  end

  # ---------------------------------------------------------------------------
  # JWKS cache behavior
  # ---------------------------------------------------------------------------

  describe "JWKS caching" do
    test "second verify call hits cache (JWKS endpoint called only once)", %{
      bypass: bypass,
      verifier: pid,
      issuer: issuer
    } do
      # Count JWKS requests via Bypass expect
      # We use Bypass.expect_once for the openid-configuration and jwks on first call
      # then stub for subsequent — if the second verify triggered another JWKS fetch,
      # the test would crash with "unexpected request".
      # Strategy: use a counter in process dict via an agent.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "GET", "/jwks", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(bypass_jwks_response()))
      end)

      jwt = build_jwt(valid_claims(iss: issuer))
      assert {:ok, _} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)
      assert {:ok, _} = OidcVerifier.verify_id_token(pid, jwt, :test_idp)

      # JWKS should have been fetched once (second call uses cache)
      jwks_calls = Agent.get(counter, & &1)
      assert jwks_calls == 1

      Agent.stop(counter)
    end
  end

  # ---------------------------------------------------------------------------
  # SessionStore integration
  # ---------------------------------------------------------------------------

  describe "SessionStore.create/2 with oidc_id_token" do
    setup do
      # Ensure SessionStore is running (may already be from app supervisor in test env)
      case Process.whereis(SessionStore) do
        nil ->
          {:ok, _} = start_supervised(SessionStore)

        _pid ->
          :ok
      end

      :ok
    end

    test "uses OIDC sub claim as user_id when oidc_id_token is valid", %{verifier: pid, issuer: issuer} do
      jwt = build_jwt(valid_claims(iss: issuer, sub: "okta|enterprise-agent-999"))

      {:ok, session_id} =
        SessionStore.create(
          "ignored-local-id",
          "agent",
          oidc_id_token: jwt,
          oidc_verifier: pid,
          oidc_provider: :test_idp
        )

      session = SessionStore.get(session_id)
      assert session != nil
      # OIDC sub takes precedence over local user_id
      assert session.user_id == "okta|enterprise-agent-999"
      assert session.metadata[:oidc_verified] == true
      assert session.metadata[:oidc_provider] == :test_idp

      SessionStore.destroy(session_id)
    end

    test "falls back to local user_id when oidc_id_token is absent", %{} do
      {:ok, session_id} = SessionStore.create("local-agent-001", "agent")
      session = SessionStore.get(session_id)

      assert session.user_id == "local-agent-001"
      refute Map.get(session.metadata, :oidc_verified)

      SessionStore.destroy(session_id)
    end

    test "returns {:error, _} when oidc_id_token is present but verification fails", %{
      verifier: pid,
      issuer: issuer
    } do
      expired_jwt = build_jwt(valid_claims(iss: issuer, exp: System.system_time(:second) - 60))

      assert {:error, _reason} =
               SessionStore.create(
                 "user",
                 "agent",
                 oidc_id_token: expired_jwt,
                 oidc_verifier: pid,
                 oidc_provider: :test_idp
               )
    end

    test "session created without oidc_id_token has no oidc metadata" do
      {:ok, session_id} = SessionStore.create("regular-user", "admin")
      session = SessionStore.get(session_id)

      refute session.metadata[:oidc_verified]
      refute session.metadata[:oidc_provider]

      SessionStore.destroy(session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Named module API (Application.get_env based)
  # ---------------------------------------------------------------------------

  describe "OidcVerifier module-level API (no pid)" do
    test "returns {:error, :no_oidc_providers_configured} when no config set" do
      # Ensure no config is set in test env for :oidc_providers
      Application.delete_env(:apm, :oidc_providers)
      jwt = build_jwt(valid_claims())
      assert {:error, :no_oidc_providers_configured} = OidcVerifier.verify_id_token(jwt, :okta)
    end
  end
end
