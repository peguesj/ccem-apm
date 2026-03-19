defmodule ApmV5.AgUi.EventRouterTest do
  use ExUnit.Case, async: false

  alias ApmV5.AgUi.EventRouter
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

    case Process.whereis(ApmV5.AgUi.EventBus) do
      nil -> ApmV5.AgUi.EventBus.start_link([])
      _pid -> :ok
    end

    case Process.whereis(EventRouter) do
      nil -> EventRouter.start_link([])
      _pid -> :ok
    end

    EventStream.clear()
    :ok
  end

  describe "route/1" do
    test "route/1 returns :ok for a valid event map" do
      # Use custom type to avoid AgentRegistry dependency in isolated test env
      event = %{type: EventType.custom(), sequence: 1, data: %{name: "test_event"}}
      assert :ok = EventRouter.route(event)
      # Give the cast time to process
      Process.sleep(20)
    end

    test "route/1 does not crash on malformed event" do
      assert :ok = EventRouter.route(%{})
      Process.sleep(20)
      assert Process.alive?(Process.whereis(EventRouter))
    end

    test "route/1 does not crash on event with unknown type" do
      event = %{type: "NOT_A_REAL_TYPE", sequence: 0, data: %{}}
      assert :ok = EventRouter.route(event)
      Process.sleep(20)
      # Router must remain alive after handling unknown type
      assert Process.alive?(Process.whereis(EventRouter))
    end
  end

  describe "emit_and_route/2" do
    test "emit_and_route/2 returns an event map" do
      event = EventRouter.emit_and_route(EventType.custom(), %{name: "test_event"})
      assert is_map(event)
      assert event.type == EventType.custom()
    end

    test "emit_and_route/2 increments sequence via EventStream" do
      # Use custom type to avoid AgentRegistry dependency in test env
      e1 = EventRouter.emit_and_route(EventType.custom(), %{name: "e1"})
      e2 = EventRouter.emit_and_route(EventType.custom(), %{name: "e2"})
      assert e2.sequence > e1.sequence
    end

    test "emit_and_route/2 event appears in EventStream store" do
      EventRouter.emit_and_route(EventType.custom(), %{router_test: true})
      events = EventStream.get_events(nil, 10)
      assert Enum.any?(events, fn e -> e.type == EventType.custom() end)
    end
  end

  describe "stats/0" do
    test "stats/0 returns a map" do
      stats = EventRouter.stats()
      assert is_map(stats)
    end

    test "stats/0 routed_count increases after routing" do
      before = EventRouter.stats().routed_count
      EventRouter.route(%{type: EventType.custom(), sequence: 0, data: %{}})
      Process.sleep(20)
      after_count = EventRouter.stats().routed_count
      assert after_count > before
    end

    test "stats/0 tracks counts by event type" do
      EventRouter.route(%{type: EventType.custom(), sequence: 0, data: %{name: "stats_test"}})
      # stats is a GenServer.call — it serializes after the preceding cast
      stats = EventRouter.stats()
      assert Map.has_key?(stats, :by_type)
      assert map_size(stats.by_type) > 0
    end
  end
end
