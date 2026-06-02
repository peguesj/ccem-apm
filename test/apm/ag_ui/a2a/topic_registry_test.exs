defmodule Apm.AgUi.A2A.TopicRegistryTest do
  @moduledoc """
  Verifies the coord-a2 v9.2.1 hotfix — `{:topic, t}` addressing must filter
  to subscribers, not silently broadcast to all agents.
  """
  use ExUnit.Case, async: false

  alias Apm.AgUi.A2A.{Addressing, TopicRegistry}

  setup do
    # TopicRegistry is started by the application supervisor; ensure clean state.
    case GenServer.whereis(TopicRegistry) do
      nil -> {:ok, _} = TopicRegistry.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      # Unsubscribe everyone (best-effort cleanup; protected ETS table)
      :ok
    end)

    :ok
  end

  describe "subscribe/2 and get_subscribers/1" do
    test "single agent subscribes to a topic" do
      :ok = TopicRegistry.subscribe("agent-a", "coalesce:skill-updates")
      subscribers = TopicRegistry.get_subscribers("coalesce:skill-updates")
      assert "agent-a" in subscribers
    end

    test "subscribing twice is idempotent (no duplicate)" do
      :ok = TopicRegistry.subscribe("agent-b", "topic-x")
      :ok = TopicRegistry.subscribe("agent-b", "topic-x")
      subscribers = TopicRegistry.get_subscribers("topic-x")
      assert Enum.count(subscribers, &(&1 == "agent-b")) == 1
    end

    test "unrelated topic returns empty list" do
      assert TopicRegistry.get_subscribers("nobody-subscribed-here") == []
    end
  end

  describe "Addressing.resolve({:topic, t})" do
    test "returns only subscribers, NOT all registered agents (coord-a2 hotfix)" do
      :ok = TopicRegistry.subscribe("subscriber-1", "scoped-topic-hotfix")
      :ok = TopicRegistry.subscribe("subscriber-2", "scoped-topic-hotfix")

      resolved = Addressing.resolve({:topic, "scoped-topic-hotfix"})

      assert "subscriber-1" in resolved
      assert "subscriber-2" in resolved
      assert length(resolved) == 2
    end

    test "empty topic returns empty list (was: all agents — silent amplification bug)" do
      resolved = Addressing.resolve({:topic, "topic-with-zero-subscribers"})
      assert resolved == []
    end
  end

  describe "unsubscribe_all/1" do
    test "removes all subscriptions for an agent" do
      :ok = TopicRegistry.subscribe("multi-agent", "topic-1")
      :ok = TopicRegistry.subscribe("multi-agent", "topic-2")
      :ok = TopicRegistry.unsubscribe_all("multi-agent")

      assert TopicRegistry.get_topics("multi-agent") == []
      refute "multi-agent" in TopicRegistry.get_subscribers("topic-1")
      refute "multi-agent" in TopicRegistry.get_subscribers("topic-2")
    end
  end
end
