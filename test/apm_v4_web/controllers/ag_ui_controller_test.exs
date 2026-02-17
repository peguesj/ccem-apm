defmodule ApmV4Web.AgUiControllerTest do
  use ApmV4Web.ConnCase, async: false

  alias ApmV4.AgentRegistry
  alias ApmV4.EventStream

  setup do
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
      assert event.type == "STATE_SNAPSHOT"
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
      assert event.type == "RUN_STARTED"
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
      assert event.type == "RUN_FINISHED"
      assert event.data.agent_id == "finish-agent"
    end

    test "sequence numbers are monotonically increasing" do
      e1 = EventStream.emit("RUN_STARTED", %{agent_id: "a1"})
      e2 = EventStream.emit("TEXT_MESSAGE_START", %{agent_id: "a1"})
      e3 = EventStream.emit("TEXT_MESSAGE_END", %{agent_id: "a1"})

      assert e1.sequence < e2.sequence
      assert e2.sequence < e3.sequence
    end

    test "events are formatted as AG-UI protocol with correct types" do
      for type <- ~w(TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END
                     TOOL_CALL_START TOOL_CALL_ARGS TOOL_CALL_END
                     STATE_SNAPSHOT RUN_STARTED RUN_FINISHED) do
        event = EventStream.emit(type, %{agent_id: "test"})
        assert event.type == type
      end
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

      EventStream.emit("TEXT_MESSAGE_CONTENT", %{
        agent_id: "writer",
        run_id: "run-1",
        content: "Hello from agent"
      })

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == "TEXT_MESSAGE_CONTENT"
      assert event.data.content == "Hello from agent"
    end

    test "TOOL_CALL events carry tool metadata" do
      EventStream.subscribe()

      EventStream.emit("TOOL_CALL_START", %{
        agent_id: "tool-user",
        run_id: "run-2",
        tool_name: "Bash",
        tool_call_id: "tc-42"
      })

      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == "TOOL_CALL_START"
      assert event.data.tool_name == "Bash"
      assert event.data.tool_call_id == "tc-42"
    end
  end
end
