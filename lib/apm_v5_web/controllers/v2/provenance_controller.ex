defmodule ApmV5Web.V2.ProvenanceController do
  @moduledoc """
  REST API controller for W3C PROV-DM provenance endpoints.

  ## Endpoints

  - `GET /api/v2/provenance/bundle?formation_id=X[&format=jsonld]`
    Returns a PROV-JSONLD bundle for the specified formation.

  - `GET /api/v2/provenance/lineage?agent_id=X`
    Returns the lineage DAG `{nodes, edges}` for an agent.
    Delegates to `ApmV5.Provenance.LineageTracker` (prov-w2-s6).
  """

  use ApmV5Web, :controller

  alias ApmV5.Provenance.ProvExporter

  # ── GET /api/v2/provenance/bundle ───────────────────────────────────────────

  @doc """
  Returns a W3C PROV-JSONLD bundle for the given `formation_id`.

  Query parameters:
  - `formation_id` (required) — the formation to export
  - `format` (optional, default: `jsonld`) — output format; only `jsonld` supported now
  """
  @spec bundle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bundle(conn, %{"formation_id" => formation_id} = params) when is_binary(formation_id) do
    format =
      case Map.get(params, "format", "jsonld") do
        "jsonld" -> :jsonld
        _ -> :jsonld
      end

    bundle_map = ProvExporter.build_bundle(formation_id, format: format)

    conn
    |> put_resp_content_type("application/ld+json")
    |> json(bundle_map)
  end

  def bundle(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{
      "error" => "missing_parameter",
      "message" => "formation_id is required"
    })
  end

  # ── GET /api/v2/agents/:agent_id/lineage ───────────────────────────────────

  @doc """
  Returns role appearance lineage for the given `agent_id` (treated as a role name).

  Response: `{"agent_id": "...", "appearances": [...]}`
  """
  @spec agent_lineage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def agent_lineage(conn, %{"agent_id" => agent_id}) do
    alias ApmV5.Identity.AgentRoleIndex

    appearances = AgentRoleIndex.role_appearances(agent_id)

    json(conn, %{
      "agent_id" => agent_id,
      "appearances" => Enum.map(appearances, fn a ->
        %{
          "role_id" => Map.get(a, :role_id) || Map.get(a, "role_id"),
          "formation_id" => Map.get(a, :formation_id) || Map.get(a, "formation_id"),
          "normalized_formation" =>
            Map.get(a, :normalized_formation) || Map.get(a, "normalized_formation"),
          "touched_at" => Map.get(a, :touched_at) || Map.get(a, "touched_at")
        }
      end)
    })
  end

  # ── GET /api/v2/provenance/lineage ──────────────────────────────────────────

  @doc """
  Returns the lineage DAG for the given `agent_id`.

  Query parameters:
  - `agent_id` (required) — the agent whose lineage to return

  Response: `{"nodes": [...], "edges": [...]}`
  """
  @spec lineage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lineage(conn, %{"agent_id" => agent_id}) when is_binary(agent_id) do
    # LineageTracker is wired in prov-w2-s6. Delegate via apply to avoid
    # compile-time resolution before that module exists.
    tracker = ApmV5.Provenance.LineageTracker

    result =
      if Code.ensure_loaded?(tracker) and function_exported?(tracker, :lineage_for_agent, 1) do
        apply(tracker, :lineage_for_agent, [agent_id])
      else
        %{nodes: [], edges: []}
      end

    json(conn, result)
  end

  def lineage(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{
      "error" => "missing_parameter",
      "message" => "agent_id is required"
    })
  end
end
