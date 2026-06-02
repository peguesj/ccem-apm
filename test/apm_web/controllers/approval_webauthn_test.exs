defmodule ApmWeb.ApprovalControllerWebAuthnTest do
  @moduledoc """
  Integration tests for the WebAuthn gate on `/api/v2/approvals/:id/approve`
  (auth-v10.3-s1 / CP-298). Verifies:

    * default (require_webauthn_for_approval=false) preserves back-compat
    * required mode rejects approve calls with no `webauthn_assertion`
    * required mode accepts a properly forged Ed25519 assertion
  """
  use ApmWeb.ConnCase, async: false

  alias Apm.AgUi.ApprovalGate
  alias Apm.Auth.WebAuthnAttestation

  setup do
    WebAuthnAttestation.reset!()
    Application.put_env(:apm, :require_webauthn_for_approval, false)
    on_exit(fn -> Application.put_env(:apm, :require_webauthn_for_approval, false) end)
    :ok
  end

  describe "POST /api/v2/approvals/:id/approve (back-compat)" do
    test "approves without webauthn when policy is disabled", %{conn: conn} do
      {:ok, gate_id} = ApprovalGate.request_approval("agent-1", %{tool: "Write"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v2/approvals/#{gate_id}/approve", Jason.encode!(%{}))

      assert json_response(conn, 200) == %{"status" => "approved"}
    end
  end

  describe "POST /api/v2/approvals/:id/approve (webauthn required)" do
    setup do
      Application.put_env(:apm, :require_webauthn_for_approval, true)
      :ok
    end

    test "rejects approval with no assertion body", %{conn: conn} do
      {:ok, gate_id} = ApprovalGate.request_approval("agent-2", %{tool: "Edit"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v2/approvals/#{gate_id}/approve", Jason.encode!(%{}))

      body = json_response(conn, 401)
      assert body["error"] =~ "webauthn"
    end

    test "rejects approval with unknown credential_id", %{conn: conn} do
      {:ok, gate_id} = ApprovalGate.request_approval("agent-3", %{tool: "Write"})

      # Register a credential under user_id 'alice' but send a different cred id
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      cred_id = :crypto.strong_rand_bytes(16)
      :ok = WebAuthnAttestation.put_credential("alice", cred_id, pub, 0)

      attacker_cred = :crypto.strong_rand_bytes(16)
      {auth_data, sig, client_data_json} = forge_assertion(priv, "alice", 1)

      params = %{
        "user_id" => "alice",
        "approver" => %{"user_id" => "alice"},
        "webauthn_assertion" => %{
          "credential_id" => Base.url_encode64(attacker_cred, padding: false),
          "signature" => Base.url_encode64(sig, padding: false),
          "authenticator_data" => Base.url_encode64(auth_data, padding: false),
          "client_data_json" => Base.url_encode64(client_data_json, padding: false)
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v2/approvals/#{gate_id}/approve", Jason.encode!(params))
      body = json_response(conn, 401)
      assert body["reason"] =~ "credential_not_found"
    end

    test "accepts a valid Ed25519 assertion", %{conn: conn} do
      {:ok, gate_id} = ApprovalGate.request_approval("agent-4", %{tool: "Edit"})

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      cred_id = :crypto.strong_rand_bytes(16)
      :ok = WebAuthnAttestation.put_credential("bob", cred_id, pub, 0)

      {auth_data, sig, client_data_json} = forge_assertion(priv, "bob", 1)

      params = %{
        "user_id" => "bob",
        "approver" => %{"user_id" => "bob"},
        "webauthn_assertion" => %{
          "credential_id" => Base.url_encode64(cred_id, padding: false),
          "signature" => Base.url_encode64(sig, padding: false),
          "authenticator_data" => Base.url_encode64(auth_data, padding: false),
          "client_data_json" => Base.url_encode64(client_data_json, padding: false)
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v2/approvals/#{gate_id}/approve", Jason.encode!(params))
      assert json_response(conn, 200) == %{"status" => "approved"}
    end
  end

  defp forge_assertion(priv, rp_id, sign_count) do
    rp_id_hash = :crypto.hash(:sha256, rp_id)
    flags = <<0x01>>
    sign_count_bin = <<sign_count::unsigned-big-integer-size(32)>>
    auth_data = rp_id_hash <> flags <> sign_count_bin
    client_data_json =
      Jason.encode!(%{type: "webauthn.get", challenge: "test", origin: "http://localhost"})
    client_data_hash = :crypto.hash(:sha256, client_data_json)
    sig = :crypto.sign(:eddsa, :none, auth_data <> client_data_hash, [priv, :ed25519])
    {auth_data, sig, client_data_json}
  end
end
