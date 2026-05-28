defmodule ApmV5Web.V2.IdentityController do
  @moduledoc """
  REST API controller for APM cryptographic identity endpoints.

  ## Endpoints

  - `GET /api/v2/identity/did-document` — returns the APM's W3C DID Document (JSON-LD)
  """

  use ApmV5Web, :controller

  alias ApmV5.Identity.DIDProvider

  # ── GET /api/v2/identity/did-document ──────────────────────────────────────

  @doc """
  Returns the APM instance's W3C DID Document in JSON-LD format.

  The DID is derived from the Ed25519 public key managed by
  `ApmV5.Identity.KeyStore`. The document is stable for the lifetime of the
  key file and is cached after the first derivation.

  ## Response schema

  ```json
  {
    "@context": ["https://www.w3.org/ns/did/v1", "..."],
    "id": "did:key:z6Mk...",
    "verificationMethod": [
      {
        "id": "did:key:z6Mk...#z6Mk...",
        "type": "Ed25519VerificationKey2020",
        "controller": "did:key:z6Mk...",
        "publicKeyMultibase": "z..."
      }
    ],
    "authentication": ["did:key:z6Mk...#z6Mk..."],
    "assertionMethod": ["did:key:z6Mk...#z6Mk..."]
  }
  ```
  """
  @spec did_document(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def did_document(conn, _params) do
    doc = DIDProvider.cached_did_document()
    json(conn, doc)
  end
end
