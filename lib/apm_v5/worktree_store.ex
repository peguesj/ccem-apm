defmodule ApmV5.WorktreeStore do
  @moduledoc """
  GenServer that tracks git worktree lifecycle metadata.

  Backed by ETS table `:worktree_store` keyed by `worktree_id`. Broadcasts
  `{:worktree_event, event, metadata}` on the `"apm:worktrees"` PubSub topic
  for every create/update/prune.

  ## Metadata schema

      %{
        worktree_id: String.t(),
        branch: String.t(),
        base_branch: String.t(),
        path: String.t(),
        created_at: String.t() (ISO-8601),
        parent_session_id: String.t() | nil,
        formation_id: String.t() | nil,
        project: String.t() | nil,
        status: :active | :archived | :pruned | :error
      }
  """

  use GenServer
  require Logger

  @ets_table :worktree_store
  @pubsub_topic "apm:worktrees"

  @type worktree_id :: String.t()
  @type metadata :: %{
          worktree_id: worktree_id(),
          branch: String.t(),
          base_branch: String.t(),
          path: String.t(),
          created_at: String.t(),
          parent_session_id: String.t() | nil,
          formation_id: String.t() | nil,
          project: String.t() | nil,
          status: atom()
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a new worktree. Requires at least `:branch` and `:path` keys.
  Generates `worktree_id` if not provided. Returns `{:ok, metadata}`.
  """
  @spec register(map()) :: {:ok, metadata()} | {:error, term()}
  def register(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:register, attrs})

  @doc "List all worktrees."
  @spec list() :: [metadata()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "List worktrees filtered by project."
  @spec list_by_project(String.t()) :: [metadata()]
  def list_by_project(project) when is_binary(project),
    do: GenServer.call(__MODULE__, {:list_by_project, project})

  @doc "Fetch a single worktree by id."
  @spec get(worktree_id()) :: {:ok, metadata()} | {:error, :not_found}
  def get(worktree_id) when is_binary(worktree_id),
    do: GenServer.call(__MODULE__, {:get, worktree_id})

  @doc "Update a worktree's metadata with the given attrs (partial update)."
  @spec update(worktree_id(), map()) :: {:ok, metadata()} | {:error, term()}
  def update(worktree_id, attrs) when is_binary(worktree_id) and is_map(attrs),
    do: GenServer.call(__MODULE__, {:update, worktree_id, attrs})

  @doc "Mark a worktree as pruned and remove from the store."
  @spec prune(worktree_id()) :: :ok | {:error, :not_found}
  def prune(worktree_id) when is_binary(worktree_id),
    do: GenServer.call(__MODULE__, {:prune, worktree_id})

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    attrs = atomize_keys(attrs)

    cond do
      not is_binary(Map.get(attrs, :branch)) ->
        {:reply, {:error, :missing_branch}, state}

      not is_binary(Map.get(attrs, :path)) ->
        {:reply, {:error, :missing_path}, state}

      true ->
        worktree_id = Map.get(attrs, :worktree_id) || generate_id()
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        metadata =
          %{
            worktree_id: worktree_id,
            branch: attrs.branch,
            base_branch: Map.get(attrs, :base_branch, "main"),
            path: attrs.path,
            created_at: Map.get(attrs, :created_at, now),
            parent_session_id: Map.get(attrs, :parent_session_id),
            formation_id: Map.get(attrs, :formation_id),
            project: Map.get(attrs, :project),
            status: Map.get(attrs, :status, :active)
          }

        :ets.insert(@ets_table, {worktree_id, metadata})
        broadcast(:registered, metadata)
        {:reply, {:ok, metadata}, state}
    end
  end

  def handle_call(:list, _from, state) do
    items = :ets.tab2list(@ets_table) |> Enum.map(fn {_k, v} -> v end)
    {:reply, items, state}
  end

  def handle_call({:list_by_project, project}, _from, state) do
    items =
      @ets_table
      |> :ets.tab2list()
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.filter(fn m -> Map.get(m, :project) == project end)

    {:reply, items, state}
  end

  def handle_call({:get, id}, _from, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, metadata}] -> {:reply, {:ok, metadata}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, existing}] ->
        merged = Map.merge(existing, atomize_keys(attrs)) |> Map.put(:worktree_id, id)
        :ets.insert(@ets_table, {id, merged})
        broadcast(:updated, merged)
        {:reply, {:ok, merged}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:prune, id}, _from, state) do
    case :ets.lookup(@ets_table, id) do
      [{^id, metadata}] ->
        :ets.delete(@ets_table, id)
        broadcast(:pruned, metadata)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp broadcast(event, metadata) do
    case Process.whereis(ApmV5.PubSub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(
          ApmV5.PubSub,
          @pubsub_topic,
          {:worktree_event, event, metadata}
        )
    end
  end

  defp generate_id do
    "wt_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_atom(k), v)
    end)
  end
end
