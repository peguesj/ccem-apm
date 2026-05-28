defmodule ApmV5.Identity.KeyStoreTest do
  @moduledoc """
  TDD suite for ApmV5.Identity.KeyStore (prov-w1-s1 / CP-275).

  Verifies:
  - Ed25519 keypair generation on first boot
  - sign/verify roundtrip correctness
  - Keypair persistence across GenServer restarts
  - public_key/0 returns a 32-byte binary
  - sign/1 returns a 64-byte binary signature
  - verify/3 returns false for tampered payloads
  """

  use ExUnit.Case, async: false

  alias ApmV5.Identity.KeyStore

  @key_dir Path.expand("~/.claude/ccem/apm/keys")
  # Use a test-specific env suffix to avoid clobbering prod keys
  @test_env "test_#{:erlang.unique_integer([:positive])}"

  setup do
    # Ensure fresh GenServer for each test using a unique env suffix
    name = :"KeyStore_#{:erlang.unique_integer([:positive])}"
    key_file = Path.join(@key_dir, "apm_#{@test_env}.pem")

    on_exit(fn ->
      # Clean up test key file
      File.rm(key_file)
    end)

    {:ok, name: name, key_file: key_file}
  end

  describe "start_link/1 and init/1" do
    test "starts successfully with a fresh key file path", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "generates a new keypair when no key file exists", %{name: name, key_file: key_file} do
      refute File.exists?(key_file)
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      assert File.exists?(key_file)
      GenServer.stop(pid)
    end

    test "persists the keypair to disk on first boot", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      pub1 = KeyStore.public_key(pid)
      GenServer.stop(pid)

      # Restart from same file
      {:ok, pid2} = KeyStore.start_link(name: :"#{name}_2", key_file: key_file)
      pub2 = KeyStore.public_key(pid2)
      GenServer.stop(pid2)

      assert pub1 == pub2, "public key must be identical after restart from same key file"
    end
  end

  describe "public_key/1" do
    test "returns a 32-byte binary (Ed25519 public key size)", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      pub = KeyStore.public_key(pid)
      assert is_binary(pub)
      assert byte_size(pub) == 32
      GenServer.stop(pid)
    end
  end

  describe "sign/2" do
    test "returns a 64-byte binary signature", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      sig = KeyStore.sign(pid, "hello world")
      assert is_binary(sig)
      assert byte_size(sig) == 64
      GenServer.stop(pid)
    end

    test "produces deterministic-length signatures for different payloads", %{
      name: name,
      key_file: key_file
    } do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      sig1 = KeyStore.sign(pid, "short")
      sig2 = KeyStore.sign(pid, String.duplicate("x", 10_000))
      assert byte_size(sig1) == 64
      assert byte_size(sig2) == 64
      GenServer.stop(pid)
    end
  end

  describe "verify/4" do
    test "roundtrip: verify succeeds for a freshly signed payload", %{
      name: name,
      key_file: key_file
    } do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      payload = "artifact:sha256:abc123"
      sig = KeyStore.sign(pid, payload)
      pub = KeyStore.public_key(pid)
      assert KeyStore.verify(pid, payload, sig, pub) == true
      GenServer.stop(pid)
    end

    test "returns false for a tampered payload", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      payload = "original payload"
      sig = KeyStore.sign(pid, payload)
      pub = KeyStore.public_key(pid)
      assert KeyStore.verify(pid, "tampered payload", sig, pub) == false
      GenServer.stop(pid)
    end

    test "returns false for a tampered signature", %{name: name, key_file: key_file} do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      payload = "original payload"
      sig = KeyStore.sign(pid, payload)
      pub = KeyStore.public_key(pid)
      <<byte, rest::binary>> = sig
      bad_sig = <<Bitwise.bxor(byte, 0xFF), rest::binary>>
      assert KeyStore.verify(pid, payload, bad_sig, pub) == false
      GenServer.stop(pid)
    end

    test "cross-restart: signature from first boot verifies with reloaded public key", %{
      name: name,
      key_file: key_file
    } do
      {:ok, pid} = KeyStore.start_link(name: name, key_file: key_file)
      payload = "cross-restart-payload"
      sig = KeyStore.sign(pid, payload)
      pub1 = KeyStore.public_key(pid)
      GenServer.stop(pid)

      # Reload from disk
      {:ok, pid2} = KeyStore.start_link(name: :"#{name}_restart", key_file: key_file)
      pub2 = KeyStore.public_key(pid2)
      assert pub1 == pub2

      # The reloaded store can verify the old signature
      assert KeyStore.verify(pid2, payload, sig, pub2) == true
      GenServer.stop(pid2)
    end
  end
end
