defmodule ApmV5.UatRunner do
  @moduledoc """
  GenServer that orchestrates UAT (User Acceptance Test) execution.

  Manages a registry of test suite modules implementing `ApmV5.Uat.TestSuite`,
  executes them sequentially, stores results in ETS, and broadcasts progress
  via PubSub on the "apm:uat" topic.

  ## ETS Table

  `:uat_results` — public set table with `read_concurrency: true`.
  Keys are `{run_id, test_id}` tuples; values are result maps.

  ## PubSub Messages

  - `{:uat_result, result}` — broadcast after each individual test result
  - `{:uat_complete, summary}` — broadcast when a run finishes
  """

  use GenServer
  require Logger

  @test_modules [
    ApmV5.Uat.ApiTests,
    ApmV5.Uat.LiveViewTests,
    ApmV5.Uat.GenServerTests,
    ApmV5.Uat.PubSubTests,
    ApmV5.Uat.AgUiTests,
    ApmV5.Uat.IntegrationTests
  ]

  @pubsub_topic "apm:uat"

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Run all registered test modules. Returns `{:ok, run_id}` or `{:error, :already_running}`."
  @spec run_all() :: {:ok, String.t()} | {:error, :already_running}
  def run_all do
    GenServer.call(__MODULE__, :run_all)
  end

  @doc "Run only test modules matching the given category atom."
  @spec run_category(atom()) :: {:ok, String.t()} | {:error, :already_running}
  def run_category(category) when is_atom(category) do
    GenServer.call(__MODULE__, {:run_category, category})
  end

  @doc "Get all results for the current or most recent run."
  @spec get_results() :: [map()]
  def get_results do
    GenServer.call(__MODULE__, :get_results)
  end

  @doc "Get a summary of the current or most recent run."
  @spec get_summary() :: map()
  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @doc "Clear all results and reset state to idle."
  @spec clear_results() :: :ok
  def clear_results do
    GenServer.call(__MODULE__, :clear_results)
  end

  @doc "Returns true if a test run is currently in progress."
  @spec running?() :: boolean()
  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_) do
    :ets.new(:uat_results, [:set, :public, :named_table, read_concurrency: true])

    state = %{
      run_id: nil,
      status: :idle,
      results: [],
      started_at: nil,
      completed_at: nil,
      category_filter: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run_all, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:run_all, _from, state) do
    run_id = generate_run_id()

    new_state = %{
      state
      | run_id: run_id,
        status: :running,
        results: [],
        started_at: DateTime.utc_now(),
        completed_at: nil,
        category_filter: nil
    }

    spawn_run(run_id, @test_modules)
    {:reply, {:ok, run_id}, new_state}
  end

  def handle_call({:run_category, _category}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:run_category, category}, _from, state) do
    run_id = generate_run_id()
    modules = modules_for_category(category)

    new_state = %{
      state
      | run_id: run_id,
        status: :running,
        results: [],
        started_at: DateTime.utc_now(),
        completed_at: nil,
        category_filter: category
    }

    spawn_run(run_id, modules)
    {:reply, {:ok, run_id}, new_state}
  end

  def handle_call(:get_results, _from, state) do
    {:reply, state.results, state}
  end

  def handle_call(:get_summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  def handle_call(:clear_results, _from, _state) do
    :ets.delete_all_objects(:uat_results)

    new_state = %{
      run_id: nil,
      status: :idle,
      results: [],
      started_at: nil,
      completed_at: nil,
      category_filter: nil
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:running?, _from, state) do
    {:reply, state.status == :running, state}
  end

  @impl true
  def handle_info({:uat_result, run_id, result}, state) do
    if run_id == state.run_id do
      :ets.insert(:uat_results, {{run_id, result.id}, result})

      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {:uat_result, result})

      {:noreply, %{state | results: state.results ++ [result]}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:uat_run_complete, run_id}, state) do
    if run_id == state.run_id do
      now = DateTime.utc_now()
      new_state = %{state | status: :complete, completed_at: now}
      summary = build_summary(new_state)

      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {:uat_complete, summary})

      Logger.info("UAT run #{run_id} complete: #{summary.passed}/#{summary.total} passed")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp modules_for_category(category) do
    Enum.filter(@test_modules, fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :category, 0) and mod.category() == category
    end)
  end

  defp spawn_run(run_id, modules) do
    parent = self()

    Task.start(fn ->
      Enum.each(modules, fn mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :run, 0) do
          try do
            results = mod.run()

            Enum.each(results, fn result ->
              result = Map.put_new(result, :id, generate_run_id())
              send(parent, {:uat_result, run_id, result})
            end)
          rescue
            e ->
              Logger.warning("UAT module #{inspect(mod)} raised: #{Exception.message(e)}")

              error_result = %{
                id: generate_run_id(),
                module: mod,
                name: "#{inspect(mod)} execution error",
                status: :failed,
                message: Exception.message(e),
                category: safe_category(mod),
                duration_ms: 0
              }

              send(parent, {:uat_result, run_id, error_result})
          end
        else
          Logger.warning("UAT module #{inspect(mod)} not loaded or missing run/0 — skipping")
        end
      end)

      send(parent, {:uat_run_complete, run_id})
    end)
  end

  defp safe_category(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :category, 0) do
      mod.category()
    else
      :unknown
    end
  end

  defp build_summary(state) do
    results = state.results

    duration_ms =
      case {state.started_at, state.completed_at || DateTime.utc_now()} do
        {nil, _} -> 0
        {started, ended} -> DateTime.diff(ended, started, :millisecond)
      end

    %{
      total: length(results),
      passed: Enum.count(results, &(&1[:status] == :passed)),
      failed: Enum.count(results, &(&1[:status] == :failed)),
      skipped: Enum.count(results, &(&1[:status] == :skipped)),
      duration_ms: duration_ms,
      status: state.status,
      run_id: state.run_id
    }
  end
end
