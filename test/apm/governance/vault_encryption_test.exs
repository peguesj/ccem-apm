defmodule Apm.Governance.VaultEncryptionTest do
  @moduledoc """
  Tests for comp-mg2 AES-256-GCM audit field encryption.

  Verifies:
  1. Vault.sensitive?/1 detection logic
  2. Vault.encrypt_details/1 and decrypt_details/1 roundtrip
  3. AuditLog.log_sync stores ciphertext for sensitive fields
  4. AuditLog.query with include_decrypted: true returns plaintext
  5. ControlRegistry contains :audit_encryption_at_rest

  CP-235 / US-467 — v9.3.0 comp-mg2.
  """

  use ExUnit.Case, async: false

  alias Apm.Governance.{Vault, ControlRegistry}
  alias Apm.AuditLog

  setup do
    AuditLog.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Vault.sensitive?/1
  # ---------------------------------------------------------------------------

  describe "Vault.sensitive?/1" do
    test "returns true for maps with :pii key" do
      assert Vault.sensitive?(%{pii: "123-45-6789"})
    end

    test "returns true for maps with :sensitive key" do
      assert Vault.sensitive?(%{sensitive: "secret value"})
    end

    test "returns true for maps with string pii key" do
      assert Vault.sensitive?(%{"pii" => "data"})
    end

    test "returns true for maps with string sensitive key" do
      assert Vault.sensitive?(%{"sensitive" => "data"})
    end

    test "returns true for maps with nested __cloak__: true" do
      assert Vault.sensitive?(%{payload: %{__cloak__: true, value: "data"}})
    end

    test "returns false for ordinary maps" do
      refute Vault.sensitive?(%{tool: "Bash", outcome: :allow})
    end

    test "returns false for non-map values" do
      refute Vault.sensitive?("string")
      refute Vault.sensitive?(nil)
      refute Vault.sensitive?(42)
    end
  end

  # ---------------------------------------------------------------------------
  # Encrypt / Decrypt roundtrip
  # ---------------------------------------------------------------------------

  describe "Vault.encrypt_details/1 + decrypt_details/1 roundtrip" do
    test "encrypts :pii value and decrypts back to plaintext" do
      original = %{pii: "123-45-6789", event: "authorization"}

      encrypted = Vault.encrypt_details(original)

      # :pii value must be a wrapped ciphertext map
      assert %{"__enc__" => _ciphertext} = encrypted[:pii]
      # non-sensitive keys pass through unchanged
      assert encrypted[:event] == "authorization"

      decrypted = Vault.decrypt_details(encrypted)
      assert decrypted[:pii] == "123-45-6789"
      assert decrypted[:event] == "authorization"
    end

    test "encrypts :sensitive value and decrypts back" do
      original = %{sensitive: "api_key_12345"}

      encrypted = Vault.encrypt_details(original)
      assert %{"__enc__" => _} = encrypted[:sensitive]

      decrypted = Vault.decrypt_details(encrypted)
      assert decrypted[:sensitive] == "api_key_12345"
    end

    test "passes through maps without sensitive keys unchanged" do
      details = %{tool: "Bash", risk: :low}
      assert Vault.encrypt_details(details) == details
    end

    test "decrypt_details is a no-op on plain maps" do
      details = %{tool: "Read", count: 5}
      assert Vault.decrypt_details(details) == details
    end
  end

  # ---------------------------------------------------------------------------
  # AuditLog integration
  # ---------------------------------------------------------------------------

  describe "AuditLog — sensitive fields encrypted at rest" do
    test "stored ETS entry has ciphertext, not plaintext, for :pii field" do
      ssn = "987-65-4321"

      AuditLog.log_sync(
        :access_attempt,
        "agent-007",
        "/secrets",
        %{pii: ssn, action: "read"},
        "corr-001"
      )

      # Query WITHOUT decryption (default) — stored value must be ciphertext
      [event] = AuditLog.query(event_type: :access_attempt, limit: 1)

      stored_pii = event.details[:pii] || event.details["pii"]
      refute stored_pii == ssn, "plaintext SSN must not appear in stored details"
      assert match?(%{"__enc__" => _}, stored_pii), "stored pii must be encrypted wrapper"

      # Non-sensitive fields pass through
      assert event.details[:action] == "read"
    end

    test "query with include_decrypted: true returns plaintext" do
      email = "alice@example.com"

      AuditLog.log_sync(
        :user_event,
        "system",
        "/users",
        %{sensitive: email, category: "auth"},
        nil
      )

      [decrypted_event] =
        AuditLog.query(event_type: :user_event, limit: 1, include_decrypted: true)

      stored_sensitive =
        decrypted_event.details[:sensitive] || decrypted_event.details["sensitive"]

      assert stored_sensitive == email
    end

    test "events without sensitive fields are not modified" do
      AuditLog.log_sync(:tool_call, "agent-x", "Bash", %{cmd: "ls -la", exit_code: 0}, nil)

      [event] = AuditLog.query(event_type: :tool_call, limit: 1)

      assert event.details[:cmd] == "ls -la"
      assert event.details[:exit_code] == 0
    end
  end

  # ---------------------------------------------------------------------------
  # ControlRegistry
  # ---------------------------------------------------------------------------

  describe "ControlRegistry" do
    test "contains :audit_encryption_at_rest with status :satisfied" do
      ctrl = ControlRegistry.get_control(:audit_encryption_at_rest)
      assert ctrl != nil
      assert ctrl.status == :satisfied
    end

    test ":audit_encryption_at_rest satisfies ISO 27001 A.8.24" do
      ctrl = ControlRegistry.get_control(:audit_encryption_at_rest)
      assert "A.8.24" in (ctrl[:iso_27001] || [])
    end

    test "framework_index includes A.8.24 mapping to audit_encryption_at_rest" do
      index = ControlRegistry.framework_index()
      iso_index = index["iso_27001"] || %{}
      assert "audit_encryption_at_rest" in Map.get(iso_index, "A.8.24", [])
    end
  end
end
