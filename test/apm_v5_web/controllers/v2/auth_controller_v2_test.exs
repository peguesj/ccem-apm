defmodule ApmV5Web.V2.AuthControllerTest do
  @moduledoc """
  Tests for the 8 apm-auth skill-spec endpoints added in CP-190 (CCEM-565):
    POST /api/v2/auth/session/start
    POST /api/v2/auth/session/heartbeat
    POST /api/v2/auth/session/end
    POST /api/v2/auth/token/redeem
    GET  /api/v2/auth/policies
    POST /api/v2/auth/policies
    GET  /api/v2/auth/approvals/pending
    POST /api/v2/auth/approvals/:id/decide

  Also tests the authorize/2 decision field (allow/ask/deny) added in CP-190.

  Run with: mix test --only govern_intelligence
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :govern_intelligence

  alias ApmV5.Auth.PolicyRulesStore

  setup do
    # Ensure PolicyRulesStore is alive
    case Process.whereis(PolicyRulesStore) do
      nil -> {:ok, _} = PolicyRulesStore.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      PolicyRulesStore.remove_rule("*")
      PolicyRulesStore.remove_rule("TestTool")
    end)

    :ok
  end

  # ── POST /api/v2/auth/authorize — decision field ─────────────────────────────

  describe "POST /api/v2/auth/authorize" do
    # /authorize is annotated with @operation in api-s5 Wave 1, so
    # open_api_spex's CastAndValidate requires application/json content-type
    # on the request body. The Phoenix test conn defaults to multipart/mixed.
    setup %{conn: conn} do
      {:ok, conn: Plug.Conn.put_req_header(conn, "content-type", "application/json")}
    end

    test "returns decision field in response", %{conn: conn} do
      PolicyRulesStore.add_rule("*", :always_allow)

      conn =
        post(conn, ~p"/api/v2/auth/authorize", %{
          "agent_id" => "test-agent",
          "session_id" => "test-sess",
          "tool_name" => "Read",
          "role" => "agent",
          "params" => %{}
        })

      body = json_response(conn, 200)
      assert Map.has_key?(body, "decision")
      assert body["decision"] in ["allow", "ask", "deny"]
    end

    test "decision is 'allow' when wildcard always_allow rule is active", %{conn: conn} do
      PolicyRulesStore.add_rule("*", :always_allow)

      conn =
        post(conn, ~p"/api/v2/auth/authorize", %{
          "agent_id" => "claude",
          "session_id" => "s1",
          "tool_name" => "Bash",
          "role" => "agent",
          "params" => %{}
        })

      body = json_response(conn, 200)
      assert body["decision"] == "allow"
      assert body["allowed"] == true
    end

    test "response includes auth_token when allowed", %{conn: conn} do
      PolicyRulesStore.add_rule("*", :always_allow)

      conn =
        post(conn, ~p"/api/v2/auth/authorize", %{
          "agent_id" => "claude",
          "session_id" => "s1",
          "tool_name" => "Write",
          "role" => "agent",
          "params" => %{}
        })

      body = json_response(conn, 200)
      assert is_binary(body["auth_token"])
    end
  end

  # ── POST /api/v2/auth/session/start ──────────────────────────────────────────

  describe "POST /api/v2/auth/session/start" do
    test "creates session and returns session_id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/session/start", %{
          "agent_id" => "specialize",
          "trust_level" => "standard"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert is_binary(body["session_id"])
    end

    test "accepts optional trust_level", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/session/start", %{
          "agent_id" => "agent-1",
          "trust_level" => "elevated"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["trust_level"] == "elevated"
    end
  end

  # ── POST /api/v2/auth/session/heartbeat ──────────────────────────────────────

  describe "POST /api/v2/auth/session/heartbeat" do
    test "returns 404 for unknown session", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/session/heartbeat", %{
          "session_id" => "sess_nonexistent_xyz"
        })

      assert json_response(conn, 404)["ok"] == false
    end

    test "returns ok for known session", %{conn: conn} do
      # Start a session first
      start_conn = post(conn, ~p"/api/v2/auth/session/start", %{"agent_id" => "hb-agent"})
      %{"session_id" => sid} = json_response(start_conn, 200)

      hb_conn = post(conn, ~p"/api/v2/auth/session/heartbeat", %{"session_id" => sid})
      body = json_response(hb_conn, 200)
      assert body["ok"] == true
      assert body["refreshed"] == true
    end
  end

  # ── POST /api/v2/auth/session/end ────────────────────────────────────────────

  describe "POST /api/v2/auth/session/end" do
    test "terminates session (idempotent)", %{conn: conn} do
      start_conn = post(conn, ~p"/api/v2/auth/session/start", %{"agent_id" => "end-agent"})
      %{"session_id" => sid} = json_response(start_conn, 200)

      end_conn = post(conn, ~p"/api/v2/auth/session/end", %{"session_id" => sid})
      body = json_response(end_conn, 200)
      assert body["ok"] == true
      assert body["terminated"] == true
    end

    test "terminating non-existent session is safe", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/auth/session/end", %{"session_id" => "gone_already"})
      assert json_response(conn, 200)["ok"] == true
    end
  end

  # ── GET /api/v2/auth/policies ────────────────────────────────────────────────

  describe "GET /api/v2/auth/policies" do
    test "returns policies list", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/auth/policies")
      body = json_response(conn, 200)
      assert body["ok"] == true
      assert is_list(body["rules"])
      assert is_list(body["policies"])
    end
  end

  # ── POST /api/v2/auth/policies ───────────────────────────────────────────────

  describe "POST /api/v2/auth/policies" do
    test "creates a tool-level policy rule", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/policies", %{
          "tool" => "TestTool",
          "default" => "allow"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["tool_name"] == "TestTool"
    end

    test "scope-based rule maps to wildcard '*'", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/policies", %{
          "scope" => "formation:fmt-test-123",
          "default" => "allow"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
    end

    test "missing tool and scope returns 400", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/auth/policies", %{"default" => "allow"})
      assert json_response(conn, 400)["ok"] == false
    end
  end

  # ── GET /api/v2/auth/approvals/pending ───────────────────────────────────────

  describe "GET /api/v2/auth/approvals/pending" do
    test "returns pending list", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/auth/approvals/pending")
      body = json_response(conn, 200)
      assert body["ok"] == true
      assert is_list(body["pending"])
      assert is_integer(body["count"])
    end
  end

  # ── POST /api/v2/auth/approvals/:id/decide ───────────────────────────────────

  describe "POST /api/v2/auth/approvals/:id/decide" do
    test "returns 404 for non-existent decision id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/approvals/req_nonexistent_xyz/decide", %{
          "decision" => "allow"
        })

      assert json_response(conn, 404)["ok"] == false
    end

    test "returns 400 for invalid decision value", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/approvals/any_id/decide", %{
          "decision" => "maybe"
        })

      assert json_response(conn, 400)["ok"] == false
    end
  end

  # ── POST /api/v2/auth/token/redeem ───────────────────────────────────────────

  describe "POST /api/v2/auth/token/redeem" do
    test "mints a new token when scope is provided without token_id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/auth/token/redeem", %{
          "scope" => "formation:fmt-test-abc",
          "single_use" => true,
          "ttl_ms" => 30_000
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert is_binary(body["auth_token"])
    end

    test "returns 404 for non-existent token_id", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/auth/token/redeem", %{"auth_token" => "tok_doesnotexist"})
      assert json_response(conn, 404)["ok"] == false
    end
  end
end
