defmodule ApmV4.AuditLogTest do
  use ExUnit.Case, async: false

  alias ApmV4.AuditLog

  @tmp_dir System.tmp_dir!() |> Path.join("apm_audit_test_#{System.unique_integer([:positive])}")

  setup do
    # Terminate the application-supervised instance so we can start our own
    _ = Supervisor.terminate_child(ApmV4.Supervisor, AuditLog)
    _ = Supervisor.delete_child(ApmV4.Supervisor, AuditLog)

    # Clean up ETS tables
    for t <- [:apm_audit_log, :apm_audit_ring] do
      try do
        :ets.delete(t)
      rescue
        ArgumentError -> :ok
      end
    end

    # Use a temp dir for log files
    Application.put_env(:apm_v4, :audit_log_dir, @tmp_dir)

    # Start PubSub if not running (test env may not have it)
    unless GenServer.whereis(ApmV4.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ApmV4.PubSub})
    end

    start_supervised!(AuditLog)
    Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:audit")

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.delete_env(:apm_v4, :audit_log_dir)
    end)

    :ok
  end

  test "log/4 writes to ETS and ring buffer" do
    AuditLog.log("agent.registered", "agent-1", "registry", %{name: "test"})
    # Give the cast time to process
    Process.sleep(50)

    events = AuditLog.tail(1)
    assert length(events) == 1
    [event] = events
    assert event.event_type == "agent.registered"
    assert event.actor == "agent-1"
    assert event.resource == "registry"
    assert event.details == %{name: "test"}
  end

  test "log_sync/5 returns the event" do
    event = AuditLog.log_sync("session.started", "session-1", "sessions", %{}, "corr-123")
    assert event.event_type == "session.started"
    assert event.correlation_id == "corr-123"
    assert event.id >= 1
    assert event.prev_hash != nil
  end

  test "query/1 filters by event_type" do
    AuditLog.log_sync("agent.registered", "a1", "r1", %{})
    AuditLog.log_sync("session.started", "s1", "r2", %{})
    AuditLog.log_sync("agent.registered", "a2", "r3", %{})

    results = AuditLog.query(event_type: "agent.registered")
    assert length(results) == 2
    assert Enum.all?(results, &(&1.event_type == "agent.registered"))
  end

  test "query/1 filters by actor" do
    AuditLog.log_sync("agent.registered", "actor-x", "r1", %{})
    AuditLog.log_sync("agent.registered", "actor-y", "r2", %{})

    results = AuditLog.query(actor: "actor-x")
    assert length(results) == 1
    assert hd(results).actor == "actor-x"
  end

  test "query/1 filters by since" do
    e1 = AuditLog.log_sync("a", "x", "r", %{})
    Process.sleep(10)
    _e2 = AuditLog.log_sync("b", "x", "r", %{})

    results = AuditLog.query(since: e1.timestamp)
    assert length(results) == 2
  end

  test "tail/1 returns correct count" do
    for i <- 1..5 do
      AuditLog.log_sync("test.event", "actor", "res-#{i}", %{})
    end

    assert length(AuditLog.tail(3)) == 3
    assert length(AuditLog.tail(10)) == 5
  end

  test "hash chain integrity" do
    events =
      for i <- 1..5 do
        AuditLog.log_sync("chain.test", "actor", "res-#{i}", %{})
      end

    # First event should have "genesis" as prev_hash
    assert hd(events).prev_hash == "genesis"

    # Each subsequent event's prev_hash should be SHA-256 of prior event's JSON
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [prev, curr] ->
      expected_hash =
        Jason.encode!(prev)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert curr.prev_hash == expected_hash
    end)
  end

  test "ring buffer cap - stays at 10000" do
    for i <- 1..10_005 do
      AuditLog.log_sync("ring.test", "actor", "res-#{i}", %{})
    end

    ring_size = :ets.info(:apm_audit_ring, :size)
    assert ring_size == 10_000
  end

  test "stats/0 returns correct counts" do
    AuditLog.log_sync("type.a", "x", "r", %{})
    AuditLog.log_sync("type.a", "x", "r", %{})
    AuditLog.log_sync("type.b", "x", "r", %{})

    stats = AuditLog.stats()
    assert stats["type.a"] == 2
    assert stats["type.b"] == 1
  end

  test "PubSub broadcasts events" do
    AuditLog.log_sync("pubsub.test", "actor", "resource", %{})
    assert_receive {:audit_event, %{event_type: "pubsub.test"}}, 500
  end

  test "disk persistence writes JSONL file" do
    AuditLog.log_sync("disk.test", "actor", "resource", %{data: "value"})

    date = Date.to_iso8601(Date.utc_today())
    path = Path.join(@tmp_dir, "ccem_audit_#{date}.jsonl")
    assert File.exists?(path)

    content = File.read!(path)
    lines = String.split(content, "\n", trim: true)
    assert length(lines) >= 1

    decoded = Jason.decode!(hd(lines))
    assert decoded["event_type"] == "disk.test"
  end
end
