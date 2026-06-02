defmodule Apm.Provenance.SLSAProvenanceTest do
  @moduledoc """
  TDD suite for SLSA Provenance v1.0 generation + DSSE envelope signing
  (comp-v10.3-s1 / CP-299). Verifies:

    * canonical in-toto Statement shape
    * SLSA predicateType present
    * subject digest preserved from ArtifactAttestation
    * DSSE PAE (pre-authentication encoding) is bit-for-bit correct
    * sign + verify roundtrip
    * tampered subject digest is detected by signature verification
  """
  use ExUnit.Case, async: false

  alias Apm.Provenance.{ArtifactAttestation, SLSAProvenance}
  alias Apm.Identity.KeyStore

  setup do
    # Boot a KeyStore on-demand so tests are self-contained.
    case Process.whereis(KeyStore) do
      nil -> {:ok, _} = KeyStore.start_link([])
      _ -> :ok
    end

    ArtifactAttestation.init_table()

    attest = %ArtifactAttestation{
      subject: [%{name: "lib/foo.ex", sha256: String.duplicate("a", 64)}],
      agent_id: "agent-1",
      tool_name: "Write",
      session_id: "sess-1",
      formation_id: "fmt-1",
      timestamp: "2026-05-28T00:00:00Z",
      signature: <<0::512>>
    }

    {:ok, attest: attest}
  end

  describe "from_attestation/1" do
    test "produces a canonical in-toto Statement v1", %{attest: attest} do
      statement = SLSAProvenance.from_attestation(attest)

      assert statement["_type"] == "https://in-toto.io/Statement/v1"
      assert statement["predicateType"] == "https://slsa.dev/provenance/v1"
    end

    test "preserves the subject and its sha256 digest", %{attest: attest} do
      statement = SLSAProvenance.from_attestation(attest)
      [subj] = statement["subject"]

      assert subj["name"] == "lib/foo.ex"
      assert subj["digest"]["sha256"] == String.duplicate("a", 64)
    end

    test "embeds buildDefinition with internal + external params", %{attest: attest} do
      statement = SLSAProvenance.from_attestation(attest)
      bd = statement["predicate"]["buildDefinition"]

      assert bd["buildType"] == "https://ccem.dev/provenance/tool-call/v1"
      assert bd["externalParameters"]["tool"] == "Write"
      assert bd["externalParameters"]["path"] == "lib/foo.ex"
      assert bd["internalParameters"]["agent_id"] == "agent-1"
      assert bd["internalParameters"]["session_id"] == "sess-1"
      assert bd["internalParameters"]["formation_id"] == "fmt-1"
    end

    test "embeds runDetails.builder.id pinned to current version", %{attest: attest} do
      statement = SLSAProvenance.from_attestation(attest)
      builder = statement["predicate"]["runDetails"]["builder"]

      assert builder["id"] =~ "https://ccem.dev/apm/"
    end

    test "embeds runDetails.metadata.invocationId derived from attestation", %{attest: attest} do
      statement = SLSAProvenance.from_attestation(attest)
      md = statement["predicate"]["runDetails"]["metadata"]

      assert is_binary(md["invocationId"])
      assert md["startedOn"] == "2026-05-28T00:00:00Z"
      assert is_binary(md["finishedOn"])
    end
  end

  describe "attestation_id/1" do
    test "is deterministic given the same signed attestation", %{attest: attest} do
      signed = sign_attest(attest)
      assert SLSAProvenance.attestation_id(signed) == SLSAProvenance.attestation_id(signed)
    end

    test "differs when the signature differs", %{attest: attest} do
      a = %{attest | signature: :crypto.strong_rand_bytes(64)}
      b = %{attest | signature: :crypto.strong_rand_bytes(64)}
      refute SLSAProvenance.attestation_id(a) == SLSAProvenance.attestation_id(b)
    end
  end

  describe "DSSE envelope" do
    test "sign/1 returns a properly-encoded DSSE envelope", %{attest: attest} do
      envelope = SLSAProvenance.sign(attest)

      assert envelope["payloadType"] == "application/vnd.in-toto+json"
      assert is_binary(envelope["payload"])
      assert is_list(envelope["signatures"])
      assert [%{"sig" => _, "keyid" => _}] = envelope["signatures"]
    end

    test "pae/2 follows the DSSE pre-authentication encoding spec" do
      # DSSE PAE: "DSSEv1" SP <len(payloadType)> SP payloadType SP <len(payload)> SP payload
      payload_type = "application/vnd.in-toto+json"
      payload = "hello"

      expected =
        "DSSEv1 #{byte_size(payload_type)} #{payload_type} #{byte_size(payload)} #{payload}"

      assert SLSAProvenance.pae(payload_type, payload) == expected
    end

    test "verify/1 accepts a freshly signed envelope", %{attest: attest} do
      envelope = SLSAProvenance.sign(attest)
      assert SLSAProvenance.verify(envelope) == :ok
    end

    test "verify/1 rejects a tampered payload", %{attest: attest} do
      envelope = SLSAProvenance.sign(attest)

      # Decode payload, tamper the subject digest, re-encode but keep the same
      # signature. Verification MUST fail because PAE will differ.
      decoded = Base.decode64!(envelope["payload"])
      stmt = Jason.decode!(decoded)
      tampered_stmt =
        update_in(stmt, ["subject", Access.at(0), "digest", "sha256"], fn _ ->
          String.duplicate("b", 64)
        end)
      tampered_payload = Base.encode64(Jason.encode!(tampered_stmt))
      tampered_envelope = %{envelope | "payload" => tampered_payload}

      assert SLSAProvenance.verify(tampered_envelope) == {:error, :bad_signature}
    end
  end

  defp sign_attest(attest) do
    payload = ArtifactAttestation.signing_payload(attest)
    sig = KeyStore.sign(payload)
    %{attest | signature: sig}
  end
end
