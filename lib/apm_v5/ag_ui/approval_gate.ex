defmodule ApmV5.AgUi.ApprovalGate do
  @moduledoc """
  Manages approval requests from agents for human-in-the-loop control.

  ## US-026 Acceptance Criteria (DoD):
  - GenServer with ETS table :ag_ui_approval_gates
  - request_approval/2 creates pending gate with gate_id
  - approve/2 marks :approved, emits 'approval_resolved' event
  - reject/2 marks :rejected with reason
  - list_pending/0, list_by_agent/1
  - CUSTOM 'approval_requested' event emitted on request
  - Gates auto-expire after 30 minutes
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  @table :ag_ui_approval_gates
  @expire_check_ms 60_000
  @default_timeout_ms 1_800_000

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Creates a pending approval gate."
  @spec request_approval(String.t(), map()) :: {:ok, String.t()}
  def request_approval(agent_id, params) do
    GenServer.call(__MODULE__, {:request, agent_id, params})
  end

  @doc "Approves a pending gate."
  @spec approve(String.t(), map()) :: :ok | {:error, :not_found | :not_pending}
  def approve(gate_id, approver_info \\ %{}) do
    GenServer.call(__MODULE__, {:approve, gate_id, approver_info})
  end

  @doc "Rejects a pending gate."
  @spec reject(String.t(), String.t()) :: :ok | {:error, :not_found | :not_pending}
  def reject(gate_id, reason) do
    GenServer.call(__MODULE__, {:reject, gate_id, reason})
  end

  @doc "Returns all pending gates."
  @spec list_pending() :: [map()]
  def list_pending do
    all_gates()
    |> Enum.filter(& &1.status == :pending)
  end

  @doc "Returns gates for a specific agent."
  @spec list_by_agent(String.t()) :: [map()]
  def list_by_agent(agent_id) do
    all_gates()
    |> Enum.filter(& &1.agent_id == agent_id)
  end

  @doc "Returns all gates."
  @spec list_all() :: [map()]
  def list_all, do: all_gates()

  @doc "Gets a specific gate."
  @spec get(String.t()) :: map() | nil
  def get(gate_id) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, gate}] -> gate
      [] -> nil
    end
  end

  @doc "Returns count of pending gates."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    list_pending() |> length()
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    schedule_expire_check()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:request, agent_id, params}, _from, state) do
    gate_id = generate_gate_id()

    gate = %{
      gate_id: gate_id,
      agent_id: agent_id,
      description: params["description"] || params[:description] || "Approval requested",
      metadata: params["metadata"] || params[:metadata] || %{},
      status: :pending,
      requested_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      resolved_at: nil,
      approver: nil,
      reject_reason: nil,
      timeout_ms: params["timeout_ms"] || @default_timeout_ms
    }

    :ets.insert(@table, {gate_id, gate})

    EventBus.publish("CUSTOM", %{
      name: "approval_requested",
      agent_id: agent_id,
      value: %{
        gate_id: gate_id,
        description: gate.description,
        metadata: gate.metadata
      }
    })

    {:reply, {:ok, gate_id}, state}
  end

  def handle_call({:approve, gate_id, approver_info}, _from, state) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, %{status: :pending} = gate}] ->
        updated = %{gate |
          status: :approved,
          resolved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          approver: approver_info
        }

        :ets.insert(@table, {gate_id, updated})

        EventBus.publish("CUSTOM", %{
          name: "approval_approve",
          agent_id: gate.agent_id,
          value: %{gate_id: gate_id, actor: approver_info}
        })

        {:reply, :ok, state}

      [{^gate_id, _gate}] ->
        {:reply, {:error, :not_pending}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:reject, gate_id, reason}, _from, state) do
    case :ets.lookup(@table, gate_id) do
      [{^gate_id, %{status: :pending} = gate}] ->
        updated = %{gate |
          status: :rejected,
          resolved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          reject_reason: reason
        }

        :ets.insert(@table, {gate_id, updated})

        EventBus.publish("CUSTOM", %{
          name: "approval_reject",
          agent_id: gate.agent_id,
          value: %{gate_id: gate_id, reason: reason}
        })

        {:reply, :ok, state}

      [{^gate_id, _gate}] ->
        {:reply, {:error, :not_pending}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:expire_check, state) do
    now = DateTime.utc_now()

    all_gates()
    |> Enum.filter(& &1.status == :pending)
    |> Enum.each(fn gate ->
      requested_at = DateTime.from_iso8601(gate.requested_at) |> elem(1)
      age_ms = DateTime.diff(now, requested_at, :millisecond)

      if age_ms > gate.timeout_ms do
        expired = %{gate | status: :expired, resolved_at: DateTime.utc_now() |> DateTime.to_iso8601()}
        :ets.insert(@table, {gate.gate_id, expired})

        EventBus.publish("CUSTOM", %{
          name: "approval_expired",
          agent_id: gate.agent_id,
          value: %{gate_id: gate.gate_id}
        })
      end
    end)

    schedule_expire_check()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp all_gates do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, gate} -> gate end)
    |> Enum.sort_by(& &1.requested_at, :desc)
  end

  defp generate_gate_id do
    "gate-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_expire_check do
    Process.send_after(self(), :expire_check, @expire_check_ms)
  end
end
