defmodule ApmV5.Upm.DecisionGate do
  @moduledoc """
  Interactive decision gating for /upm plan deployments.

  When UPM generates stories and is ready to deploy a formation, this module
  gates the deployment by:
    1. Posting a CCEMHelper notification via POST /api/notify (category: upm_decision)
    2. Firing an osascript dialog as a fallback/reinforcement
    3. Waiting up to `timeout_ms` for a resolution via approve/2 or reject/2
    4. Returning {:approved, method} or {:rejected, reason}

  REST endpoint: POST /api/v2/upm/gate
  Body: %{question, context, options, timeout_ms}
  Response: %{decision: "approved"|"rejected", method: "notification"|"osascript"|"timeout"}

  ETS table: :upm_decision_gates
  PubSub topic: "upm:decisions"
  """

  use GenServer

  require Logger

  @table :upm_decision_gates
  @default_timeout_ms 20_000
  @expire_check_ms 3_000

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a decision gate and blocks the caller up to `timeout_ms`.

  Returns {:approved, method} or {:rejected, reason} or {:timeout, gate_id}.
  This is a synchronous call — the caller blocks until resolution.
  """
  @spec request(String.t(), map()) :: {:approved, String.t()} | {:rejected, String.t()} | {:timeout, String.t()}
  def request(question, opts \\ %{}) do
    GenServer.call(__MODULE__, {:request, question, opts}, :infinity)
  end

  @doc "Approves a pending gate (called from REST endpoint or notification action)."
  @spec approve(String.t()) :: :ok | {:error, :not_found | :not_pending}
  def approve(gate_id) do
    GenServer.call(__MODULE__, {:resolve, gate_id, :approved, "notification"})
  end

  @doc "Rejects a pending gate."
  @spec reject(String.t(), String.t()) :: :ok | {:error, :not_found | :not_pending}
  def reject(gate_id, reason \\ "User cancelled") do
    GenServer.call(__MODULE__, {:resolve, gate_id, :rejected, reason})
  end

  @doc "Lists all pending decision gates."
  @spec list_pending() :: [map()]
  def list_pending do
    all_gates()
    |> Enum.filter(&(&1.status == :pending))
  end

  @doc "Gets a single gate by id."
  @spec get(String.t()) :: map() | nil
  def get(gate_id) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, gate}] -> gate
      [] -> nil
    end
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    schedule_expire_check()
    {:ok, %{waiters: %{}}}
  end

  @impl true
  def handle_call({:request, question, opts}, from, state) do
    gate_id = generate_gate_id()
    timeout_ms = Map.get(opts, "timeout_ms", Map.get(opts, :timeout_ms, @default_timeout_ms))
    context = Map.get(opts, "context", Map.get(opts, :context, ""))
    options = Map.get(opts, "options", Map.get(opts, :options, ["Deploy", "Cancel"]))
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    gate = %{
      gate_id: gate_id,
      question: question,
      context: context,
      options: options,
      status: :pending,
      timeout_ms: timeout_ms,
      requested_at: now,
      resolved_at: nil,
      decision: nil,
      method: nil
    }

    :ets.insert(@table, {gate_id, gate})

    # Broadcast for LiveView panels
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "upm:decisions", {:gate_created, gate})

    # Fire notifications and osascript asynchronously
    Task.start(fn -> notify_user(gate) end)

    # Set up timeout
    Process.send_after(self(), {:gate_timeout, gate_id}, timeout_ms)

    # Store the caller ref so we can reply when resolved
    waiters = Map.put(state.waiters, gate_id, from)
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_call({:resolve, gate_id, decision, method_or_reason}, _from, state) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, %{status: :pending} = gate}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{gate | status: decision, decision: decision, method: method_or_reason, resolved_at: now}
        :ets.insert(@table, {gate_id, updated})

        Phoenix.PubSub.broadcast(ApmV5.PubSub, "upm:decisions", {:gate_resolved, updated})

        # Unblock the waiting caller
        if waiter = Map.get(state.waiters, gate_id) do
          result = case decision do
            :approved -> {:approved, method_or_reason}
            :rejected -> {:rejected, method_or_reason}
          end

          GenServer.reply(waiter, result)
        end

        {:reply, :ok, %{state | waiters: Map.delete(state.waiters, gate_id)}}

      [{^gate_id, _gate}] ->
        {:reply, {:error, :not_pending}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:gate_timeout, gate_id}, state) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, %{status: :pending} = gate}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{gate | status: :timeout, resolved_at: now}
        :ets.insert(@table, {gate_id, updated})

        Phoenix.PubSub.broadcast(ApmV5.PubSub, "upm:decisions", {:gate_timeout, updated})

        if waiter = Map.get(state.waiters, gate_id) do
          GenServer.reply(waiter, {:timeout, gate_id})
        end

        {:noreply, %{state | waiters: Map.delete(state.waiters, gate_id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:expire_check, state) do
    now = DateTime.utc_now()

    all_gates()
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.each(fn gate ->
      case DateTime.from_iso8601(gate.requested_at) do
        {:ok, requested_at, _} ->
          age_ms = DateTime.diff(now, requested_at, :millisecond)

          if age_ms > gate.timeout_ms + 5_000 do
            # Stale gate (timeout message may have been dropped) — clean up
            expired = %{gate | status: :expired, resolved_at: now |> DateTime.to_iso8601()}
            :ets.insert(@table, {gate.gate_id, expired})
          end

        _ ->
          :ok
      end
    end)

    schedule_expire_check()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp notify_user(gate) do
    # 1. Post APM notification (CCEMHelper will deliver macOS banner)
    post_apm_notification(gate)

    # 2. Fire osascript dialog as reinforcement (non-blocking)
    fire_osascript(gate)
  end

  defp post_apm_notification(gate) do
    payload =
      Jason.encode!(%{
        title: "UPM Decision Required",
        message: gate.question,
        type: "warning",
        category: "upm_decision",
        actions: [
          %{label: "Deploy", href: "http://localhost:3032/api/v2/upm/gate/#{gate.gate_id}/approve", method: "post"},
          %{label: "Cancel", href: "http://localhost:3032/api/v2/upm/gate/#{gate.gate_id}/reject", method: "post"}
        ],
        metadata: %{gate_id: gate.gate_id, context: gate.context}
      })

    :httpc.request(
      :post,
      {~c"http://localhost:3032/api/notify", [], ~c"application/json", payload},
      [{:timeout, 3_000}],
      []
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("DecisionGate: notify failed: #{inspect(reason)}")
    end
  end

  defp fire_osascript(gate) do
    context_snippet = if gate.context != "", do: "\n\n#{String.slice(gate.context, 0, 200)}", else: ""
    message = "#{gate.question}#{context_snippet}"

    buttons = gate.options |> Enum.take(3) |> Enum.map(&inspect/1) |> Enum.join(", ")
    default_btn = gate.options |> List.first() |> inspect()

    script = ~s(display dialog "#{escape_applescript(message)}" buttons {#{buttons}} default button #{default_btn} with title "UPM Decision Required" with icon caution giving up after #{div(gate.timeout_ms, 1_000)})

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse button returned
        btn = output |> String.trim() |> parse_osascript_button()
        decision = if btn == List.first(gate.options), do: :approved, else: :rejected
        reason = if decision == :approved, do: "osascript", else: btn || "osascript_cancel"

        GenServer.call(__MODULE__, {:resolve, gate.gate_id, decision, reason})

      {_output, _code} ->
        # Dialog cancelled or gave up — leave for timeout handler
        Logger.debug("DecisionGate: osascript cancelled or timed out for gate #{gate.gate_id}")
    end
  rescue
    e ->
      Logger.warning("DecisionGate: osascript error: #{inspect(e)}")
  end

  defp escape_applescript(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp parse_osascript_button(output) do
    case Regex.run(~r/button returned:(.+)/, output) do
      [_, btn] -> String.trim(btn)
      _ -> nil
    end
  end

  defp all_gates do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.sort_by(& &1.requested_at, :desc)
  end

  defp generate_gate_id do
    "dg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_expire_check do
    Process.send_after(self(), :expire_check, @expire_check_ms)
  end
end
