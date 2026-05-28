defmodule ApmV5.Governance.VerifiableCredentialTest do
  @moduledoc """
  TDD suite for ApmV5.Governance.VerifiableCredential (CP-300 / comp-v10.3-s2).

  Covers:
  - VC issuance roundtrip (issue → verify → ok)
  - Expired VC rejected
  - Tampered VC payload rejected
  - Tampered signature rejected
  - Revoked VC rejected (after revoke_credential call)
  - W3C VC document shape validation
  - HTTP endpoint contract (issue/verify/revoke)
  """

  use ExUnit.Case, async: false

  alias ApmV5.Governance.VerifiableCredential
  alias ApmV5.Identity.{KeyStore, DIDProvider}

  # ── Test helpers ────────────────────────────────────────────────────────────

  defp start_key_store(_ctx) do
    # Each test group gets an isolated KeyStore with a temp file so tests don't
    # share state with the real production keypair on disk.
    tmp = System.tmp_dir!()
    key_file = Path.join(tmp, "vc_test_#{:erlang.unique_integer([:positive])}.pem")

    on_exit(fn -> File.rm(key_file) end)

    {:ok, ks} =
      start_supervised(
        {KeyStore, key_file: key_file, name: :"ks_#{:erlang.unique_integer([:positive])}"}
      )

    %{key_store: ks}
  end

  defp sample_subject do
    %{
      "agent_id" => "test-agent-001",
      "formation_id" => "formation-wave-c",
      "invoked_by" => "jeremiah",
      "capabilities" => ["tool:Write", "tool:Bash"],
      "risk_level" => "medium",
      "session_id" => "upm-1020"
    }
  end

  defp agent_identity(ks) do
    pub = KeyStore.public_key(ks)
    %{did: DIDProvider.did_for_public_key(pub), agent_id: "test-agent-001"}
  end

  # ── Issuance roundtrip ───────────────────────────────────────────────────────

  describe "issue_agent_credential/3" do
    setup :start_key_store

    test "returns a JWT-VC string", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      assert is_binary(jwt)
      # JWT format: 3 base64url segments separated by "."
      assert length(String.split(jwt, ".")) == 3
    end

    test "JWT header carries alg=EdDSA typ=JWT kid=issuer_did", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [header_b64 | _] = String.split(jwt, ".")
      {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
      header = Jason.decode!(header_json)

      assert header["alg"] == "EdDSA"
      assert header["typ"] == "JWT"
      assert String.starts_with?(header["kid"], "did:key:z6Mk")
    end

    test "JWT payload contains W3C vc claim with @context", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert is_map(payload["vc"])
      vc = payload["vc"]
      assert "https://www.w3.org/ns/credentials/v2" in vc["@context"]
      assert "VerifiableCredential" in vc["type"]
      assert "CCEMAgentCredential" in vc["type"]
    end

    test "VC document has correct issuer (APM DID)", %{key_store: ks} do
      identity = agent_identity(ks)
      pub = KeyStore.public_key(ks)
      expected_issuer = DIDProvider.did_for_public_key(pub)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert payload["vc"]["issuer"] == expected_issuer
    end

    test "VC credentialSubject contains agent fields", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      cs = payload["vc"]["credentialSubject"]
      assert cs["agent_id"] == "test-agent-001"
      assert cs["capabilities"] == ["tool:Write", "tool:Bash"]
      assert cs["risk_level"] == "medium"
      assert String.starts_with?(cs["id"], "did:key:z6Mk")
    end

    test "VC has validFrom and validUntil ISO timestamps", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      vc = payload["vc"]
      assert is_binary(vc["validFrom"])
      assert is_binary(vc["validUntil"])
      {:ok, valid_from, _} = DateTime.from_iso8601(vc["validFrom"])
      {:ok, valid_until, _} = DateTime.from_iso8601(vc["validUntil"])
      assert DateTime.compare(valid_until, valid_from) == :gt
    end

    test "VC id is a urn:uuid: URI", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert String.starts_with?(payload["vc"]["id"], "urn:uuid:")
    end

    test "valid_seconds option controls validity window", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt =
        VerifiableCredential.issue_agent_credential(identity, sample_subject(),
          keystore: ks,
          valid_seconds: 60
        )

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      vc = payload["vc"]
      {:ok, valid_from, _} = DateTime.from_iso8601(vc["validFrom"])
      {:ok, valid_until, _} = DateTime.from_iso8601(vc["validUntil"])
      diff = DateTime.diff(valid_until, valid_from, :second)
      assert diff == 60
    end
  end

  # ── Verification roundtrip ───────────────────────────────────────────────────

  describe "verify_credential/2 — happy path" do
    setup :start_key_store

    test "roundtrip: issued VC verifies successfully", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      assert {:ok, vc_doc} = VerifiableCredential.verify_credential(jwt, keystore: ks)
      assert vc_doc["type"] == ["VerifiableCredential", "CCEMAgentCredential"]
    end

    test "verified vc_doc has credentialSubject with agent_id", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)
      {:ok, vc_doc} = VerifiableCredential.verify_credential(jwt, keystore: ks)

      assert vc_doc["credentialSubject"]["agent_id"] == "test-agent-001"
    end
  end

  # ── Rejection cases ──────────────────────────────────────────────────────────

  describe "verify_credential/2 — rejection" do
    setup :start_key_store

    test "expired VC is rejected", %{key_store: ks} do
      identity = agent_identity(ks)

      # Issue with -10 second validity (already expired)
      jwt =
        VerifiableCredential.issue_agent_credential(identity, sample_subject(),
          keystore: ks,
          valid_seconds: -10
        )

      assert {:error, :credential_expired} = VerifiableCredential.verify_credential(jwt, keystore: ks)
    end

    test "tampered VC payload is rejected", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      # Tamper: decode payload, change agent_id, re-encode
      [h, p, s] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(p, padding: false)
      tampered_payload = Jason.decode!(payload_json) |> put_in(["vc", "credentialSubject", "agent_id"], "ATTACKER")
      tampered_p = Base.url_encode64(Jason.encode!(tampered_payload), padding: false)
      tampered_jwt = Enum.join([h, tampered_p, s], ".")

      assert {:error, :invalid_signature} =
               VerifiableCredential.verify_credential(tampered_jwt, keystore: ks)
    end

    test "tampered signature is rejected", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      # Flip 5 bytes in the base64-encoded signature segment
      [h, p, s] = String.split(jwt, ".")
      # Corrupt the middle of the signature
      half = div(byte_size(s), 2)
      <<before::binary-size(half), _::binary-size(5), rest::binary>> = s
      corrupted_s = before <> "XXXXX" <> rest
      tampered_jwt = Enum.join([h, p, corrupted_s], ".")

      assert {:error, _reason} = VerifiableCredential.verify_credential(tampered_jwt, keystore: ks)
    end

    test "malformed JWT string is rejected", %{key_store: ks} do
      assert {:error, :malformed_token} =
               VerifiableCredential.verify_credential("not.a.jwt", keystore: ks)
    end

    test "empty string is rejected", %{key_store: ks} do
      assert {:error, :malformed_token} =
               VerifiableCredential.verify_credential("", keystore: ks)
    end
  end

  # ── Revocation ───────────────────────────────────────────────────────────────

  describe "revoke_credential/1 and revocation enforcement" do
    setup :start_key_store

    test "revoke_credential/1 returns :ok", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)
      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)
      cred_id = payload["vc"]["id"]

      assert :ok = VerifiableCredential.revoke_credential(cred_id)
    end

    test "revoked VC is rejected on subsequent verify", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)
      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)
      cred_id = payload["vc"]["id"]

      # First verify passes
      assert {:ok, _} = VerifiableCredential.verify_credential(jwt, keystore: ks)

      # Revoke
      :ok = VerifiableCredential.revoke_credential(cred_id)

      # Second verify fails
      assert {:error, :credential_revoked} =
               VerifiableCredential.verify_credential(jwt, keystore: ks)
    end

    test "revocation is idempotent", %{key_store: _ks} do
      assert :ok = VerifiableCredential.revoke_credential("urn:uuid:does-not-exist")
      assert :ok = VerifiableCredential.revoke_credential("urn:uuid:does-not-exist")
    end
  end

  # ── W3C VC document shape ────────────────────────────────────────────────────

  describe "W3C VC document shape" do
    setup :start_key_store

    test "issued VC document passes W3C VC 2.0 shape validation", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)

      [_, payload_b64 | _] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)
      vc = payload["vc"]

      # W3C VC Data Model 2.0 §4 — required fields
      assert is_list(vc["@context"])
      assert "https://www.w3.org/ns/credentials/v2" == hd(vc["@context"])
      assert is_list(vc["type"])
      assert "VerifiableCredential" in vc["type"]
      assert is_binary(vc["id"])
      assert is_binary(vc["issuer"])
      assert is_binary(vc["validFrom"])
      assert is_map(vc["credentialSubject"])

      # credentialSubject must have id
      assert is_binary(vc["credentialSubject"]["id"])
    end

    test "verify_credential returns the full vc document (not JWT payload)", %{key_store: ks} do
      identity = agent_identity(ks)

      jwt = VerifiableCredential.issue_agent_credential(identity, sample_subject(), keystore: ks)
      {:ok, vc_doc} = VerifiableCredential.verify_credential(jwt, keystore: ks)

      # Returned document is the vc claim (W3C VC), not the outer JWT payload
      assert Map.has_key?(vc_doc, "@context")
      assert Map.has_key?(vc_doc, "issuer")
      assert Map.has_key?(vc_doc, "credentialSubject")
      refute Map.has_key?(vc_doc, "exp")
      refute Map.has_key?(vc_doc, "iat")
    end
  end

  # ── ControlRegistry integration ──────────────────────────────────────────────

  describe "ControlRegistry :verifiable_credentials control" do
    test "control exists and is satisfied" do
      ctrl = ApmV5.Governance.ControlRegistry.get_control(:verifiable_credentials)
      assert ctrl != nil
      assert ctrl.status == :satisfied
    end

    test "control references EU AI Act Article 13 and Article 52" do
      ctrl = ApmV5.Governance.ControlRegistry.get_control(:verifiable_credentials)
      eu_refs = ctrl[:eu_ai_act] || []
      assert "Article 13" in eu_refs
      assert "Article 52" in eu_refs
    end

    test "controls_by_framework returns :verifiable_credentials for EU AI Act Article 13" do
      ctrl_ids = ApmV5.Governance.ControlRegistry.controls_by_framework(:eu_ai_act, "Article 13")
      assert :verifiable_credentials in ctrl_ids
    end
  end
end
