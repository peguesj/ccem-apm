defmodule ApmV5Web.V2.ProvControllerTest do
  @moduledoc """
  HTTP endpoint tests for provenance bundle endpoint (prov-w2-s4 / CP-278).

  Tests:
  - GET /api/v2/provenance/bundle?formation_id=X returns 200 with JSON-LD
  - Missing formation_id returns 400
  """

  use ApmV5Web.ConnCase, async: false

  @moduletag :prov_exporter

  alias ApmV5.AgentRegistry

  setup do
    case Process.whereis(AgentRegistry) do
      nil -> {:ok, _} = AgentRegistry.start_link([])
      _ -> :ok
    end

    formation_id = "http-test-formation-#{System.unique_integer([:positive])}"

    AgentRegistry.register_agent("agent-http-prov", %{
      agent_id: "agent-http-prov",
      role: "worker",
      formation_id: formation_id,
      status: "active"
    })

    {:ok, formation_id: formation_id}
  end

  describe "GET /api/v2/provenance/bundle" do
    test "returns 200 with JSON-LD body when formation_id provided", %{
      conn: conn,
      formation_id: fid
    } do
      conn = get(conn, "/api/v2/provenance/bundle?formation_id=#{fid}")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "@context")
      assert Map.has_key?(body, "entity")
      assert Map.has_key?(body, "activity")
      assert Map.has_key?(body, "agent")
    end

    test "returns 400 when formation_id is missing", %{conn: conn} do
      conn = get(conn, "/api/v2/provenance/bundle")
      assert conn.status == 400
    end
  end
end
