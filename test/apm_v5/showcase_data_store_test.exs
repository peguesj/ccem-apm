defmodule ApmV5.ShowcaseDataStoreTest do
  use ExUnit.Case, async: false

  alias ApmV5.ShowcaseDataStore

  setup do
    # Ensure PubSub is running
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    # Ensure ConfigLoader is running (ShowcaseDataStore.resolve_showcase_path uses it)
    case Process.whereis(ApmV5.ConfigLoader) do
      nil ->
        case ApmV5.ConfigLoader.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid -> :ok
    end

    # Ensure ShowcaseDataStore is running
    case Process.whereis(ShowcaseDataStore) do
      nil ->
        {:ok, _pid} = ShowcaseDataStore.start_link([])
      _pid ->
        :ok
    end

    :ok
  end

  describe "get_showcase_data/1" do
    test "returns map with expected keys for ccem project" do
      data = ShowcaseDataStore.get_showcase_data("ccem")

      assert is_map(data)
      assert Map.has_key?(data, "features")
      assert Map.has_key?(data, "narratives")
      assert Map.has_key?(data, "design_system")
      assert Map.has_key?(data, "redaction_rules")
      assert Map.has_key?(data, "speaker_notes")
      assert Map.has_key?(data, "slides")
      assert Map.has_key?(data, "version")
      assert Map.has_key?(data, "path")
    end

    test "returns features list for ccem project" do
      data = ShowcaseDataStore.get_showcase_data("ccem")
      features = data["features"]
      assert is_list(features)
      assert length(features) > 0
    end

    test "returns data for nil project (defaults to ccem)" do
      data = ShowcaseDataStore.get_showcase_data(nil)
      assert is_map(data)
      assert Map.has_key?(data, "features")
    end

    test "returns fallback data for unknown project" do
      data = ShowcaseDataStore.get_showcase_data("nonexistent-project-xyz")

      assert is_map(data)
      # Should still have the expected structure even if all values are defaults
      assert Map.has_key?(data, "features")
      assert Map.has_key?(data, "version")
    end

    test "caches data on subsequent calls" do
      # First call loads from disk
      data1 = ShowcaseDataStore.get_showcase_data("ccem")
      # Second call should return cached version
      data2 = ShowcaseDataStore.get_showcase_data("ccem")

      assert data1 == data2
    end
  end

  describe "get_features/1" do
    test "returns feature list for ccem" do
      features = ShowcaseDataStore.get_features("ccem")
      assert is_list(features)
      assert length(features) > 0
    end

    test "returns list for unknown project" do
      features = ShowcaseDataStore.get_features("nonexistent-project-xyz")
      # Should return default features or empty list depending on load path
      assert is_list(features)
    end

    test "returns features for nil project" do
      features = ShowcaseDataStore.get_features(nil)
      assert is_list(features)
    end
  end

  describe "reload/1" do
    test "reloads data from disk and returns :ok" do
      assert :ok = ShowcaseDataStore.reload("ccem")
    end

    test "reloads default ccem when called with nil" do
      assert :ok = ShowcaseDataStore.reload(nil)
    end

    test "broadcasts PubSub event on reload" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:showcase")

      ShowcaseDataStore.reload("ccem")

      assert_receive {:showcase_data_reloaded, "ccem", data}
      assert is_map(data)
    end
  end

  describe "has_showcase?/1" do
    test "returns true for ccem project by name" do
      assert ShowcaseDataStore.has_showcase?(%{"name" => "ccem"})
    end

    test "returns true for CCEM APM project by name" do
      assert ShowcaseDataStore.has_showcase?(%{"name" => "CCEM APM"})
    end

    test "returns false for project with no showcase markers" do
      refute ShowcaseDataStore.has_showcase?(%{"name" => "random-project"})
    end

    test "returns true for project with valid showcase_data_path" do
      assert ShowcaseDataStore.has_showcase?(%{
               "showcase_data_path" => "~/Developer/ccem/showcase/data"
             })
    end

    test "returns false for project with nonexistent showcase_data_path" do
      refute ShowcaseDataStore.has_showcase?(%{
               "showcase_data_path" => "/nonexistent/path/showcase/data"
             })
    end

    test "returns true for project_root with showcase/data dir" do
      assert ShowcaseDataStore.has_showcase?(%{
               "project_root" => "~/Developer/ccem"
             })
    end

    test "returns false for empty map" do
      refute ShowcaseDataStore.has_showcase?(%{})
    end

    test "returns false for nil" do
      refute ShowcaseDataStore.has_showcase?(nil)
    end
  end

  describe "filter_showcase_projects/1" do
    test "filters to projects with showcase data" do
      projects = [
        %{"name" => "ccem"},
        %{"name" => "no-showcase-project"},
        %{"name" => "also-no-showcase"}
      ]

      filtered = ShowcaseDataStore.filter_showcase_projects(projects)
      names = Enum.map(filtered, & &1["name"])
      assert "ccem" in names
    end

    test "always includes ccem project when present in list" do
      projects = [
        %{"name" => "ccem"},
        %{"name" => "other-project"}
      ]

      filtered = ShowcaseDataStore.filter_showcase_projects(projects)
      assert Enum.any?(filtered, &(&1["name"] == "ccem"))
    end

    test "returns all projects as graceful degradation when no showcase projects found" do
      projects = [
        %{"name" => "no-showcase-1"},
        %{"name" => "no-showcase-2"}
      ]

      filtered = ShowcaseDataStore.filter_showcase_projects(projects)
      # When nothing passes, returns all as fallback
      assert length(filtered) == 2
    end

    test "handles empty list" do
      assert ShowcaseDataStore.filter_showcase_projects([]) == []
    end
  end
end
