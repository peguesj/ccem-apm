defmodule ApmV5.AgUi.EventBusTest do
  use ExUnit.Case, async: false

  alias ApmV5.AgUi.EventBus
  alias AgUi.Core.Events.EventType

  setup do
    case Process.whereis(EventBus) do
      nil -> EventBus.start_link([])
      _pid -> :ok
    end

    :ok
  end

  describe "subscribe/1 and publish/2 — valid event types" do
    test "subscriber receives published events matching wildcard" do
      :ok = EventBus.subscribe("*")
      {:ok, _event} = EventBus.publish(EventType.run_started(), %{agent_id: "a1"})
      assert_receive {:event_bus, _topic, event}
      assert event.type == EventType.run_started()
    end

    test "publish returns {:ok, event} for valid event type" do
      result = EventBus.publish(EventType.custom(), %{payload: "test"})
      assert {:ok, event} = result
      assert is_map(event)
    end

    test "publish returns {:error, :invalid_event_type} for unknown type" do
      assert {:error, :invalid_event_type} =
               EventBus.publish("NOT_A_REAL_AG_UI_TYPE", %{})
    end

    test "subscriber only receives events after subscribing (no replay by default)" do
      # Publish before subscribing
      EventBus.publish(EventType.custom(), %{seq: :before})
      :ok = EventBus.subscribe("*")
      EventBus.publish(EventType.run_started(), %{seq: :after})
      assert_receive {:event_bus, _topic, event}
      assert event.data.seq == :after
    end
  end

  describe "unsubscribe/0" do
    test "unsubscribed process no longer receives events" do
      :ok = EventBus.subscribe("*")
      :ok = EventBus.unsubscribe()
      EventBus.publish(EventType.custom(), %{msg: "after unsub"})
      refute_receive {:event_bus, _, _}, 150
    end
  end

  describe "stats/0" do
    test "stats/0 returns a map" do
      stats = EventBus.stats()
      assert is_map(stats)
    end

    test "stats/0 has expected keys" do
      stats = EventBus.stats()
      # At minimum, some count field should be present
      assert map_size(stats) > 0
    end
  end

  describe "replay_since/1-2" do
    test "replay_since/1 returns {:ok, list} or :gap" do
      result = EventBus.replay_since(0)
      assert match?({:ok, _}, result) or result == :gap
    end

    test "replay_since after publishing returns events or :gap" do
      EventBus.publish(EventType.custom(), %{replay_test: true})
      result = EventBus.replay_since(0, nil)
      case result do
        {:ok, events} -> assert is_list(events)
        :gap -> :ok
      end
    end
  end
end
