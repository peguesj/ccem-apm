defmodule Apm.Instrumentation do
  @moduledoc """
  Central telemetry event definitions and helpers for CCEM APM hot paths.

  This module does three things:

    1. Documents the full set of `:telemetry` events emitted by the app.
    2. Provides small helper macros/functions so call sites can wrap work
       in consistent start/stop spans without repeating boilerplate.
    3. Offers an `attach_default_handlers/0` entry point that logs
       slow / exceptional spans at `:warning`. Useful in dev, harmless in
       prod.

  ## Events

  ### PendingDecisions
    * `[:apm, :auth, :pending_decisions, :add]`
    * `[:apm, :auth, :pending_decisions, :decide]`

  ### AuthorizationGate
    * `[:apm, :auth, :authorization_gate, :evaluate, :start | :stop | :exception]`

  ### AgentRegistry
    * `[:apm, :agent_registry, :register]`
    * `[:apm, :agent_registry, :list]`

  ### PubSub
    * `[:apm, :pubsub, :broadcast]` -- measurement `:payload_bytes`

  ### ConcurrencyLayer / JobQueue / NativeTransport
    * see `Apm.ConcurrencyLayer`, `Apm.JobQueue`,
      `Apm.NativeTransport.UnixSocket` for their own docs.
  """

  require Logger

  @doc """
  Emit a PubSub broadcast with telemetry instrumentation. Drop-in replacement
  for `Phoenix.PubSub.broadcast/3`.
  """
  @spec broadcast(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast(pubsub, topic, message) do
    size =
      try do
        byte_size(:erlang.term_to_binary(message))
      rescue
        _ -> 0
      end

    :telemetry.execute(
      [:apm, :pubsub, :broadcast],
      %{payload_bytes: size},
      %{topic: topic}
    )

    Phoenix.PubSub.broadcast(pubsub, topic, message)
  end

  @doc """
  Span helper: executes `fun`, emits `:start` + `:stop` events, and
  returns the function's return value. On exception, emits `:exception`
  and re-raises.
  """
  @spec span([atom()], map(), (-> term())) :: term()
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_function(fun, 0) do
    start = System.monotonic_time()

    :telemetry.execute(event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start
      :telemetry.execute(event_prefix ++ [:stop], %{duration: duration}, metadata)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e})
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Attach a default logger handler that warns on exception events and
  slow spans (> `threshold_ms`).
  """
  @spec attach_default_handlers(pos_integer()) :: :ok
  def attach_default_handlers(threshold_ms \\ 500) do
    threshold_native = System.convert_time_unit(threshold_ms, :millisecond, :native)

    events = [
      [:apm, :concurrency, :task, :stop],
      [:apm, :concurrency, :task, :exception],
      [:apm, :job_queue, :job, :stop],
      [:apm, :job_queue, :job, :exception],
      [:apm, :job_queue, :job, :dropped],
      [:apm, :auth, :authorization_gate, :evaluate, :stop],
      [:apm, :auth, :authorization_gate, :evaluate, :exception]
    ]

    :telemetry.attach_many(
      "apm-v5-default-logger",
      events,
      &__MODULE__.handle_event/4,
      %{threshold_native: threshold_native}
    )

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    cond do
      List.last(event) == :exception ->
        Logger.warning(
          "[telemetry] #{inspect(event)} exception label=#{inspect(Map.get(metadata, :label))} reason=#{inspect(Map.get(metadata, :reason))}"
        )

      List.last(event) == :dropped ->
        Logger.warning("[telemetry] #{inspect(event)} dropped metadata=#{inspect(metadata)}")

      Map.has_key?(measurements, :duration) and
          measurements.duration > config.threshold_native ->
        ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
        Logger.warning("[telemetry] slow span #{inspect(event)} took #{ms}ms metadata=#{inspect(metadata)}")

      true ->
        :ok
    end
  end
end
