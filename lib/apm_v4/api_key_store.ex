defmodule ApmV4.ApiKeyStore do
  @moduledoc """
  GenServer backed by ETS for API key management.
  Keys are persisted to apm_config.json under `api_auth.keys[]`.
  """

  use GenServer

  @table :apm_api_keys

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Generates a new `apm_` prefixed API key with the given label."
  @spec generate_key(String.t()) :: {:ok, String.t()}
  def generate_key(label) do
    GenServer.call(__MODULE__, {:generate_key, label})
  end

  @doc "Revokes an API key."
  @spec revoke_key(String.t()) :: :ok
  def revoke_key(key) do
    GenServer.call(__MODULE__, {:revoke_key, key})
  end

  @doc "Checks if a key is valid."
  @spec valid_key?(String.t()) :: boolean()
  def valid_key?(key) do
    :ets.lookup(@table, key) != []
  end

  @doc "Lists all keys with the key value masked (showing only last 4 chars)."
  @spec list_keys() :: [map()]
  def list_keys do
    GenServer.call(__MODULE__, :list_keys)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    load_keys_from_config()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:generate_key, label}, _from, state) do
    key = "apm_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    created_at = DateTime.utc_now() |> DateTime.to_iso8601()

    :ets.insert(@table, {key, %{label: label, created_at: created_at}})
    persist_keys()

    {:reply, {:ok, key}, state}
  end

  def handle_call({:revoke_key, key}, _from, state) do
    :ets.delete(@table, key)
    persist_keys()
    {:reply, :ok, state}
  end

  def handle_call(:list_keys, _from, state) do
    keys =
      :ets.tab2list(@table)
      |> Enum.map(fn {key, meta} ->
        masked = String.duplicate("*", max(String.length(key) - 4, 0)) <> String.slice(key, -4..-1//1)
        %{key: masked, label: meta.label, created_at: meta.created_at}
      end)

    {:reply, keys, state}
  end

  # --- Private ---

  defp load_keys_from_config do
    config = ApmV4.ConfigLoader.get_config()

    keys = get_in(config, ["api_auth", "keys"]) || []

    Enum.each(keys, fn entry ->
      key = entry["key"]
      if key do
        :ets.insert(@table, {key, %{
          label: entry["label"] || "unknown",
          created_at: entry["created_at"] || ""
        }})
      end
    end)
  end

  defp persist_keys do
    path = ApmV4.ConfigLoader.config_path()

    config =
      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, c} -> c
            _ -> %{}
          end
        _ -> %{}
      end

    keys_list =
      :ets.tab2list(@table)
      |> Enum.map(fn {key, meta} ->
        %{"key" => key, "label" => meta.label, "created_at" => meta.created_at}
      end)

    auth = Map.get(config, "api_auth", %{}) |> Map.put("keys", keys_list)
    updated = Map.put(config, "api_auth", auth)

    case Jason.encode(updated, pretty: true) do
      {:ok, json} -> File.write(path, json)
      _ -> :ok
    end
  end
end
