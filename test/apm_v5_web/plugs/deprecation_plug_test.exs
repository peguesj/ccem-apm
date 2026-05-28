defmodule ApmV5Web.Plugs.DeprecationTest do
  @moduledoc """
  Tests for ApmV5Web.Plugs.Deprecation (api-s8 / CP-267).

  RFC 8594 Deprecation header behaviour:
  - Legacy /api/* routes receive Deprecation: true + Sunset: 2027-01-01
  - /api/v2/* routes are exempt (no headers added)
  """

  use ApmV5Web.ConnCase, async: true

  alias ApmV5Web.Plugs.Deprecation

  @moduletag :deprecation_plug

  # ── Plug unit tests (direct call) ──────────────────────────────────────────

  describe "Deprecation plug direct call" do
    test "adds Deprecation and Sunset headers to /api/agents (legacy path)" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/agents")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["true"]
      assert Plug.Conn.get_resp_header(conn, "sunset") == ["2027-01-01"]
    end

    test "adds Deprecation header to /api/notifications (legacy path)" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/notifications")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["true"]
    end

    test "adds Deprecation header to /api/register (POST legacy path)" do
      conn =
        Phoenix.ConnTest.build_conn(:post, "/api/register")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["true"]
      assert Plug.Conn.get_resp_header(conn, "sunset") == ["2027-01-01"]
    end

    test "does NOT add headers to /api/v2/agents" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/v2/agents")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
      assert Plug.Conn.get_resp_header(conn, "sunset") == []
    end

    test "does NOT add headers to /api/v2/auth/authorize" do
      conn =
        Phoenix.ConnTest.build_conn(:post, "/api/v2/auth/authorize")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
    end

    test "does NOT add headers to /api/v2/openapi.json" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/v2/openapi.json")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
    end

    test "does NOT add headers to non-api paths (e.g. /)" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
      assert Plug.Conn.get_resp_header(conn, "sunset") == []
    end

    test "does NOT add headers to /metrics (internal)" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/metrics")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
    end
  end

  # ── Integration tests (via router pipeline) ────────────────────────────────

  describe "Deprecation headers via live router" do
    test "GET /api/agents returns Deprecation header", %{conn: conn} do
      # /api/agents is a legacy v1 endpoint (not /api/v2/*)
      conn = get(conn, "/api/agents")
      # Status can be anything (200, 401 etc) — we just verify the header
      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["true"]
      assert Plug.Conn.get_resp_header(conn, "sunset") == ["2027-01-01"]
    end

    test "GET /api/v2/agents does NOT return Deprecation header", %{conn: conn} do
      conn = get(conn, "/api/v2/agents")
      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
      assert Plug.Conn.get_resp_header(conn, "sunset") == []
    end
  end

  # ── Sunset date invariant ──────────────────────────────────────────────────

  describe "Sunset date" do
    test "sunset date is RFC 3339 date format (YYYY-MM-DD)" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/status")
        |> Deprecation.call([])

      [sunset] = Plug.Conn.get_resp_header(conn, "sunset")
      assert sunset =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end

    test "sunset date is 2027-01-01" do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/api/status")
        |> Deprecation.call([])

      assert Plug.Conn.get_resp_header(conn, "sunset") == ["2027-01-01"]
    end
  end
end
