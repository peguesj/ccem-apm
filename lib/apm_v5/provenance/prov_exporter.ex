defmodule ApmV5.Provenance.ProvExporter do
  @moduledoc """
  Builds a W3C PROV-DM bundle as PROV-JSONLD from APM runtime state.

  ## W3C PROV-DM mapping

  | PROV concept         | APM source                                         |
  |----------------------|----------------------------------------------------|
  | `prov:Entity`        | ArtifactAttestation ETS entries (files written)    |
  | `prov:Activity`      | AuditLog :tool_call events for the formation       |
  | `prov:Agent`         | AgentRegistry agents for the formation             |
  | `wasGeneratedBy`     | Entity → Activity (tool_name Write/Edit/MultiEdit) |
  | `wasAttributedTo`    | Entity → Agent (agent_id on attestation)           |
  | `wasDerivedFrom`     | LineageTracker edges (populated after prov-w2-s6)  |

  ## Output format

  The bundle is a plain Elixir map conforming to PROV-JSONLD. Serialize with
  `Jason.encode!/1` for wire transfer.

  ## DRTW

  Hand-authored PROV-JSONLD mapping — no `prov`, `rdf`, or `grax` hex packages.
  The PROV-JSONLD @context is embedded inline per DRTW governance
  `docs/drtw-governance/08-provenance.md`.
  """

  alias ApmV5.AgentRegistry
  alias ApmV5.AuditLog
  alias ApmV5.Provenance.ArtifactAttestation

  @prov_context %{
    "prov" => "http://www.w3.org/ns/prov#",
    "xsd" => "http://www.w3.org/2001/XMLSchema#",
    "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
    "ccem" => "https://pegues.io/ns/ccem#",
    "entity" => "prov:entity",
    "activity" => "prov:activity",
    "agent" => "prov:agent",
    "wasGeneratedBy" => "prov:wasGeneratedBy",
    "wasAttributedTo" => "prov:wasAttributedTo",
    "wasDerivedFrom" => "prov:wasDerivedFrom",
    "startedAtTime" => %{
      "@id" => "prov:startedAtTime",
      "@type" => "xsd:dateTime"
    },
    "endedAtTime" => %{
      "@id" => "prov:endedAtTime",
      "@type" => "xsd:dateTime"
    },
    "atTime" => %{
      "@id" => "prov:atTime",
      "@type" => "xsd:dateTime"
    }
  }

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Builds a W3C PROV-JSONLD bundle for the given formation.

  Accepts an optional `format:` keyword — only `:jsonld` is currently supported
  (and is the default).

  Returns a plain map ready for `Jason.encode!/1`.
  """
  @spec build_bundle(String.t(), keyword()) :: map()
  def build_bundle(formation_id, opts \\ []) when is_binary(formation_id) do
    _format = Keyword.get(opts, :format, :jsonld)

    agents = build_agents(formation_id)
    activities = build_activities(formation_id)
    {entities, was_generated_by, was_attributed_to} = build_entities(formation_id)
    was_derived_from = build_derived_from(formation_id)

    %{
      "@context" => @prov_context,
      "@id" => "ccem:bundle/#{formation_id}",
      "@type" => "prov:Bundle",
      "ccem:formation_id" => formation_id,
      "ccem:generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "entity" => entities,
      "activity" => activities,
      "agent" => agents,
      "wasGeneratedBy" => was_generated_by,
      "wasAttributedTo" => was_attributed_to,
      "wasDerivedFrom" => was_derived_from
    }
  end

  # ── Private builders ────────────────────────────────────────────────────────

  # Builds prov:Agent map from AgentRegistry for the formation.
  @spec build_agents(String.t()) :: map()
  defp build_agents(formation_id) do
    AgentRegistry.list_formation(formation_id)
    |> Enum.map(fn agent ->
      agent_id = Map.get(agent, :agent_id) || Map.get(agent, "agent_id") || "unknown"
      role = Map.get(agent, :role) || Map.get(agent, "role") || "unknown"
      status = Map.get(agent, :status) || Map.get(agent, "status") || "unknown"

      key = "ccem:agent/#{agent_id}"

      value = %{
        "@type" => "prov:SoftwareAgent",
        "rdfs:label" => agent_id,
        "ccem:role" => role,
        "ccem:status" => status,
        "ccem:formation_id" => formation_id
      }

      {key, value}
    end)
    |> Map.new()
  end

  # Builds prov:Activity map from AuditLog :tool_call events for the formation.
  @spec build_activities(String.t()) :: map()
  defp build_activities(formation_id) do
    AuditLog.query(formation_id: formation_id, event_type: :tool_call, limit: 1000)
    |> Enum.map(fn event ->
      event_id = Map.get(event, :id) || Map.get(event, "id") || System.unique_integer([:positive])
      actor = Map.get(event, :actor) || Map.get(event, "actor") || "unknown"
      resource = Map.get(event, :resource) || Map.get(event, "resource") || "unknown"
      timestamp = Map.get(event, :timestamp) || Map.get(event, "timestamp")

      details = Map.get(event, :details) || Map.get(event, "details") || %{}
      tool_name = Map.get(details, :tool_name) || Map.get(details, "tool_name") || "unknown"

      key = "ccem:activity/#{event_id}"

      value =
        %{
          "@type" => "prov:Activity",
          "rdfs:label" => "#{tool_name}:#{resource}",
          "ccem:tool_name" => tool_name,
          "ccem:actor" => actor,
          "ccem:resource" => resource
        }
        |> maybe_put_timestamp("startedAtTime", timestamp)
        |> maybe_put_timestamp("endedAtTime", timestamp)

      {key, value}
    end)
    |> Map.new()
  end

  # Builds prov:Entity, wasGeneratedBy, and wasAttributedTo from ArtifactAttestation ETS.
  @spec build_entities(String.t()) :: {map(), map(), map()}
  defp build_entities(formation_id) do
    attestations = load_attestations_for_formation(formation_id)

    entities =
      attestations
      |> Enum.flat_map(fn attest ->
        Enum.map(attest.subject, fn subj ->
          name = Map.get(subj, :name) || Map.get(subj, "name") || "unknown"
          sha256 = Map.get(subj, :sha256) || Map.get(subj, "sha256") || ""
          key = "ccem:entity/#{Base.encode16(:crypto.hash(:sha256, name), case: :lower)}"

          value = %{
            "@type" => "prov:Entity",
            "rdfs:label" => name,
            "ccem:sha256" => sha256,
            "ccem:tool_name" => attest.tool_name
          }

          {key, value}
        end)
      end)
      |> Map.new()

    # wasGeneratedBy: entity_id → activity ref
    was_generated_by =
      attestations
      |> Enum.with_index()
      |> Enum.flat_map(fn {attest, idx} ->
        Enum.map(attest.subject, fn subj ->
          name = Map.get(subj, :name) || Map.get(subj, "name") || "unknown"
          entity_key = "ccem:entity/#{Base.encode16(:crypto.hash(:sha256, name), case: :lower)}"
          rel_key = "ccem:wgb/#{idx}"

          value = %{
            "@type" => "prov:wasGeneratedBy",
            "prov:entity" => %{"@id" => entity_key},
            "prov:activity" => %{"@id" => "ccem:activity/attest/#{idx}"},
            "atTime" => attest.timestamp
          }

          {rel_key, value}
        end)
      end)
      |> Map.new()

    # wasAttributedTo: entity → agent
    was_attributed_to =
      attestations
      |> Enum.with_index()
      |> Enum.flat_map(fn {attest, idx} ->
        Enum.map(attest.subject, fn subj ->
          name = Map.get(subj, :name) || Map.get(subj, "name") || "unknown"
          entity_key = "ccem:entity/#{Base.encode16(:crypto.hash(:sha256, name), case: :lower)}"
          rel_key = "ccem:wat/#{idx}"
          agent_key = "ccem:agent/#{attest.agent_id}"

          value = %{
            "@type" => "prov:wasAttributedTo",
            "prov:entity" => %{"@id" => entity_key},
            "prov:agent" => %{"@id" => agent_key}
          }

          {rel_key, value}
        end)
      end)
      |> Map.new()

    {entities, was_generated_by, was_attributed_to}
  end

  # Builds wasDerivedFrom edges from LineageTracker ETS (prov-w2-s6 populates this).
  # Returns empty map if LineageTracker not yet available.
  @spec build_derived_from(String.t()) :: map()
  defp build_derived_from(formation_id) do
    case :ets.whereis(:apm_lineage_edges) do
      :undefined ->
        %{}

      _tid ->
        load_lineage_edges_for_formation(formation_id)
        |> Enum.with_index()
        |> Enum.map(fn {{from_id, to_id, agent_id, _ts}, idx} ->
          key = "ccem:wdf/#{idx}"

          value = %{
            "@type" => "prov:wasDerivedFrom",
            "prov:generatedEntity" => %{"@id" => "ccem:output/#{to_id}"},
            "prov:usedEntity" => %{"@id" => "ccem:output/#{from_id}"},
            "ccem:agent_id" => agent_id
          }

          {key, value}
        end)
        |> Map.new()
    end
  end

  # ── ETS helpers ─────────────────────────────────────────────────────────────

  # Loads ArtifactAttestation entries matching the formation_id.
  # Falls back to all attestations if formation_id filtering not possible.
  @spec load_attestations_for_formation(String.t()) :: [ArtifactAttestation.t()]
  defp load_attestations_for_formation(formation_id) do
    case :ets.whereis(:apm_artifact_attestations) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(:apm_artifact_attestations)
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.filter(fn
          %ArtifactAttestation{formation_id: ^formation_id} -> true
          %ArtifactAttestation{formation_id: nil} -> false
          _ -> false
        end)
    end
  end

  # Loads lineage edges from LineageTracker ETS filtered to formation agents.
  # Returns list of {from_invocation_id, to_invocation_id, agent_id, timestamp}.
  @spec load_lineage_edges_for_formation(String.t()) :: list()
  defp load_lineage_edges_for_formation(_formation_id) do
    # All edges — LineageTracker does not index by formation in prov-w2-s6.
    # We return all edges here; callers may filter further if needed.
    :ets.tab2list(:apm_lineage_edges)
    |> Enum.map(fn {_key, edge} -> edge end)
  end

  # ── Utilities ───────────────────────────────────────────────────────────────

  @spec maybe_put_timestamp(map(), String.t(), any()) :: map()
  defp maybe_put_timestamp(map, _key, nil), do: map
  defp maybe_put_timestamp(map, key, ts) when is_binary(ts), do: Map.put(map, key, ts)

  defp maybe_put_timestamp(map, key, %DateTime{} = dt),
    do: Map.put(map, key, DateTime.to_iso8601(dt))

  defp maybe_put_timestamp(map, _key, _), do: map
end
