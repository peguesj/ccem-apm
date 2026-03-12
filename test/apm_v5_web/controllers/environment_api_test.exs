defmodule ApmV5Web.EnvironmentApiTest do
  use ApmV5Web.ConnCase, async: false

  describe "GET /api/environments" do
    test "returns list of environments", %{conn: conn} do
      conn = get(conn, "/api/environments")
      assert %{"environments" => envs, "count" => count} = json_response(conn, 200)
      assert is_list(envs)
      assert is_integer(count)
    end

    test "includes CORS headers", %{conn: conn} do
      conn = get(conn, "/api/environments")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "GET /api/environments/:name" do
    test "returns 404 for unknown environment", %{conn: conn} do
      conn = get(conn, "/api/environments/nonexistent_project_xyz")
      assert json_response(conn, 404)["error"] == "Environment not found"
    end
  end

  describe "POST /api/environments/:name/exec" do
    test "returns 400 without command", %{conn: conn} do
      conn = post(conn, "/api/environments/test/exec", %{})
      assert json_response(conn, 400)["error"] =~ "command"
    end

    test "returns 404 for unknown environment", %{conn: conn} do
      conn = post(conn, "/api/environments/nonexistent_xyz/exec", %{command: "echo hi"})
      assert json_response(conn, 404)["error"] == "Environment not found"
    end
  end

  describe "POST /api/environments/:name/session/start" do
    test "returns 404 for unknown environment", %{conn: conn} do
      conn = post(conn, "/api/environments/nonexistent_xyz/session/start", %{})
      assert json_response(conn, 404)["error"] == "Environment not found"
    end
  end

  describe "POST /api/environments/:name/session/stop" do
    test "returns 404 for unknown environment", %{conn: conn} do
      conn = post(conn, "/api/environments/nonexistent_xyz/session/stop", %{})
      assert json_response(conn, 404)["error"] == "Environment not found"
    end
  end
end
