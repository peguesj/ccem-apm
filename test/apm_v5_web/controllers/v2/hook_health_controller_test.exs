defmodule ApmV5Web.V2.HookHealthControllerTest do
  @moduledoc """
  Tests for HookHealthController endpoints.

  Run with: mix test --only hook_repair_v2
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :hook_repair_v2

  alias ApmV5.HookHealthMonitor

  setup do
    # Ensure monitor is running
    case Process.whereis(HookHealthMonitor) do
      nil -> {:ok, _} = HookHealthMonitor.start_link([])
      _ -> :ok
    end

    root = Path.join(System.tmp_dir!(), "hhc_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:apm_v5, :hook_health_root, root)

    on_exit(fn ->
      Application.delete_env(:apm_v5, :hook_health_root)
      File.rm_rf!(root)
    end)

    {:ok, dev_root: root}
  end

  describe "GET /api/v2/hooks/health" do
    test "returns JSON with healthy/unhealthy/projects keys", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/hooks/health")
      body = json_response(conn, 200)

      assert Map.has_key?(body["data"], "healthy")
      assert Map.has_key?(body["data"], "unhealthy")
      assert Map.has_key?(body["data"], "projects")
      assert is_integer(body["data"]["healthy"])
      assert is_integer(body["data"]["unhealthy"])
      assert is_list(body["data"]["projects"])
    end
  end

  describe "POST /api/v2/hooks/scan" do
    test "returns ok: true and queued_at", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/hooks/scan", %{})
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert is_binary(body["queued_at"])
    end
  end

  describe "POST /api/v2/hooks/clear/:project" do
    test "returns 200 and rotates when project is healthy", %{conn: conn, dev_root: root} do
      # Set up a healthy project
      proj_path = Path.join(root, "myproj")
      File.mkdir_p!(Path.join(proj_path, ".remember/logs"))
      File.mkdir_p!(Path.join(proj_path, ".remember/tmp"))
      File.write!(Path.join(proj_path, ".remember/logs/hook-errors.log"), "")
      File.mkdir_p!(Path.join(proj_path, ".git"))

      # Trigger scan so monitor has state
      HookHealthMonitor.scan_now()
      Process.sleep(300)

      conn = post(conn, ~p"/api/v2/hooks/clear/myproj", %{})
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert is_binary(body["rotated_to"])
    end

    test "returns 200 when unhealthy is content-only (stale_log)", %{conn: conn, dev_root: root} do
      proj_path = Path.join(root, "staleproj")
      log_dir = Path.join(proj_path, ".remember/logs")
      tmp_dir = Path.join(proj_path, ".remember/tmp")
      File.mkdir_p!(log_dir)
      File.mkdir_p!(tmp_dir)
      File.mkdir_p!(Path.join(proj_path, ".git"))
      log_path = Path.join(log_dir, "hook-errors.log")
      File.write!(log_path, "old error\n")
      eight_days_ago = System.os_time(:second) - 8 * 24 * 3600
      File.touch!(log_path, eight_days_ago)

      HookHealthMonitor.scan_now()
      Process.sleep(300)

      conn = post(conn, ~p"/api/v2/hooks/clear/staleproj", %{})
      body = json_response(conn, 200)

      assert body["ok"] == true
    end

    test "returns 409 when project has filesystem issue (:missing_remember)", %{conn: conn, dev_root: root} do
      # Project exists but has NO .remember/ at all
      proj_path = Path.join(root, "brokenproj")
      File.mkdir_p!(Path.join(proj_path, ".git"))

      HookHealthMonitor.scan_now()
      Process.sleep(300)

      conn = post(conn, ~p"/api/v2/hooks/clear/brokenproj", %{})
      body = json_response(conn, 409)

      assert Map.has_key?(body, "error")
      assert is_list(body["issues"])
    end

    test "returns 404 when project not found", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/hooks/clear/nonexistent_zzz", %{})
      assert json_response(conn, 404)
    end
  end
end
