defmodule Apm.Coalesce.DecisionGateStore do
  @moduledoc """
  ETS-backed store for coalesce decision gates.

  Extends the approval_gate pattern to support:
  - Per-run gate registration
  - Auto-approve for high-confidence gates
  - Human gate pending/approve/reject/defer lifecycle
  - PubSub broadcast on every state transition
  - Gate history for audit trail

  Gate IDs are namespaced as "<run_id>:<gate_id>" (e.g. "crs-001:G3").
  """

  use GenServer

  require Logger

  alias Apm.AgUi.EventBus

  @table :coalesce_gates
  @expire_check_ms 120_000
  @default_timeout_ms 3_600_000

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new decision gate."
  @spec register_gate(String.t(), map()) :: {:ok, String.t()}
  def register_gate(composite_id, params) do
    GenServer.call(__MODULE__, {:register, composite_id, params})
  end

  @doc "Auto-approve a gate (high-confidence path)."
  @spec auto_approve(String.t(), map()) :: :ok | {:error, term()}
  def auto_approve(composite_id, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:auto_approve, composite_id, metadata})
  end

  @doc "Human approves a gate."
  @spec approve(String.t(), map()) :: :ok | {:error, term()}
  def approve(composite_id, approver_info \\ %{}) do
    GenServer.call(__MODULE__, {:approve, composite_id, approver_info})
  end

  @doc "Human rejects a gate."
  @spec reject(String.t(), String.t()) :: :ok | {:error, term()}
  def reject(composite_id, reason \\ "rejected by user") do
    GenServer.call(__MODULE__, {:reject, composite_id, reason})
  end

  @doc "Defer a gate for later review."
  @spec defer(String.t(), String.t()) :: :ok | {:error, term()}
  def defer(composite_id, note \\ "") do
    GenServer.call(__MODULE__, {:defer, composite_id, note})
  end

  @doc "Get a gate by composite_id."
  @spec get(String.t()) :: map() | nil
  def get(composite_id) do
    case :ets.lookup(@table, composite_id) do
      [{^composite_id, gate}] -> gate
      [] -> nil
    end
  end

  @doc "List all gates for a run."
  @spec list_for_run(String.t()) :: [map()]
  def list_for_run(run_id) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.filter(&(&1.run_id == run_id))
    |> Enum.sort_by(& &1.registered_at)
  end

  @doc "Count pending human gates."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.count(&(&1.status == :pending and &1.type == :human))
  end

  @doc "List all pending human gates across all runs."
  @spec list_pending() :: [map()]
  def list_pending do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.filter(&(&1.status == :pending and &1.type == :human))
    |> Enum.sort_by(& &1.registered_at)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    schedule_expire_check()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, composite_id, params}, _from, state) do
    gate = %{
      composite_id: composite_id,
      run_id: params[:run_id] || params["run_id"],
      gate_id: params[:gate_id] || params["gate_id"],
      type: params[:type] || :human,
      status: :pending,
      metadata: params[:metadata] || %{},
      registered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      decided_at: nil,
      decided_by: nil,
      decision_note: nil,
      timeout_ms: @default_timeout_ms
    }

    :ets.insert(@table, {composite_id, gate})

    _emit_event("coalesce_gate_registered", gate)
    Logger.info("[CoalesceGate] Registered #{composite_id} type=#{gate.type}")

    {:reply, {:ok, composite_id}, state}
  end

  def handle_call({:auto_approve, composite_id, metadata}, _from, state) do
    _transition(composite_id, :approved, %{decided_by: "auto", metadata: metadata}, state)
  end

  def handle_call({:approve, composite_id, approver_info}, _from, state) do
    _transition(composite_id, :approved, %{decided_by: approver_info}, state)
  end

  def handle_call({:reject, composite_id, reason}, _from, state) do
    _transition(composite_id, :rejected, %{decided_by: "user", decision_note: reason}, state)
  end

  def handle_call({:defer, composite_id, note}, _from, state) do
    _transition(composite_id, :deferred, %{decided_by: "user", decision_note: note}, state)
  end

  @impl true
  def handle_info(:expire_check, state) do
    now = DateTime.utc_now()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.each(fn gate ->
      registered_at = gate.registered_at |> DateTime.from_iso8601() |> elem(1)
      age_ms = DateTime.diff(now, registered_at, :millisecond)

      if age_ms > gate.timeout_ms do
        expired = %{
          gate
          | status: :expired,
            decided_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(@table, {gate.composite_id, expired})
        _emit_event("coalesce_gate_expired", expired)

        # Notify orchestrator
        send(
          Apm.Coalesce.CoalesceOrchestrator,
          {:gate_decided, gate.run_id, gate.gate_id, :expired}
        )
      end
    end)

    schedule_expire_check()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────────

  defp _transition(composite_id, new_status, extra, state) do
    case :ets.lookup(@table, composite_id) do
      [{^composite_id, %{status: :pending} = gate}] ->
        updated =
          gate
          |> Map.merge(%{
            status: new_status,
            decided_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })
          |> Map.merge(extra)

        :ets.insert(@table, {composite_id, updated})
        _emit_event("coalesce_gate_#{new_status}", updated)

        # Notify orchestrator
        send(
          Apm.Coalesce.CoalesceOrchestrator,
          {:gate_decided, gate.run_id, gate.gate_id, new_status}
        )

        {:reply, :ok, state}

      [{^composite_id, _}] ->
        {:reply, {:error, :not_pending}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp _emit_event(event_name, gate) do
    EventBus.publish("CUSTOM", %{
      name: event_name,
      agent_id: "coalesce-gate-store",
      value: Map.take(gate, [:composite_id, :run_id, :gate_id, :type, :status, :metadata])
    })

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "apm:coalesce",
      {String.to_atom(event_name), gate}
    )
  end

  defp schedule_expire_check do
    Process.send_after(self(), :expire_check, @expire_check_ms)
  end
end
