defmodule Apm.JobQueue do
  @moduledoc """
  ETS-backed priority job queue with bounded concurrency and exponential
  backoff retry. Replaces ad-hoc `Task.start/1` calls that need retry /
  ordering / rate-limiting.

  ## Priority levels

    * `:critical` (0) -- immediate execution, jumps the queue
    * `:high` (1)
    * `:normal` (2)
    * `:low` (3)

  Jobs within the same priority are FIFO.

  ## Retry

  On job failure the job is re-enqueued with `attempt + 1`. Delay is
  `base_backoff_ms * 2^(attempt - 1)` up to `max_backoff_ms`. After
  `max_attempts` failures the job is dropped and a telemetry exception
  event is emitted.

  ## Telemetry

    * `[:apm, :job_queue, :job, :enqueue]`
    * `[:apm, :job_queue, :job, :start]`
    * `[:apm, :job_queue, :job, :stop]`
    * `[:apm, :job_queue, :job, :exception]`
    * `[:apm, :job_queue, :job, :dropped]`
  """

  use GenServer
  require Logger

  @table :job_queue
  @priorities %{critical: 0, high: 1, normal: 2, low: 3}
  @default_max_concurrent 8
  @default_max_attempts 3
  @default_base_backoff_ms 250
  @default_max_backoff_ms 30_000
  @tick_ms 50

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a 0-arity function for async execution.

  Options:
    * `:priority` -- `:critical | :high | :normal | :low` (default `:normal`)
    * `:label` -- atom for telemetry metadata (default `:unlabeled`)
    * `:max_attempts` -- override retry ceiling
  """
  @spec enqueue((-> any()), keyword()) :: {:ok, reference()}
  def enqueue(fun, opts \\ []) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:enqueue, fun, opts})
  end

  @doc """
  Returns counts by state: `%{queued: n, running: n, completed: n, failed: n}`.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    state = %{
      table: table,
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
      seq: 0,
      running: %{},
      completed: 0,
      failed: 0
    }

    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, fun, opts}, _from, state) do
    priority = Keyword.get(opts, :priority, :normal)
    label = Keyword.get(opts, :label, :unlabeled)
    max_attempts = Keyword.get(opts, :max_attempts, state.max_attempts)
    ref = make_ref()
    seq = state.seq + 1
    now = System.monotonic_time(:millisecond)
    prio_int = Map.get(@priorities, priority, 2)

    job = %{
      ref: ref,
      fun: fun,
      label: label,
      priority: priority,
      attempt: 1,
      max_attempts: max_attempts,
      scheduled_at: now
    }

    :ets.insert(state.table, {{prio_int, now, seq}, job})

    :telemetry.execute(
      [:apm, :job_queue, :job, :enqueue],
      %{count: 1},
      %{label: label, priority: priority}
    )

    {:reply, {:ok, ref}, %{state | seq: seq}, {:continue, :dispatch}}
  end

  def handle_call(:stats, _from, state) do
    queued = :ets.info(state.table, :size)

    reply = %{
      queued: queued,
      running: map_size(state.running),
      completed: state.completed,
      failed: state.failed
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, dispatch(state)}
  end

  def handle_info({ref, :ok}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:job_finished, job_ref, :ok}, state) do
    state = %{state | running: Map.delete(state.running, job_ref), completed: state.completed + 1}
    {:noreply, dispatch(state)}
  end

  def handle_info({:job_finished, job_ref, {:error, reason}}, state) do
    {job, running} = Map.pop(state.running, job_ref)
    state = %{state | running: running}

    state =
      cond do
        is_nil(job) ->
          state

        job.attempt >= job.max_attempts ->
          :telemetry.execute(
            [:apm, :job_queue, :job, :dropped],
            %{count: 1},
            %{label: job.label, reason: reason, attempts: job.attempt}
          )

          Logger.warning(
            "JobQueue dropping job [#{job.label}] after #{job.attempt} attempts: #{inspect(reason)}"
          )

          %{state | failed: state.failed + 1}

        true ->
          delay =
            min(
              state.base_backoff_ms * :math.pow(2, job.attempt - 1),
              state.max_backoff_ms
            )
            |> trunc()

          Process.send_after(self(), {:retry, %{job | attempt: job.attempt + 1}}, delay)
          state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({:retry, job}, state) do
    prio_int = Map.get(@priorities, job.priority, 2)
    now = System.monotonic_time(:millisecond)
    seq = state.seq + 1
    :ets.insert(state.table, {{prio_int, now, seq}, job})
    {:noreply, dispatch(%{state | seq: seq})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  ## Internal

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp dispatch(state) do
    capacity = state.max_concurrent - map_size(state.running)

    if capacity > 0 do
      take_and_run(state, capacity)
    else
      state
    end
  end

  defp take_and_run(state, 0), do: state

  defp take_and_run(state, capacity) do
    case :ets.first(state.table) do
      :"$end_of_table" ->
        state

      key ->
        case :ets.lookup(state.table, key) do
          [{^key, job}] ->
            :ets.delete(state.table, key)
            state = run_job(state, job)
            take_and_run(state, capacity - 1)

          _ ->
            state
        end
    end
  end

  defp run_job(state, job) do
    parent = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(
        Apm.ConcurrencyLayer.TaskSupervisor,
        fn ->
          start = System.monotonic_time()
          meta = %{label: job.label, priority: job.priority, attempt: job.attempt}

          :telemetry.execute(
            [:apm, :job_queue, :job, :start],
            %{system_time: System.system_time()},
            meta
          )

          result =
            try do
              job.fun.()
              {:ok, nil}
            rescue
              e ->
                duration = System.monotonic_time() - start

                :telemetry.execute(
                  [:apm, :job_queue, :job, :exception],
                  %{duration: duration},
                  Map.put(meta, :reason, e)
                )

                {:error, e}
            end

          case result do
            {:ok, _} ->
              duration = System.monotonic_time() - start
              :telemetry.execute([:apm, :job_queue, :job, :stop], %{duration: duration}, meta)
              send(parent, {:job_finished, job.ref, :ok})

            {:error, reason} ->
              send(parent, {:job_finished, job.ref, {:error, reason}})
          end
        end
      )

    %{state | running: Map.put(state.running, job.ref, job)}
  end
end
