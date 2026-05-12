defmodule ApmV5.ActionRunStoreTest do
  @moduledoc """
  Tests for ActionRunStore GenServer (ETS-backed async run tracking).

  Run with: mix test --only hook_repair_v2
  """

  use ExUnit.Case, async: false

  @moduletag :hook_repair_v2

  alias ApmV5.ActionRunStore

  setup do
    case Process.whereis(ActionRunStore) do
      nil ->
        {:ok, _} = ActionRunStore.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  describe "start_run/3" do
    test "returns {:ok, run_id} with ar_ prefix for known action" do
      assert {:ok, run_id} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      assert is_binary(run_id)
      assert String.starts_with?(run_id, "ar_")
    end

    test "returns {:error, :unknown_action} for unknown action type" do
      assert {:error, :unknown_action} =
               ActionRunStore.start_run("not_real_xxxx", System.tmp_dir!(), %{})
    end

    test "run_id is unique across calls" do
      {:ok, id1} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      {:ok, id2} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      assert id1 != id2
    end

    test "a second test noop type also starts" do
      {:ok, id} = ActionRunStore.start_run("test_noop_b", System.tmp_dir!(), %{})
      assert String.starts_with?(id, "ar_")
    end
  end

  describe "get_run/1" do
    test "returns {:ok, map} for valid run_id" do
      {:ok, run_id} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})

      assert {:ok, run} = ActionRunStore.get_run(run_id)
      assert run.id == run_id
      assert run.action_type == "test_noop"
      assert run.status in ["pending", "running", "success", "error"]
    end

    test "returns {:error, :not_found} for bogus id" do
      assert {:error, :not_found} = ActionRunStore.get_run("ar_doesnotexist000000")
    end

    test "returns {:error, :not_found} for empty string" do
      assert {:error, :not_found} = ActionRunStore.get_run("")
    end
  end

  describe "list_runs/1" do
    test "returns list" do
      ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      runs = ActionRunStore.list_runs()
      assert is_list(runs)
      assert length(runs) >= 1
    end

    test "respects limit option" do
      for _ <- 1..10 do
        ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      end

      runs = ActionRunStore.list_runs(limit: 3)
      assert length(runs) <= 3
    end

    test "filters by action_type" do
      ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      ActionRunStore.start_run("test_noop_b", System.tmp_dir!(), %{})

      runs = ActionRunStore.list_runs(action_type: "test_noop")
      assert Enum.all?(runs, &(&1.action_type == "test_noop"))
    end

    test "returns desc by started_at" do
      {:ok, id1} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      # tiny sleep to ensure distinct started_at
      Process.sleep(2)
      {:ok, id2} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})

      runs = ActionRunStore.list_runs(action_type: "test_noop", limit: 10)
      ids = Enum.map(runs, & &1.id)

      # id2 should appear before id1 (desc)
      assert Enum.find_index(ids, &(&1 == id2)) <= Enum.find_index(ids, &(&1 == id1))
    end
  end

  describe "async execution" do
    test "run transitions to success or error within 2s" do
      {:ok, run_id} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})

      # Poll up to 2s
      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          Process.sleep(100)
          {:ok, run} = ActionRunStore.get_run(run_id)

          if run.status in ["success", "error"] do
            {:halt, run}
          else
            {:cont, nil}
          end
        end)

      assert result != nil
      assert result.status in ["success", "error"]
    end
  end
end
