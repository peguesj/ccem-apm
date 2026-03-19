defmodule ApmV5.ActionEngineTest do
  use ExUnit.Case, async: false

  alias ApmV5.ActionEngine

  # ── list_catalog/0 ──────────────────────────────────────────────────────────

  test "list_catalog/0 returns a non-empty list" do
    catalog = ActionEngine.list_catalog()
    assert is_list(catalog)
    assert length(catalog) > 0
  end

  test "list_catalog/0 each entry has required fields" do
    for entry <- ActionEngine.list_catalog() do
      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :name)
      assert Map.has_key?(entry, :description)
      assert Map.has_key?(entry, :category)
      assert is_binary(entry.id)
      assert is_binary(entry.name)
    end
  end

  test "list_catalog/0 includes the core actions" do
    ids = ActionEngine.list_catalog() |> Enum.map(& &1.id)
    assert "deploy_apm_hooks" in ids
    assert "add_memory_pointer" in ids
    assert "backfill_apm_config" in ids
    assert "analyze_project" in ids
  end

  test "list_catalog/0 includes port-management actions" do
    ids = ActionEngine.list_catalog() |> Enum.map(& &1.id)
    assert "register_all_ports" in ids
    assert "analyze_port_assignment" in ids
    assert "smart_reassign_ports" in ids
  end

  # ── run/2 ── run_action/2-3 ─────────────────────────────────────────────────

  test "run_action/3 returns {:ok, run_id} for a known action" do
    dir = System.tmp_dir!()
    assert {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    assert is_binary(run_id)
    assert byte_size(run_id) > 0
  end

  test "run_action/3 returns {:error, :unknown_action} for unknown action" do
    assert {:error, :unknown_action} =
             ActionEngine.run_action("not_a_real_action", System.tmp_dir!())
  end

  test "run_action/3 accepts optional params map" do
    dir = System.tmp_dir!()
    assert {:ok, _run_id} = ActionEngine.run_action("analyze_project", dir, %{})
  end

  test "run_action/3 analyze_project completes asynchronously" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    # Poll for completion (async task)
    result =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        case ActionEngine.get_run(run_id) do
          {:ok, %{status: "completed"} = run} -> {:halt, run}
          {:ok, %{status: "failed"} = run} -> {:halt, run}
          _ ->
            Process.sleep(100)
            {:cont, nil}
        end
      end)

    assert result != nil
    assert result.status in ["completed", "failed"]
  end

  # ── get_run/1 ───────────────────────────────────────────────────────────────

  test "get_run/1 returns {:error, :not_found} for unknown run_id" do
    assert {:error, :not_found} = ActionEngine.get_run("no-such-run-id")
  end

  test "get_run/1 returns {:ok, run} for a known run_id" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    assert {:ok, run} = ActionEngine.get_run(run_id)
    assert run.id == run_id
    assert run.action_type == "analyze_project"
    assert is_binary(run.started_at)
  end

  test "get_run/1 run has expected fields" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    {:ok, run} = ActionEngine.get_run(run_id)
    assert Map.has_key?(run, :id)
    assert Map.has_key?(run, :action_type)
    assert Map.has_key?(run, :project_path)
    assert Map.has_key?(run, :status)
    assert Map.has_key?(run, :started_at)
    assert run.project_path == dir
  end

  # ── list_runs/0 ─────────────────────────────────────────────────────────────

  test "list_runs/0 returns a list" do
    runs = ActionEngine.list_runs()
    assert is_list(runs)
  end

  test "list_runs/0 returns runs in descending order by started_at" do
    dir = System.tmp_dir!()
    {:ok, _} = ActionEngine.run_action("analyze_project", dir)
    Process.sleep(5)
    {:ok, _} = ActionEngine.run_action("analyze_project", dir)

    runs = ActionEngine.list_runs()
    timestamps = Enum.map(runs, & &1.started_at)
    assert timestamps == Enum.sort(timestamps, :desc)
  end

  test "list_runs/0 includes a run after run_action is called" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    ids = ActionEngine.list_runs() |> Enum.map(& &1.id)
    assert run_id in ids
  end

  # ── ETS cap / TTL pruning ───────────────────────────────────────────────────

  test "prune_runs handle_info does not crash the server" do
    pid = Process.whereis(ActionEngine)
    assert is_pid(pid)
    # Send prune message directly — should not crash
    send(pid, :prune_runs)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "prune_runs preserves recent runs" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)
    pid = Process.whereis(ActionEngine)
    send(pid, :prune_runs)
    Process.sleep(50)
    # Recent run should still be there
    ids = ActionEngine.list_runs() |> Enum.map(& &1.id)
    assert run_id in ids
  end

  # ── ETS / state integration ──────────────────────────────────────────────────

  test "multiple concurrent run_action calls all succeed" do
    dir = System.tmp_dir!()
    results =
      1..5
      |> Enum.map(fn _ ->
        Task.async(fn -> ActionEngine.run_action("analyze_project", dir) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    run_ids = Enum.map(results, fn {:ok, id} -> id end)
    assert length(Enum.uniq(run_ids)) == 5
  end

  test "run_action result is stored and retrievable after async completion" do
    dir = System.tmp_dir!()
    {:ok, run_id} = ActionEngine.run_action("analyze_project", dir)

    # Wait for async completion
    Enum.reduce_while(1..30, nil, fn _, _ ->
      case ActionEngine.get_run(run_id) do
        {:ok, %{status: s}} when s in ["completed", "failed"] -> {:halt, :done}
        _ ->
          Process.sleep(100)
          {:cont, nil}
      end
    end)

    {:ok, run} = ActionEngine.get_run(run_id)
    assert run.completed_at != nil
    assert run.status in ["completed", "failed"]
  end
end
