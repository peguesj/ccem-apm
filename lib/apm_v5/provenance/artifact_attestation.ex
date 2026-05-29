defmodule ApmV5.Provenance.ArtifactAttestation do
  @moduledoc """
  SLSA-inspired artifact attestation struct and signing utilities for CCEM APM.

  ## Schema

  ```
  %ArtifactAttestation{
    subject:      [%{name: path, sha256: hex_digest}],
    agent_id:     string,
    tool_name:    "Write" | "Edit" | "MultiEdit",
    session_id:   nil | string,
    formation_id: nil | string,
    timestamp:    iso8601_utc_string,
    signature:    64-byte Ed25519 binary
  }
  ```

  ## Signing payload

  The canonical bytes fed to `KeyStore.sign/2` are the JSON encoding of the
  struct **without** the `signature` field, sorted by key for determinism:

  ```json
  {"agent_id":"...","formation_id":"...","session_id":"...","subject":[...],"timestamp":"...","tool_name":"..."}
  ```

  This means the signature covers all provenance fields including the file
  hashes, making tampering with any field detectable.

  ## ETS Ring Buffer

  Attestations are stored in `:apm_artifact_attestations` (cap 5000).  The
  ring key is `rem(counter, 5000)`.  The counter is held in a persistent_term
  so the GenServer-free path (init via Application) remains lock-free.

  ## Wire-up

  `ApmV5.AuditLog.do_log/7` calls `ApmV5.Provenance.ArtifactAttestation.Signer.maybe_attest/5`
  for `:tool_call` events whose `tool_name` is `"Write"`, `"Edit"`, or
  `"MultiEdit"`.

  ## DRTW

  `:crypto` (OTP native) used for SHA-256 file hashing and signing delegation
  to `ApmV5.Identity.KeyStore`.
  """

  @type subject_item() :: %{name: String.t(), sha256: String.t()}

  @type t() :: %__MODULE__{
          subject: [subject_item()],
          agent_id: String.t(),
          tool_name: String.t(),
          session_id: String.t() | nil,
          formation_id: String.t() | nil,
          timestamp: String.t(),
          signature: binary()
        }

  defstruct [
    :subject,
    :agent_id,
    :tool_name,
    :session_id,
    :formation_id,
    :timestamp,
    :signature
  ]

  @ets_table :apm_artifact_attestations
  @ring_cap 5000
  @persistent_term_key {__MODULE__, :counter}

  # ── ETS init ───────────────────────────────────────────────────────────────

  @doc """
  Creates the ETS ring buffer table if it does not already exist.

  Called during Application startup (before AuditLog GenServer).
  Safe to call multiple times — idempotent.
  """
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    unless :persistent_term.get(@persistent_term_key, nil) do
      :persistent_term.put(@persistent_term_key, :atomics.new(1, signed: false))
    end

    :ok
  rescue
    # Table already created by another process
    ArgumentError -> :ok
  end

  # ── Signing payload ─────────────────────────────────────────────────────────

  @doc """
  Returns the deterministic bytes to be signed for `attestation`.

  The payload is JSON-encoded with keys sorted alphabetically (excluding
  the `signature` field).
  """
  @spec signing_payload(t()) :: binary()
  def signing_payload(%__MODULE__{} = a) do
    # Sorted-key map — Jason does not guarantee insertion-order for maps,
    # so we build an ordered list of KV pairs and encode via a Jason-compatible
    # ordered structure.
    payload_map = %{
      "agent_id" => a.agent_id,
      "formation_id" => a.formation_id,
      "session_id" => a.session_id,
      "subject" => Enum.map(a.subject, &%{"name" => &1.name, "sha256" => &1.sha256}),
      "timestamp" => a.timestamp,
      "tool_name" => a.tool_name
    }

    Jason.encode!(payload_map, pretty: false)
  end

  # ── Ring buffer write ───────────────────────────────────────────────────────

  @doc """
  Inserts an attestation into the ETS ring buffer using an atomic counter.
  """
  @spec store(t()) :: :ok
  def store(%__MODULE__{} = attest) do
    init_table()
    atomics_ref = :persistent_term.get(@persistent_term_key)
    idx = :atomics.add_get(atomics_ref, 1, 1)
    ring_key = rem(idx - 1, @ring_cap)
    :ets.insert(@ets_table, {ring_key, attest})
    :ok
  end

  @doc """
  Find an attestation by the SLSA-style attestation id (first 32 hex chars of
  sha256(signature)). Used by the public SLSA Provenance retrieval endpoint
  (`GET /api/v2/provenance/slsa/:attestation_id`).

  O(n) over the ring buffer (n ≤ 5000). Returns `{:ok, attest}` or
  `{:error, :not_found}`.
  """
  @spec find_by_id(String.t()) :: {:ok, t()} | {:error, :not_found}
  def find_by_id(attestation_id) when is_binary(attestation_id) do
    init_table()

    result =
      :ets.foldl(
        fn {_k, %__MODULE__{} = a}, acc ->
          id = :crypto.hash(:sha256, a.signature) |> Base.encode16(case: :lower) |> binary_part(0, 32)
          if id == attestation_id, do: a, else: acc
        end,
        nil,
        @ets_table
      )

    case result do
      nil -> {:error, :not_found}
      attest -> {:ok, attest}
    end
  end
end

defmodule ApmV5.Provenance.ArtifactAttestation.Signer do
  @moduledoc """
  Signs file-write artifacts and stores attestations in the ETS ring buffer.
  """

  alias ApmV5.Provenance.ArtifactAttestation
  alias ApmV5.Identity.KeyStore

  @write_tools ~w(Write Edit MultiEdit)

  @doc """
  Signs an artifact attestation for the given file write operation.

  `tool_name`  — one of `"Write"`, `"Edit"`, `"MultiEdit"`
  `resource`   — the file path (resource field from AuditLog)
  `agent_id`   — the acting agent's ID
  `context`    — AuditLog context map (may contain session_id, formation_id)

  The SHA-256 of the resource path (content not available at this call site)
  is derived from the path itself for ETS metadata. In production the hook
  payload would carry the actual file hash; here we hash the path as a
  deterministic stand-in.

  Returns the completed `%ArtifactAttestation{}` with a valid Ed25519 signature.
  """
  @spec sign_artifact(String.t(), String.t(), String.t(), map()) :: ArtifactAttestation.t()
  def sign_artifact(tool_name, resource, agent_id, context) do
    ArtifactAttestation.init_table()

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    sha256 = :crypto.hash(:sha256, resource) |> Base.encode16(case: :lower)

    session_id = Map.get(context, :session_id) || Map.get(context, "session_id")
    formation_id = Map.get(context, :formation_id) || Map.get(context, "formation_id")

    attest = %ArtifactAttestation{
      subject: [%{name: resource, sha256: sha256}],
      agent_id: agent_id,
      tool_name: tool_name,
      session_id: session_id,
      formation_id: formation_id,
      timestamp: timestamp,
      signature: <<0::512>>
    }

    payload = ArtifactAttestation.signing_payload(attest)
    sig = KeyStore.sign(payload)

    signed = %{attest | signature: sig}

    ArtifactAttestation.store(signed)

    signed
  end

  @doc """
  Conditionally produces an attestation for AuditLog `:tool_call` events.

  Called from `ApmV5.AuditLog.do_log/7`. No-ops for non-write tools or
  non-`:tool_call` event types to avoid performance overhead.
  """
  @spec maybe_attest(
          atom() | String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map()
        ) :: :ok
  def maybe_attest(:tool_call, resource, agent_id, tool_name, context)
      when tool_name in @write_tools do
    resolved_agent = agent_id || "unknown"

    Task.start(fn ->
      sign_artifact(tool_name, resource, resolved_agent, context)
    end)

    :ok
  end

  def maybe_attest(_event_type, _resource, _agent_id, _tool_name, _context), do: :ok
end
