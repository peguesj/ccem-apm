defmodule ApmV4Web.A2uiControllerTest do
  use ApmV4Web.ConnCase, async: false

  alias ApmV4.AgentRegistry

  setup do
    AgentRegistry.clear_all()
    :ok
  end

  describe "GET /api/a2ui/components" do
    test "returns application/jsonl content type by default", %{conn: conn} do
      conn = get(conn, ~p"/api/a2ui/components")
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "application/jsonl"
    end

    test "JSONL response has one valid JSON object per line", %{conn: conn} do
      AgentRegistry.register_agent("jsonl-a1", %{name: "Alpha", status: "active"})

      conn = get(conn, ~p"/api/a2ui/components")

      lines =
        conn.resp_body
        |> String.split("\n", trim: true)

      assert length(lines) > 0

      for line <- lines do
        assert {:ok, component} = Jason.decode(line)
        assert is_map(component)
        assert Map.has_key?(component, "id")
        assert Map.has_key?(component, "type")
      end
    end

    test "returns application/json when Accept: application/json", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "application/json"

      body = json_response(conn, 200)
      assert is_list(body["components"])
    end

    test "all component types are present with agents registered", %{conn: conn} do
      AgentRegistry.register_agent("type-a1", %{name: "Alpha", status: "active", tier: 1})
      AgentRegistry.add_notification(%{title: "Test", message: "Msg", level: "info"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      types = Enum.map(body["components"], & &1["type"]) |> Enum.uniq() |> Enum.sort()

      assert "alert" in types
      assert "badge" in types
      assert "card" in types
      assert "chart" in types
      assert "progress" in types
      assert "table" in types
    end

    test "card components include title, body, footer, variant fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      cards = Enum.filter(body["components"], &(&1["type"] == "card"))

      assert length(cards) > 0

      for card <- cards do
        assert Map.has_key?(card, "title")
        assert Map.has_key?(card, "body")
        assert Map.has_key?(card, "footer")
        assert Map.has_key?(card, "variant")
      end
    end

    test "chart components include chart_type, data, labels fields", %{conn: conn} do
      AgentRegistry.register_agent("chart-a1", %{name: "Alpha", status: "active"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      charts = Enum.filter(body["components"], &(&1["type"] == "chart"))

      assert length(charts) > 0

      for chart <- charts do
        assert Map.has_key?(chart, "chart_type")
        assert Map.has_key?(chart, "data")
        assert Map.has_key?(chart, "labels")
      end
    end

    test "table components include columns, rows, sortable fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      tables = Enum.filter(body["components"], &(&1["type"] == "table"))

      assert length(tables) == 1

      for table <- tables do
        assert Map.has_key?(table, "columns")
        assert Map.has_key?(table, "rows")
        assert Map.has_key?(table, "sortable")
      end
    end

    test "alert components include level, message, dismissible fields", %{conn: conn} do
      AgentRegistry.add_notification(%{title: "Alert", message: "Test alert", level: "error"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      alerts = Enum.filter(body["components"], &(&1["type"] == "alert"))

      assert length(alerts) > 0

      for alert <- alerts do
        assert Map.has_key?(alert, "level")
        assert Map.has_key?(alert, "message")
        assert Map.has_key?(alert, "dismissible")
      end
    end

    test "components include unique IDs for incremental updates", %{conn: conn} do
      AgentRegistry.register_agent("id-a1", %{name: "Alpha", status: "active"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      ids = Enum.map(body["components"], & &1["id"])

      assert length(ids) > 0
      assert ids == Enum.uniq(ids)
    end

    test "empty state returns valid components", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      assert is_list(body["components"])
      # Should still have stat cards + table + chart
      assert length(body["components"]) >= 6
    end

    test "JSONL with Accept: application/jsonl header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/jsonl")
        |> get(~p"/api/a2ui/components")

      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "application/jsonl"
    end

    test "multiple agents produce correct badge and table data", %{conn: conn} do
      AgentRegistry.register_agent("multi-a1", %{name: "Alpha", status: "active", tier: 1})
      AgentRegistry.register_agent("multi-a2", %{name: "Beta", status: "idle", tier: 2})
      AgentRegistry.register_agent("multi-a3", %{name: "Gamma", status: "error", tier: 1})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      body = json_response(conn, 200)
      badges = Enum.filter(body["components"], &(&1["type"] == "badge"))
      tables = Enum.filter(body["components"], &(&1["type"] == "table"))

      assert length(badges) == 3
      assert length(List.first(tables)["rows"]) == 3
    end
  end
end
