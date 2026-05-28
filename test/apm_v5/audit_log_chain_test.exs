defmodule ApmV5.AuditLogChainTest do
  @moduledoc """
  Verifies the audit-s1 v9.2.1 hotfix — self_hash storage + verify_chain!/1 API.
  """
  use ExUnit.Case, async: false

  alias ApmV5.AuditLog
  alias ApmV5.AuditLog.AuditIntegrityError

  @tmp_log_dir Path.join(System.tmp_dir!(), "apm_audit_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_log_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_log_dir)
    end)

    :ok
  end

  describe "do_log/6 stores self_hash" do
    test "logged events include self_hash and prev_hash fields" do
      AuditLog.clear_all()
      event = AuditLog.log_sync(:test_event, "test-actor", "test-resource", %{n: 1})

      assert Map.has_key?(event, :self_hash)
      assert Map.has_key?(event, :prev_hash)
      assert is_binary(event.self_hash)
      assert byte_size(event.self_hash) == 64
    end
  end

  describe "verify_memory_chain/0" do
    test "passes on untampered in-memory chain" do
      AuditLog.clear_all()
      _e1 = AuditLog.log_sync(:e1, "a1", "r1", %{n: 1})
      _e2 = AuditLog.log_sync(:e2, "a2", "r2", %{n: 2})
      _e3 = AuditLog.log_sync(:e3, "a3", "r3", %{n: 3})

      assert :ok = AuditLog.verify_memory_chain()
    end
  end

  describe "verify_chain!/1 on JSONL file" do
    test "raises AuditIntegrityError on tampered JSONL line" do
      tampered_file = Path.join(@tmp_log_dir, "tampered.jsonl")

      # Fake a chain where event 2's self_hash is mutated.
      event1 = %{
        "id" => 1,
        "timestamp" => "2026-05-28T12:00:00Z",
        "event_type" => "e1",
        "actor" => "a",
        "resource" => "r",
        "details" => %{},
        "correlation_id" => nil,
        "prev_hash" => ""
      }

      hash1 =
        :crypto.hash(:sha256, Jason.encode!(event1))
        |> Base.encode16(case: :lower)

      event1_full = Map.put(event1, "self_hash", hash1)

      event2 = %{
        "id" => 2,
        "timestamp" => "2026-05-28T12:00:01Z",
        "event_type" => "e2",
        "actor" => "a",
        "resource" => "r",
        "details" => %{},
        "correlation_id" => nil,
        "prev_hash" => hash1
      }

      # Compute correct self_hash, then tamper.
      _real_hash2 =
        :crypto.hash(:sha256, Jason.encode!(event2))
        |> Base.encode16(case: :lower)

      tampered_event2 = Map.put(event2, "self_hash", String.duplicate("0", 64))

      File.write!(tampered_file, [
        Jason.encode!(event1_full),
        "\n",
        Jason.encode!(tampered_event2),
        "\n"
      ])

      assert_raise AuditIntegrityError, fn ->
        AuditLog.verify_chain!(tampered_file)
      end
    end
  end
end
