defmodule Apm.ActionRunStore do
  @moduledoc """
  ETS-backed GenServer for tracking async ActionEngine run state.

  Each run is stored as a map with keys:
    id, action_type, project_path, params, status, stdout, stderr,
    exit_code, result, error, started_at, completed_at

  Statuses: "pending" → "running" → "success" | "error"

  ## API

      start_run(action_type, project_path, params) :: {:ok, run_id} | {:error, :unknown_action}
      get_run(run_id)                               :: {:ok, map()} | {:error, :not_found}
      list_runs(opts \\ [])                         :: [map()]

  ## Test registration

  For testing, action types "test_noop" and "test_noop_b" are always registered
  and complete immediately with {:ok, %{test: true}}.
  """

  use GenServer
  require Logger

  @table :action_runs
  @default_limit 50

  # Extra action types accepted for testing — registered in addition to ActionEngine catalog.
  @test_action_types ~w(test_noop test_noop_b)

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Starts an async action run. Returns `{:ok, run_id}` immediately.
  Unknown action types return `{:error, :unknown_action}`.
  """
  @spec start_run(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, :unknown_action}
  def start_run(action_type, project_path, params) do
    GenServer.call(__MODULE__, {:start_run, action_type, project_path, params})
  end

  @doc "Fetch a single run by id."
  @spec get_run(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] -> {:ok, run}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List runs, optionally filtered/limited.

  Options:
    - `:action_type` — filter by exact action type string
    - `:limit`       — max rows returned (default 50)

  Rows are sorted descending by `started_at`.
  """
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) do
    action_type = Keyword.get(opts, :action_type)
    limit = Keyword.get(opts, :limit, @default_limit)

    runs =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, run} -> run end)
      |> then(fn rs ->
        if action_type do
          Enum.filter(rs, &(&1.action_type == action_type))
        else
          rs
        end
      end)
      |> Enum.sort_by(& &1.started_at, :desc)
      |> Enum.take(limit)

    runs
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init([]) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_run, action_type, project_path, params}, _from, state) do
    if valid_action_type?(action_type) do
      run_id = generate_run_id()

      run = %{
        id: run_id,
        action_type: action_type,
        project_path: project_path,
        params: params,
        status: "pending",
        stdout: nil,
        stderr: nil,
        exit_code: nil,
        result: nil,
        error: nil,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        completed_at: nil
      }

      :ets.insert(@table, {run_id, run})

      # Spawn async execution
      store = self()

      Task.start(fn ->
        # Transition to running
        GenServer.cast(store, {:set_running, run_id})

        result =
          if action_type in @test_action_types do
            {:ok, %{test: true}}
          else
            Apm.ActionEngine.execute_action_public(action_type, project_path, params)
          end

        GenServer.cast(store, {:action_done, run_id, result})
      end)

      {:reply, {:ok, run_id}, state}
    else
      {:reply, {:error, :unknown_action}, state}
    end
  end

  @impl true
  def handle_cast({:set_running, run_id}, state) do
    update_run(run_id, &Map.put(&1, :status, "running"))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:action_done, run_id, result}, state) do
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    update_run(run_id, fn run ->
      case result do
        {:ok, data} ->
          run
          |> Map.put(:status, "success")
          |> Map.put(:result, data)
          |> Map.put(:completed_at, completed_at)

        {:error, reason} ->
          run
          |> Map.put(:status, "error")
          |> Map.put(:error, to_string(reason))
          |> Map.put(:completed_at, completed_at)
      end
    end)

    {:noreply, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec generate_run_id() :: String.t()
  defp generate_run_id do
    "ar_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  @spec valid_action_type?(String.t()) :: boolean()
  defp valid_action_type?(action_type) do
    action_type in @test_action_types or
      Enum.any?(Apm.ActionEngine.list_catalog(), &(&1.id == action_type))
  end

  @spec update_run(String.t(), (map() -> map())) :: :ok
  defp update_run(run_id, fun) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        :ets.insert(@table, {run_id, fun.(run)})
        :ok

      [] ->
        :ok
    end
  end
end
