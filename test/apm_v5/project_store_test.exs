defmodule ApmV5.ProjectStoreTest do
  use ExUnit.Case, async: false

  alias ApmV5.ProjectStore

  setup do
    ProjectStore.clear_all()
    :ok
  end

  describe "tasks" do
    test "sync_tasks/2 and get_tasks/1" do
      tasks = [%{id: 1, subject: "Build feature"}, %{id: 2, subject: "Write tests"}]
      :ok = ProjectStore.sync_tasks("test-project", tasks)

      result = ProjectStore.get_tasks("test-project")
      assert length(result) == 2
      assert Enum.at(result, 0).id == 1
    end

    test "get_tasks/1 returns empty list for unknown project" do
      assert ProjectStore.get_tasks("unknown") == []
    end

    test "sync_tasks/2 replaces existing tasks" do
      ProjectStore.sync_tasks("proj", [%{id: 1}])
      ProjectStore.sync_tasks("proj", [%{id: 2}, %{id: 3}])

      result = ProjectStore.get_tasks("proj")
      assert length(result) == 2
    end
  end

  describe "commands" do
    test "register_commands/2 and get_commands/1" do
      cmds = [%{"name" => "fix", "description" => "Fix loop"}]
      :ok = ProjectStore.register_commands("proj", cmds)

      result = ProjectStore.get_commands("proj")
      assert length(result) == 1
      assert hd(result)["name"] == "fix"
    end

    test "get_commands/1 returns empty list for unknown project" do
      assert ProjectStore.get_commands("unknown") == []
    end

    test "register_commands/2 merges by name" do
      ProjectStore.register_commands("proj", [%{"name" => "fix", "description" => "v1"}])
      ProjectStore.register_commands("proj", [%{"name" => "fix", "description" => "v2"}])

      result = ProjectStore.get_commands("proj")
      assert length(result) == 1
      assert hd(result)["description"] == "v2"
    end
  end

  describe "plane" do
    test "update_plane/2 and get_plane/1" do
      :ok = ProjectStore.update_plane("proj", %{workspace: "my-ws", project_id: "123"})

      result = ProjectStore.get_plane("proj")
      assert result.workspace == "my-ws"
    end

    test "get_plane/1 returns empty map for unknown project" do
      assert ProjectStore.get_plane("unknown") == %{}
    end
  end

  describe "input requests" do
    test "add_input_request/1 returns incrementing IDs" do
      id1 = ProjectStore.add_input_request(%{"prompt" => "Choose option", "options" => ["a", "b"]})
      id2 = ProjectStore.add_input_request(%{"prompt" => "Pick color", "options" => ["red", "blue"]})

      assert id1 == 1
      assert id2 == 2
    end

    test "get_pending_inputs/0 returns unresponded requests" do
      ProjectStore.add_input_request(%{"prompt" => "Q1", "options" => ["a"]})
      ProjectStore.add_input_request(%{"prompt" => "Q2", "options" => ["b"]})

      pending = ProjectStore.get_pending_inputs()
      assert length(pending) == 2
    end

    test "respond_to_input/2 marks input as responded" do
      id = ProjectStore.add_input_request(%{"prompt" => "Q1", "options" => ["a", "b"]})
      :ok = ProjectStore.respond_to_input(id, "a")

      pending = ProjectStore.get_pending_inputs()
      assert length(pending) == 0
    end

    test "respond_to_input/2 returns error for unknown id" do
      assert {:error, :not_found} = ProjectStore.respond_to_input(999, "x")
    end
  end
end
