defmodule ApmV5Web.V2.ProvenanceControllerTest do
  @moduledoc """
  Tests for GET /api/v2/provenance/slsa/:attestation_id
  (comp-v10.3-s1 / CP-299).
  """
  use ApmV5Web.ConnCase, async: false

  alias ApmV5.Provenance.{ArtifactAttestation, SLSAProvenance}
  alias ApmV5.Identity.KeyStore

  setup do
    case Process.whereis(KeyStore) do
      nil -> {:ok, _} = KeyStore.start_link([])
      _ -> :ok
    end

    ArtifactAttestation.init_table()
    :ok
  end

  describe "GET /api/v2/provenance/slsa/:attestation_id" do
    test "returns a DSSE envelope for a stored attestation", %{conn: conn} do
      attest = build_signed_attestation()
      :ok = ArtifactAttestation.store(attest)
      attestation_id = SLSAProvenance.attestation_id(attest)

      conn = get(conn, ~p"/api/v2/provenance/slsa/#{attestation_id}")
      body = json_response(conn, 200)

      assert body["payloadType"] == "application/vnd.in-toto+json"
      assert is_binary(body["payload"])
      assert [%{"sig" => _, "keyid" => _}] = body["signatures"]
    end

    test "envelope payload decodes to an in-toto Statement v1", %{conn: conn} do
      attest = build_signed_attestation()
      :ok = ArtifactAttestation.store(attest)
      attestation_id = SLSAProvenance.attestation_id(attest)

      conn = get(conn, ~p"/api/v2/provenance/slsa/#{attestation_id}")
      body = json_response(conn, 200)
      stmt = body["payload"] |> Base.decode64!() |> Jason.decode!()

      assert stmt["_type"] == "https://in-toto.io/Statement/v1"
      assert stmt["predicateType"] == "https://slsa.dev/provenance/v1"
    end

    test "DSSE envelope verifies against KeyStore", %{conn: conn} do
      attest = build_signed_attestation()
      :ok = ArtifactAttestation.store(attest)
      attestation_id = SLSAProvenance.attestation_id(attest)

      conn = get(conn, ~p"/api/v2/provenance/slsa/#{attestation_id}")
      body = json_response(conn, 200)

      assert SLSAProvenance.verify(body) == :ok
    end

    test "returns 404 for an unknown attestation_id", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/provenance/slsa/deadbeef00000000000000000000beef")
      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  defp build_signed_attestation do
    attest = %ArtifactAttestation{
      subject: [%{name: "lib/bar.ex", sha256: String.duplicate("c", 64)}],
      agent_id: "agent-7",
      tool_name: "Edit",
      session_id: "sess-7",
      formation_id: "fmt-7",
      timestamp: "2026-05-28T01:00:00Z",
      signature: <<0::512>>
    }

    payload = ArtifactAttestation.signing_payload(attest)
    sig = KeyStore.sign(payload)
    %{attest | signature: sig}
  end
end
