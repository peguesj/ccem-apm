defmodule ApmV5.AgentActivityLogTest do
  use ExUnit.Case, async: false

  alias ApmV5.AgentActivityLog

  setup do
    # Ensure PubSub is running
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    # Ensure EventBus is running (AgentActivityLog subscribes on init)
    case Process.whereis(ApmV5.AgUi.EventBus) do
      nil ->
        case ApmV5.AgUi.EventBus.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid -> :ok
    end

    # Ensure AgentActivityLog is running
    case Process.whereis(AgentActivityLog) do
      nil ->
        {:ok, _pid} = AgentActivityLog.start_link([])
      _pid ->
        :ok
    end

    # Clear entries between tests
    AgentActivityLog.clear()
    :ok
  end

  defp inject_entry(agent_id, event_type, data \\ %{}) do
    # Simulate an EventBus event arriving via handle_info
    event = %{type: event_type, data: Map.put(data, "agent_id", agent_id)}
    send(Process.whereis(AgentActivityLog), {:event_bus, "lifecycle:*", event})
    # Give GenServer time to process the message
    Process.sleep(5)
  end

  describe "list_recent/1" do
    test "returns empty list initially" do
      assert AgentActivityLog.list_recent() == []
    end

    test "returns most recent entries first (newest first)" do
      inject_entry("a1", "RUN_STARTED")
      inject_entry("a1", "TOOL_CALL_START", %{"tool_name" => "Bash"})
      inject_entry("a1", "TOOL_CALL_END", %{"tool_name" => "Bash"})

      entries = AgentActivityLog.list_recent()
      assert length(entries) == 3

      types = Enum.map(entries, & &1.event_type)
      assert types == ["TOOL_CALL_END", "TOOL_CALL_START", "RUN_STARTED"]
    end

    test "respects limit parameter" do
      for _ <- 1..10 do
        inject_entry("a1", "RUN_STARTED")
      end

      entries = AgentActivityLog.list_recent(3)
      assert length(entries) == 3
    end

    test "default limit is 50" do
      for _ <- 1..60 do
        inject_entry("a1", "RUN_STARTED")
      end

      entries = AgentActivityLog.list_recent()
      assert length(entries) == 50
    end
  end

  describe "get_agent_log/2" do
    test "filters entries by agent_id" do
      inject_entry("a1", "RUN_STARTED")
      inject_entry("a2", "RUN_STARTED")
      inject_entry("a1", "TOOL_CALL_START", %{"tool_name" => "Bash"})
      inject_entry("a2", "TOOL_CALL_START", %{"tool_name" => "Read"})
      inject_entry("a1", "RUN_FINISHED")

      a1_log = AgentActivityLog.get_agent_log("a1")
      a2_log = AgentActivityLog.get_agent_log("a2")

      assert length(a1_log) == 3
      assert length(a2_log) == 2
      assert Enum.all?(a1_log, &(&1.agent_id == "a1"))
      assert Enum.all?(a2_log, &(&1.agent_id == "a2"))
    end

    test "respects limit parameter" do
      for _ <- 1..10 do
        inject_entry("a1", "RUN_STARTED")
      end

      log = AgentActivityLog.get_agent_log("a1", 3)
      assert length(log) == 3
    end

    test "returns empty list for unknown agent" do
      assert AgentActivityLog.get_agent_log("nonexistent") == []
    end
  end

  describe "clear/0" do
    test "empties the log" do
      inject_entry("a1", "RUN_STARTED")
      inject_entry("a2", "RUN_STARTED")

      assert length(AgentActivityLog.list_recent()) == 2

      assert :ok = AgentActivityLog.clear()
      assert AgentActivityLog.list_recent() == []
    end
  end

  describe "ring buffer truncation" do
    test "truncates at max 200 entries" do
      for i <- 1..210 do
        inject_entry("a1", "RUN_STARTED", %{"iteration" => i})
      end

      entries = AgentActivityLog.list_recent(300)
      assert length(entries) == 200
    end
  end

  describe "entry structure" do
    test "entries contain expected fields" do
      inject_entry("a1", "TOOL_CALL_START", %{"tool_name" => "Bash"})

      [entry] = AgentActivityLog.list_recent(1)

      assert is_binary(entry.id)
      assert entry.agent_id == "a1"
      assert entry.event_type == "TOOL_CALL_START"
      assert is_binary(entry.description)
      assert is_binary(entry.timestamp)
      assert is_map(entry.metadata)
    end

    test "TOOL_CALL_START description includes tool name" do
      inject_entry("a1", "TOOL_CALL_START", %{"tool_name" => "Bash"})
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.description =~ "Bash"
    end

    test "TOOL_CALL_END description includes tool name" do
      inject_entry("a1", "TOOL_CALL_END", %{"tool_name" => "Read"})
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.description =~ "Read"
    end

    test "RUN_STARTED description" do
      inject_entry("a1", "RUN_STARTED")
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.description == "Agent started"
    end

    test "RUN_FINISHED description" do
      inject_entry("a1", "RUN_FINISHED")
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.description == "Agent finished"
    end

    test "THINKING_START description" do
      inject_entry("a1", "THINKING_START")
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.description == "Thinking..."
    end

    test "metadata includes tool_name for tool events" do
      inject_entry("a1", "TOOL_CALL_START", %{"tool_name" => "Grep"})
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.metadata.tool_name == "Grep"
    end

    test "metadata includes step_name for step events" do
      inject_entry("a1", "STEP_STARTED", %{"step_name" => "compile"})
      [entry] = AgentActivityLog.list_recent(1)
      assert entry.metadata.step_name == "compile"
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts activity log entry on new event" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:activity_log")

      inject_entry("a1", "RUN_STARTED")

      assert_receive {:activity_log_entry, entry}
      assert entry.agent_id == "a1"
      assert entry.event_type == "RUN_STARTED"
    end
  end
end
