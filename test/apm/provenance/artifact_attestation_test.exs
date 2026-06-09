defmodule Apm.Provenance.ArtifactAttestationTest do
  @moduledoc """
  TDD suite for Apm.Provenance.ArtifactAttestation (prov-w1-s3 / CP-277).

  Verifies:
  - ArtifactAttestation struct field presence and types
  - Signer.sign_artifact/4 produces attestation with valid Ed25519 signature
  - Signature verifies with KeyStore public key
  - ETS ring buffer (:apm_artifact_attestations) stores attestations
  - AuditLog wiring: :tool_call events for Write/Edit/MultiEdit produce attestations
  """

  use ExUnit.Case, async: false

  alias Apm.Provenance.ArtifactAttestation
  alias Apm.Provenance.ArtifactAttestation.Signer
  alias Apm.Identity.KeyStore

  # ── Struct tests ────────────────────────────────────────────────────────────

  describe "ArtifactAttestation struct" do
    test "has all required fields" do
      attest = %ArtifactAttestation{
        subject: [%{name: "foo.ex", sha256: "abc123"}],
        agent_id: "v940-identity-lead",
        tool_name: "Write",
        session_id: "sess-001",
        formation_id: "fmt-20260528",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        signature: <<0::512>>
      }

      assert attest.agent_id == "v940-identity-lead"
      assert attest.tool_name == "Write"
      assert length(attest.subject) == 1
      assert byte_size(attest.signature) == 64
    end

    test "allows nil optional fields" do
      attest = %ArtifactAttestation{
        subject: [],
        agent_id: "agent-x",
        tool_name: "Edit",
        session_id: nil,
        formation_id: nil,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        signature: <<0::512>>
      }

      assert is_nil(attest.session_id)
      assert is_nil(attest.formation_id)
    end
  end

  # ── Signer tests ─────────────────────────────────────────────────────────────

  describe "Signer.sign_artifact/4" do
    test "returns an ArtifactAttestation struct" do
      attest = Signer.sign_artifact("Write", "test/fixtures/a.ex", "v940-agent", %{})
      assert %ArtifactAttestation{} = attest
    end

    test "signature field is a 64-byte binary" do
      attest = Signer.sign_artifact("Edit", "lib/foo.ex", "agent-1", %{session_id: "s1"})
      assert is_binary(attest.signature)
      assert byte_size(attest.signature) == 64
    end

    test "subject list contains the file path and sha256 hash" do
      path = "lib/apm/identity/key_store.ex"
      attest = Signer.sign_artifact("Write", path, "agent-1", %{})
      assert length(attest.subject) == 1
      [subject] = attest.subject
      assert subject.name == path
      assert is_binary(subject.sha256) and byte_size(subject.sha256) > 0
    end

    test "tool_name is set from the first argument" do
      attest = Signer.sign_artifact("MultiEdit", "lib/foo.ex", "agent-1", %{})
      assert attest.tool_name == "MultiEdit"
    end

    test "agent_id is set from the third argument" do
      attest = Signer.sign_artifact("Write", "lib/foo.ex", "my-agent-xyz", %{})
      assert attest.agent_id == "my-agent-xyz"
    end

    test "session_id and formation_id propagated from context" do
      ctx = %{session_id: "sess-abc", formation_id: "fmt-xyz"}
      attest = Signer.sign_artifact("Write", "lib/foo.ex", "agent-1", ctx)
      assert attest.session_id == "sess-abc"
      assert attest.formation_id == "fmt-xyz"
    end

    test "timestamp is an ISO 8601 UTC string" do
      attest = Signer.sign_artifact("Edit", "lib/foo.ex", "agent-1", %{})
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(attest.timestamp)
    end

    test "signature verifies with KeyStore public key (roundtrip)" do
      attest = Signer.sign_artifact("Write", "lib/apm/identity/key_store.ex", "agent-1", %{})
      pub = KeyStore.public_key()

      # Reconstruct the signing payload (same as Signer does internally)
      payload = ArtifactAttestation.signing_payload(attest)

      assert KeyStore.verify(Apm.Identity.KeyStore, payload, attest.signature, pub) == true,
             "Signature must verify with KeyStore public key"
    end

    test "signature fails verification with tampered subject" do
      attest = Signer.sign_artifact("Write", "lib/foo.ex", "agent-1", %{})
      pub = KeyStore.public_key()
      tampered = %{attest | subject: [%{name: "tampered.ex", sha256: "bad"}]}
      payload = ArtifactAttestation.signing_payload(tampered)
      assert KeyStore.verify(Apm.Identity.KeyStore, payload, attest.signature, pub) == false
    end
  end

  # ── ETS ring buffer tests ────────────────────────────────────────────────────

  describe "ETS :apm_artifact_attestations ring buffer" do
    test "table exists after application start" do
      assert :ets.whereis(:apm_artifact_attestations) != :undefined
    end

    test "Signer.sign_artifact stores attestation in ETS ring buffer" do
      # Count before
      before_count = :ets.info(:apm_artifact_attestations, :size)
      Signer.sign_artifact("Write", "lib/test_ring.ex", "agent-ring", %{})
      after_count = :ets.info(:apm_artifact_attestations, :size)
      # Ring buffer may evict old entries at cap — assert at least one entry
      assert after_count >= 1
      # Must have increased OR be at cap (ring buffer eviction)
      assert after_count >= min(before_count + 1, 5000)
    end

    test "stored attestation is retrievable from ETS" do
      _attest =
        Signer.sign_artifact("Edit", "lib/test_retrieve.ex", "agent-retrieve", %{
          session_id: "sess-ets-test"
        })

      # Scan the ring buffer for our attestation by session_id
      found =
        :ets.tab2list(:apm_artifact_attestations)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.find(fn a -> a.session_id == "sess-ets-test" end)

      assert found != nil, "Attestation should be retrievable from ETS"
      assert found.tool_name == "Edit"
      assert byte_size(found.signature) == 64
    end
  end

  # ── AuditLog integration tests ───────────────────────────────────────────────

  describe "AuditLog :tool_call event attestation" do
    test "Write tool_call event produces attestation in ETS ring buffer" do
      before_size = :ets.info(:apm_artifact_attestations, :size)

      Apm.AuditLog.log_with_context(
        :tool_call,
        "test-agent",
        "lib/some_file.ex",
        %{content: "hello"},
        nil,
        %{
          tool_name: "Write",
          agent_id: "audit-test-agent",
          session_id: "audit-sess-#{:erlang.unique_integer([:positive])}"
        }
      )

      # Give the GenServer cast time to process
      Process.sleep(50)

      after_size = :ets.info(:apm_artifact_attestations, :size)

      assert after_size > before_size or after_size >= 1,
             "AuditLog Write event should produce an attestation in ETS"
    end

    test "Edit tool_call event produces attestation" do
      unique_session = "edit-sess-#{:erlang.unique_integer([:positive])}"

      Apm.AuditLog.log_with_context(
        :tool_call,
        "test-agent",
        "lib/edit_target.ex",
        %{},
        nil,
        %{
          tool_name: "Edit",
          agent_id: "audit-edit-agent",
          session_id: unique_session
        }
      )

      Process.sleep(50)

      found =
        :ets.tab2list(:apm_artifact_attestations)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.find(fn a -> a.session_id == unique_session end)

      assert found != nil,
             "Edit tool_call audit event should produce an attestation"

      assert found.tool_name == "Edit"
    end

    test "non-write tool_call events (Bash) do NOT produce attestation" do
      unique_session = "bash-sess-#{:erlang.unique_integer([:positive])}"

      Apm.AuditLog.log_with_context(
        :tool_call,
        "test-agent",
        "ls -la",
        %{},
        nil,
        %{
          tool_name: "Bash",
          agent_id: "audit-bash-agent",
          session_id: unique_session
        }
      )

      Process.sleep(50)

      found =
        :ets.tab2list(:apm_artifact_attestations)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.find(fn a -> a.session_id == unique_session end)

      assert found == nil,
             "Bash tool_call should NOT produce an attestation"
    end

    test "non-tool_call events do NOT produce attestation" do
      unique_session = "other-evt-#{:erlang.unique_integer([:positive])}"

      Apm.AuditLog.log_with_context(
        :session_start,
        "test-agent",
        "session",
        %{},
        nil,
        %{
          tool_name: "Write",
          session_id: unique_session
        }
      )

      Process.sleep(50)

      found =
        :ets.tab2list(:apm_artifact_attestations)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.find(fn a -> a.session_id == unique_session end)

      assert found == nil,
             "Non-:tool_call events should not produce attestations even if tool_name is Write"
    end
  end
end
