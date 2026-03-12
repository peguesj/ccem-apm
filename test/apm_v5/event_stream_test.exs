defmodule ApmV5.EventStreamTest do
  use ExUnit.Case, async: false

  alias ApmV5.EventStream

  setup do
    EventStream.clear()
    :ok
  end

  describe "emit/2" do
    test "emits an event with monotonically increasing sequence number" do
      e1 = EventStream.emit("RUN_STARTED", %{agent_id: "a1"})
      e2 = EventStream.emit("RUN_FINISHED", %{agent_id: "a1"})

      assert e1.sequence == 1
      assert e2.sequence == 2
      assert e2.sequence > e1.sequence
    end

    test "emitted event contains type, data, timestamp, and sequence" do
      event = EventStream.emit("STATE_SNAPSHOT", %{agents: []})

      assert event.type == "STATE_SNAPSHOT"
      assert event.data == %{agents: []}
      assert is_binary(event.timestamp)
      assert is_integer(event.sequence)
    end

    test "emitted event includes run_id and thread_id from data" do
      event =
        EventStream.emit("RUN_STARTED", %{
          agent_id: "a1",
          run_id: "run-123",
          thread_id: "thread-abc"
        })

      assert event.run_id == "run-123"
      assert event.thread_id == "thread-abc"
    end
  end

  describe "get_events/2" do
    test "returns events in reverse chronological order (newest first)" do
      EventStream.emit("RUN_STARTED", %{agent_id: "a1"})
      EventStream.emit("TEXT_MESSAGE_START", %{agent_id: "a1"})
      EventStream.emit("TEXT_MESSAGE_END", %{agent_id: "a1"})

      events = EventStream.get_events()
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == [3, 2, 1]
    end

    test "filters events by agent_id" do
      EventStream.emit("RUN_STARTED", %{agent_id: "a1"})
      EventStream.emit("RUN_STARTED", %{agent_id: "a2"})
      EventStream.emit("TEXT_MESSAGE_START", %{agent_id: "a1"})

      events = EventStream.get_events("a1")
      assert length(events) == 2
      assert Enum.all?(events, fn e -> e.data.agent_id == "a1" end)
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        EventStream.emit("TEXT_MESSAGE_CONTENT", %{agent_id: "a1", content: "msg-#{i}"})
      end

      events = EventStream.get_events(nil, 3)
      assert length(events) == 3
    end

    test "returns empty list when no events exist" do
      assert EventStream.get_events() == []
    end
  end

  describe "convenience emitters" do
    test "emit_run_started generates run_id and thread_id" do
      event = EventStream.emit_run_started("orchestrator")

      assert event.type == "RUN_STARTED"
      assert event.data.agent_id == "orchestrator"
      assert String.starts_with?(event.data.run_id, "run-")
      assert event.data.thread_id == "thread-orchestrator"
    end

    test "emit_run_finished includes agent_id and run_id" do
      event = EventStream.emit_run_finished("worker-1", "run-abc123")

      assert event.type == "RUN_FINISHED"
      assert event.data.agent_id == "worker-1"
      assert event.data.run_id == "run-abc123"
    end

    test "emit_text_message_start generates message_id" do
      event = EventStream.emit_text_message_start("a1", "run-1")

      assert event.type == "TEXT_MESSAGE_START"
      assert String.starts_with?(event.data.message_id, "msg-")
    end

    test "emit_text_message_content includes content" do
      event = EventStream.emit_text_message_content("a1", "run-1", "Hello world")

      assert event.type == "TEXT_MESSAGE_CONTENT"
      assert event.data.content == "Hello world"
    end

    test "emit_text_message_end" do
      event = EventStream.emit_text_message_end("a1", "run-1")
      assert event.type == "TEXT_MESSAGE_END"
    end

    test "emit_tool_call_start generates tool_call_id" do
      event = EventStream.emit_tool_call_start("a1", "run-1", "Bash")

      assert event.type == "TOOL_CALL_START"
      assert event.data.tool_name == "Bash"
      assert String.starts_with?(event.data.tool_call_id, "tc-")
    end

    test "emit_tool_call_args includes args" do
      event = EventStream.emit_tool_call_args("a1", "run-1", "tc-1", %{command: "ls"})

      assert event.type == "TOOL_CALL_ARGS"
      assert event.data.args == %{command: "ls"}
    end

    test "emit_tool_call_end" do
      event = EventStream.emit_tool_call_end("a1", "run-1", "tc-1")

      assert event.type == "TOOL_CALL_END"
      assert event.data.tool_call_id == "tc-1"
    end

    test "emit_state_snapshot includes agents, sessions, notifications" do
      event =
        EventStream.emit_state_snapshot(%{
          agents: [%{id: "a1", name: "Alpha"}],
          sessions: [%{session_id: "s1"}],
          notifications: []
        })

      assert event.type == "STATE_SNAPSHOT"
      assert length(event.data.agents) == 1
      assert length(event.data.sessions) == 1
      assert event.data.notifications == []
    end
  end

  describe "PubSub integration" do
    test "subscribers receive emitted events" do
      EventStream.subscribe()

      EventStream.emit("RUN_STARTED", %{agent_id: "test-agent"})

      assert_receive {:ag_ui_event, event}
      assert event.type == "RUN_STARTED"
      assert event.data.agent_id == "test-agent"
    end
  end

  describe "clear/0" do
    test "resets sequence counter and clears events" do
      EventStream.emit("RUN_STARTED", %{agent_id: "a1"})
      EventStream.emit("RUN_STARTED", %{agent_id: "a2"})

      assert length(EventStream.get_events()) == 2

      EventStream.clear()

      assert EventStream.get_events() == []

      # Sequence resets
      event = EventStream.emit("RUN_STARTED", %{agent_id: "a3"})
      assert event.sequence == 1
    end
  end
end
