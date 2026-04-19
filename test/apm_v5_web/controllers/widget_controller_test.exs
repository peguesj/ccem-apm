defmodule ApmV5Web.V2.WidgetControllerTest do
  @moduledoc """
  API integration tests for the WidgetController (US-369).

  Run with: mix test --only widgetization
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :widgetization

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    :ok
  end

  describe "GET /api/v2/widgets" do
    test "returns all registered widgets including projects", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/widgets")
      body = json_response(conn, 200)

      assert is_list(body["widgets"])
      assert body["count"] >= 13

      widget_ids = Enum.map(body["widgets"], & &1["id"])
      assert "projects" in widget_ids
      assert "agent_fleet" in widget_ids
      assert "notifications" in widget_ids
    end

    test "each widget has the new schema fields", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/widgets")
      body = json_response(conn, 200)

      widget = Enum.find(body["widgets"], &(&1["id"] == "agent_fleet"))
      assert is_boolean(widget["editable"])
      assert is_boolean(widget["pinnable"])
      assert is_list(widget["supported_scopes"])
      assert is_map(widget["default_config"])
      assert is_integer(widget["display_order"])
    end
  end

  describe "GET /api/v2/widgets/:id" do
    test "returns a single widget by id", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/widgets/agent_fleet")
      body = json_response(conn, 200)

      assert body["id"] == "agent_fleet"
      assert body["name"] == "Agent Fleet"
    end

    test "returns 404 for unknown widget", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/widgets/does_not_exist")
      body = json_response(conn, 404)

      assert body["error"] == "Widget not found"
    end
  end

  describe "PATCH /api/v2/widgets/:id/config" do
    test "persists widget config override", %{conn: conn} do
      conn =
        patch(conn, ~p"/api/v2/widgets/notifications/config", %{
          session_id: "api-test-session",
          config: %{max_items: 5}
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["widget_id"] == "notifications"
      assert is_map(body["merged_config"])
    end

    test "returns 404 for unknown widget", %{conn: conn} do
      conn =
        patch(conn, ~p"/api/v2/widgets/ghost_widget/config", %{
          session_id: "api-test-session",
          config: %{}
        })

      assert json_response(conn, 404)["error"] == "Widget not found"
    end
  end

  describe "GET /api/v2/dashboard/layout" do
    test "returns layout with placements and available presets", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/dashboard/layout?session_id=api-test-layout-session")
      body = json_response(conn, 200)

      assert is_list(body["placements"])
      assert is_list(body["available_presets"])
      assert length(body["available_presets"]) >= 1
    end
  end

  describe "POST /api/v2/dashboard/layout" do
    test "saves a custom layout", %{conn: conn} do
      placements = [
        %{widget_id: "agent_fleet", col_start: 1, col_end: 5, row_start: 1, row_end: 3}
      ]

      conn =
        post(conn, ~p"/api/v2/dashboard/layout", %{
          session_id: "api-test-save-session",
          placements: placements,
          preset_id: "custom"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["session_id"] == "api-test-save-session"
    end

    test "returns 400 when session_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/dashboard/layout", %{placements: []})
      assert json_response(conn, 400)["error"] =~ "session_id"
    end
  end

  describe "POST /api/v2/dashboard/pin" do
    test "pins a pinnable widget", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/dashboard/pin", %{
          session_id: "api-test-pin-session",
          widget_id: "projects"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["pinned_widget_id"] == "projects"
    end

    test "unpins when widget_id is omitted", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/dashboard/pin", %{
          session_id: "api-test-pin-session"
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["pinned_widget_id"] == nil
    end

    test "returns 422 for non-pinnable widget", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v2/dashboard/pin", %{
          session_id: "api-test-pin-session",
          widget_id: "agent_fleet"
        })

      assert json_response(conn, 422)["error"] =~ "not pinnable"
    end

    test "returns 400 when session_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v2/dashboard/pin", %{widget_id: "projects"})
      assert json_response(conn, 400)["error"] =~ "session_id"
    end
  end
end
