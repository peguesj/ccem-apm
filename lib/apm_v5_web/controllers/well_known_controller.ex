defmodule ApmV5Web.WellKnownController do
  @moduledoc """
  Serves RFC 8615 well-known URIs.

  ## Endpoints

    - `GET /.well-known/agent-card.json` — A2A v0.3.0 AgentCard for the APM
      server itself. Industry-standard agent discovery endpoint.

  Story `coord-a1` from v9.2.1 hotfix sprint.
  See `docs/drtw-governance/09-multi-agent-coordination.md`.
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.A2A.AgentCard
  alias ApmV5.AgentRegistry

  @doc "GET /.well-known/agent-card.json — APM's own AgentCard"
  def agent_card(conn, _params) do
    base_url = build_base_url(conn)
    card = AgentCard.apm_card(base_url)

    conn
    |> put_resp_content_type("application/json")
    |> json(card)
  end

  @doc "GET /api/v2/agents/:agent_id/agent-card.json — per-agent AgentCard"
  def agent_card_for_agent(conn, %{"agent_id" => agent_id}) do
    base_url = build_base_url(conn)

    case AgentRegistry.get_agent(agent_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "agent not found", agent_id: agent_id})

      agent_map ->
        identity = build_identity_from_agent(agent_map, agent_id)
        card = AgentCard.from_identity(identity, base_url)

        conn
        |> put_resp_content_type("application/json")
        |> json(card)
    end
  end

  defp build_identity_from_agent(agent_map, agent_id) do
    %ApmV5.AgentIdentity{
      agent_id: agent_id,
      agent_name: get_field(agent_map, [:agent_name, :display_name]) || agent_id,
      agent_description: get_field(agent_map, [:agent_description, :description]),
      agent_version: get_field(agent_map, [:agent_version, :version]),
      role: get_field(agent_map, [:role]) || "unknown",
      agent_type: get_field(agent_map, [:agent_type, :type]) || "unknown",
      display_name: get_field(agent_map, [:display_name, :agent_name]) || agent_id,
      formation_id: get_field(agent_map, [:formation_id]),
      session_id: get_field(agent_map, [:session_id]),
      skills: get_field(agent_map, [:skills]) || []
    }
  end

  defp get_field(map, [key | rest]) do
    Map.get(map, key) || Map.get(map, to_string(key)) || get_field(map, rest)
  end

  defp get_field(_map, []), do: nil

  defp build_base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    "#{scheme}://#{conn.host}:#{conn.port}"
  end
end
