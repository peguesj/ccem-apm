defmodule Apm.Auth.WebAuthnAttestation do
  @moduledoc """
  FIDO2 / WebAuthn attestation gate for `/api/v2/approvals/:id/approve`
  (auth-v10.3-s1 / CP-298, DRTW `docs/drtw-governance/01-authorization.md` GAP 8).

  ## Why this exists

  Prior to v10.3.0 the approval endpoint accepted any HTTP body — any caller
  in possession of an API token could impersonate a human approver. This
  module enforces a **hardware-bound attestation** (touchID, Windows Hello,
  YubiKey, …) on each approval decision so the act of approving requires
  posession of a physical authenticator that has been previously registered
  to the approver's identity.

  ## Library choice (DRTW)

  Built on top of [`wax_`](https://hex.pm/packages/wax_) `~> 0.7`, the only
  mature Elixir relying-party WebAuthn implementation. `wax_` handles
  registration challenge generation, attestation parsing, and the
  registration ceremony heavy lifting. We layer our own:

    1. ETS-backed credential store (`:webauthn_credentials`)
    2. Replay-protection via monotonic `sign_count` enforcement
    3. Lightweight Ed25519 / ECDSA-P256 assertion verifier used by the
       `verify_assertion/5` fast path. Real-world deployments should delegate
       to `Wax.authenticate/6` once a `Wax.Challenge` is available, but
       the fast path is what the approval HTTP endpoint hits when a fresh
       per-request challenge has already been generated and stored
       server-side.

  ## ETS schema

      :webauthn_credentials
      key:   user_id
      value: [
        %{
          credential_id: binary,
          public_key:    binary,   # raw key material (Ed25519 32B or P-256 65B)
          algorithm:     :ed25519 | :es256,
          sign_count:    non_neg_integer,
          registered_at: iso8601_string
        }
      ]

  ## Replay protection

  Each authenticatorData blob carries a 32-bit big-endian `sign_count`. We
  reject any assertion whose `sign_count` is *less than or equal to* the
  stored value. This is the FIDO-mandated detection of cloned authenticators
  per W3C WebAuthn §6.1.1.
  """

  alias Apm.AuditLog

  @ets_table :webauthn_credentials
  @default_algorithm :ed25519

  @type credential() :: %{
          credential_id: binary(),
          public_key: binary(),
          algorithm: :ed25519 | :es256,
          sign_count: non_neg_integer(),
          registered_at: String.t()
        }

  # ── ETS lifecycle ──────────────────────────────────────────────────────────

  @doc """
  Initialise the credentials ETS table. Called from `Apm.Application` at
  boot. Idempotent.
  """
  @spec init_table() :: :ok
  def init_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Test helper — wipes all credentials. Do not call in production.
  """
  @spec reset!() :: :ok
  def reset! do
    init_table()
    :ets.delete_all_objects(@ets_table)
    :ok
  end

  # ── Registration ───────────────────────────────────────────────────────────

  @doc """
  Generate a fresh registration challenge (delegates to `Wax`). The caller is
  expected to stash the returned `Wax.Challenge` in session state so it can be
  produced again during `register_authenticator/3`.
  """
  @spec new_registration_challenge(keyword()) :: Wax.Challenge.t()
  def new_registration_challenge(opts \\ []) do
    Wax.new_registration_challenge(opts)
  end

  @doc """
  Complete registration of a hardware authenticator. Verifies the attestation
  via `wax_` and persists the resulting credential under `user_id`.

  The `attestation_object` is the raw CBOR bytes returned by
  `navigator.credentials.create()`; `client_data_json_raw` is the literal
  JSON string the browser produced (NOT the parsed object).

  Returns `{:ok, credential}` on success.
  """
  @spec register_authenticator(
          String.t(),
          binary(),
          binary(),
          Wax.Challenge.t()
        ) :: {:ok, credential()} | {:error, term()}
  def register_authenticator(
        user_id,
        attestation_object,
        client_data_json_raw,
        %Wax.Challenge{} = challenge
      ) do
    with {:ok, {auth_data, _attestation_result}} <-
           Wax.register(attestation_object, client_data_json_raw, challenge),
         credential_id when is_binary(credential_id) <-
           auth_data.attested_credential_data.credential_id,
         {algorithm, public_key} <-
           normalize_cose_key(auth_data.attested_credential_data.credential_public_key) do
      :ok = put_credential(user_id, credential_id, public_key, auth_data.sign_count, algorithm)

      AuditLog.log(
        :webauthn_registered,
        user_id,
        "credential:" <> Base.encode16(credential_id, case: :lower),
        %{
          algorithm: algorithm
        }
      )

      {:ok,
       %{
         credential_id: credential_id,
         public_key: public_key,
         algorithm: algorithm,
         sign_count: auth_data.sign_count,
         registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc """
  Persist a credential directly. Used by tests and by the registration path
  after attestation verification. Exposed publicly so an out-of-band
  provisioning flow (e.g. an admin pre-registering a YubiKey) can call it.
  """
  @spec put_credential(String.t(), binary(), binary(), non_neg_integer(), atom()) :: :ok
  def put_credential(
        user_id,
        credential_id,
        public_key,
        sign_count,
        algorithm \\ @default_algorithm
      )
      when is_binary(user_id) and is_binary(credential_id) and is_binary(public_key) do
    init_table()

    new = %{
      credential_id: credential_id,
      public_key: public_key,
      algorithm: algorithm,
      sign_count: sign_count,
      registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    existing =
      case :ets.lookup(@ets_table, user_id) do
        [{^user_id, list}] -> list
        [] -> []
      end

    deduped = Enum.reject(existing, &(&1.credential_id == credential_id))
    :ets.insert(@ets_table, {user_id, [new | deduped]})
    :ok
  end

  @doc """
  List all credentials registered for a user.
  """
  @spec list_credentials(String.t()) :: {:ok, [credential()]}
  def list_credentials(user_id) when is_binary(user_id) do
    init_table()

    case :ets.lookup(@ets_table, user_id) do
      [{^user_id, list}] -> {:ok, list}
      [] -> {:ok, []}
    end
  end

  # ── Assertion verification ─────────────────────────────────────────────────

  @doc """
  Verify a WebAuthn assertion (login ceremony) against a previously-registered
  credential.

  ## Arguments

    * `user_id` — opaque identity string the credential was registered under
    * `credential_id` — raw bytes from the assertion (`response.rawId`)
    * `signature` — raw bytes from `response.signature`
    * `authenticator_data` — raw bytes from `response.authenticatorData`
    * `client_data_json` — raw bytes from `response.clientDataJSON`

  ## Returns

    * `{:ok, %{sign_count: new_count}}`
    * `{:error, :no_credential}` — user has no registered authenticators
    * `{:error, :credential_not_found}` — credential_id does not match any
       record for this user (substitution / phishing attempt)
    * `{:error, :replay_detected}` — sign_count did not strictly increase
    * `{:error, :bad_signature}` — Ed25519/ECDSA verify failed
    * `{:error, :malformed_auth_data}` — auth_data too short to parse
  """
  @spec verify_assertion(String.t(), binary(), binary(), binary(), binary()) ::
          {:ok, %{sign_count: non_neg_integer()}} | {:error, atom()}
  def verify_assertion(user_id, credential_id, signature, authenticator_data, client_data_json)
      when is_binary(user_id) and is_binary(credential_id) do
    with {:ok, creds} <- list_credentials(user_id),
         :ok <- ensure_some(creds),
         {:ok, %{public_key: pk, algorithm: alg, sign_count: stored_count} = cred} <-
           find_credential(creds, credential_id),
         {:ok, new_count} <- parse_sign_count(authenticator_data),
         :ok <- ensure_monotonic(stored_count, new_count),
         :ok <- verify_signature(alg, pk, authenticator_data, client_data_json, signature) do
      bump_sign_count(user_id, cred, new_count)

      AuditLog.log(
        :webauthn_verified,
        user_id,
        "credential:" <> Base.encode16(credential_id, case: :lower),
        %{
          sign_count: new_count
        }
      )

      {:ok, %{sign_count: new_count}}
    end
  end

  # ── Policy gate ────────────────────────────────────────────────────────────

  @doc """
  Returns `true` when the operator has opted into mandatory WebAuthn on
  approval. Default is `false` for backward compatibility — operators turn
  this on after they have provisioned authenticators for all approvers.
  """
  @spec require_webauthn?() :: boolean()
  def require_webauthn? do
    Application.get_env(:apm, :require_webauthn_for_approval, false) == true
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp ensure_some([]), do: {:error, :no_credential}
  defp ensure_some(_), do: :ok

  defp find_credential(creds, credential_id) do
    case Enum.find(creds, &(&1.credential_id == credential_id)) do
      nil -> {:error, :credential_not_found}
      cred -> {:ok, cred}
    end
  end

  defp parse_sign_count(
         <<_rp_id_hash::binary-size(32), _flags::binary-size(1),
           sign_count::unsigned-big-integer-size(32), _rest::binary>>
       ) do
    {:ok, sign_count}
  end

  defp parse_sign_count(_), do: {:error, :malformed_auth_data}

  defp ensure_monotonic(stored, new) when new > stored, do: :ok
  defp ensure_monotonic(_stored, _new), do: {:error, :replay_detected}

  defp verify_signature(:ed25519, public_key, auth_data, client_data_json, signature) do
    client_data_hash = :crypto.hash(:sha256, client_data_json)
    payload = auth_data <> client_data_hash

    if :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp verify_signature(:es256, public_key, auth_data, client_data_json, signature) do
    client_data_hash = :crypto.hash(:sha256, client_data_json)
    payload = auth_data <> client_data_hash

    if :crypto.verify(:ecdsa, :sha256, payload, signature, [public_key, :secp256r1]) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp verify_signature(_alg, _pk, _ad, _cdj, _sig), do: {:error, :unsupported_algorithm}

  defp bump_sign_count(user_id, cred, new_count) do
    updated = %{cred | sign_count: new_count}

    {:ok, all} = list_credentials(user_id)

    new_list =
      Enum.map(all, fn c -> if c.credential_id == cred.credential_id, do: updated, else: c end)

    :ets.insert(@ets_table, {user_id, new_list})
    :ok
  end

  # COSE key normalisation. wax_ returns a `%Wax.CoseKey{}` style map keyed by
  # integer labels per RFC 8152. We extract the raw key bytes for our local
  # store so the verifier can hand them to `:crypto.verify/5` directly.
  defp normalize_cose_key(%{} = cose) do
    cond do
      # Ed25519 (OKP / alg = -8 / crv = Ed25519)
      Map.get(cose, 1) == 1 and Map.get(cose, 3) == -8 ->
        {:ed25519, Map.get(cose, -2)}

      # ECDSA P-256 (EC2 / alg = -7 / crv = P-256). Public key is uncompressed
      # 0x04 || X || Y per SEC1.
      Map.get(cose, 1) == 2 and Map.get(cose, 3) == -7 ->
        x = Map.get(cose, -2)
        y = Map.get(cose, -3)
        {:es256, <<0x04>> <> x <> y}

      true ->
        {@default_algorithm, :erlang.term_to_binary(cose)}
    end
  end

  defp normalize_cose_key(raw) when is_binary(raw), do: {@default_algorithm, raw}
end
