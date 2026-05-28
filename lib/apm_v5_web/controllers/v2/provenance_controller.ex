defmodule ApmV5Web.V2.ProvenanceController do
  @moduledoc """
  SLSA Provenance v1.0 retrieval endpoint
  (comp-v10.3-s1 / CP-299, DRTW 08-provenance.md).

  ## Endpoint

      GET /api/v2/provenance/slsa/:attestation_id

  Returns a DSSE envelope wrapping the in-toto Statement that carries the
  SLSA Provenance v1 predicate for a given artefact write. The envelope is
  signed with the APM KeyStore key; callers can verify with
  `ApmV5.Provenance.SLSAProvenance.verify/1` or any DSSE-aware tool
  (e.g. `cosign verify-blob --type slsaprovenance`).

  ## Responses

    * 200 — DSSE envelope JSON
    * 404 — no attestation with that id is in the ring buffer
  """

  use ApmV5Web, :controller

  alias ApmV5.Provenance.{ArtifactAttestation, SLSAProvenance}

  def show(conn, %{"attestation_id" => attestation_id}) do
    case ArtifactAttestation.find_by_id(attestation_id) do
      {:ok, attest} ->
        envelope = SLSAProvenance.sign(attest)
        json(conn, envelope)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "attestation not found", attestation_id: attestation_id})
    end
  end
end
