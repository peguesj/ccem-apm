defmodule Apm.Identity.DIDProvider do
  @moduledoc """
  Derives a W3C DID (Decentralized Identifier) from the APM's Ed25519 public key.

  ## DID format: did:key

  The `did:key` method encodes a public key directly in the DID string without
  requiring a registry or on-chain lookup:

  ```
  did:key:z6Mk...
  ```

  Encoding steps:
  1. Prepend the multicodec varint for `ed25519-pub` (0xED 0x01) to the 32-byte
     raw public key.
  2. Base58-encode (Bitcoin alphabet) the resulting 34-byte buffer.
  3. Prepend the multibase prefix `z` (base58btc identifier).
  4. Prepend `did:key:`.

  ## DID Document

  A minimal conformant DID Document is returned with:
  - `@context`: W3C DID v1 + security suites v2
  - `id`: the full `did:key:z6Mk...` string
  - `verificationMethod`: one `Ed25519VerificationKey2020` entry
  - `authentication`: reference to the verification method
  - `assertionMethod`: same reference (for attestation signing)

  ## Caching

  `cached_did/0` memoises the resolved DID in an ETS table on first call.
  The DID is deterministic for a given keypair so the cache never expires.

  ## DRTW

  All encoding is done with OTP stdlib (`:crypto`, `Base`) plus a minimal
  Base58 encoder implemented inline. No `ex_did` hex package needed for
  `did:key` derivation — the algorithm is trivial enough to own directly.
  """

  require Logger

  @ets_cache :apm_did_cache
  @cache_key :resolved_did

  # Bitcoin Base58 alphabet (identical to the base58btc multibase alphabet)
  @base58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  # Multicodec varint for ed25519-pub (0xED 0x01 in LEB-128 unsigned varint)
  @ed25519_multicodec <<0xED, 0x01>>

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Derives a `did:key` DID from a raw 32-byte Ed25519 public key.

  ## Example

      iex> pub = :crypto.strong_rand_bytes(32)
      iex> did = Apm.Identity.DIDProvider.did_for_public_key(pub)
      iex> String.starts_with?(did, "did:key:z6Mk")
      true
  """
  @spec did_for_public_key(binary()) :: String.t()
  def did_for_public_key(pub_key) when is_binary(pub_key) and byte_size(pub_key) == 32 do
    # 1. Prepend multicodec prefix
    payload = @ed25519_multicodec <> pub_key
    # 2. Base58btc encode
    encoded = encode_base58(payload)
    # 3. Multibase prefix "z" = base58btc
    "did:key:z" <> encoded
  end

  @doc """
  Builds a minimal W3C DID Document map for the given DID and public key.

  Returns a plain map suitable for JSON serialization with `Jason.encode!/1`.
  """
  @spec did_document(String.t(), binary()) :: map()
  def did_document(did, pub_key) when is_binary(did) and is_binary(pub_key) do
    vm_id = did <> "#" <> String.replace_prefix(did, "did:key:", "")
    pub_key_multibase = "z" <> encode_base58(pub_key)

    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/ed25519-2020/v1"
      ],
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => vm_id,
          "type" => "Ed25519VerificationKey2020",
          "controller" => did,
          "publicKeyMultibase" => pub_key_multibase
        }
      ],
      "authentication" => [vm_id],
      "assertionMethod" => [vm_id]
    }
  end

  @doc """
  Returns the memoised DID for the running APM instance.

  Derives the DID from `Apm.Identity.KeyStore.public_key/0` on first call,
  then caches it in ETS for zero-cost subsequent lookups.
  """
  @spec cached_did() :: String.t()
  def cached_did do
    ensure_cache_table()

    case :ets.lookup(@ets_cache, @cache_key) do
      [{_, did}] ->
        did

      [] ->
        did = Apm.Identity.KeyStore.public_key() |> did_for_public_key()
        :ets.insert(@ets_cache, {@cache_key, did})
        did
    end
  end

  @doc """
  Returns the full DID Document map for the running APM instance.
  """
  @spec cached_did_document() :: map()
  def cached_did_document do
    pub_key = Apm.Identity.KeyStore.public_key()
    did = did_for_public_key(pub_key)
    did_document(did, pub_key)
  end

  @doc """
  Decodes a Base58btc-encoded binary string.

  Exposed as a public function for test verification of the multicodec prefix.
  """
  @spec decode_base58(String.t()) :: binary()
  def decode_base58(encoded) when is_binary(encoded) do
    encoded
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc ->
      idx = Enum.find_index(@base58_alphabet, &(&1 == char))

      if is_nil(idx) do
        raise ArgumentError, "Invalid Base58 character: #{<<char>>}"
      end

      acc * 58 + idx
    end)
    |> integer_to_binary()
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec encode_base58(binary()) :: String.t()
  defp encode_base58(data) when is_binary(data) do
    # Count leading zero bytes (they map to "1" in Base58)
    leading_zeros =
      data
      |> :binary.bin_to_list()
      |> Enum.take_while(&(&1 == 0))
      |> length()

    prefix = String.duplicate("1", leading_zeros)

    # Convert binary to big integer
    int_val =
      data
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, acc -> acc * 256 + byte end)

    suffix = encode_base58_int(int_val, [])
    prefix <> suffix
  end

  @spec encode_base58_int(non_neg_integer(), [char()]) :: String.t()
  defp encode_base58_int(0, acc), do: IO.iodata_to_binary(acc)

  defp encode_base58_int(n, acc) when n > 0 do
    rem = rem(n, 58)
    encode_base58_int(div(n, 58), [Enum.at(@base58_alphabet, rem) | acc])
  end

  @spec integer_to_binary(non_neg_integer()) :: binary()
  defp integer_to_binary(0), do: <<0>>

  defp integer_to_binary(n) when n > 0 do
    integer_to_binary(n, [])
  end

  defp integer_to_binary(n, acc) when n > 0 do
    integer_to_binary(div(n, 256), [rem(n, 256) | acc])
  end

  defp integer_to_binary(0, acc), do: :erlang.list_to_binary(acc)

  @spec ensure_cache_table() :: :ok
  defp ensure_cache_table do
    if :ets.whereis(@ets_cache) == :undefined do
      :ets.new(@ets_cache, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  rescue
    # Table already created by another process — fine
    ArgumentError -> :ok
  end
end
