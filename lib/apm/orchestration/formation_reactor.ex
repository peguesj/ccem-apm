defmodule Apm.Orchestration.FormationReactor do
  @moduledoc """
  Reactor-based saga orchestrator for multi-wave formation deployments.

  Each formation wave is modelled as a `Reactor.Step`. Each squadron within a
  wave is a sub-step. When a step fails mid-wave, the Reactor invokes
  `compensate/4` on all previously-completed steps in REVERSE order, allowing
  each wave to undo its side-effects (tear down spawned processes, revert state,
  etc.).

  ## Saga compensation return values

  - `:ok`               — accept rollback, propagate failure
  - `{:continue, val}`  — provide a fallback value, allow run to continue
  - `:retry`            — retry compensation
  - `{:error, reason}`  — compensation itself failed

  ## Integration with OrchestrationManager

  `start_run/2` delegates to `Reactor.run/3` when the run params include
  `type: :formation`. This enables the DAG executor to perform saga
  compensation automatically on partial failures.

  ## PubSub events on `"apm:orchestration"`

  - `{:compensation_started, run_id, step_id}`
  - `{:compensation_completed, run_id, step_id}`
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Per-wave step behaviour
  # ---------------------------------------------------------------------------

  defmodule WaveStep do
    @moduledoc """
    Reactor.Step implementation for a single formation wave.

    Each wave step wraps a squadron list.  On failure the `compensate/4`
    callback fires, broadcasting saga events to APM.
    """
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      wave_id = Map.get(arguments, :wave_id, "unknown")
      run_id = Map.get(context, :run_id, "unknown")
      wave_fn = Map.get(context, :wave_fn)

      Logger.debug("[FormationReactor] Running wave #{wave_id} for run #{run_id}")

      case apply_wave(wave_fn, wave_id, run_id) do
        {:ok, result} ->
          {:ok, %{wave_id: wave_id, result: result, run_id: run_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def compensate(reason, arguments, context, _options) do
      wave_id = Map.get(arguments, :wave_id, "unknown")
      run_id = Map.get(context, :run_id, "unknown")

      Logger.warning(
        "[FormationReactor] Compensating (failed) wave #{wave_id} for run #{run_id} — reason: #{inspect(reason)}"
      )

      broadcast_saga_event(run_id, wave_id)

      compensate_fn = Map.get(context, :compensate_fn)
      result = apply_compensate(compensate_fn, wave_id, run_id, reason)

      broadcast_saga_complete(run_id, wave_id)

      result
    end

    @impl true
    def undo(value, arguments, context, _options) do
      # Called on previously SUCCESSFUL steps when a later step fails.
      # This is the primary saga rollback path for completed waves.
      wave_id =
        Map.get(value, :wave_id) || Map.get(arguments, :wave_id, "unknown")

      run_id = Map.get(context, :run_id, "unknown")

      Logger.warning("[FormationReactor] Undoing (successful) wave #{wave_id} for run #{run_id}")

      broadcast_saga_event(run_id, wave_id)

      compensate_fn = Map.get(context, :compensate_fn)
      undo_result = apply_compensate(compensate_fn, wave_id, run_id, :undo)

      broadcast_saga_complete(run_id, wave_id)

      # undo/4 must return :ok | {:error, reason} | :retry
      case undo_result do
        :ok -> :ok
        {:continue, _} -> :ok
        {:error, reason} -> {:error, reason}
        :retry -> :retry
      end
    end

    defp broadcast_saga_event(run_id, wave_id) do
      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "apm:orchestration",
        {:compensation_started, run_id, wave_id}
      )
    end

    defp broadcast_saga_complete(run_id, wave_id) do
      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "apm:orchestration",
        {:compensation_completed, run_id, wave_id}
      )
    end

    # ── Private ──────────────────────────────────────────────────────────────

    defp apply_wave(nil, wave_id, run_id) do
      # Default implementation: simulate wave success
      Logger.debug("[FormationReactor] Default wave handler for #{wave_id}/#{run_id}")
      {:ok, %{wave_id: wave_id, deployed: true}}
    end

    defp apply_wave(fun, wave_id, run_id) when is_function(fun, 2) do
      fun.(wave_id, run_id)
    end

    defp apply_wave({m, f, a}, wave_id, run_id) do
      apply(m, f, [wave_id, run_id | a])
    end

    defp apply_compensate(nil, wave_id, run_id, _reason) do
      Logger.debug("[FormationReactor] Default compensate for wave #{wave_id}/#{run_id}")
      :ok
    end

    defp apply_compensate(fun, wave_id, run_id, reason) when is_function(fun, 3) do
      fun.(wave_id, run_id, reason)
    end

    defp apply_compensate({m, f, a}, wave_id, run_id, reason) do
      apply(m, f, [wave_id, run_id, reason | a])
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build and run a formation saga reactor for the given run.

  `opts` may include:
  - `:wave_fn`        — `fun(wave_id, run_id) :: {:ok, any} | {:error, any}`
  - `:compensate_fn`  — `fun(wave_id, run_id, reason) :: compensate_result`

  Returns `{:ok, results}` or `{:error, reason}` with compensation already applied.
  """
  @spec run_formation(map(), keyword()) :: {:ok, any} | {:error, any}
  def run_formation(run, opts \\ []) do
    wave_fn = Keyword.get(opts, :wave_fn)
    compensate_fn = Keyword.get(opts, :compensate_fn)

    context = %{
      run_id: run.id,
      wave_fn: wave_fn,
      compensate_fn: compensate_fn
    }

    reactor = build_reactor(run, context)
    inputs = build_inputs(run)

    case Reactor.run(reactor, inputs, context, async?: false) do
      {:ok, result} ->
        Logger.info("[FormationReactor] Formation run #{run.id} completed successfully")
        {:ok, result}

      {:error, reason} ->
        Logger.warning("[FormationReactor] Formation run #{run.id} failed: #{inspect(reason)}")
        {:error, reason}

      {:halted, reason} ->
        Logger.warning("[FormationReactor] Formation run #{run.id} halted: #{inspect(reason)}")
        {:error, {:halted, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_reactor(run, _context) do
    alias Reactor.Builder

    reactor = Builder.new()

    # Add steps for each wave (using step index as wave identifier)
    waves = extract_waves(run)

    reactor =
      Enum.reduce(waves, reactor, fn {wave_id, _wave_config}, acc ->
        input_name = String.to_atom("wave_input_#{wave_id}")

        {:ok, acc_with_input} = Builder.add_input(acc, input_name)

        # Each step depends on the previous to enforce ordering
        prev_step = previous_step_name(waves, wave_id)

        arguments =
          if is_nil(prev_step) do
            [{:wave_id, {:input, input_name}}]
          else
            [{:wave_id, {:input, input_name}}, {:prev, {:result, prev_step}}]
          end

        {:ok, new_acc} =
          Builder.add_step(acc_with_input, step_name(wave_id), WaveStep, arguments)

        new_acc
      end)

    # Return result of the last wave step
    last_wave_id = waves |> List.last() |> elem(0)
    {:ok, final_reactor} = Builder.return(reactor, step_name(last_wave_id))
    final_reactor
  end

  defp build_inputs(run) do
    waves = extract_waves(run)

    Enum.reduce(waves, %{}, fn {wave_id, _}, acc ->
      input_name = String.to_atom("wave_input_#{wave_id}")
      Map.put(acc, input_name, wave_id)
    end)
  end

  defp extract_waves(run) do
    # Group steps by wave (use topo sort order, assign wave numbers)
    # For formation runs, steps may carry :wave metadata, otherwise use index
    run.steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, idx} ->
      wave_id = Map.get(step, :wave, "wave_#{idx}")
      {wave_id, step}
    end)
  end

  defp step_name(wave_id), do: String.to_atom("wave_step_#{wave_id}")

  defp previous_step_name(waves, wave_id) do
    wave_ids = Enum.map(waves, &elem(&1, 0))
    idx = Enum.find_index(wave_ids, &(&1 == wave_id))

    if idx > 0 do
      prev_id = Enum.at(wave_ids, idx - 1)
      step_name(prev_id)
    else
      nil
    end
  end
end
