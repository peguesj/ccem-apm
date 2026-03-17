defmodule ApmV5.ChatStoreTest do
  use ExUnit.Case, async: false

  alias ApmV5.ChatStore

  setup do
    # Ensure PubSub is running
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    # Ensure EventStream is running (ChatStore subscribes to ag_ui:events PubSub)
    case Process.whereis(ApmV5.EventStream) do
      nil ->
        case ApmV5.EventStream.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid -> :ok
    end

    # Ensure ChatStore is running
    case Process.whereis(ChatStore) do
      nil ->
        {:ok, _pid} = ChatStore.start_link([])
      _pid ->
        :ok
    end

    # Clear ETS table between tests
    :ets.delete_all_objects(:chat_messages)

    :ok
  end

  describe "send_message/3" do
    test "stores message and returns {:ok, message}" do
      assert {:ok, message} = ChatStore.send_message("project:test", "Hello world")

      assert message["content"] == "Hello world"
      assert message["scope"] == "project:test"
      assert message["role"] == "user"
      assert message["source"] == "chat_input"
      assert is_binary(message["id"])
      assert is_binary(message["timestamp"])
    end

    test "stores message with custom metadata" do
      metadata = %{"role" => "assistant", "agent_id" => "agent-1"}
      assert {:ok, message} = ChatStore.send_message("agent:a1", "Response text", metadata)

      assert message["role"] == "assistant"
      assert message["agent_id"] == "agent-1"
    end
  end

  describe "list_messages/1" do
    test "returns messages in newest-first order" do
      ChatStore.send_message("project:test", "First")
      ChatStore.send_message("project:test", "Second")
      ChatStore.send_message("project:test", "Third")

      messages = ChatStore.list_messages("project:test")
      assert length(messages) == 3
      contents = Enum.map(messages, & &1["content"])
      assert contents == ["Third", "Second", "First"]
    end

    test "returns empty list for unknown scope" do
      assert ChatStore.list_messages("nonexistent:scope") == []
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        ChatStore.send_message("project:test", "Message #{i}")
      end

      messages = ChatStore.list_messages("project:test", 3)
      assert length(messages) == 3
    end

    test "default limit is 50" do
      for i <- 1..60 do
        ChatStore.send_message("project:test", "Message #{i}")
      end

      messages = ChatStore.list_messages("project:test")
      assert length(messages) == 50
    end

    test "messages are scoped — different scopes are independent" do
      ChatStore.send_message("project:alpha", "Alpha message")
      ChatStore.send_message("project:beta", "Beta message")

      alpha_msgs = ChatStore.list_messages("project:alpha")
      beta_msgs = ChatStore.list_messages("project:beta")

      assert length(alpha_msgs) == 1
      assert length(beta_msgs) == 1
      assert hd(alpha_msgs)["content"] == "Alpha message"
      assert hd(beta_msgs)["content"] == "Beta message"
    end
  end

  describe "clear_scope/1" do
    test "clears all messages for a scope" do
      ChatStore.send_message("project:test", "Hello")
      ChatStore.send_message("project:test", "World")

      assert length(ChatStore.list_messages("project:test")) == 2

      ChatStore.clear_scope("project:test")
      # clear_scope is a cast, give it a moment
      Process.sleep(20)

      assert ChatStore.list_messages("project:test") == []
    end

    test "does not affect other scopes" do
      ChatStore.send_message("project:alpha", "Alpha")
      ChatStore.send_message("project:beta", "Beta")

      ChatStore.clear_scope("project:alpha")
      Process.sleep(20)

      assert ChatStore.list_messages("project:alpha") == []
      assert length(ChatStore.list_messages("project:beta")) == 1
    end
  end

  describe "get_message/1" do
    test "retrieves a specific message by ID" do
      {:ok, sent} = ChatStore.send_message("project:test", "Find me")

      assert {:ok, found} = ChatStore.get_message(sent["id"])
      assert found["content"] == "Find me"
      assert found["id"] == sent["id"]
    end

    test "returns {:error, :not_found} for unknown message ID" do
      assert {:error, :not_found} = ChatStore.get_message("nonexistent-msg-id")
    end
  end

  describe "FIFO enforcement (max 500 messages per scope)" do
    test "enforces maximum messages per scope" do
      scope = "project:overflow"

      # Insert 510 messages
      for i <- 1..510 do
        ChatStore.send_message(scope, "Message #{i}")
      end

      # list_messages with a high limit to see total stored
      all = ChatStore.list_messages(scope, 600)
      assert length(all) == 500

      # The newest message should be the last one sent
      assert hd(all)["content"] == "Message 510"
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts :new_message event on send_message" do
      scope = "project:pubsub-test"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, ChatStore.topic(scope))

      ChatStore.send_message(scope, "Broadcast me")

      assert_receive {:chat_event, ^scope, {:new_message, message}}
      assert message["content"] == "Broadcast me"
    end

    test "broadcasts :cleared event on clear_scope" do
      scope = "project:clear-test"
      ChatStore.send_message(scope, "To be cleared")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, ChatStore.topic(scope))

      ChatStore.clear_scope(scope)

      assert_receive {:chat_event, ^scope, :cleared}
    end
  end

  describe "topic/1" do
    test "returns properly prefixed topic string" do
      assert ChatStore.topic("project:myapp") == "apm:chat:project:myapp"
      assert ChatStore.topic("agent:a1") == "apm:chat:agent:a1"
    end
  end

  describe "scope variants — formation and project scoping" do
    test "formation scope stores and retrieves messages independently" do
      scope = "formation:fmt-test-001"
      {:ok, _} = ChatStore.send_message(scope, "Formation message")
      msgs = ChatStore.list_messages(scope)
      assert length(msgs) == 1
      assert hd(msgs)["scope"] == scope
    end

    test "project scope stores and retrieves messages independently" do
      scope = "project:my-project"
      {:ok, _} = ChatStore.send_message(scope, "Project message")
      msgs = ChatStore.list_messages(scope)
      assert length(msgs) >= 1
      assert Enum.any?(msgs, &(&1["content"] == "Project message"))
    end

    test "agent scope stores and retrieves messages independently" do
      scope = "agent:agent-xyz"
      {:ok, _} = ChatStore.send_message(scope, "Agent message")
      msgs = ChatStore.list_messages(scope)
      assert Enum.any?(msgs, &(&1["content"] == "Agent message"))
    end

    test "global scope works as a valid scope key" do
      {:ok, msg} = ChatStore.send_message("global", "Global broadcast")
      assert msg["scope"] == "global"
    end

    test "formation and project scopes are fully isolated" do
      formation_scope = "formation:fmt-isolation-01"
      project_scope = "project:isolation-proj"

      ChatStore.send_message(formation_scope, "formation only")
      ChatStore.send_message(project_scope, "project only")

      formation_msgs = ChatStore.list_messages(formation_scope)
      project_msgs = ChatStore.list_messages(project_scope)

      assert Enum.all?(formation_msgs, &(&1["scope"] == formation_scope))
      assert Enum.all?(project_msgs, &(&1["scope"] == project_scope))
    end
  end

  describe "500-msg FIFO enforcement (extended)" do
    test "oldest messages are dropped when cap is exceeded" do
      scope = "project:fifo-extended"

      for i <- 1..505 do
        ChatStore.send_message(scope, "msg-#{i}")
      end

      msgs = ChatStore.list_messages(scope, 600)
      contents = Enum.map(msgs, & &1["content"])

      # msg-1 through msg-5 should have been evicted
      refute "msg-1" in contents
      refute "msg-5" in contents
      assert "msg-505" in contents
    end

    test "cap applies per scope — two scopes can each hold 500" do
      scope_a = "project:cap-scope-a"
      scope_b = "project:cap-scope-b"

      for i <- 1..500 do
        ChatStore.send_message(scope_a, "a-#{i}")
        ChatStore.send_message(scope_b, "b-#{i}")
      end

      assert length(ChatStore.list_messages(scope_a, 600)) == 500
      assert length(ChatStore.list_messages(scope_b, 600)) == 500
    end
  end

  describe "send_message metadata — role and agent_id" do
    test "assistant role stored correctly" do
      {:ok, msg} = ChatStore.send_message("project:roles", "AI reply", %{"role" => "assistant"})
      assert msg["role"] == "assistant"
    end

    test "agent_id stored in message metadata" do
      {:ok, msg} = ChatStore.send_message("project:agent-meta", "Hello", %{"agent_id" => "agent-007"})
      assert msg["agent_id"] == "agent-007"
    end

    test "source defaults to chat_input" do
      {:ok, msg} = ChatStore.send_message("project:source-check", "Test")
      assert msg["source"] == "chat_input"
    end
  end

  describe "AG-UI TEXT_MESSAGE assembly via PubSub" do
    alias AgUi.Core.Events.EventType

    test "TEXT_MESSAGE_START initializes assembly buffer" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.broadcast(ApmV5.PubSub, "ag_ui:events", {:ag_ui_event, %{
        type: EventType.text_message_start(),
        data: %{agent_id: agent_id, message_id: "msg-abc", role: "assistant"}
      }})
      # Give handle_info time to process
      Process.sleep(50)
      # No messages stored yet (buffer not flushed)
      msgs = ChatStore.list_messages("agent:#{agent_id}")
      refute Enum.any?(msgs, &(&1["source"] == "ag_ui"))
    end

    test "complete TEXT_MESSAGE sequence stores assembled message" do
      agent_id = "asm-agent-#{System.unique_integer([:positive])}"
      msg_id = "asm-msg-001"
      topic = "ag_ui:events"

      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, {:ag_ui_event, %{
        type: EventType.text_message_start(),
        data: %{agent_id: agent_id, message_id: msg_id, role: "assistant"}
      }})
      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, {:ag_ui_event, %{
        type: EventType.text_message_content(),
        data: %{agent_id: agent_id, message_id: msg_id, content: "Hello"}
      }})
      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, {:ag_ui_event, %{
        type: EventType.text_message_content(),
        data: %{agent_id: agent_id, message_id: msg_id, content: " world"}
      }})
      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, {:ag_ui_event, %{
        type: EventType.text_message_end(),
        data: %{agent_id: agent_id, message_id: msg_id}
      }})

      Process.sleep(100)

      scope = "agent:#{agent_id}"
      msgs = ChatStore.list_messages(scope, 10)
      assembled = Enum.find(msgs, &(&1["source"] == "ag_ui"))

      assert assembled != nil
      assert assembled["content"] == "Hello world"
      assert assembled["role"] == "assistant"
    end
  end
end
