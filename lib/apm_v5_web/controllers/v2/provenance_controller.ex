defmodule ApmV5Web.V2.ProvenanceController do
  @moduledoc """
  REST API controller for W3C PROV-DM provenance endpoints.

  ## Endpoints shipped in Wave 2

  - `GET /api/v2/provenance/bundle?formation_id=X[&format=jsonld]`
    Returns a PROV-JSONLD bundle for the specified formation.

  - `GET /api/v2/provenance/lineage?agent_id=X`
    Returns the lineage DAG `{nodes, edges}` for an agent.
    Delegates to `ApmV5.Provenance.LineageTracker` (prov-w2-s6).

  ## Endpoints added in Wave 4 (prov-w4-s9 / CP-283)

  - `GET /api/v2/provenance/agents/:id`
    Full provenance record for a single agent: identity_token, did,
    delegation_chain, artifact_attestations, role_lineage.

  - `GET /api/v2/provenance/artifacts?session_id=&agent_id=&since=`
    Paginated artifact attestations with live signature verification.

  - `POST /api/v2/provenance/verify`
    Accept `{attestation: {...}, signature: "<hex>"}` and return
    `{valid: bool, agent_id: "...", timestamp: "..."}`.
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # NOTE: CastAndValidate is NOT plugged here because the legacy Wave 2 endpoints
  # (bundle, lineage, agent_lineage) lack operation annotations and would crash.
  # The Wave 4 endpoints are annotated for OpenAPI documentation only.

  alias ApmV5.Provenance.ProvExporter
  alias ApmV5.Provenance.ArtifactAttestation
  alias ApmV5.Identity.{KeyStore, DIDProvider, AgentRoleIndex}
  alias ApmV5.AgentRegistry

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
    appearances = AgentRoleIndex.role_appearances(agent_id)

    json(conn, %{
      "agent_id" => agent_id,
      "appearances" =>
        Enum.map(appearances, fn a ->
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

  # ── GET /api/v2/provenance/agents/:id ──────────────────────────────────────
  # prov-w4-s9 / CP-283

  operation :agent_provenance,
    summary: "Full provenance record for an agent",
    description: """
    Returns the complete provenance record for a registered agent, combining:
    - `identity_token` from KeyStore (APM public key as base16 hex)
    - `did` from DIDProvider
    - `delegation_chain` JWT stored in agent state
    - `artifact_attestations` from the ArtifactAttestation ETS ring buffer
    - `role_lineage` appearances from AgentRoleIndex
    """,
    tags: ["Provenance"],
    parameters: [
      id: [in: :path, description: "Agent ID", type: :string, required: true]
    ],
    responses: [
      ok: {"Agent provenance record", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Agent not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  @doc "GET /api/v2/provenance/agents/:id — full provenance record for an agent"
  @spec agent_provenance(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def agent_provenance(conn, %{"id" => agent_id}) when is_binary(agent_id) do
    agent = AgentRegistry.get_agent(agent_id)

    if is_nil(agent) do
      conn
      |> put_status(404)
      |> json(%{"error" => "not_found", "message" => "Agent #{agent_id} not registered"})
    else
      # identity_token: APM's own public key as hex (the key that signs attestations)
      identity_token =
        try do
          pub = KeyStore.public_key()
          if is_binary(pub), do: Base.encode16(pub, case: :lower), else: nil
        rescue
          _ -> nil
        end

      # DID for this APM instance
      did = DIDProvider.cached_did()

      # delegation_chain JWT from agent state (built during registration)
      delegation_chain = Map.get(agent, :delegation_chain)

      # artifact_attestations from ETS ring buffer for this agent
      attestations = list_attestations_for_agent(agent_id)

      # role_lineage from AgentRoleIndex
      role = Map.get(agent, :role) || agent_id
      role_lineage = AgentRoleIndex.role_appearances(role)

      json(conn, %{
        "agent_id" => agent_id,
        "identity_token" => identity_token,
        "did" => did,
        "delegation_chain" => delegation_chain,
        "artifact_attestations" => Enum.map(attestations, &serialize_attestation/1),
        "role_lineage" =>
          Enum.map(role_lineage, fn a ->
            %{
              "role_id" => Map.get(a, :role_id),
              "formation_id" => Map.get(a, :formation_id),
              "normalized_formation" => Map.get(a, :normalized_formation),
              "touched_at" => Map.get(a, :touched_at)
            }
          end)
      })
    end
  end

  def agent_provenance(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"error" => "missing_parameter", "message" => "id path parameter is required"})
  end

  # ── GET /api/v2/provenance/artifacts ──────────────────────────────────────
  # prov-w4-s9 / CP-283

  operation :artifacts,
    summary: "Paginated artifact attestations with signature verification",
    description: """
    Returns a filtered, paginated list of artifact attestations from the
    ETS ring buffer. Each attestation includes a `valid` field reflecting
    a live Ed25519 signature check.

    Optional query parameters:
    - `session_id` — filter by session
    - `agent_id` — filter by agent
    - `since` — ISO 8601 timestamp; only return attestations at or after this time
    - `limit` — max results (default 50, max 200)
    - `offset` — pagination offset (default 0)
    """,
    tags: ["Provenance"],
    parameters: [
      session_id: [in: :query, description: "Filter by session ID", type: :string, required: false],
      agent_id: [in: :query, description: "Filter by agent ID", type: :string, required: false],
      since: [
        in: :query,
        description: "ISO 8601 lower-bound timestamp",
        type: :string,
        required: false
      ],
      limit: [in: :query, description: "Max results (default 50, max 200)", type: :integer, required: false],
      offset: [in: :query, description: "Pagination offset (default 0)", type: :integer, required: false]
    ],
    responses: [
      ok: {"Attestations list", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  @doc "GET /api/v2/provenance/artifacts — paginated artifact attestations with verify status"
  @spec artifacts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def artifacts(conn, params) do
    session_filter = Map.get(params, "session_id")
    agent_filter = Map.get(params, "agent_id")
    since_filter = Map.get(params, "since")
    limit = parse_int(Map.get(params, "limit", "50"), 50) |> min(200)
    offset = parse_int(Map.get(params, "offset", "0"), 0)

    all_attestations = list_all_attestations()

    filtered =
      all_attestations
      |> filter_by(:session_id, session_filter)
      |> filter_by(:agent_id, agent_filter)
      |> filter_since(since_filter)

    paginated = filtered |> Enum.drop(offset) |> Enum.take(limit)

    serialized =
      Enum.map(paginated, fn attest ->
        valid = verify_attestation_signature(attest)
        Map.put(serialize_attestation(attest), "valid", valid)
      end)

    json(conn, %{
      "attestations" => serialized,
      "total" => length(filtered),
      "limit" => limit,
      "offset" => offset
    })
  end

  # ── POST /api/v2/provenance/verify ─────────────────────────────────────────
  # prov-w4-s9 / CP-283

  operation :verify,
    summary: "Verify an artifact attestation signature",
    description: """
    Accepts an attestation map and a hex-encoded Ed25519 signature.
    Reconstructs the canonical signing payload from the attestation fields,
    then verifies the signature against the APM's public key.

    Returns `{valid: bool, agent_id: "...", timestamp: "..."}`.
    """,
    tags: ["Provenance"],
    request_body: {
      "Attestation + signature to verify",
      "application/json",
      %OpenApiSpex.Schema{
        type: :object,
        required: ["attestation", "signature"],
        properties: %{
          attestation: %OpenApiSpex.Schema{
            type: :object,
            description: "Attestation fields (agent_id, tool_name, subject, timestamp, etc.)"
          },
          signature: %OpenApiSpex.Schema{
            type: :string,
            description: "Hex-encoded 64-byte Ed25519 signature"
          }
        }
      },
      required: true
    },
    responses: [
      ok: {"Verification result", "application/json", %OpenApiSpex.Schema{type: :object}},
      unprocessable_entity:
        {"Validation error", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  @doc "POST /api/v2/provenance/verify — verify attestation signature"
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"attestation" => attestation_map, "signature" => sig_hex})
      when is_map(attestation_map) and is_binary(sig_hex) do
    with {:ok, sig_bytes} <- Base.decode16(sig_hex, case: :mixed),
         :ok <- validate_sig_length(sig_bytes),
         payload <- build_verify_payload(attestation_map),
         {:ok, pub_key} <- fetch_public_key() do
      valid = KeyStore.verify(payload, sig_bytes, pub_key)
      agent_id =
        Map.get(attestation_map, "agent_id") || Map.get(attestation_map, :agent_id, "unknown")

      timestamp =
        Map.get(attestation_map, "timestamp") ||
          Map.get(attestation_map, :timestamp) ||
          DateTime.utc_now() |> DateTime.to_iso8601()

      json(conn, %{
        "valid" => valid,
        "agent_id" => agent_id,
        "timestamp" => timestamp
      })
    else
      :error ->
        conn
        |> put_status(422)
        |> json(%{
          "error" => "invalid_signature_encoding",
          "message" => "signature must be lowercase or uppercase hex-encoded bytes"
        })

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{"error" => "verify_failed", "message" => inspect(reason)})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{
      "error" => "missing_parameters",
      "message" => "Both 'attestation' (object) and 'signature' (hex string) are required"
    })
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Returns all attestations from the ETS ring buffer as a flat list.
  @spec list_all_attestations() :: [ArtifactAttestation.t()]
  defp list_all_attestations do
    table = :apm_artifact_attestations

    if :ets.whereis(table) != :undefined do
      :ets.tab2list(table) |> Enum.map(fn {_idx, attest} -> attest end)
    else
      []
    end
  end

  # Returns attestations for a specific agent_id.
  @spec list_attestations_for_agent(String.t()) :: [ArtifactAttestation.t()]
  defp list_attestations_for_agent(agent_id) do
    list_all_attestations()
    |> Enum.filter(fn a -> Map.get(a, :agent_id) == agent_id end)
  end

  # Filter a list of attestations by a struct field.
  @spec filter_by([ArtifactAttestation.t()], atom(), String.t() | nil) ::
          [ArtifactAttestation.t()]
  defp filter_by(list, _field, nil), do: list
  defp filter_by(list, _field, ""), do: list

  defp filter_by(list, field, value) do
    Enum.filter(list, fn a -> Map.get(a, field) == value end)
  end

  # Filter attestations with timestamp >= since (ISO 8601).
  @spec filter_since([ArtifactAttestation.t()], String.t() | nil) :: [ArtifactAttestation.t()]
  defp filter_since(list, nil), do: list
  defp filter_since(list, ""), do: list

  defp filter_since(list, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, since_dt, _offset} ->
        Enum.filter(list, fn a ->
          case DateTime.from_iso8601(Map.get(a, :timestamp, "")) do
            {:ok, ts_dt, _} -> DateTime.compare(ts_dt, since_dt) != :lt
            _ -> false
          end
        end)

      _ ->
        list
    end
  end

  # Serializes an ArtifactAttestation struct to a JSON-safe map.
  @spec serialize_attestation(ArtifactAttestation.t()) :: map()
  defp serialize_attestation(%ArtifactAttestation{} = a) do
    sig_hex =
      if is_binary(a.signature) and byte_size(a.signature) == 64 do
        Base.encode16(a.signature, case: :lower)
      else
        nil
      end

    subjects =
      case a.subject do
        subjects when is_list(subjects) ->
          Enum.map(subjects, fn s ->
            %{
              "name" => Map.get(s, :name) || Map.get(s, "name"),
              "sha256" => Map.get(s, :sha256) || Map.get(s, "sha256")
            }
          end)

        _ ->
          []
      end

    %{
      "agent_id" => a.agent_id,
      "tool_name" => a.tool_name,
      "session_id" => a.session_id,
      "formation_id" => a.formation_id,
      "timestamp" => a.timestamp,
      "subject" => subjects,
      "signature" => sig_hex
    }
  end

  # Fallback for non-struct maps (should not normally occur).
  defp serialize_attestation(other) when is_map(other), do: other

  # Verifies the Ed25519 signature on an ArtifactAttestation.
  @spec verify_attestation_signature(ArtifactAttestation.t()) :: boolean()
  defp verify_attestation_signature(%ArtifactAttestation{signature: sig} = attest)
       when is_binary(sig) and byte_size(sig) == 64 do
    payload = ArtifactAttestation.signing_payload(attest)

    case fetch_public_key() do
      {:ok, pub} -> KeyStore.verify(payload, sig, pub)
      _ -> false
    end
  end

  defp verify_attestation_signature(_), do: false

  # Wraps KeyStore.public_key/0 with a tagged tuple interface.
  # KeyStore returns the raw 32-byte binary directly (not {:ok, _}).
  @spec fetch_public_key() :: {:ok, binary()} | {:error, :unavailable}
  defp fetch_public_key do
    try do
      pub = KeyStore.public_key()
      if is_binary(pub) and byte_size(pub) == 32, do: {:ok, pub}, else: {:error, :unavailable}
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  # Build a signing payload from a raw map for the /verify endpoint.
  # Mirrors the canonical JSON produced by ArtifactAttestation.signing_payload/1.
  @spec build_verify_payload(map()) :: binary()
  defp build_verify_payload(m) do
    subjects =
      (Map.get(m, "subject") || Map.get(m, :subject) || [])
      |> Enum.map(fn s ->
        %{
          "name" => Map.get(s, "name") || Map.get(s, :name),
          "sha256" => Map.get(s, "sha256") || Map.get(s, :sha256)
        }
      end)

    payload_map = %{
      "agent_id" => Map.get(m, "agent_id") || Map.get(m, :agent_id),
      "formation_id" => Map.get(m, "formation_id") || Map.get(m, :formation_id),
      "session_id" => Map.get(m, "session_id") || Map.get(m, :session_id),
      "subject" => subjects,
      "timestamp" => Map.get(m, "timestamp") || Map.get(m, :timestamp),
      "tool_name" => Map.get(m, "tool_name") || Map.get(m, :tool_name)
    }

    Jason.encode!(payload_map, pretty: false)
  end

  @spec validate_sig_length(binary()) :: :ok | {:error, String.t()}
  defp validate_sig_length(sig) when byte_size(sig) == 64, do: :ok
  defp validate_sig_length(_), do: {:error, "signature must be exactly 64 bytes (128 hex chars)"}

  @spec parse_int(any(), integer()) :: integer()
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default
end
