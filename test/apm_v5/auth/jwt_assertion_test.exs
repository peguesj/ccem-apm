defmodule ApmV5.Auth.JwtAssertionTest do
  @moduledoc """
  TDD coverage for ApmV5.Auth.JwtAssertion (v10.0.0/s1).

  Covers:
  - sign+verify roundtrip
  - tampered payload fails verification
  - tampered signature fails verification
  - expired JWT rejected
  - wrong-issuer JWT rejected (signed with different key)
  - claim contents preserved
  - jti uniqueness
  - graceful handling of malformed tokens
  """

  use ExUnit.Case, async: false

  alias ApmV5.Auth.JwtAssertion
  alias ApmV5.Identity.KeyStore

  @tmp_key_file Path.join(System.tmp_dir!(), "jwt_assertion_test_key.pem")
  @alt_key_file Path.join(System.tmp_dir!(), "jwt_assertion_test_alt_key.pem")

  setup do
    File.rm(@tmp_key_file)
    File.rm(@alt_key_file)

    {:ok, ks} = KeyStore.start_link(name: :jwt_test_ks, key_file: @tmp_key_file)

    on_exit(fn ->
      if Process.alive?(ks), do: GenServer.stop(ks)
      File.rm(@tmp_key_file)
      File.rm(@alt_key_file)
    end)

    {:ok, keystore: ks}
  end

  describe "sign_assertion/3 + verify_assertion/2" do
    test "roundtrip — valid signed JWT verifies and returns claims", %{keystore: ks} do
      claims = %{
        agent_id: "agent-roundtrip",
        formation_id: "fmt-123",
        invoked_by: "user-1",
        parent_agent_id: nil,
        session_id: "sess-1"
      }

      jwt = JwtAssertion.sign_assertion(claims, keystore: ks)
      assert is_binary(jwt)
      assert String.contains?(jwt, ".")
      # 3 segments header.payload.signature
      assert length(String.split(jwt, ".")) == 3

      assert {:ok, verified} = JwtAssertion.verify_assertion(jwt, keystore: ks)
      assert verified["agent_id"] == "agent-roundtrip"
      assert verified["formation_id"] == "fmt-123"
      assert verified["invoked_by"] == "user-1"
      assert verified["session_id"] == "sess-1"
      assert is_integer(verified["iat"])
      assert is_integer(verified["exp"])
      assert verified["exp"] > verified["iat"]
      assert is_binary(verified["jti"])
    end

    test "tampered payload fails verification (flip a byte)", %{keystore: ks} do
      claims = %{agent_id: "agent-tamper", session_id: "sess-x"}
      jwt = JwtAssertion.sign_assertion(claims, keystore: ks)

      [header, payload, sig] = String.split(jwt, ".")

      # Decode payload, mutate, re-encode (sig over original payload still)
      {:ok, decoded} = Base.url_decode64(payload, padding: false)
      tampered_decoded = String.replace(decoded, "agent-tamper", "agent-EVIL00")
      tampered_payload = Base.url_encode64(tampered_decoded, padding: false)

      tampered_jwt = Enum.join([header, tampered_payload, sig], ".")

      assert {:error, :invalid_signature} = JwtAssertion.verify_assertion(tampered_jwt, keystore: ks)
    end

    test "tampered signature fails verification", %{keystore: ks} do
      claims = %{agent_id: "agent-sig-tamper", session_id: "sess-y"}
      jwt = JwtAssertion.sign_assertion(claims, keystore: ks)

      [header, payload, sig_b64] = String.split(jwt, ".")

      # Decode signature → flip a middle byte → re-encode. This guarantees a
      # different raw signature regardless of any base64 char-padding subtleties.
      {:ok, sig_bytes} = Base.url_decode64(sig_b64, padding: false)
      mid = div(byte_size(sig_bytes), 2)
      <<head::binary-size(mid), b::8, tail::binary>> = sig_bytes
      flipped = <<head::binary, Bitwise.bxor(b, 0xFF)::8, tail::binary>>
      tampered_sig = Base.url_encode64(flipped, padding: false)

      tampered_jwt = Enum.join([header, payload, tampered_sig], ".")

      assert {:error, reason} = JwtAssertion.verify_assertion(tampered_jwt, keystore: ks)
      assert reason in [:invalid_signature, :malformed_token]
    end

    test "expired JWT rejected (ttl=-1)", %{keystore: ks} do
      claims = %{agent_id: "agent-expired", session_id: "sess-z"}
      # Negative TTL → already expired
      jwt = JwtAssertion.sign_assertion(claims, [keystore: ks, ttl_seconds: -1])

      assert {:error, :token_expired} = JwtAssertion.verify_assertion(jwt, keystore: ks)
    end

    test "wrong-issuer JWT rejected (signed with different key)", %{keystore: ks} do
      # Start an alternate key store
      {:ok, alt_ks} = KeyStore.start_link(name: :alt_test_ks, key_file: @alt_key_file)

      claims = %{agent_id: "agent-wrong-issuer", session_id: "sess-w"}
      # Sign with alternate key
      jwt = JwtAssertion.sign_assertion(claims, keystore: alt_ks)

      # Verify against primary key store — should fail
      assert {:error, :invalid_signature} = JwtAssertion.verify_assertion(jwt, keystore: ks)

      # But valid when verified against the alt key store
      assert {:ok, _claims} = JwtAssertion.verify_assertion(jwt, keystore: alt_ks)

      GenServer.stop(alt_ks)
    end

    test "jti is unique across two signs of identical claims", %{keystore: ks} do
      claims = %{agent_id: "agent-jti", session_id: "sess-j"}
      jwt1 = JwtAssertion.sign_assertion(claims, keystore: ks)
      jwt2 = JwtAssertion.sign_assertion(claims, keystore: ks)

      {:ok, v1} = JwtAssertion.verify_assertion(jwt1, keystore: ks)
      {:ok, v2} = JwtAssertion.verify_assertion(jwt2, keystore: ks)

      assert v1["jti"] != v2["jti"]
    end

    test "header advertises EdDSA algorithm", %{keystore: ks} do
      jwt = JwtAssertion.sign_assertion(%{agent_id: "a"}, keystore: ks)
      [header_b64, _payload, _sig] = String.split(jwt, ".")
      {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
      header = Jason.decode!(header_json)
      assert header["alg"] == "EdDSA"
      assert header["typ"] == "JWT"
    end

    test "malformed token returns :malformed_token", %{keystore: ks} do
      assert {:error, :malformed_token} = JwtAssertion.verify_assertion("not-a-jwt", keystore: ks)
      assert {:error, :malformed_token} = JwtAssertion.verify_assertion("only.two", keystore: ks)
      assert {:error, :malformed_token} = JwtAssertion.verify_assertion("", keystore: ks)
    end

    test "ttl_seconds defaults to 3600", %{keystore: ks} do
      now = System.system_time(:second)
      jwt = JwtAssertion.sign_assertion(%{agent_id: "a"}, keystore: ks)
      {:ok, claims} = JwtAssertion.verify_assertion(jwt, keystore: ks)

      # iat within 5s of now, exp ~ iat + 3600
      assert_in_delta claims["iat"], now, 5
      assert_in_delta claims["exp"], claims["iat"] + 3600, 1
    end

    test "custom ttl_seconds honored", %{keystore: ks} do
      jwt = JwtAssertion.sign_assertion(%{agent_id: "a"}, [keystore: ks, ttl_seconds: 60])
      {:ok, claims} = JwtAssertion.verify_assertion(jwt, keystore: ks)
      assert_in_delta claims["exp"], claims["iat"] + 60, 1
    end
  end
end
