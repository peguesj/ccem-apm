defmodule ApmV5Web.Plugs.CorrelationIdTest do
  use ApmV5Web.ConnCase, async: true

  alias ApmV5Web.Plugs.CorrelationId

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  describe "CorrelationId plug" do
    test "generates correlation ID when not provided", %{conn: conn} do
      conn = CorrelationId.call(conn, CorrelationId.init([]))

      [header_value] = get_resp_header(conn, "x-correlation-id")
      assert String.match?(header_value, @uuid_regex)
      assert conn.assigns[:correlation_id] == header_value
    end

    test "uses client-provided X-Correlation-ID", %{conn: conn} do
      client_id = "client-provided-id-123"

      conn =
        conn
        |> put_req_header("x-correlation-id", client_id)
        |> CorrelationId.call(CorrelationId.init([]))

      [header_value] = get_resp_header(conn, "x-correlation-id")
      assert header_value == client_id
      assert conn.assigns[:correlation_id] == client_id
    end

    test "sets response header", %{conn: conn} do
      conn = CorrelationId.call(conn, CorrelationId.init([]))

      assert [_] = get_resp_header(conn, "x-correlation-id")
    end
  end
end
