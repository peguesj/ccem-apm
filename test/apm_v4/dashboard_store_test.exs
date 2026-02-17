defmodule ApmV4.DashboardStoreTest do
  use ExUnit.Case, async: false

  alias ApmV4.DashboardStore

  setup do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "dashboard_store_test_#{:erlang.unique_integer([:positive])}"
      )

    File.rm_rf!(test_dir)
    File.mkdir_p!(test_dir)

    # Use a unique name to avoid conflict with the app's global instance
    name = :"dashboard_store_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({DashboardStore, storage_dir: test_dir, name: name})

    on_exit(fn -> File.rm_rf!(test_dir) end)
    %{name: name, test_dir: test_dir}
  end

  describe "layouts" do
    test "save_layout/2 and load_layout/1 roundtrip", %{name: name} do
      panels = [%{"id" => "p1", "type" => "stats", "position" => %{"x" => 0, "y" => 0}}]
      {:ok, layout} = GenServer.call(name, {:save_layout, "My Layout", panels})

      assert layout["name"] == "My Layout"
      assert layout["panels"] == panels
      assert layout["id"]

      loaded = GenServer.call(name, {:load_layout, layout["id"]})
      assert loaded["name"] == "My Layout"
      assert loaded["panels"] == panels
    end

    test "list_layouts/0 returns saved layouts", %{name: name} do
      {:ok, _} = GenServer.call(name, {:save_layout, "L1", []})
      {:ok, _} = GenServer.call(name, {:save_layout, "L2", []})

      layouts = GenServer.call(name, :list_layouts)
      names = Enum.map(layouts, & &1["name"])
      assert "L1" in names
      assert "L2" in names
    end

    test "delete_layout/1 removes layout", %{name: name} do
      {:ok, layout} = GenServer.call(name, {:save_layout, "To Delete", []})
      assert GenServer.call(name, {:load_layout, layout["id"]}) != nil

      :ok = GenServer.call(name, {:delete_layout, layout["id"]})
      assert GenServer.call(name, {:load_layout, layout["id"]}) == nil
    end
  end

  describe "filter presets" do
    test "save_preset/2 and load_preset/1 roundtrip", %{name: name} do
      filters = %{"status" => ["active"], "project" => "myproj"}
      {:ok, preset} = GenServer.call(name, {:save_preset, "Active Only", filters})

      loaded = GenServer.call(name, {:load_preset, preset["id"]})
      assert loaded["name"] == "Active Only"
      assert loaded["filters"] == filters
    end
  end

  describe "custom views" do
    test "save_view/2 and load_view/1 roundtrip", %{name: name} do
      config = %{"type" => "graph", "columns" => ["name", "status"], "sort_by" => "name"}
      {:ok, view} = GenServer.call(name, {:save_view, "Graph View", config})

      loaded = GenServer.call(name, {:load_view, view["id"]})
      assert loaded["name"] == "Graph View"
      assert loaded["type"] == "graph"
      assert loaded["columns"] == ["name", "status"]
    end
  end

  describe "layout history" do
    test "push_history/2 and undo_layout/1", %{name: name} do
      panels_v1 = [%{"id" => "p1"}]
      panels_v2 = [%{"id" => "p1"}, %{"id" => "p2"}]

      :ok = GenServer.call(name, {:push_history, "layout_1", panels_v1})
      :ok = GenServer.call(name, {:push_history, "layout_1", panels_v2})

      {:ok, restored} = GenServer.call(name, {:undo_layout, "layout_1"})
      assert restored == panels_v2

      {:ok, restored2} = GenServer.call(name, {:undo_layout, "layout_1"})
      assert restored2 == panels_v1

      assert :empty == GenServer.call(name, {:undo_layout, "layout_1"})
    end

    test "history capped at 20 entries", %{name: name} do
      for i <- 1..25 do
        :ok = GenServer.call(name, {:push_history, "cap_test", [%{"v" => i}]})
      end

      results =
        Stream.repeatedly(fn -> GenServer.call(name, {:undo_layout, "cap_test"}) end)
        |> Enum.take_while(fn r -> r != :empty end)

      assert length(results) == 20
    end
  end

  describe "persistence" do
    test "atomic write safety - file exists after save", %{name: name, test_dir: test_dir} do
      {:ok, _} = GenServer.call(name, {:save_layout, "Persisted", []})
      assert File.exists?(Path.join(test_dir, "layouts.json"))
    end
  end
end
