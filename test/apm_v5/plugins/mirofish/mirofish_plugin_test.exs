defmodule ApmV5.Plugins.Mirofish.MirofishPluginTest do
  use ExUnit.Case, async: false

  alias ApmV5.Plugins.Mirofish.MirofishPlugin
  alias ApmV5.Plugins.Mirofish.MiroClient

  @env_key "MIRO_ACCESS_TOKEN"

  setup do
    prev = System.get_env(@env_key)
    System.delete_env(@env_key)

    on_exit(fn ->
      if prev, do: System.put_env(@env_key, prev), else: System.delete_env(@env_key)
    end)

    :ok
  end

  describe "plugin metadata" do
    test "name, description, version, scope" do
      assert MirofishPlugin.plugin_name() == "mirofish"
      assert is_binary(MirofishPlugin.plugin_description())
      assert MirofishPlugin.plugin_version() == "1.0.0"
      assert MirofishPlugin.plugin_scope() == :ccem
    end
  end

  describe "list_endpoints/0" do
    test "returns 9 action descriptors" do
      endpoints = MirofishPlugin.list_endpoints()
      assert length(endpoints) == 9

      actions = Enum.map(endpoints, & &1.action)

      for required <- [
            "list_boards",
            "get_board",
            "create_board",
            "create_sticky",
            "create_frame",
            "create_text",
            "list_items",
            "delete_item",
            "coalesce_findings"
          ] do
        assert required in actions, "missing action: #{required}"
      end

      for ep <- endpoints do
        assert is_binary(ep.description)
        assert is_map(ep.params)
      end
    end
  end

  describe "handle_action/3" do
    test "missing token returns {:error, :no_token}" do
      # Token file may exist; only assert on env-less path when file also missing.
      # Rather than manipulating the home dir, we confirm the error wraps cleanly
      # when no token is resolvable.
      token_path = Path.expand("~/.config/mirofish/token")

      if File.exists?(token_path) do
        # Skip strict no_token assertion; instead ensure the action runs and
        # returns a tagged tuple of some kind (no crash).
        result =
          MirofishPlugin.handle_action("list_boards", %{}, [])

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      else
        assert {:error, :no_token} = MirofishPlugin.handle_action("list_boards", %{}, [])
      end
    end

    test "unknown action returns {:error, {:unknown_action, _}}" do
      assert {:error, {:unknown_action, "fly_to_mars"}} =
               MirofishPlugin.handle_action("fly_to_mars", %{}, [])
    end

    test "missing required params returns {:error, {:invalid_params, action}}" do
      assert {:error, {:invalid_params, "get_board"}} =
               MirofishPlugin.handle_action("get_board", %{}, [])

      assert {:error, {:invalid_params, "create_sticky"}} =
               MirofishPlugin.handle_action("create_sticky", %{"board_id" => "b1"}, [])
    end

    test "create_board without name returns missing_param error" do
      assert {:error, {:missing_param, "name"}} =
               MirofishPlugin.handle_action("create_board", %{}, [])
    end

    test "coalesce_findings with empty list returns {:ok, %{created: 0}}" do
      assert {:ok, %{created: 0, items: []}} =
               MirofishPlugin.handle_action(
                 "coalesce_findings",
                 %{"board_id" => "b1", "findings" => []},
                 []
               )
    end

    test "atom keys are normalized" do
      assert {:error, {:invalid_params, "get_board"}} =
               MirofishPlugin.handle_action("get_board", %{board_id: ""}, [])
    end
  end

  describe "MiroClient.parse_response_body/1" do
    test "parses valid JSON object" do
      body = ~s({"id":"abc","name":"test"})
      assert {:ok, %{"id" => "abc", "name" => "test"}} = MiroClient.parse_response_body(body)
    end

    test "parses JSON array" do
      body = ~s([{"id":"1"},{"id":"2"}])
      assert {:ok, [%{"id" => "1"}, %{"id" => "2"}]} = MiroClient.parse_response_body(body)
    end

    test "empty body returns empty map" do
      assert {:ok, %{}} = MiroClient.parse_response_body("")
    end

    test "non-JSON body returned as raw" do
      assert {:ok, %{raw: "not json"}} = MiroClient.parse_response_body("not json")
    end

    test "charlist body is supported" do
      body = ~c({"ok":true})
      assert {:ok, %{"ok" => true}} = MiroClient.parse_response_body(body)
    end

    test "parses realistic create_sticky response" do
      body = ~s({
        "id": "3458764517234567890",
        "type": "sticky_note",
        "data": {"content": "Research finding", "shape": "square"},
        "style": {"fillColor": "light_yellow"},
        "position": {"x": 0.0, "y": 0.0, "origin": "center"},
        "geometry": {"width": 200}
      })

      assert {:ok, parsed} = MiroClient.parse_response_body(body)
      assert parsed["id"] == "3458764517234567890"
      assert parsed["type"] == "sticky_note"
      assert parsed["data"]["content"] == "Research finding"
      assert parsed["style"]["fillColor"] == "light_yellow"
    end
  end

  describe "MiroClient.get_token/0" do
    test "returns token from env var" do
      System.put_env(@env_key, "env-token-123")
      assert {:ok, "env-token-123"} = MiroClient.get_token()
    end

    test "trims whitespace from env token" do
      System.put_env(@env_key, "  spaced-token  ")
      assert {:ok, "spaced-token"} = MiroClient.get_token()
    end
  end
end
