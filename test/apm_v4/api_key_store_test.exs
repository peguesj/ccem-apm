defmodule ApmV4.ApiKeyStoreTest do
  use ExUnit.Case, async: false

  alias ApmV4.ApiKeyStore

  describe "generate_key/1" do
    test "creates a key with apm_ prefix" do
      {:ok, key} = ApiKeyStore.generate_key("test-label")
      assert String.starts_with?(key, "apm_")
      assert String.length(key) > 10
    end
  end

  describe "valid_key?/1" do
    test "returns true for a generated key" do
      {:ok, key} = ApiKeyStore.generate_key("valid-test")
      assert ApiKeyStore.valid_key?(key)
    end

    test "returns false for an invalid key" do
      refute ApiKeyStore.valid_key?("apm_bogus_key_000")
    end
  end

  describe "revoke_key/1" do
    test "invalidates a previously valid key" do
      {:ok, key} = ApiKeyStore.generate_key("revoke-test")
      assert ApiKeyStore.valid_key?(key)

      :ok = ApiKeyStore.revoke_key(key)
      refute ApiKeyStore.valid_key?(key)
    end
  end

  describe "list_keys/0" do
    test "masks keys showing only last 4 chars" do
      {:ok, key} = ApiKeyStore.generate_key("list-test")
      last4 = String.slice(key, -4..-1//1)

      keys = ApiKeyStore.list_keys()
      match = Enum.find(keys, fn k -> String.ends_with?(k.key, last4) && k.label == "list-test" end)

      assert match
      refute match.key == key
      assert String.contains?(match.key, "****")
    end
  end
end
