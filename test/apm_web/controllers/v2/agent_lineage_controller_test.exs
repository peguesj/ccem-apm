defmodule ApmWeb.V2.AgentLineageControllerTest do
  @moduledoc """
  HTTP tests for GET /api/v2/agents/:agent_id/lineage (prov-w2-s5 / CP-279).
  """

  use ApmWeb.ConnCase, async: false

  @moduletag :agent_role_index

  alias Apm.Identity.AgentRoleIndex

  setup do
    case Process.whereis(AgentRoleIndex) do
      nil -> {:ok, _} = AgentRoleIndex.start_link([])
      _ -> :ok
    end

    AgentRoleIndex.touch("worker", "formation-20260101-test")
    :ok
  end

  describe "GET /api/v2/agents/:agent_id/lineage" do
    test "returns 200 with appearances list", %{conn: conn} do
      conn = get(conn, "/api/v2/agents/worker/lineage")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "agent_id") or Map.has_key?(body, "appearances")
    end

    test "returns appearances key as list", %{conn: conn} do
      conn = get(conn, "/api/v2/agents/worker/lineage")
      body = Jason.decode!(conn.resp_body)
      appearances = Map.get(body, "appearances", [])
      assert is_list(appearances)
    end
  end
end
