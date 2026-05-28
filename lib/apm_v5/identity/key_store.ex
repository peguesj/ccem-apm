defmodule ApmV5.Identity.KeyStore do
  @moduledoc """
  GenServer that owns the APM's Ed25519 signing identity.

  ## Lifecycle

  On `init/1` the store:
  1. Ensures `~/.claude/ccem/apm/keys/` exists.
  2. Attempts to load an existing PEM file at `key_file` (default:
     `~/.claude/ccem/apm/keys/apm_{env}.pem`).
  3. If the file does not exist, generates a fresh Ed25519 keypair via
     `:crypto.generate_key(:eddsa, :ed25519)` (OTP native — zero new deps)
     and persists it as a custom PEM bundle.

  ## Key persistence format

  The PEM file is a plain-text file with two sections separated by a blank line:

  ```
  PUBLIC_KEY:<base64>
  PRIVATE_KEY:<base64>
  ```

  This keeps the implementation dependency-free (no `:public_key` ASN.1 codec
  required for Ed25519 in OTP < 25, which lacks native OKP PEM support).

  ## Public API

  - `public_key/1` — returns the 32-byte raw Ed25519 public key.
  - `sign/2`       — signs an arbitrary binary payload; returns 64-byte signature.
  - `verify/4`     — verifies a signature against a payload and public key.

  ## Supervision

  Registered under `ApmV5.Identity.KeyStore` by default (overridable via
  `name:` option) and wired into `ApmV5.Application`.

  ## DRTW

  `:crypto` (OTP native) is used throughout — no additional hex packages needed
  for Ed25519 keypair generation or signing (as documented in
  `docs/drtw-governance/08-provenance.md`).
  """

  use GenServer

  require Logger

  @default_key_dir Path.expand("~/.claude/ccem/apm/keys")

  # ── Client API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the 32-byte raw Ed25519 public key for this APM instance.
  """
  @spec public_key(GenServer.server()) :: binary()
  def public_key(server \\ __MODULE__) do
    GenServer.call(server, :public_key)
  end

  @doc """
  Signs `payload` using the APM's Ed25519 private key.

  Returns a 64-byte raw signature binary.
  """
  @spec sign(GenServer.server(), binary()) :: binary()
  def sign(server \\ __MODULE__, payload) when is_binary(payload) do
    GenServer.call(server, {:sign, payload})
  end

  @doc """
  Verifies `signature` over `payload` using `public_key`.

  Returns `true` when the signature is valid, `false` otherwise.
  Pure function — delegates to `:crypto` with no GenServer state used.
  The `server` argument is accepted for API symmetry; the actual crypto
  verification is stateless.
  """
  @spec verify(GenServer.server(), binary(), binary(), binary()) :: boolean()
  def verify(_server \\ __MODULE__, payload, signature, public_key)
      when is_binary(payload) and is_binary(signature) and is_binary(public_key) do
    try do
      :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
    rescue
      _ -> false
    end
  end

  # ── Server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    key_file = resolve_key_file(opts)
    :ok = File.mkdir_p!(Path.dirname(key_file))

    {pub, priv} = load_or_generate(key_file)

    Logger.info(
      "[KeyStore] Ed25519 identity loaded — pub=#{Base.encode16(pub, case: :lower) |> binary_part(0, 16)}… key_file=#{key_file}"
    )

    {:ok, %{public_key: pub, private_key: priv, key_file: key_file}}
  end

  @impl true
  def handle_call(:public_key, _from, state) do
    {:reply, state.public_key, state}
  end

  @impl true
  def handle_call({:sign, payload}, _from, state) do
    sig = :crypto.sign(:eddsa, :none, payload, [state.private_key, :ed25519])
    {:reply, sig, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec resolve_key_file(keyword()) :: Path.t()
  defp resolve_key_file(opts) do
    case Keyword.get(opts, :key_file) do
      nil ->
        env = Application.get_env(:apm_v5, :env, Mix.env() |> to_string())
        Path.join(@default_key_dir, "apm_#{env}.pem")

      path ->
        Path.expand(path)
    end
  end

  @spec load_or_generate(Path.t()) :: {binary(), binary()}
  defp load_or_generate(key_file) do
    case load_pem(key_file) do
      {:ok, pub, priv} ->
        Logger.debug("[KeyStore] Loaded existing Ed25519 keypair from #{key_file}")
        {pub, priv}

      :error ->
        Logger.info("[KeyStore] No keypair found at #{key_file} — generating new Ed25519 keypair")
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        :ok = write_pem(key_file, pub, priv)
        {pub, priv}
    end
  end

  # Reads the custom PEM bundle and returns `{:ok, pub_bytes, priv_bytes}` or `:error`.
  @spec load_pem(Path.t()) :: {:ok, binary(), binary()} | :error
  defp load_pem(path) do
    with {:ok, content} <- File.read(path),
         [pub_line, priv_line | _] <- String.split(String.trim(content), "\n"),
         {"PUBLIC_KEY:", pub_b64} <- split_kv(pub_line),
         {"PRIVATE_KEY:", priv_b64} <- split_kv(priv_line),
         {:ok, pub} <- Base.decode64(String.trim(pub_b64)),
         {:ok, priv} <- Base.decode64(String.trim(priv_b64)) do
      {:ok, pub, priv}
    else
      _ -> :error
    end
  end

  # Writes the custom PEM bundle. File mode 0600 — owner read/write only.
  @spec write_pem(Path.t(), binary(), binary()) :: :ok
  defp write_pem(path, pub, priv) do
    content =
      "PUBLIC_KEY:#{Base.encode64(pub)}\nPRIVATE_KEY:#{Base.encode64(priv)}\n"

    File.write!(path, content)
    File.chmod!(path, 0o600)
    :ok
  end

  @spec split_kv(String.t()) :: {String.t(), String.t()} | :error
  defp split_kv(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> {key <> ":", value}
      _ -> :error
    end
  end
end
