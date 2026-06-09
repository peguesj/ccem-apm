defmodule Apm.Provenance.DelegationChainTest do
  @moduledoc """
  TDD suite for Apm.Provenance.DelegationChain (prov-w3-s7 / CP-281).

  Verifies:
  - new_chain/3 creates a single-hop signed chain
  - append_hop/3 extends a valid chain and stores encoded chain
  - append_hop/3 rejects a tampered chain with {:error, :invalid_chain}
  - verify/1 passes on a valid 3-hop chain
  - verify/1 fails on a chain with a tampered hop signature
  - to_jwt/1 returns a non-empty binary JWT string
  - AgentRegistry stores delegation_chain in agent record when parent_agent_id is present
  """

  use ExUnit.Case, async: false

  alias Apm.Provenance.DelegationChain
  alias Apm.Identity.KeyStore

  # ── Hop struct ───────────────────────────────────────────────────────────────

  describe "DelegationChain.Hop struct" do
    test "has all required fields" do
      hop = %DelegationChain.Hop{
        authorizer_did: "did:key:z6MkAuthorizer",
        agent_did: "did:key:z6MkAgent",
        session_id: "sess-001",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        sig: <<0::512>>
      }

      assert hop.authorizer_did == "did:key:z6MkAuthorizer"
      assert hop.agent_did == "did:key:z6MkAgent"
      assert byte_size(hop.sig) == 64
    end
  end

  # ── new_chain/3 ──────────────────────────────────────────────────────────────

  describe "new_chain/3" do
    test "returns {:ok, chain} with a single hop" do
      assert {:ok, chain} =
               DelegationChain.new_chain(
                 "did:key:z6MkHuman",
                 "did:key:z6MkOrchestrator",
                 "sess-001"
               )

      assert length(chain.hops) == 1
      hop = hd(chain.hops)
      assert hop.authorizer_did == "did:key:z6MkHuman"
      assert hop.agent_did == "did:key:z6MkOrchestrator"
      assert hop.session_id == "sess-001"
      assert byte_size(hop.sig) == 64
    end

    test "first hop has a valid Ed25519 signature" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      hop = hd(chain.hops)
      payload = DelegationChain.hop_signing_payload(hop)
      pub = KeyStore.public_key()

      assert KeyStore.verify(payload, hop.sig, pub) == true
    end
  end

  # ── append_hop/3 ─────────────────────────────────────────────────────────────

  describe "append_hop/3" do
    test "extends the chain by one hop" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      assert {:ok, chain2} =
               DelegationChain.append_hop(chain, "did:key:z6MkSwarmAgent", "sess-002")

      assert length(chain2.hops) == 2
      last_hop = List.last(chain2.hops)
      assert last_hop.agent_did == "did:key:z6MkSwarmAgent"
      assert last_hop.authorizer_did == "did:key:z6MkOrchestrator"
    end

    test "each appended hop has a valid Ed25519 signature" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      {:ok, chain2} =
        DelegationChain.append_hop(chain, "did:key:z6MkSwarmAgent", "sess-002")

      pub = KeyStore.public_key()

      Enum.each(chain2.hops, fn hop ->
        payload = DelegationChain.hop_signing_payload(hop)
        assert KeyStore.verify(payload, hop.sig, pub) == true
      end)
    end

    test "rejects append on a chain with tampered last hop signature" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      # Tamper the signature of the only hop
      [hop] = chain.hops
      tampered_hop = %{hop | sig: :crypto.strong_rand_bytes(64)}
      tampered_chain = %{chain | hops: [tampered_hop]}

      assert {:error, :invalid_chain} =
               DelegationChain.append_hop(tampered_chain, "did:key:z6MkSwarmAgent", "sess-002")
    end
  end

  # ── verify/1 ─────────────────────────────────────────────────────────────────

  describe "verify/1" do
    test "passes on a 3-hop chain" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      {:ok, chain2} =
        DelegationChain.append_hop(chain, "did:key:z6MkSwarmLead", "sess-002")

      {:ok, chain3} =
        DelegationChain.append_hop(chain2, "did:key:z6MkLeafAgent", "sess-003")

      assert length(chain3.hops) == 3
      assert DelegationChain.verify(chain3) == :ok
    end

    test "fails when a middle hop is tampered" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      {:ok, chain2} =
        DelegationChain.append_hop(chain, "did:key:z6MkSwarmLead", "sess-002")

      {:ok, chain3} =
        DelegationChain.append_hop(chain2, "did:key:z6MkLeafAgent", "sess-003")

      # Tamper hop index 1 (middle hop)
      [hop0, hop1, hop2] = chain3.hops
      tampered_hop1 = %{hop1 | sig: :crypto.strong_rand_bytes(64)}
      tampered_chain = %{chain3 | hops: [hop0, tampered_hop1, hop2]}

      assert {:error, {:invalid_hop, 1}} = DelegationChain.verify(tampered_chain)
    end

    test "fails when the first hop is tampered" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      [hop] = chain.hops
      tampered = %{hop | sig: :crypto.strong_rand_bytes(64)}
      tampered_chain = %{chain | hops: [tampered]}

      assert {:error, {:invalid_hop, 0}} = DelegationChain.verify(tampered_chain)
    end
  end

  # ── to_jwt/1 ─────────────────────────────────────────────────────────────────

  describe "to_jwt/1" do
    test "returns a non-empty binary JWT string (3 dot-separated parts)" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      jwt = DelegationChain.to_jwt(chain)
      assert is_binary(jwt)
      parts = String.split(jwt, ".")
      assert length(parts) == 3
    end

    test "JWT delegation_chain claim contains all hops" do
      {:ok, chain} =
        DelegationChain.new_chain("did:key:z6MkHuman", "did:key:z6MkOrchestrator", "sess-001")

      {:ok, chain2} =
        DelegationChain.append_hop(chain, "did:key:z6MkSwarmAgent", "sess-002")

      jwt = DelegationChain.to_jwt(chain2)

      # Decode the payload (second part)
      [_header, payload_b64, _sig] = String.split(jwt, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert Map.has_key?(payload, "delegation_chain")
      assert length(payload["delegation_chain"]) == 2
    end
  end

  # ── AgentRegistry integration ─────────────────────────────────────────────────

  describe "AgentRegistry.register_agent/3 with parent_agent_id" do
    setup do
      # Ensure registry is started
      case Process.whereis(Apm.AgentRegistry) do
        nil ->
          {:ok, _} = Apm.AgentRegistry.start_link()
          :ok

        _pid ->
          Apm.AgentRegistry.clear_all()
          :ok
      end
    end

    test "stores delegation_chain when parent_agent_id is present" do
      # Register parent first
      :ok = Apm.AgentRegistry.register_agent("parent-orchestrator", %{}, nil)

      # Register child with parent_agent_id
      :ok =
        Apm.AgentRegistry.register_agent(
          "child-swarm-agent",
          %{parent_agent_id: "parent-orchestrator", session_id: "sess-reg-001"},
          nil
        )

      agent = Apm.AgentRegistry.get_agent("child-swarm-agent")
      assert agent != nil
      assert Map.has_key?(agent, :delegation_chain)
      chain_jwt = Map.get(agent, :delegation_chain)
      assert is_binary(chain_jwt)
      assert String.contains?(chain_jwt, ".")
    end

    test "does not set delegation_chain when parent_agent_id is absent" do
      :ok =
        Apm.AgentRegistry.register_agent(
          "standalone-agent",
          %{session_id: "sess-standalone"},
          nil
        )

      agent = Apm.AgentRegistry.get_agent("standalone-agent")
      assert agent != nil
      # delegation_chain should be nil or missing when no parent
      refute Map.get(agent, :delegation_chain)
    end
  end
end
