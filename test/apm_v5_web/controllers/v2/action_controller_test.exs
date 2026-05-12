defmodule ApmV5Web.V2.ActionControllerTest do
  @moduledoc """
  Tests for ActionController — GET /api/v2/actions, POST /api/v2/actions/:type,
  GET /api/v2/actions/runs/:run_id, GET /api/v2/actions/runs.

  Run with: mix test --only hook_repair_v2
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :hook_repair_v2

  alias ApmV5.ActionRunStore

  setup do
    # Ensure ActionRunStore is alive
    case Process.whereis(ActionRunStore) do
      nil ->
        {:ok, _} = ActionRunStore.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  describe "GET /api/v2/actions" do
    test "returns catalog as JSON list", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/actions")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert length(body["data"]) > 0
    end

    test "catalog entries have required fields", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/actions")
      body = json_response(conn, 200)

      for entry <- body["data"] do
        assert Map.has_key?(entry, "id")
        assert Map.has_key?(entry, "name")
        assert Map.has_key?(entry, "category")
        assert Map.has_key?(entry, "icon")
        assert Map.has_key?(entry, "description")
      end
    end

    test "catalog includes repair_hooks action", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/actions")
      body = json_response(conn, 200)

      ids = Enum.map(body["data"], & &1["id"])
      assert "repair_hooks" in ids
    end
  end

  describe "POST /api/v2/actions/:type" do
    test "returns 202 with run_id for known action type", %{conn: conn} do
      # Use analyze_project which won't block long
      conn =
        post(conn, ~p"/api/v2/actions/test_noop", %{
          "project_path" => System.tmp_dir!(),
          "params" => %{}
        })

      body = json_response(conn, 202)
      assert is_binary(body["run_id"])
      assert String.starts_with?(body["run_id"], "ar_")
      assert body["status"] == "pending"
      assert is_binary(body["started_at"])
    end

    test "returns 404 for unknown action type", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/actions/not_a_real_action", %{
          "project_path" => System.tmp_dir!(),
          "params" => %{}
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "unknown_action"
    end

    test "returns 404 when action type not in catalog", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/actions/bogus_xyz", %{"project_path" => "/tmp"})
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v2/actions/runs/:run_id" do
    test "returns run map for known run_id", %{conn: conn} do
      {:ok, run_id} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})

      conn = get(conn, ~p"/api/v2/actions/runs/#{run_id}")
      body = json_response(conn, 200)

      assert body["data"]["id"] == run_id
      assert is_binary(body["data"]["status"])
    end

    test "returns 404 for unknown run_id", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/actions/runs/ar_doesnotexist")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v2/actions/runs" do
    test "returns list of runs", %{conn: conn} do
      {:ok, _} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})

      conn = get(conn, ~p"/api/v2/actions/runs")
      body = json_response(conn, 200)

      assert is_list(body["data"])
    end

    test "respects limit param", %{conn: conn} do
      for _ <- 1..5 do
        ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      end

      conn = get(conn, ~p"/api/v2/actions/runs?limit=2")
      body = json_response(conn, 200)

      assert length(body["data"]) <= 2
    end

    test "filters by action_type", %{conn: conn} do
      {:ok, _} = ActionRunStore.start_run("test_noop", System.tmp_dir!(), %{})
      {:ok, _} = ActionRunStore.start_run("test_noop_b", System.tmp_dir!(), %{})

      conn = get(conn, ~p"/api/v2/actions/runs?action_type=test_noop")
      body = json_response(conn, 200)

      for run <- body["data"] do
        assert run["action_type"] == "test_noop"
      end
    end
  end
end
