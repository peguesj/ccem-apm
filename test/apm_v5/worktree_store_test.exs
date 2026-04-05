defmodule ApmV5.WorktreeStoreTest do
  use ExUnit.Case, async: false

  alias ApmV5.WorktreeStore

  setup do
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    case Process.whereis(WorktreeStore) do
      nil -> {:ok, _pid} = WorktreeStore.start_link([])
      _pid -> :ok
    end

    # Clear state between tests
    :ets.delete_all_objects(:worktree_store)
    :ok
  end

  describe "register/1" do
    test "registers a new worktree with required fields" do
      assert {:ok, metadata} =
               WorktreeStore.register(%{
                 branch: "feature/foo",
                 path: "/tmp/wt-foo",
                 project: "apm-v4"
               })

      assert is_binary(metadata.worktree_id)
      assert metadata.branch == "feature/foo"
      assert metadata.path == "/tmp/wt-foo"
      assert metadata.base_branch == "main"
      assert metadata.status == :active
      assert is_binary(metadata.created_at)
    end

    test "returns error when branch is missing" do
      assert {:error, :missing_branch} = WorktreeStore.register(%{path: "/tmp/wt"})
    end

    test "returns error when path is missing" do
      assert {:error, :missing_path} = WorktreeStore.register(%{branch: "x"})
    end

    test "broadcasts :registered event on apm:worktrees topic" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:worktrees")
      {:ok, _} = WorktreeStore.register(%{branch: "b", path: "/tmp/x"})
      assert_receive {:worktree_event, :registered, _metadata}, 500
    end
  end

  describe "list/0 and list_by_project/1" do
    test "list returns all registered worktrees" do
      {:ok, _} = WorktreeStore.register(%{branch: "a", path: "/tmp/a", project: "p1"})
      {:ok, _} = WorktreeStore.register(%{branch: "b", path: "/tmp/b", project: "p2"})
      assert length(WorktreeStore.list()) == 2
    end

    test "list_by_project filters correctly" do
      {:ok, _} = WorktreeStore.register(%{branch: "a", path: "/tmp/a", project: "p1"})
      {:ok, _} = WorktreeStore.register(%{branch: "b", path: "/tmp/b", project: "p2"})
      assert length(WorktreeStore.list_by_project("p1")) == 1
    end
  end

  describe "get/1, update/2, prune/1" do
    test "get returns metadata by id" do
      {:ok, m} = WorktreeStore.register(%{branch: "x", path: "/tmp/x"})
      assert {:ok, fetched} = WorktreeStore.get(m.worktree_id)
      assert fetched.worktree_id == m.worktree_id
    end

    test "get returns :not_found for missing id" do
      assert {:error, :not_found} = WorktreeStore.get("nope")
    end

    test "update merges attrs and broadcasts" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:worktrees")
      {:ok, m} = WorktreeStore.register(%{branch: "x", path: "/tmp/x"})
      assert {:ok, updated} = WorktreeStore.update(m.worktree_id, %{status: :archived})
      assert updated.status == :archived
      assert_receive {:worktree_event, :updated, _}, 500
    end

    test "prune removes worktree and broadcasts" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:worktrees")
      {:ok, m} = WorktreeStore.register(%{branch: "x", path: "/tmp/x"})
      assert :ok = WorktreeStore.prune(m.worktree_id)
      assert {:error, :not_found} = WorktreeStore.get(m.worktree_id)
      assert_receive {:worktree_event, :pruned, _}, 500
    end
  end
end
