defmodule Apm.Provenance.SLSAProvenance do
  @moduledoc """
  SLSA Provenance v1.0 generator + DSSE envelope signer
  (comp-v10.3-s1 / CP-299, DRTW `docs/drtw-governance/08-provenance.md`).

  ## What this produces

  Given an `Apm.Provenance.ArtifactAttestation` (signed by `KeyStore` at the
  time of a `Write`/`Edit`/`MultiEdit` tool call), this module emits two
  artefacts:

    1. A canonical **in-toto Statement v1** carrying the SLSA Provenance v1
       predicate (`from_attestation/1`).
    2. A **DSSE envelope** (RFC-style PAE + Ed25519 signature) wrapping that
       statement (`sign/1`). DSSE is the in-toto-mandated signing envelope.

  ## In-toto Statement shape

      {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": "lib/foo.ex", "digest": {"sha256": "…"}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
          "buildDefinition": {
            "buildType": "https://ccem.dev/provenance/tool-call/v1",
            "externalParameters": {"tool": "Write", "path": "lib/foo.ex"},
            "internalParameters": {"agent_id":…, "session_id":…, "formation_id":…}
          },
          "runDetails": {
            "builder": {"id": "https://ccem.dev/apm/v10.3.0"},
            "metadata": {
              "invocationId": "<hex>",
              "startedOn": "<iso8601>",
              "finishedOn": "<iso8601>"
            }
          }
        }
      }

  ## DSSE envelope shape

      {
        "payloadType": "application/vnd.in-toto+json",
        "payload":     "<base64(statement_json)>",
        "signatures":  [{"keyid": "<hex>", "sig": "<base64(signature)>"}]
      }

  The signature covers `PAE(payloadType, payload)` — NOT the raw payload —
  per the DSSE spec. PAE is:

      "DSSEv1" SP <len(payloadType)> SP payloadType SP <len(payload)> SP payload

  ## DRTW

  Uses `KeyStore` (Ed25519 from `:crypto`, already in tree) for signing.
  No new external crypto dependency.
  """

  alias Apm.Provenance.ArtifactAttestation
  alias Apm.Identity.KeyStore

  @builder_id "https://ccem.dev/apm/v10.3.0"
  @build_type "https://ccem.dev/provenance/tool-call/v1"
  @predicate_type "https://slsa.dev/provenance/v1"
  @payload_type "application/vnd.in-toto+json"

  @type statement() :: map()
  @type envelope() :: %{
          required(String.t()) => term()
        }

  # ── Statement generation ───────────────────────────────────────────────────

  @doc """
  Convert an `ArtifactAttestation` into a canonical SLSA Provenance v1
  in-toto Statement.
  """
  @spec from_attestation(ArtifactAttestation.t()) :: statement()
  def from_attestation(%ArtifactAttestation{} = a) do
    %{
      "_type" => "https://in-toto.io/Statement/v1",
      "subject" => Enum.map(a.subject, &subject_to_in_toto/1),
      "predicateType" => @predicate_type,
      "predicate" => %{
        "buildDefinition" => %{
          "buildType" => @build_type,
          "externalParameters" => external_params(a),
          "internalParameters" => internal_params(a)
        },
        "runDetails" => %{
          "builder" => %{"id" => @builder_id},
          "metadata" => %{
            "invocationId" => attestation_id(a),
            "startedOn" => a.timestamp,
            "finishedOn" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      }
    }
  end

  defp subject_to_in_toto(%{name: name, sha256: sha}),
    do: %{"name" => name, "digest" => %{"sha256" => sha}}

  defp external_params(%ArtifactAttestation{tool_name: tool, subject: [%{name: path} | _]}),
    do: %{"tool" => tool, "path" => path}

  defp external_params(%ArtifactAttestation{tool_name: tool}),
    do: %{"tool" => tool}

  defp internal_params(%ArtifactAttestation{} = a) do
    %{
      "agent_id" => a.agent_id,
      "session_id" => a.session_id,
      "formation_id" => a.formation_id
    }
  end

  @doc """
  Deterministic attestation id derived from the signature. Used as the
  `invocationId` in SLSA metadata and as the URL parameter on the public
  retrieval endpoint.

  Two distinct signatures produce distinct ids; the same signature
  reproduces the same id (idempotent on retrieval).
  """
  @spec attestation_id(ArtifactAttestation.t()) :: String.t()
  def attestation_id(%ArtifactAttestation{signature: sig}) when is_binary(sig) do
    :crypto.hash(:sha256, sig) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  # ── DSSE envelope ──────────────────────────────────────────────────────────

  @doc """
  Build a DSSE envelope around the SLSA Statement derived from `attest`.

  Signature is produced by `KeyStore.sign/2` over the DSSE PAE bytes.
  """
  @spec sign(ArtifactAttestation.t()) :: envelope()
  def sign(%ArtifactAttestation{} = attest) do
    statement_json = attest |> from_attestation() |> Jason.encode!()
    payload_b64 = Base.encode64(statement_json)
    pae_bytes = pae(@payload_type, statement_json)
    signature = KeyStore.sign(pae_bytes)
    keyid = key_fingerprint()

    %{
      "payloadType" => @payload_type,
      "payload" => payload_b64,
      "signatures" => [
        %{"keyid" => keyid, "sig" => Base.encode64(signature)}
      ]
    }
  end

  @doc """
  Verify a DSSE envelope produced by `sign/1`.

  Returns `:ok` on success or `{:error, :bad_signature}` if PAE-over-payload
  does not match the signature.
  """
  @spec verify(envelope()) :: :ok | {:error, :bad_signature | :malformed_envelope}
  def verify(%{} = envelope) do
    with %{"payloadType" => pt, "payload" => payload_b64, "signatures" => [sig | _]} <- envelope,
         {:ok, payload_bin} <- Base.decode64(payload_b64),
         {:ok, sig_bin} <- Base.decode64(sig["sig"]) do
      pae_bytes = pae(pt, payload_bin)
      pub = KeyStore.public_key()

      if KeyStore.verify(pae_bytes, sig_bin, pub),
        do: :ok,
        else: {:error, :bad_signature}
    else
      _ -> {:error, :malformed_envelope}
    end
  end

  @doc """
  DSSE pre-authentication encoding (PAE):

      "DSSEv1" SP <len(payloadType)> SP payloadType SP <len(payload)> SP payload

  Lengths are decimal-encoded byte sizes. Exposed publicly so tests can
  cross-check bit-for-bit against the spec.
  """
  @spec pae(String.t(), binary()) :: binary()
  def pae(payload_type, payload) when is_binary(payload_type) and is_binary(payload) do
    "DSSEv1 #{byte_size(payload_type)} #{payload_type} #{byte_size(payload)} #{payload}"
  end

  defp key_fingerprint do
    KeyStore.public_key()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
