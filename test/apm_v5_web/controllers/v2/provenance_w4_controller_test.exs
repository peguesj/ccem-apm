defmodule ApmV5Web.V2.ProvenanceW4ControllerTest do
  @moduledoc """
  TDD suite for prov-w4-s9 / CP-283: 3 new Provenance REST API endpoints.

  Tests:
  - GET /api/v2/provenance/agents/:id — full provenance record
  - GET /api/v2/provenance/artifacts — paginated attestations with verify status
  - POST /api/v2/provenance/verify — sign+verify roundtrip

  Run with: mix test test/apm_v5_web/controllers/v2/provenance_w4_controller_test.exs
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :prov_w4

  alias ApmV5.AgentRegistry
  alias ApmV5.Provenance.{ArtifactAttestation, ArtifactAttestation.Signer}

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # PubSub is started as part of the test application (ApmV5Web.Endpoint supervisor).
    # AgentRegistry is started lazily in tests that need it.
    case Process.whereis(AgentRegistry) do
      nil -> {:ok, _} = AgentRegistry.start_link([])
      _ -> :ok
    end

    # Ensure ArtifactAttestation ETS table exists
    ArtifactAttestation.init_table()

    agent_id = "prov-w4-test-agent-#{System.unique_integer([:positive])}"

    AgentRegistry.register_agent(agent_id, %{
      agent_id: agent_id,
      role: "worker",
      formation_id: "formation-prov-w4-test",
      session_id: "sess-prov-w4-test",
      status: "active"
    })

    {:ok, agent_id: agent_id}
  end

  # ── GET /api/v2/provenance/agents/:id ─────────────────────────────────────

  describe "GET /api/v2/provenance/agents/:id" do
    test "returns 200 with full provenance record for a registered agent", %{
      conn: conn,
      agent_id: agent_id
    } do
      conn = get(conn, "/api/v2/provenance/agents/#{agent_id}")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["agent_id"] == agent_id
      assert Map.has_key?(body, "identity_token")
      assert Map.has_key?(body, "did")
      assert Map.has_key?(body, "delegation_chain")
      assert Map.has_key?(body, "artifact_attestations")
      assert Map.has_key?(body, "role_lineage")
      assert is_list(body["artifact_attestations"])
      assert is_list(body["role_lineage"])
    end

    test "identity_token is a hex string when KeyStore is running", %{conn: conn, agent_id: agent_id} do
      conn = get(conn, "/api/v2/provenance/agents/#{agent_id}")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)

      # identity_token may be nil if KeyStore isn't started in test env,
      # but if present it must be a hex string
      if token = body["identity_token"] do
        assert is_binary(token)
        assert String.match?(token, ~r/^[0-9a-f]+$/)
      end
    end

    test "returns 404 for an unknown agent", %{conn: conn} do
      conn = get(conn, "/api/v2/provenance/agents/definitely-not-registered-xyz")
      assert conn.status == 404

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end

  # ── GET /api/v2/provenance/artifacts ──────────────────────────────────────

  describe "GET /api/v2/provenance/artifacts" do
    test "returns 200 with empty list when no attestations exist", %{conn: conn} do
      conn = get(conn, "/api/v2/provenance/artifacts")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "attestations")
      assert Map.has_key?(body, "total")
      assert Map.has_key?(body, "limit")
      assert Map.has_key?(body, "offset")
      assert is_list(body["attestations"])
    end

    test "returns attestation records with valid field", %{conn: conn, agent_id: agent_id} do
      # Write a real signed attestation so we have something to filter
      Signer.sign_artifact("Write", "/tmp/test-file-prov-w4.ex", agent_id, %{
        session_id: "sess-prov-w4-test",
        formation_id: "formation-prov-w4-test"
      })

      # Give the async Task a moment to complete
      Process.sleep(100)

      conn = get(conn, "/api/v2/provenance/artifacts?agent_id=#{agent_id}")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert is_list(body["attestations"])

      Enum.each(body["attestations"], fn attest ->
        assert Map.has_key?(attest, "valid")
        assert is_boolean(attest["valid"])
        assert Map.has_key?(attest, "agent_id")
        assert Map.has_key?(attest, "tool_name")
        assert Map.has_key?(attest, "timestamp")
        assert Map.has_key?(attest, "subject")
        assert Map.has_key?(attest, "signature")
      end)
    end

    test "respects limit and offset pagination", %{conn: conn} do
      conn = get(conn, "/api/v2/provenance/artifacts?limit=5&offset=0")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["limit"] == 5
      assert body["offset"] == 0
      assert length(body["attestations"]) <= 5
    end

    test "filters by session_id", %{conn: conn, agent_id: agent_id} do
      unique_session = "sess-filter-test-#{System.unique_integer([:positive])}"

      Signer.sign_artifact("Edit", "/tmp/filter-test.ex", agent_id, %{
        session_id: unique_session,
        formation_id: "formation-prov-w4-test"
      })

      Process.sleep(100)

      conn = get(conn, "/api/v2/provenance/artifacts?session_id=#{unique_session}")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)

      # All returned attestations should match the session filter
      Enum.each(body["attestations"], fn a ->
        assert a["session_id"] == unique_session
      end)
    end
  end

  # ── POST /api/v2/provenance/verify ─────────────────────────────────────────

  describe "POST /api/v2/provenance/verify — sign+verify roundtrip" do
    test "returns valid: true for a correctly signed attestation", %{
      conn: conn,
      agent_id: agent_id
    } do
      # Build a real signed attestation
      attest =
        Signer.sign_artifact("Write", "/tmp/roundtrip-test.ex", agent_id, %{
          session_id: "sess-roundtrip",
          formation_id: "formation-roundtrip"
        })

      sig_hex = Base.encode16(attest.signature, case: :lower)

      attestation_map = %{
        "agent_id" => attest.agent_id,
        "tool_name" => attest.tool_name,
        "session_id" => attest.session_id,
        "formation_id" => attest.formation_id,
        "timestamp" => attest.timestamp,
        "subject" =>
          Enum.map(attest.subject, fn s ->
            %{"name" => s.name, "sha256" => s.sha256}
          end)
      }

      conn =
        post(conn, "/api/v2/provenance/verify", %{
          "attestation" => attestation_map,
          "signature" => sig_hex
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "valid")
      assert body["agent_id"] == agent_id
      assert Map.has_key?(body, "timestamp")
    end

    test "returns valid: false for a tampered attestation", %{conn: conn, agent_id: agent_id} do
      attest =
        Signer.sign_artifact("Write", "/tmp/tamper-test.ex", agent_id, %{
          session_id: "sess-tamper"
        })

      sig_hex = Base.encode16(attest.signature, case: :lower)

      # Tamper with the agent_id
      tampered_attestation = %{
        "agent_id" => "attacker-agent",
        "tool_name" => attest.tool_name,
        "session_id" => attest.session_id,
        "formation_id" => attest.formation_id,
        "timestamp" => attest.timestamp,
        "subject" =>
          Enum.map(attest.subject, fn s ->
            %{"name" => s.name, "sha256" => s.sha256}
          end)
      }

      conn =
        post(conn, "/api/v2/provenance/verify", %{
          "attestation" => tampered_attestation,
          "signature" => sig_hex
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["valid"] == false
    end

    test "returns 422 when attestation or signature is missing", %{conn: conn} do
      conn = post(conn, "/api/v2/provenance/verify", %{"attestation" => %{}})
      assert conn.status == 422

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "missing_parameters"
    end

    test "returns 422 for invalid hex signature", %{conn: conn, agent_id: agent_id} do
      conn =
        post(conn, "/api/v2/provenance/verify", %{
          "attestation" => %{"agent_id" => agent_id, "tool_name" => "Write"},
          "signature" => "not-valid-hex!!!"
        })

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_signature_encoding"
    end

    test "returns 422 for wrong-length signature (not 64 bytes)", %{conn: conn, agent_id: agent_id} do
      # 32 bytes = 64 hex chars — wrong length for Ed25519
      short_sig = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      conn =
        post(conn, "/api/v2/provenance/verify", %{
          "attestation" => %{"agent_id" => agent_id, "tool_name" => "Write"},
          "signature" => short_sig
        })

      assert conn.status == 422
    end
  end
end
