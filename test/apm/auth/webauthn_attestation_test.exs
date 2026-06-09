defmodule Apm.Auth.WebAuthnAttestationTest do
  @moduledoc """
  TDD suite for WebAuthn FIDO2 attestation gate (auth-v10.3-s1 / CP-298).

  Tests use synthetic Ed25519 (COSE -8) credentials forged from `:crypto` so we
  exercise the registration/assertion plumbing without requiring a real browser
  authenticator. The shape of the data fed into `Wax` mirrors the WebAuthn
  spec (authenticatorData|clientDataJSON|signature) so the test catches any
  regression in our adapter layer.

  Adversarial cases:
    * replay attack via stale sign_count
    * substituted credential_id (wrong key)
    * absent assertion when policy requires
  """
  use ExUnit.Case, async: false

  alias Apm.Auth.WebAuthnAttestation

  setup do
    # Reset ETS between tests for hermetic state.
    WebAuthnAttestation.reset!()
    :ok
  end

  describe "register_authenticator/3" do
    test "stores a credential record keyed by user_id" do
      user_id = "user-1"
      {cred_id, pub_key_cose} = synthetic_credential()

      assert :ok = WebAuthnAttestation.put_credential(user_id, cred_id, pub_key_cose, 0)

      assert {:ok, [%{credential_id: ^cred_id, sign_count: 0}]} =
               WebAuthnAttestation.list_credentials(user_id)
    end

    test "allows multiple credentials per user" do
      {cred_id_a, pk_a} = synthetic_credential()
      {cred_id_b, pk_b} = synthetic_credential()

      :ok = WebAuthnAttestation.put_credential("u", cred_id_a, pk_a, 0)
      :ok = WebAuthnAttestation.put_credential("u", cred_id_b, pk_b, 0)

      {:ok, creds} = WebAuthnAttestation.list_credentials("u")
      assert length(creds) == 2
    end
  end

  describe "verify_assertion/5" do
    test "rejects when no credential is registered" do
      assert {:error, :no_credential} =
               WebAuthnAttestation.verify_assertion(
                 "ghost",
                 <<1, 2, 3>>,
                 <<>>,
                 <<>>,
                 <<>>
               )
    end

    test "rejects assertion with unknown credential_id (substitution attack)" do
      {cred_id, pk} = synthetic_credential()
      :ok = WebAuthnAttestation.put_credential("u", cred_id, pk, 0)

      attacker_cred_id = :crypto.strong_rand_bytes(32)

      assert {:error, :credential_not_found} =
               WebAuthnAttestation.verify_assertion(
                 "u",
                 attacker_cred_id,
                 <<>>,
                 <<>>,
                 <<>>
               )
    end

    test "rejects replay attack via non-increasing sign_count" do
      {cred_id, pk, priv} = synthetic_credential_with_priv()
      :ok = WebAuthnAttestation.put_credential("u", cred_id, pk, 10)

      # Forge an authenticatorData with sign_count = 5 (lower than stored 10).
      {auth_data, sig, client_data_json} = forge_assertion(priv, "u", sign_count: 5)

      assert {:error, :replay_detected} =
               WebAuthnAttestation.verify_assertion(
                 "u",
                 cred_id,
                 sig,
                 auth_data,
                 client_data_json
               )
    end

    test "accepts a valid assertion and increments sign_count" do
      {cred_id, pk, priv} = synthetic_credential_with_priv()
      :ok = WebAuthnAttestation.put_credential("u", cred_id, pk, 1)

      {auth_data, sig, client_data_json} = forge_assertion(priv, "u", sign_count: 7)

      assert {:ok, %{sign_count: 7}} =
               WebAuthnAttestation.verify_assertion(
                 "u",
                 cred_id,
                 sig,
                 auth_data,
                 client_data_json
               )

      # Replay of the same assertion now fails because counter is 7.
      assert {:error, :replay_detected} =
               WebAuthnAttestation.verify_assertion(
                 "u",
                 cred_id,
                 sig,
                 auth_data,
                 client_data_json
               )
    end
  end

  describe "policy gate" do
    test "require_webauthn?/0 reads runtime config" do
      Application.put_env(:apm, :require_webauthn_for_approval, true)
      assert WebAuthnAttestation.require_webauthn?() == true

      Application.put_env(:apm, :require_webauthn_for_approval, false)
      assert WebAuthnAttestation.require_webauthn?() == false
    after
      Application.put_env(:apm, :require_webauthn_for_approval, false)
    end
  end

  # ── Test fixtures ──────────────────────────────────────────────────────────

  # Synthetic COSE Ed25519 credential. The "public key" here is the raw Ed25519
  # 32-byte pub; our impl serialises to CBOR-COSE on the way in.
  defp synthetic_credential do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    cred_id = :crypto.strong_rand_bytes(16)
    {cred_id, pub}
  end

  defp synthetic_credential_with_priv do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    cred_id = :crypto.strong_rand_bytes(16)
    {cred_id, pub, priv}
  end

  # Build an authenticatorData blob conformant enough for our impl to extract
  # sign_count and verify the Ed25519 signature.
  defp forge_assertion(priv, rp_id, opts) do
    sign_count = Keyword.fetch!(opts, :sign_count)
    rp_id_hash = :crypto.hash(:sha256, rp_id)
    # flags: UP=1 (0x01)
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
