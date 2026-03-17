defmodule ApmV5.EventStreamTest do
  use ExUnit.Case, async: false

  alias ApmV5.EventStream
  alias AgUi.Core.Events.EventType

  setup do
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    case Process.whereis(EventStream) do
      nil -> EventStream.start_link([])
      _pid -> :ok
    end

    EventStream.clear()
    :ok
  end

  describe "emit/2" do
    test "emit/2 returns a map with sequence, type, and data" do
      event = EventStream.emit(EventType.run_started(), %{agent_id: "test"})
      assert is_map(event)
      assert event.type == EventType.run_started()
      assert is_integer(event.sequence)
      assert event.sequence >= 0
    end

    test "successive emits have increasing sequence numbers" do
      e1 = EventStream.emit(EventType.run_started(), %{agent_id: "a1"})
      e2 = EventStream.emit(EventType.run_finished(), %{agent_id: "a1"})
      assert e2.sequence > e1.sequence
    end

    test "emit broadcasts to PubSub topic" do
      EventStream.subscribe()
      EventStream.emit(EventType.custom(), %{broadcast: true})
      assert_receive {:ag_ui_event, event}
      assert event.type == EventType.custom()
    end
  end

  describe "get_events/2" do
    test "get_events/0 returns a list" do
      events = EventStream.get_events()
      assert is_list(events)
    end

    test "get_events returns newest events first" do
      EventStream.emit(EventType.run_started(), %{order: 1})
      EventStream.emit(EventType.run_finished(), %{order: 2})
      events = EventStream.get_events(nil, 10)
      seqs = Enum.map(events, & &1.sequence)
      assert seqs == Enum.sort(seqs, :desc)
    end

    test "get_events filtered by agent_id returns only matching events" do
      EventStream.emit(EventType.run_started(), %{agent_id: "agent-filter-A"})
      EventStream.emit(EventType.run_started(), %{agent_id: "agent-filter-B"})
      events = EventStream.get_events("agent-filter-A", 50)
      assert Enum.all?(events, fn e -> e.data.agent_id == "agent-filter-A" end)
    end

    test "get_events limit is respected" do
      for _ <- 1..10 do
        EventStream.emit(EventType.custom(), %{})
      end

      events = EventStream.get_events(nil, 3)
      assert length(events) <= 3
    end
  end

  describe "subscribe/0 and clear/0" do
    test "subscribe/0 returns :ok" do
      assert :ok = EventStream.subscribe()
    end

    test "clear/0 removes all stored events" do
      EventStream.emit(EventType.custom(), %{pre_clear: true})
      EventStream.clear()
      events = EventStream.get_events()
      assert events == []
    end

    test "topic/0 returns a non-empty string" do
      assert is_binary(EventStream.topic())
      assert String.length(EventStream.topic()) > 0
    end
  end

  describe "convenience emitters" do
    test "emit_run_started/2 produces RUN_STARTED event" do
      event = EventStream.emit_run_started("agent-convenience")
      assert event.type == EventType.run_started()
      assert event.data.agent_id == "agent-convenience"
    end

    test "emit_run_finished/3 produces RUN_FINISHED event" do
      event = EventStream.emit_run_finished("agent-fin", "run-001")
      assert event.type == EventType.run_finished()
      assert event.data.agent_id == "agent-fin"
    end
  end
end
