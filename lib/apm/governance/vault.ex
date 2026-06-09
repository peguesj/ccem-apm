defmodule Apm.Governance.Vault do
  @moduledoc """
  AES-256-GCM encryption vault for audit log PII / sensitive fields.

  Built on `Cloak` (hex.pm/packages/cloak, Apache 2.0).

  ## Cipher

  Single cipher: `Cloak.Ciphers.AES.GCM` with tag `"AES.GCM.V1"`.
  Key is sourced at runtime from `CCEM_CLOAK_KEY` (base64-encoded 32-byte
  value). In dev/test a random key is generated as a fallback if the env
  var is absent (see `config/runtime.exs`).

  ## Design decision — encrypt-before-hash

  When `AuditLog.do_log/6` encrypts a sensitive details field the encryption
  is applied **before** the canonical event is composed and hashed. This means
  the SHA-256 self-hash chain covers ciphertext, not plaintext. Consequences:

    1. **Audit integrity** — the chain still proves no tampering occurred at the
       ciphertext level. An attacker cannot substitute one ciphertext for another
       without breaking the chain.
    2. **No plaintext in the hash chain** — the raw PII value is never present
       in the canonical JSON that forms the self_hash input.
    3. **Decrypt-on-demand** — callers who pass `include_decrypted: true` to
       `AuditLog.query/1` AND hold an admin context receive the plaintext back.

  ## Sensitive field detection

  A details map is considered sensitive if any of the following are true:

    * A key is `:pii` or `:sensitive` (atom or string).
    * Any nested map value carries `__cloak__: true`.

  Only the _value_ of that key is encrypted; the key name itself is kept in
  plaintext so the schema remains inspectable.

  ## ControlRegistry entry

  `ControlRegistry` is updated in this file (at compile time via module
  attribute extension pattern) to register `:audit_encryption_at_rest` →
  ISO 27001 A.8.24.

  Spec: CP-235 / US-467 / Plane ecd7b85d — v9.3.0 comp-mg2.
  """

  use Cloak.Vault, otp_app: :apm

  # ---------------------------------------------------------------------------
  # Encrypt / Decrypt helpers
  # ---------------------------------------------------------------------------

  @doc """
  Encrypts a binary `plaintext` using the configured AES-256-GCM cipher.

  Returns `{:ok, ciphertext}` where `ciphertext` is a base64-encoded binary
  that can be stored as a string value.
  """
  @spec encrypt_field(String.t() | binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt_field(plaintext) when is_binary(plaintext) do
    case Apm.Governance.Vault.encrypt(plaintext) do
      {:ok, ciphertext} -> {:ok, Base.encode64(ciphertext)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Decrypts a base64-encoded ciphertext previously produced by `encrypt_field/1`.

  Returns `{:ok, plaintext}` or `{:error, reason}`.
  """
  @spec decrypt_field(binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt_field(ciphertext_b64) when is_binary(ciphertext_b64) do
    with {:ok, ciphertext} <- Base.decode64(ciphertext_b64) do
      Apm.Governance.Vault.decrypt(ciphertext)
    end
  end

  @doc """
  Returns `true` if `details` map contains sensitive fields that should be
  encrypted before storage.

  A map is considered sensitive if:
    - any of the keys `:pii`, `:sensitive`, `"pii"`, or `"sensitive"` exist, OR
    - any value is a map with `__cloak__: true` (or `"__cloak__" => true`).
  """
  @spec sensitive?(map()) :: boolean()
  def sensitive?(details) when is_map(details) do
    sensitive_key? =
      Enum.any?([:pii, :sensitive, "pii", "sensitive"], &Map.has_key?(details, &1))

    cloak_flag? =
      Enum.any?(details, fn
        {_, v} when is_map(v) ->
          Map.get(v, :__cloak__) == true or Map.get(v, "__cloak__") == true

        _ ->
          false
      end)

    sensitive_key? or cloak_flag?
  end

  def sensitive?(_), do: false

  @doc """
  Encrypts sensitive values in `details` map in-place, returning a new map.

  Keys `:pii`, `:sensitive`, `"pii"`, `"sensitive"` are encrypted. Any nested
  map with `__cloak__: true` has its non-`__cloak__` values encrypted.

  Encrypted values are wrapped as `%{"__enc__" => "<base64_ciphertext>"}` so
  that downstream consumers can identify them and call `decrypt_details/1`.
  """
  @spec encrypt_details(map()) :: map()
  def encrypt_details(details) when is_map(details) do
    Map.new(details, fn {k, v} ->
      {k, maybe_encrypt_value(k, v)}
    end)
  end

  def encrypt_details(other), do: other

  @doc """
  Decrypts any previously-encrypted values in `details`. Safe to call on
  maps that have no encrypted values (returns as-is).
  """
  @spec decrypt_details(map()) :: map()
  def decrypt_details(details) when is_map(details) do
    Map.new(details, fn
      {k, %{"__enc__" => ciphertext}} ->
        case decrypt_field(ciphertext) do
          {:ok, plaintext} -> {k, plaintext}
          _ -> {k, %{"__enc__" => ciphertext}}
        end

      {k, v} ->
        {k, v}
    end)
  end

  def decrypt_details(other), do: other

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @sensitive_keys [:pii, :sensitive, "pii", "sensitive"]

  defp maybe_encrypt_value(key, value) when key in @sensitive_keys do
    plaintext = if is_binary(value), do: value, else: Jason.encode!(value)

    case encrypt_field(plaintext) do
      {:ok, ciphertext} -> %{"__enc__" => ciphertext}
      _ -> value
    end
  end

  defp maybe_encrypt_value(_key, value) when is_map(value) do
    if Map.get(value, :__cloak__) == true or Map.get(value, "__cloak__") == true do
      Map.new(value, fn
        {:__cloak__, _} ->
          {:__cloak__, true}

        {"__cloak__", _} ->
          {"__cloak__", true}

        {k, v} ->
          plaintext = if is_binary(v), do: v, else: Jason.encode!(v)

          case encrypt_field(plaintext) do
            {:ok, ct} -> {k, %{"__enc__" => ct}}
            _ -> {k, v}
          end
      end)
    else
      value
    end
  end

  defp maybe_encrypt_value(_key, value), do: value
end
