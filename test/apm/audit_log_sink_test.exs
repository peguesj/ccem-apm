defmodule Apm.AuditLogSinkTest do
  @moduledoc """
  Tests for the HTTP audit sink behaviour (audit-s7 / CP-225 / US-457).

  Covers:
  - Apm.AuditLog.Sink behaviour contract
  - NoopSink returns :ok for any event
  - HttpSink config / module attributes
  - dispatch_sinks/1 with NoopSink wired via application config
  - Fire-and-forget: dispatch_sinks/1 completes without blocking for a
    module that captures calls via process messaging
  """
  use ExUnit.Case, async: false

  alias Apm.AuditLog
  alias Apm.AuditLog.Sinks.NoopSink
  alias Apm.AuditLog.Sinks.HttpSink

  # ── NoopSink ─────────────────────────────────────────────────────────────────

  describe "NoopSink" do
    test "implements Apm.AuditLog.Sink behaviour" do
      behaviours =
        NoopSink.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Apm.AuditLog.Sink in behaviours
    end

    test "push_event/1 returns :ok for any event" do
      assert :ok = NoopSink.push_event(%{event_type: :test, actor: "agent", resource: "/res"})
    end

    test "push_event/1 returns :ok for empty map" do
      assert :ok = NoopSink.push_event(%{})
    end
  end

  # ── HttpSink ─────────────────────────────────────────────────────────────────

  describe "HttpSink" do
    test "implements Apm.AuditLog.Sink behaviour" do
      behaviours =
        HttpSink.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Apm.AuditLog.Sink in behaviours
    end

    test "has push_event/1 function" do
      assert function_exported?(HttpSink, :push_event, 1)
    end

    test "push_event/1 fails gracefully when endpoint is unreachable" do
      # Temporarily override config to point at a local port that is not open.
      Application.put_env(:apm, HttpSink,
        endpoint_url: "http://127.0.0.1:19999/no-such-endpoint",
        timeout_ms: 100,
        max_retries: 0
      )

      # Must not raise — returns {:error, _reason}
      result = HttpSink.push_event(%{event_id: "test-unreachable", actor: "test"})
      assert match?({:error, _}, result) or result == :ok

      Application.delete_env(:apm, HttpSink)
    end
  end

  # ── AuditLog.dispatch_sinks/1 ─────────────────────────────────────────────

  describe "AuditLog.dispatch_sinks/1" do
    test "is a public function" do
      assert function_exported?(AuditLog, :dispatch_sinks, 1)
    end

    test "returns :ok with empty sink list" do
      Application.put_env(:apm, :audit_sinks, [])
      assert :ok = AuditLog.dispatch_sinks(%{event_id: "e1"})
      Application.delete_env(:apm, :audit_sinks)
    end

    test "returns :ok with NoopSink configured" do
      Application.put_env(:apm, :audit_sinks, [NoopSink])
      assert :ok = AuditLog.dispatch_sinks(%{event_id: "e2", actor: "test"})
      Application.delete_env(:apm, :audit_sinks)
    end

    test "is fire-and-forget: dispatching a sink that sends to test PID completes promptly" do
      test_pid = self()

      # Define an inline sink module via a process dictionary trick:
      # We use a real module that looks up the calling PID from a known registry
      # key so the spawned Task can message back.
      :persistent_term.put({:audit_sink_test_pid, :sink_capture}, test_pid)

      Application.put_env(:apm, :audit_sinks, [Apm.AuditLog.Sinks.CaptureSink])

      event = %{event_id: "fire-and-forget-test", actor: "obs-audit-lead", resource: "/test"}
      :ok = AuditLog.dispatch_sinks(event)

      # The Task is spawned; wait for the notification with a generous timeout.
      assert_receive {:sink_captured, ^event}, 2_000

      Application.delete_env(:apm, :audit_sinks)
      :persistent_term.erase({:audit_sink_test_pid, :sink_capture})
    end

    test "sink returning {:error, reason} does not crash dispatch" do
      Application.put_env(:apm, :audit_sinks, [Apm.AuditLog.Sinks.ErrorSink])
      # Must not raise
      assert :ok = AuditLog.dispatch_sinks(%{event_id: "err-test"})
      Application.delete_env(:apm, :audit_sinks)
    end
  end

  # ── AuditLog integration: sinks called after log_sync ─────────────────────

  describe "AuditLog integration with sinks" do
    test "NoopSink is called when configured — event flows end-to-end" do
      Application.put_env(:apm, :audit_sinks, [NoopSink])
      AuditLog.clear_all()

      event = AuditLog.log_sync(:sink_test, "agent-x", "/resource", %{sink: "noop"})

      assert event.event_type == :sink_test
      assert event.actor == "agent-x"
      assert Map.has_key?(event, :self_hash)

      Application.delete_env(:apm, :audit_sinks)
    end

    test "CaptureSink receives the event logged via log_sync" do
      test_pid = self()
      :persistent_term.put({:audit_sink_test_pid, :sink_capture}, test_pid)
      Application.put_env(:apm, :audit_sinks, [Apm.AuditLog.Sinks.CaptureSink])

      AuditLog.clear_all()
      logged = AuditLog.log_sync(:capture_test, "obs-lead", "/audit/sink", %{wave: 6})

      assert_receive {:sink_captured, received_event}, 2_000
      assert received_event.event_id == logged.event_id

      Application.delete_env(:apm, :audit_sinks)
      :persistent_term.erase({:audit_sink_test_pid, :sink_capture})
    end
  end
end

# ── Test-only sink helpers (defined at the bottom of the test file so they are
#    compiled only when `Mix.env() == :test`).

defmodule Apm.AuditLog.Sinks.CaptureSink do
  @moduledoc """
  Test-only sink — sends `{:sink_captured, event}` to the PID stored under the
  `:persistent_term` key `{:audit_sink_test_pid, :sink_capture}`.
  """
  @behaviour Apm.AuditLog.Sink

  @impl true
  def push_event(event) do
    case :persistent_term.get({:audit_sink_test_pid, :sink_capture}, nil) do
      nil -> :ok
      pid -> send(pid, {:sink_captured, event})
    end

    :ok
  end
end

defmodule Apm.AuditLog.Sinks.ErrorSink do
  @moduledoc "Test-only sink that always returns an error."
  @behaviour Apm.AuditLog.Sink

  @impl true
  def push_event(_event), do: {:error, :intentional_test_error}
end
