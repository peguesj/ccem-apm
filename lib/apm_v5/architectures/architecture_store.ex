defmodule ApmV5.Architectures.ArchitectureStore do
  @moduledoc """
  Registry and store for architecture types.

  Manages registered architectures and their instantiated trees.
  ETS-backed for fast reads, PubSub-broadcast on changes.
  """

  use GenServer

  require Logger

  @table :architecture_store
  @pubsub_topic "apm:architectures"

  @default_architectures [
    ApmV5.Architectures.Diligent
  ]

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all registered architecture types"
  @spec list_architectures() :: [map()]
  def list_architectures do
    case :ets.info(@table) do
      :undefined -> []
      _ ->
        :ets.tab2list(@table)
        |> Enum.filter(fn {key, _} -> is_binary(key) and not String.starts_with?(key, "tree:") end)
        |> Enum.map(fn {_name, meta} -> meta end)
    end
  end

  @doc "Get a specific architecture by name"
  @spec get_architecture(String.t()) :: map() | nil
  def get_architecture(name) do
    case :ets.lookup(@table, name) do
      [{^name, meta}] -> meta
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Build and store a tree for an architecture from live agent data"
  @spec build_tree(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def build_tree(architecture_name, agents, opts \\ []) do
    GenServer.call(__MODULE__, {:build_tree, architecture_name, agents, opts})
  end

  @doc "Get the most recently built tree for an architecture"
  @spec get_tree(String.t()) :: map() | nil
  def get_tree(architecture_name) do
    case :ets.lookup(@table, "tree:#{architecture_name}") do
      [{_, tree}] -> tree
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Get graph config for an architecture"
  @spec graph_config(String.t()) :: map() | nil
  def graph_config(architecture_name) do
    case get_architecture(architecture_name) do
      %{module: module} -> module.graph_config()
      _ -> nil
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    Enum.each(@default_architectures, fn mod ->
      meta = %{
        name: mod.architecture_name(),
        description: mod.architecture_description(),
        version: mod.architecture_version(),
        levels: mod.levels(),
        module: mod
      }

      :ets.insert(table, {mod.architecture_name(), meta})
    end)

    Logger.info("[ArchitectureStore] Initialized with #{length(@default_architectures)} architectures")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:build_tree, arch_name, agents, opts}, _from, state) do
    case :ets.lookup(state.table, arch_name) do
      [{^arch_name, %{module: module}}] ->
        tree = module.build_tree(agents, opts)

        case module.validate(tree) do
          :ok ->
            :ets.insert(state.table, {"tree:#{arch_name}", tree})
            broadcast({:tree_built, arch_name, tree})
            {:reply, {:ok, tree}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, "Architecture '#{arch_name}' not found"}, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, event)
  end
end
