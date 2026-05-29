defmodule ApmV5Web.V2.IdentityController do
  @moduledoc """
  REST API controller for APM cryptographic identity endpoints.

  ## Endpoints

  - `GET /api/v2/identity/did-document` — returns the APM's W3C DID Document (JSON-LD)
  - `GET /api/v2/identity/jwks` — RFC 7517 JWK Set for the APM's Ed25519 signing key
  - `GET /.well-known/jwks.json` — RFC 8615 well-known alias of the above
  """

  use ApmV5Web, :controller

  alias ApmV5.Identity.{DIDProvider, KeyStore}

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

  # ── GET /api/v2/identity/jwks (CP-302) ─────────────────────────────────────
  # ── GET /.well-known/jwks.json — RFC 8615 alias ────────────────────────────

  @doc """
  Returns a JWK Set containing the APM's Ed25519 public signing key.

  Per RFC 8037, Ed25519 keys are encoded as Octet Key Pair (OKP) JWKs with
  `kty: "OKP"`, `crv: "Ed25519"`, and the raw 32-byte public key
  base64url-encoded as `x`. The `kid` is the SHA-256 thumbprint of the
  canonical JWK (RFC 7638), truncated to the first 16 base64url chars for
  brevity.

  This endpoint is the public-key counterpart to the JWT Bearer Assertion
  tokens issued by `ApmV5.Auth.JwtAssertion` (RFC 7523, CP-287). External
  verifiers fetch this JWKS to validate signatures without needing the
  private key.
  """
  @spec jwks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def jwks(conn, _params) do
    pubkey = KeyStore.public_key()
    x_b64 = Base.url_encode64(pubkey, padding: false)

    canonical = %{"crv" => "Ed25519", "kty" => "OKP", "x" => x_b64}
    thumbprint = :crypto.hash(:sha256, Jason.encode!(canonical))
    kid = thumbprint |> Base.url_encode64(padding: false) |> binary_part(0, 16)

    jwk = %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => x_b64,
      "kid" => kid,
      "use" => "sig",
      "alg" => "EdDSA"
    }

    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(%{"keys" => [jwk]})
  end
end
