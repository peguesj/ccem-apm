defmodule ApmV5.VerifyStore do
  @moduledoc """
  GenServer-backed ETS store for double-verification sessions.
  Tracks two-pass verification runs with consensus tracking.
  """

  use GenServer
  require Logger

  @table :verify_sessions

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new verification session. Returns {:ok, session}."
  @spec create(String.t(), String.t(), list()) :: {:ok, map()}
  def create(project_root, app_url, stories) do
    GenServer.call(__MODULE__, {:create, project_root, app_url, stories})
  end

  @doc "Get a verification session by ID. Returns {:ok, session} | {:error, :not_found}."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc "Update a verification session. Returns {:ok, updated} | {:error, :not_found}."
  @spec update(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def update(id, attrs) do
    GenServer.call(__MODULE__, {:update, id, attrs})
  end

  @doc "List all verification sessions, most recent first."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, project_root, app_url, stories}, _from, state) do
    id = ApmV5.Correlation.generate()
    session = %{
      id: id,
      project_root: project_root,
      app_url: app_url,
      stories: stories,
      status: "started",
      pass_1_result: nil,
      pass_2_result: nil,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }
    :ets.insert(@table, {id, session})
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:verify", {:verify_created, session})
    {:reply, {:ok, session}, state}
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, session}] ->
        updated = Map.merge(session, attrs)
        :ets.insert(@table, {id, updated})
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:verify", {:verify_updated, updated})
        {:reply, {:ok, updated}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end
end
