defmodule Apm.Plugins.Composio.ComposioMcpRegistry do
  @moduledoc """
  GenServer that persists Composio MCP server configurations to
  `priv/composio_mcp_registry.json`.

  State is a map of `server_id => config_map`. On init the file is loaded
  if it exists. Writes are flushed to disk after every mutation.
  """

  use GenServer

  require Logger

  @persist_path Path.join(:code.priv_dir(:apm), "composio_mcp_registry.json")

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all registered MCP server configs."
  @spec list_servers() :: [map()]
  def list_servers do
    GenServer.call(__MODULE__, :list_servers)
  end

  @doc "Return a single server config map, or nil."
  @spec get_server(String.t()) :: map() | nil
  def get_server(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:get_server, server_id})
  end

  @doc "Register or update a server config."
  @spec register_server(String.t(), map()) :: :ok
  def register_server(server_id, config) when is_binary(server_id) and is_map(config) do
    GenServer.call(__MODULE__, {:register_server, server_id, config})
  end

  @doc "Delete a server config by id."
  @spec delete_server(String.t()) :: :ok
  def delete_server(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:delete_server, server_id})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = load_from_disk()
    {:ok, state}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    servers = state |> Map.values() |> Enum.map(&Map.put(&1, "id", find_id(state, &1)))
    {:reply, servers, state}
  end

  def handle_call({:get_server, server_id}, _from, state) do
    case Map.fetch(state, server_id) do
      {:ok, config} -> {:reply, Map.put(config, "id", server_id), state}
      :error -> {:reply, nil, state}
    end
  end

  def handle_call({:register_server, server_id, config}, _from, state) do
    new_state = Map.put(state, server_id, config)
    flush(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:delete_server, server_id}, _from, state) do
    new_state = Map.delete(state, server_id)
    flush(new_state)
    {:reply, :ok, new_state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec load_from_disk() :: map()
  defp load_from_disk do
    case File.read(@persist_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} when is_map(data) ->
            Logger.debug("[ComposioMcpRegistry] Loaded #{map_size(data)} servers from disk")
            data

          _ ->
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("[ComposioMcpRegistry] Failed to load registry: #{inspect(reason)}")
        %{}
    end
  end

  @spec flush(map()) :: :ok
  defp flush(state) do
    case Jason.encode(state, pretty: true) do
      {:ok, json} ->
        File.write!(@persist_path, json)

      {:error, reason} ->
        Logger.warning("[ComposioMcpRegistry] Failed to encode state: #{inspect(reason)}")
    end

    :ok
  end

  defp find_id(state, config) do
    Enum.find_value(state, "", fn {id, v} -> if v == config, do: id end)
  end
end
