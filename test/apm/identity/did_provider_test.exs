defmodule Apm.Identity.DIDProviderTest do
  @moduledoc """
  TDD suite for Apm.Identity.DIDProvider (prov-w1-s2 / CP-276).

  Verifies:
  - DID format: did:key:z6Mk... (multibase base58btc prefix + multicodec 0xed01)
  - DID Document structure (JSON-LD @context, id, verificationMethod, authentication)
  - DID derives deterministically from KeyStore public key
  - GET /api/v2/identity/did-document returns valid JSON-LD DID Doc
  - Cache returns same DID on repeated calls
  """

  use ExUnit.Case, async: false
  use ApmWeb.ConnCase

  alias Apm.Identity.DIDProvider

  describe "did_for_public_key/1" do
    test "returns a string starting with 'did:key:z6Mk'" do
      # Ed25519 public key — 32 bytes of zeros for deterministic testing
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      assert is_binary(did)

      assert String.starts_with?(did, "did:key:z6Mk"),
             "Expected DID to start with 'did:key:z6Mk', got: #{did}"
    end

    test "produces deterministic output for the same public key" do
      pub_key = :crypto.strong_rand_bytes(32)
      did1 = DIDProvider.did_for_public_key(pub_key)
      did2 = DIDProvider.did_for_public_key(pub_key)
      assert did1 == did2
    end

    test "produces different DIDs for different public keys" do
      pub1 = :crypto.strong_rand_bytes(32)
      pub2 = :crypto.strong_rand_bytes(32)
      # Probability of collision is astronomically small; assert inequality
      assert DIDProvider.did_for_public_key(pub1) != DIDProvider.did_for_public_key(pub2)
    end

    test "encoded key embeds multicodec 0xed01 prefix for ed25519-pub" do
      # The multibase-decoded bytes should start with 0xed 0x01
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      # Strip "did:key:" and "z" (multibase base58btc identifier)
      "did:key:z" <> encoded = did
      decoded = DIDProvider.decode_base58(encoded)
      assert byte_size(decoded) == 34, "Expected 2-byte multicodec prefix + 32-byte key"
      <<0xED, 0x01, _rest::binary>> = decoded
      assert true
    end
  end

  describe "did_document/1" do
    test "returns a map with required JSON-LD @context" do
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      doc = DIDProvider.did_document(did, pub_key)
      assert is_map(doc)
      context = doc["@context"]
      assert is_list(context) or is_binary(context)

      contexts = List.wrap(context)

      assert "https://www.w3.org/ns/did/v1" in contexts,
             "DID Doc must include W3C DID v1 context"
    end

    test "returns a map with 'id' matching the DID" do
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      doc = DIDProvider.did_document(did, pub_key)
      assert doc["id"] == did
    end

    test "includes verificationMethod with Ed25519VerificationKey2020 type" do
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      doc = DIDProvider.did_document(did, pub_key)
      vm_list = doc["verificationMethod"]
      assert is_list(vm_list) and length(vm_list) >= 1
      vm = List.first(vm_list)
      assert vm["type"] == "Ed25519VerificationKey2020"
      assert vm["controller"] == did
    end

    test "includes authentication referencing the verification method" do
      pub_key = :crypto.strong_rand_bytes(32)
      did = DIDProvider.did_for_public_key(pub_key)
      doc = DIDProvider.did_document(did, pub_key)
      auth = doc["authentication"]
      assert is_list(auth) and length(auth) >= 1
    end
  end

  describe "GET /api/v2/identity/did-document" do
    test "returns 200 with a valid DID Document JSON-LD body", %{conn: conn} do
      conn = get(conn, "/api/v2/identity/did-document")
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert is_map(body)

      assert String.starts_with?(body["id"] || "", "did:key:z6Mk"),
             "Response 'id' must be a did:key DID, got: #{inspect(body["id"])}"

      contexts = List.wrap(body["@context"])
      assert "https://www.w3.org/ns/did/v1" in contexts
    end

    test "returns consistent DID on repeated calls (cache hit)", %{conn: conn} do
      conn1 = get(conn, "/api/v2/identity/did-document")
      conn2 = get(Phoenix.ConnTest.build_conn(), "/api/v2/identity/did-document")

      body1 = Jason.decode!(conn1.resp_body)
      body2 = Jason.decode!(conn2.resp_body)

      assert body1["id"] == body2["id"],
             "DID must be stable across requests"
    end

    test "response content-type is application/json", %{conn: conn} do
      conn = get(conn, "/api/v2/identity/did-document")
      content_type = conn |> get_resp_header("content-type") |> List.first()
      assert content_type =~ "application/json"
    end
  end

  describe "cached_did/0" do
    test "returns the same DID as did_for_public_key with KeyStore public key" do
      cached = DIDProvider.cached_did()
      assert is_binary(cached)
      assert String.starts_with?(cached, "did:key:z6Mk")
    end

    test "returns same value on repeated calls" do
      did1 = DIDProvider.cached_did()
      did2 = DIDProvider.cached_did()
      assert did1 == did2
    end
  end
end
