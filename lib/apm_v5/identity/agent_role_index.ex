defmodule ApmV5.Identity.AgentRoleIndex do
  @moduledoc """
  GenServer + ETS index that assigns a deterministic UUID v5 `agent_role_id`
  to each `{role, normalized_formation_pattern}` pair.

  ## Motivation

  Agents with the same *role* in the same *type* of formation (e.g. "squad-lead"
  in any "my-feature" formation run) share a stable `agent_role_id` across
  independent sessions. This allows lineage graphs to link the same logical
  agent across time without requiring a shared identity server.

  ## Normalization

  Timestamps are stripped from formation IDs before keying:

  ```
  "formation-20260101-my-feature"  → "formation-my-feature"
  "formation-20260101-120000-sprint" → "formation-sprint"
  ```

  The stripping regex removes 8-digit (YYYYMMDD) and 6-digit (HHMMSS) segments
  preceded/followed by hyphens.

  ## UUID v5 derivation

  We derive a deterministic UUID v5 using SHA-1 (OTP `:crypto.hash(:sha, …)`)
  over a CCEM namespace UUID + the canonical key string, then format the bytes
  as a standard UUID string. No `elixir_uuid` or `uuid` hex package is needed.

  CCEM namespace UUID (version 5, random): `6ba7b814-9dad-11d1-80b4-00c04fd430c8`
  (the standard DNS namespace from RFC 4122 § Appendix C, re-used here as a
  stable CCEM namespace — sufficient for determinism within this system).

  ## ETS table

  `:apm_agent_roles` — `{role, normalized_formation_pattern}` → `agent_role_id`

  Secondary index `:apm_agent_role_appearances` — `role` → `[{role_id, formation_id, touched_at}]`

  ## DRTW

  Uses OTP native `:crypto.hash(:sha, …)` for UUID v5. No additional hex deps.
  Documented in `docs/drtw-governance/08-provenance.md`.
  """

  use GenServer

  import Bitwise

  require Logger

  @roles_table :apm_agent_roles
  @appearances_table :apm_agent_role_appearances

  # RFC 4122 DNS namespace bytes — used as CCEM namespace for UUID v5
  # "6ba7b814-9dad-11d1-80b4-00c04fd430c8"
  @namespace_bytes <<0x6B, 0xA7, 0xB8, 0x14, 0x9D, 0xAD, 0x11, 0xD1, 0x80, 0xB4, 0x00, 0xC0,
                     0x4F, 0xD4, 0x30, 0xC8>>

  # Regex to strip 8-digit (YYYYMMDD) and 6-digit (HHMMSS) timestamp-like
  # numeric segments that appear between hyphens in formation IDs.
  @timestamp_pattern ~r/-\d{8}(?:-\d{6})?/

  # ── Client API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records that `role` was seen in `formation_id`.

  Returns `{:ok, agent_role_id}` where `agent_role_id` is a deterministic
  UUID v5 derived from `{role, normalize_formation_id(formation_id)}`.

  Calling `touch/2` multiple times with the same logical role+formation is
  idempotent — the role_id is always identical.
  """
  @spec touch(String.t(), String.t()) :: {:ok, String.t()}
  def touch(role, formation_id) when is_binary(role) and is_binary(formation_id) do
    normalized = normalize_formation_id(formation_id)
    role_id = derive_role_id(role, normalized)
    GenServer.call(__MODULE__, {:touch, role, formation_id, normalized, role_id})
  end

  @doc """
  Returns all recorded appearances for the given `role`.

  Each appearance is a map with keys `:role_id`, `:formation_id`, `:touched_at`.
  """
  @spec role_appearances(String.t()) :: [map()]
  def role_appearances(role) when is_binary(role) do
    case :ets.lookup(@appearances_table, role) do
      [{^role, appearances}] -> appearances
      [] -> []
    end
  end

  @doc """
  Normalizes a `formation_id` by stripping timestamp segments.

  ## Examples

      iex> ApmV5.Identity.AgentRoleIndex.normalize_formation_id("formation-20260101-my-feature")
      "formation-my-feature"

      iex> ApmV5.Identity.AgentRoleIndex.normalize_formation_id("formation-my-feature")
      "formation-my-feature"
  """
  @spec normalize_formation_id(String.t()) :: String.t()
  def normalize_formation_id(formation_id) when is_binary(formation_id) do
    Regex.replace(@timestamp_pattern, formation_id, "")
  end

  @doc """
  Clears all ETS state. Test-only.
  """
  @spec clear_for_test() :: :ok
  def clear_for_test do
    if Mix.env() == :test do
      :ets.delete_all_objects(@roles_table)
      :ets.delete_all_objects(@appearances_table)
      :ok
    else
      {:error, :not_allowed_in_production}
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_tables()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:touch, role, formation_id, normalized, role_id}, _from, state) do
    # Upsert roles table: {role, normalized} → role_id
    :ets.insert(@roles_table, {{role, normalized}, role_id})

    # Append to appearances — deduplicate by formation_id
    existing =
      case :ets.lookup(@appearances_table, role) do
        [{^role, list}] -> list
        [] -> []
      end

    already_present? = Enum.any?(existing, &(Map.get(&1, :formation_id) == formation_id))

    updated =
      if already_present? do
        existing
      else
        appearance = %{
          role_id: role_id,
          formation_id: formation_id,
          normalized_formation: normalized,
          touched_at: DateTime.to_iso8601(DateTime.utc_now())
        }

        [appearance | existing]
      end

    :ets.insert(@appearances_table, {role, updated})

    {:reply, {:ok, role_id}, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Derives a UUID v5 from namespace + "role:normalized_formation".
  @spec derive_role_id(String.t(), String.t()) :: String.t()
  defp derive_role_id(role, normalized_formation) do
    name = "#{role}:#{normalized_formation}"
    sha_bytes = :crypto.hash(:sha, @namespace_bytes <> name)
    # Take first 16 bytes of SHA-1 (SHA-1 produces 20 bytes)
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, _rest::binary>> =
      sha_bytes

    # Set UUID version to 5 (0101xxxx in byte 6)
    b6_v5 = b6 &&& 0x0F ||| 0x50
    # Set UUID variant to 10xxxxxx in byte 8
    b8_variant = b8 &&& 0x3F ||| 0x80

    format_uuid(b0, b1, b2, b3, b4, b5, b6_v5, b7, b8_variant, b9, b10, b11, b12, b13, b14, b15)
  end

  @spec format_uuid(
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte(),
          byte()
        ) :: String.t()
  defp format_uuid(b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15) do
    hex = fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase() end

    "#{hex.(b0)}#{hex.(b1)}#{hex.(b2)}#{hex.(b3)}" <>
      "-#{hex.(b4)}#{hex.(b5)}" <>
      "-#{hex.(b6)}#{hex.(b7)}" <>
      "-#{hex.(b8)}#{hex.(b9)}" <>
      "-#{hex.(b10)}#{hex.(b11)}#{hex.(b12)}#{hex.(b13)}#{hex.(b14)}#{hex.(b15)}"
  end

  @spec ensure_tables() :: :ok
  defp ensure_tables do
    for {name, opts} <- [
          {@roles_table, [:set, :named_table, :public, read_concurrency: true]},
          {@appearances_table, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      case :ets.whereis(name) do
        :undefined ->
          :ets.new(name, opts)

        _ ->
          :ok
      end
    end

    :ok
  end
end
