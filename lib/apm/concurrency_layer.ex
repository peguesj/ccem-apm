defmodule Apm.ConcurrencyLayer do
  @moduledoc """
  Unified abstraction over `Task.Supervisor` for supervised fire-and-forget work,
  bounded async streams, and telemetry-instrumented task execution.

  Replaces scattered `Task.start/1` calls across the codebase with a single,
  supervised, observable concurrency primitive. All work dispatched through
  this module is:

    * supervised by `Apm.ConcurrencyLayer.TaskSupervisor`
    * wrapped in a `rescue` so crashes don't propagate
    * instrumented via `:telemetry` for latency and throughput visibility
    * bounded where backpressure matters (`bounded_async_stream/3`)

  ## Telemetry

  Events emitted:

    * `[:apm, :concurrency, :task, :start]`
    * `[:apm, :concurrency, :task, :stop]`  -- measurement `:duration` (native time)
    * `[:apm, :concurrency, :task, :exception]`

  Metadata: `%{label: atom()}`.
  """

  @task_supervisor Apm.ConcurrencyLayer.TaskSupervisor

  @doc """
  Returns the child spec for the supervised `Task.Supervisor` that backs this
  layer. Add to your application supervision tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Task.Supervisor.child_spec(name: @task_supervisor)
  end

  @doc """
  Dispatch an arbitrary 0-arity function to the supervised task pool and return
  immediately. Any exception is caught and logged; the caller never blocks.

  This is the canonical replacement for `Task.start(fn -> ... end)`.
  """
  @spec fire_and_forget((-> any()), atom()) :: :ok
  def fire_and_forget(fun, label \\ :unlabeled) when is_function(fun, 0) do
    Task.Supervisor.start_child(@task_supervisor, fn ->
      run_with_telemetry(fun, label)
    end)

    :ok
  end

  @doc """
  Async stream with bounded concurrency. Thin wrapper around
  `Task.Supervisor.async_stream_nolink/4` with sensible defaults.
  """
  @spec bounded_async_stream(Enumerable.t(), (term() -> term()), keyword()) :: Enumerable.t()
  def bounded_async_stream(enum, fun, opts \\ []) when is_function(fun, 1) do
    defaults = [max_concurrency: System.schedulers_online(), ordered: false, timeout: 30_000]
    merged = Keyword.merge(defaults, opts)
    Task.Supervisor.async_stream_nolink(@task_supervisor, enum, fun, merged)
  end

  @doc """
  Run an awaited task on the supervised pool. Useful when you do need the
  result but still want supervision and telemetry.
  """
  @spec supervised_await((-> term()), atom(), timeout()) :: {:ok, term()} | {:error, term()}
  def supervised_await(fun, label \\ :unlabeled, timeout \\ 10_000) when is_function(fun, 0) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        run_with_telemetry(fun, label)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  ## Internal

  defp run_with_telemetry(fun, label) do
    start = System.monotonic_time()
    meta = %{label: label}

    :telemetry.execute(
      [:apm, :concurrency, :task, :start],
      %{system_time: System.system_time()},
      meta
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start
      :telemetry.execute([:apm, :concurrency, :task, :stop], %{duration: duration}, meta)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start

        :telemetry.execute(
          [:apm, :concurrency, :task, :exception],
          %{duration: duration},
          Map.merge(meta, %{kind: :error, reason: e})
        )

        require Logger
        Logger.warning("ConcurrencyLayer task failed [#{label}]: #{inspect(e)}")
        {:error, e}
    end
  end
end
