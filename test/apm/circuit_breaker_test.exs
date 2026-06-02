defmodule Apm.CircuitBreakerTest do
  @moduledoc """
  Integration tests for fuse circuit breakers on hot-path API endpoints.

  Covers:
    - :apm_register_fuse  (POST /api/register)
    - :apm_heartbeat_fuse (POST /api/heartbeat)
    - :apm_notify_fuse    (POST /api/notify)

  The test blows each fuse manually via :fuse.melt/1 calls, then verifies
  the controller returns 503 + Retry-After when the fuse is blown, and 2xx
  when the fuse is in the :ok state.
  """
  use ApmWeb.ConnCase, async: false

  @fuses [:apm_register_fuse, :apm_heartbeat_fuse, :apm_notify_fuse]

  setup do
    # Reset all three fuses to a known :ok state before each test.
    # :fuse.reset/1 clears trip state and resumes normal operation.
    Enum.each(@fuses, fn fuse ->
      try do
        :fuse.reset(fuse)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "GET /api/status (fuse-exempt endpoint)" do
    test "status endpoint is never affected by circuit breakers", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      assert conn.status in [200, 204]
    end
  end

  describe "POST /api/register fuse guard" do
    test "returns 201 when :apm_register_fuse is ok", %{conn: conn} do
      conn =
        post(conn, ~p"/api/register", %{
          "agent_id" => "test-reg-#{System.unique_integer()}",
          "project" => "test"
        })

      assert conn.status in [200, 201]
    end

    test "returns 503 with Retry-After when :apm_register_fuse is blown", %{conn: conn} do
      # Blow the fuse by exceeding its threshold via :fuse.melt/1
      blow_fuse(:apm_register_fuse, 600)

      conn =
        post(conn, ~p"/api/register", %{
          "agent_id" => "test-blown-#{System.unique_integer()}",
          "project" => "test"
        })

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert json_response(conn, 503)["error"] == "circuit_open"
    end
  end

  describe "POST /api/heartbeat fuse guard" do
    test "returns 200 when :apm_heartbeat_fuse is ok", %{conn: conn} do
      # Register an agent first so heartbeat finds it
      agent_id = "hb-test-#{System.unique_integer()}"

      post(conn, ~p"/api/register", %{
        "agent_id" => agent_id,
        "project" => "test"
      })

      conn2 = build_conn()

      conn2 =
        post(conn2, ~p"/api/heartbeat", %{
          "agent_id" => agent_id,
          "status" => "active"
        })

      assert conn2.status in [200, 201]
    end

    test "returns 503 with Retry-After when :apm_heartbeat_fuse is blown", %{conn: conn} do
      blow_fuse(:apm_heartbeat_fuse, 1100)

      conn =
        post(conn, ~p"/api/heartbeat", %{
          "agent_id" => "hb-blown-#{System.unique_integer()}",
          "status" => "active"
        })

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["15"]
      assert json_response(conn, 503)["error"] == "circuit_open"
    end
  end

  describe "POST /api/notify fuse guard" do
    test "returns 200 when :apm_notify_fuse is ok", %{conn: conn} do
      conn =
        post(conn, ~p"/api/notify", %{
          "title" => "Test",
          "message" => "circuit breaker test",
          "type" => "info"
        })

      assert conn.status in [200, 201]
    end

    test "returns 503 with Retry-After when :apm_notify_fuse is blown", %{conn: conn} do
      blow_fuse(:apm_notify_fuse, 400)

      conn =
        post(conn, ~p"/api/notify", %{
          "title" => "Test blown",
          "message" => "should be blocked",
          "type" => "info"
        })

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert json_response(conn, 503)["error"] == "circuit_open"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Blow a fuse by calling :fuse.melt/1 enough times to exceed its threshold.
  # :fuse.melt/1 records a failure event; once threshold is exceeded in the
  # time window the fuse trips to :blown state.
  defp blow_fuse(fuse_name, count) do
    Enum.each(1..count, fn _ -> :fuse.melt(fuse_name) end)
    # Give fuse OTP process a moment to process all melt messages
    Process.sleep(50)
  end
end
