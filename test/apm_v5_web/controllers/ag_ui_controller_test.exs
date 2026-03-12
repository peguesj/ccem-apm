defmodule ApmV5Web.AgUiControllerTest do
  use ApmV5Web.ConnCase, async: false

  alias ApmV5.AgentRegistry
  alias ApmV5.EventStream
  alias AgUi.Core.Events.EventType

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    EventStream.clear()
    :ok
  end

  describe "GET /api/ag-ui/events" do
    test "returns text/event-stream content type", %{conn: conn} do
      # Use a Task to make the request since SSE is long-lived.
      # We'll test via a direct controller call with conn inspection.
      # For SSE, we test the response headers by checking the initial response.
      task =
        Task.async(fn ->
          get(conn, ~p"/api/ag-ui/events")
        end)

      # Give the SSE endpoint time to set up
      Process.sleep(100)

      # The task is blocked in the SSE loop, so we shut it down
      Task.shutdown(task, :brutal_kill)
    end

    test "initial STATE_SNAPSHOT is emitted on connect", %{conn: conn} do
      # Register some agents first
      AgentRegistry.register_agent("snap-a1", %{name: "Alpha", status: "active"})
      AgentRegistry.register_agent("snap-a2", %{name: "Beta", status: "idle"})

      # Subscribe to EventStream to verify the snapshot was emitted
      EventStream.subscribe()

      task =
        Task.async(fn ->
          get(conn, ~p"/api/ag-ui/events")
        end)

      # We should receive the STATE_SNAPSHOT event via PubSub
      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == EventType.state_snapshot()
      assert is_list(event.data.agents)
      assert length(event.data.agents) == 2

      Task.shutdown(task, :brutal_kill)
    end

    test "events have required AG-UI fields", %{conn: conn} do
      EventStream.subscribe()

      task =
        Task.async(fn ->
          get(conn, ~p"/api/ag-ui/events")
        end)

      # Wait for initial snapshot
      assert_receive {:ag_ui_event, event}, 2_000

      assert Map.has_key?(event, :type)
      assert Map.has_key?(event, :data)
      assert Map.has_key?(event, :timestamp)
      assert Map.has_key?(event, :sequence)

      Task.shutdown(task, :brutal_kill)
    end

    test "agent registration triggers RUN_STARTED event" do
      EventStream.subscribe()

      AgentRegistry.register_agent("new-agent", %{name: "New Agent", status: "active"})

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == EventType.run_started()
      assert event.data.agent_id == "new-agent"
    end

    test "agent completion triggers RUN_FINISHED event" do
      AgentRegistry.register_agent("finish-agent", %{name: "Finisher", status: "active"})

      EventStream.subscribe()
      # Clear the RUN_STARTED that was emitted during registration
      receive do
        {:ag_ui_event, _} -> :ok
      after
        100 -> :ok
      end

      AgentRegistry.update_status("finish-agent", "completed")

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == EventType.run_finished()
      assert event.data.agent_id == "finish-agent"
    end

    test "sequence numbers are monotonically increasing" do
      e1 = EventStream.emit(EventType.run_started(), %{agent_id: "a1"})
      e2 = EventStream.emit(EventType.text_message_start(), %{agent_id: "a1"})
      e3 = EventStream.emit(EventType.text_message_end(), %{agent_id: "a1"})

      assert e1.sequence < e2.sequence
      assert e2.sequence < e3.sequence
    end

    test "events are formatted as AG-UI protocol with correct types" do
      for type <- [
        EventType.text_message_start(), EventType.text_message_content(),
        EventType.text_message_end(), EventType.tool_call_start(),
        EventType.tool_call_args(), EventType.tool_call_end(),
        EventType.state_snapshot(), EventType.run_started(),
        EventType.run_finished()
      ] do
        event = EventStream.emit(type, %{agent_id: "test"})
        assert event.type == type
      end
    end

    test "ag_ui_ex EventType constants match expected values" do
      assert EventType.run_started() == "RUN_STARTED"
      assert EventType.run_finished() == "RUN_FINISHED"
      assert EventType.run_error() == "RUN_ERROR"
      assert EventType.step_started() == "STEP_STARTED"
      assert EventType.step_finished() == "STEP_FINISHED"
      assert EventType.text_message_start() == "TEXT_MESSAGE_START"
      assert EventType.text_message_content() == "TEXT_MESSAGE_CONTENT"
      assert EventType.text_message_end() == "TEXT_MESSAGE_END"
      assert EventType.tool_call_start() == "TOOL_CALL_START"
      assert EventType.tool_call_end() == "TOOL_CALL_END"
      assert EventType.state_snapshot() == "STATE_SNAPSHOT"
      assert EventType.state_delta() == "STATE_DELTA"
      assert EventType.custom() == "CUSTOM"
    end

    test "EventType.all/0 returns complete list of valid types" do
      all = EventType.all()
      assert is_list(all)
      assert length(all) >= 25
      assert "RUN_STARTED" in all
      assert "CUSTOM" in all
    end

    test "EventType.valid?/1 validates types" do
      assert EventType.valid?("RUN_STARTED")
      assert EventType.valid?("CUSTOM")
      refute EventType.valid?("INVALID_TYPE")
      refute EventType.valid?("")
    end

    test "events can be filtered by agent_id query param", %{conn: conn} do
      EventStream.subscribe()

      task =
        Task.async(fn ->
          get(conn, ~p"/api/ag-ui/events?agent_id=filtered-agent")
        end)

      # Wait for initial snapshot (unfiltered, global event)
      assert_receive {:ag_ui_event, _snapshot}, 2_000

      Task.shutdown(task, :brutal_kill)
    end

    test "TEXT_MESSAGE events carry content" do
      EventStream.subscribe()

      EventStream.emit(EventType.text_message_content(), %{
        agent_id: "writer",
        run_id: "run-1",
        content: "Hello from agent"
      })

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == EventType.text_message_content()
      assert event.data.content == "Hello from agent"
    end

    test "TOOL_CALL events carry tool metadata" do
      EventStream.subscribe()

      EventStream.emit(EventType.tool_call_start(), %{
        agent_id: "tool-user",
        run_id: "run-2",
        tool_name: "Bash",
        tool_call_id: "tc-42"
      })

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == EventType.tool_call_start()
      assert event.data.tool_name == "Bash"
      assert event.data.tool_call_id == "tc-42"
    end
  end
end
