defmodule ApmV5.AuditLog.Sinks.EventStoreSinkTest do
  @moduledoc """
  TDD tests for CP-287 (audit-s9): EventStoreSink WORM backend.

  Tests use a mock EventStoreAdapter — no PostgreSQL required.
  The real EventStore.append_to_stream/4 is only called when
  config :apm_v5, :audit_backend is :eventstore (opt-in, default :ets).

  Run with: mix test --only auth_ext
  """

  use ExUnit.Case, async: false

  @moduletag :auth_ext

  alias ApmV5.AuditLog.Sinks.EventStoreSink

  # ---------------------------------------------------------------------------
  # Behaviour contract
  # ---------------------------------------------------------------------------

  describe "behaviour contract" do
    test "EventStoreSink implements ApmV5.AuditLog.Sink" do
      behaviours =
        EventStoreSink.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert ApmV5.AuditLog.Sink in behaviours
    end

    test "EventStoreSink exports push_event/1" do
      assert function_exported?(EventStoreSink, :push_event, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Default backend (:ets) — sink is a no-op / skips EventStore
  # ---------------------------------------------------------------------------

  describe "default backend (:ets)" do
    setup do
      Application.delete_env(:apm_v5, :audit_backend)
      on_exit(fn -> Application.delete_env(:apm_v5, :audit_backend) end)
    end

    test "push_event/1 returns :ok when backend is :ets (default)" do
      event = %{event_id: "test-1", event_type: "auth:test", actor: "agent-1"}
      assert EventStoreSink.push_event(event) == :ok
    end

    test "push_event/1 does NOT call event store adapter when backend is :ets" do
      # Install a spy adapter that sends to test PID if called
      test_pid = self()

      spy_adapter = fn _stream, _version, _events, _opts ->
        send(test_pid, :unexpected_append_call)
        :ok
      end

      Application.put_env(:apm_v5, :event_store_adapter_fn, spy_adapter)
      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      EventStoreSink.push_event(%{event_id: "should-not-append"})
      refute_receive :unexpected_append_call, 100
    end
  end

  # ---------------------------------------------------------------------------
  # EventStore backend (:eventstore) — routes through adapter
  # ---------------------------------------------------------------------------

  describe "eventstore backend" do
    setup do
      Application.put_env(:apm_v5, :audit_backend, :eventstore)
      on_exit(fn -> Application.delete_env(:apm_v5, :audit_backend) end)
    end

    test "push_event/1 calls the event store adapter when backend is :eventstore" do
      test_pid = self()

      capture_adapter = fn stream_id, expected_version, events, opts ->
        send(test_pid, {:append_called, stream_id, expected_version, events, opts})
        :ok
      end

      Application.put_env(:apm_v5, :event_store_adapter_fn, capture_adapter)
      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      event = %{event_id: "evt-123", event_type: "auth:authorize", actor: "agent-1"}
      assert EventStoreSink.push_event(event) == :ok

      assert_receive {:append_called, stream_id, :any_version, events, _opts}, 500
      assert is_binary(stream_id)
      assert length(events) == 1
    end

    test "stream_id is derived from event_type when present" do
      test_pid = self()

      capture_adapter = fn stream_id, _version, _events, _opts ->
        send(test_pid, {:stream_id, stream_id})
        :ok
      end

      Application.put_env(:apm_v5, :event_store_adapter_fn, capture_adapter)
      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      event = %{event_id: "evt-456", event_type: "auth:authorize"}
      EventStoreSink.push_event(event)

      assert_receive {:stream_id, stream_id}, 500
      assert String.contains?(stream_id, "auth")
    end

    test "event data is serialised as JSON in the event record" do
      test_pid = self()

      capture_adapter = fn _stream, _version, events, _opts ->
        send(test_pid, {:events, events})
        :ok
      end

      Application.put_env(:apm_v5, :event_store_adapter_fn, capture_adapter)
      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      event = %{event_id: "evt-789", event_type: "audit:log", actor: "test-actor"}
      EventStoreSink.push_event(event)

      assert_receive {:events, [event_record]}, 500
      assert is_map(event_record)
      assert Map.has_key?(event_record, :event_type) or Map.has_key?(event_record, :data)
    end

    test "adapter returning :ok causes push_event/1 to return :ok" do
      Application.put_env(:apm_v5, :event_store_adapter_fn, fn _, _, _, _ -> :ok end)
      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      assert EventStoreSink.push_event(%{event_id: "ok-result"}) == :ok
    end

    test "adapter returning {:error, reason} is propagated as {:error, reason}" do
      Application.put_env(:apm_v5, :event_store_adapter_fn, fn _, _, _, _ ->
        {:error, :connection_refused}
      end)

      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      assert {:error, :connection_refused} = EventStoreSink.push_event(%{event_id: "err-result"})
    end

    test "adapter crash is caught and returns {:error, exception}" do
      Application.put_env(:apm_v5, :event_store_adapter_fn, fn _, _, _, _ ->
        raise RuntimeError, "simulated crash"
      end)

      on_exit(fn -> Application.delete_env(:apm_v5, :event_store_adapter_fn) end)

      result = EventStoreSink.push_event(%{event_id: "crash-test"})
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # config/2 — backend config helper
  # ---------------------------------------------------------------------------

  describe "backend_enabled?/0" do
    test "returns false when :audit_backend is :ets (default)" do
      Application.delete_env(:apm_v5, :audit_backend)
      refute EventStoreSink.backend_enabled?()
    end

    test "returns true when :audit_backend is :eventstore" do
      Application.put_env(:apm_v5, :audit_backend, :eventstore)
      on_exit(fn -> Application.delete_env(:apm_v5, :audit_backend) end)
      assert EventStoreSink.backend_enabled?()
    end
  end
end
