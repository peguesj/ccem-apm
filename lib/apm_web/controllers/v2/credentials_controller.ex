defmodule ApmWeb.V2.CredentialsController do
  @moduledoc """
  HTTP endpoints for W3C Verifiable Credential issuance, verification, and revocation.

  ## Endpoints

    * `POST /api/v2/governance/credentials/issue`
      Body: `{credential_subject: {...}, valid_seconds: 3600}`
      Returns: `{jwt: "ey...", credential_id: "urn:uuid:..."}`

    * `POST /api/v2/governance/credentials/verify`
      Body: `{jwt: "ey..."}`
      Returns: `{valid: true, credential: {...}}` or `{valid: false, reason: "..."}`

    * `POST /api/v2/governance/credentials/revoke`
      Body: `{credential_id: "urn:uuid:..."}`
      Returns: `{revoked: true}`

  Spec: CP-300 / comp-v10.3-s2
  """

  use ApmWeb, :controller

  alias Apm.Governance.VerifiableCredential
  alias Apm.Identity.{KeyStore, DIDProvider}

  # ── POST /api/v2/governance/credentials/issue ───────────────────────────────

  @doc """
  Issues a W3C JWT-VC for an agent.

  Resolves the APM's own DID as the issuer. The `agent_id` in `credential_subject`
  is used to derive the subject DID unless an explicit `subject_did` is provided.
  """
  def issue(conn, params) do
    credential_subject = Map.get(params, "credential_subject", %{})
    valid_seconds = params |> Map.get("valid_seconds", 31_536_000) |> parse_integer()

    # Resolve subject DID from agent_id or explicit did field
    agent_id = Map.get(credential_subject, "agent_id", "unknown")

    subject_did =
      case Map.get(credential_subject, "subject_did") do
        nil ->
          # Derive a stable DID from the agent_id by hashing it into a key-like binary.
          # In production this would come from the agent's registered DID; for now
          # we use the APM's own public key prefixed with the agent_id hash so each
          # agent gets a distinct DID fragment while remaining verifiable.
          pub = KeyStore.public_key()
          agent_seed = :crypto.hash(:sha256, agent_id <> pub) |> binary_part(0, 32)
          DIDProvider.did_for_public_key(agent_seed)

        did ->
          did
      end

    agent_identity = %{did: subject_did, agent_id: agent_id}
    subject = Map.delete(credential_subject, "subject_did")

    jwt =
      VerifiableCredential.issue_agent_credential(agent_identity, subject,
        valid_seconds: valid_seconds
      )

    # Extract credential_id from the issued JWT for convenience
    credential_id = extract_credential_id(jwt)

    json(conn, %{jwt: jwt, credential_id: credential_id})
  end

  # ── POST /api/v2/governance/credentials/verify ─────────────────────────────

  @doc """
  Verifies a JWT-VC string. Returns validity flag, credential document, and
  optional reason on failure.
  """
  def verify(conn, %{"jwt" => jwt}) when is_binary(jwt) do
    case VerifiableCredential.verify_credential(jwt) do
      {:ok, vc_doc} ->
        json(conn, %{valid: true, credential: vc_doc})

      {:error, reason} ->
        json(conn, %{valid: false, credential: nil, reason: to_string(reason)})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing required field: jwt"})
  end

  # ── POST /api/v2/governance/credentials/revoke ─────────────────────────────

  @doc """
  Revokes a credential by its ID.
  """
  def revoke(conn, %{"credential_id" => credential_id}) when is_binary(credential_id) do
    :ok = VerifiableCredential.revoke_credential(credential_id)
    json(conn, %{revoked: true, credential_id: credential_id})
  end

  def revoke(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing required field: credential_id"})
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec extract_credential_id(binary()) :: String.t() | nil
  defp extract_credential_id(jwt) do
    case String.split(jwt, ".") do
      [_, payload_b64 | _] ->
        with {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, payload} <- Jason.decode(json),
             %{"vc" => %{"id" => cred_id}} <- payload do
          cred_id
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec parse_integer(any()) :: integer()
  defp parse_integer(n) when is_integer(n), do: n
  defp parse_integer(s) when is_binary(s), do: String.to_integer(s)
  defp parse_integer(_), do: 31_536_000
end
