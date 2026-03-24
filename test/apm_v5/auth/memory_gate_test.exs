defmodule ApmV5.Auth.MemoryGateTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.MemoryGate

  # ── scan_prohibited/1 ─────────────────────────────────────────────────────

  test "scan_prohibited detects API keys in assignment context" do
    matches = MemoryGate.scan_prohibited("api_key: AKIAIOSFODNN7EXAMPLE1234extra5678")
    assert length(matches) > 0
  end

  test "scan_prohibited detects PEM private keys" do
    matches = MemoryGate.scan_prohibited("-----BEGIN PRIVATE KEY-----")
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :private_key end)
  end

  test "scan_prohibited detects RSA private keys" do
    matches = MemoryGate.scan_prohibited("-----BEGIN RSA PRIVATE KEY-----")
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :private_key end)
  end

  test "scan_prohibited detects connection strings" do
    matches = MemoryGate.scan_prohibited("postgres://admin:s3cret@db.host.com/mydb")
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :connection_string end)
  end

  test "scan_prohibited detects JWT tokens" do
    jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    matches = MemoryGate.scan_prohibited(jwt)
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :jwt_token end)
  end

  test "scan_prohibited detects SSH keys" do
    ssh_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDCZfh80bxLh3sLqMDEIGFw6kx4d user@host"
    matches = MemoryGate.scan_prohibited(ssh_key)
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :ssh_key end)
  end

  test "scan_prohibited detects AWS access keys" do
    matches = MemoryGate.scan_prohibited("AKIAIOSFODNN7EXAMPLE1")
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :aws_key end)
  end

  test "scan_prohibited detects OAuth bearer tokens" do
    matches = MemoryGate.scan_prohibited("Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.test")
    assert length(matches) > 0
    assert Enum.any?(matches, fn {type, _} -> type == :oauth_token end)
  end

  test "scan_prohibited returns empty for safe content" do
    matches = MemoryGate.scan_prohibited("hello world, this is safe text")
    assert matches == []
  end

  test "scan_prohibited returns empty for normal code" do
    matches = MemoryGate.scan_prohibited("def my_function(arg), do: arg + 1")
    assert matches == []
  end

  # ── prohibited_pattern_types/0 ─────────────────────────────────────────────

  test "prohibited_pattern_types returns all expected types" do
    types = MemoryGate.prohibited_pattern_types()
    assert :api_key in types
    assert :private_key in types
    assert :connection_string in types
    assert :jwt_token in types
    assert :ssh_key in types
    assert :aws_key in types
    assert :oauth_token in types
    assert length(types) == 7
  end

  # ── authorize_write/4 ─────────────────────────────────────────────────────

  test "authorize_write returns :ok for safe content" do
    assert :ok = MemoryGate.authorize_write("session-1", "agent-1", "safe text")
  end

  test "authorize_write rejects content with prohibited patterns" do
    result =
      MemoryGate.authorize_write(
        "session-1",
        "agent-1",
        "-----BEGIN PRIVATE KEY-----"
      )

    assert {:error, :memory_prohibited_content, detail} = result
    assert is_binary(detail)
    assert String.contains?(detail, "private_key")
  end

  test "authorize_write rejects JWT tokens" do
    jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

    result = MemoryGate.authorize_write("session-1", "agent-1", jwt)
    assert {:error, :memory_prohibited_content, _detail} = result
  end

  # ── authorize_read/2 ──────────────────────────────────────────────────────

  test "authorize_read permits reads with default trust" do
    assert :ok = MemoryGate.authorize_read("session-1", "agent-1")
  end
end
