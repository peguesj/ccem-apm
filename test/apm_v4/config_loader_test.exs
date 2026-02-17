defmodule ApmV4.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias ApmV4.ConfigLoader

  describe "get_config/0" do
    test "returns a map with version field" do
      config = ConfigLoader.get_config()
      assert is_map(config)
      assert Map.has_key?(config, "version")
    end

    test "returns projects as a list" do
      config = ConfigLoader.get_config()
      assert is_list(config["projects"])
    end

    test "returns active_project field" do
      config = ConfigLoader.get_config()
      assert Map.has_key?(config, "active_project")
    end
  end

  describe "get_project/1" do
    test "returns nil for unknown project" do
      assert ConfigLoader.get_project("nonexistent-project-xyz") == nil
    end

    test "returns project map for known project" do
      config = ConfigLoader.get_config()
      projects = config["projects"] || []

      if length(projects) > 0 do
        name = hd(projects)["name"]
        project = ConfigLoader.get_project(name)
        assert project["name"] == name
      end
    end
  end

  describe "get_active_project/0" do
    test "returns a project map or nil" do
      result = ConfigLoader.get_active_project()
      assert is_nil(result) or is_map(result)
    end
  end

  describe "reload/0" do
    test "returns :ok" do
      assert :ok = ConfigLoader.reload()
    end

    test "broadcasts config change via PubSub" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:config")
      :ok = ConfigLoader.reload()
      assert_receive {:config_reloaded, config} when is_map(config), 1000
    end
  end
end
