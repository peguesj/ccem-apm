defmodule ApmV5.AgUi.StateManager do
  @moduledoc """
  Manages per-agent state using AG-UI snapshot/delta pattern.

  Tracks state for each agent registered with APM. Emits STATE_SNAPSHOT
  on initial state set and STATE_DELTA on subsequent changes.

  State is stored in ETS for fast concurrent reads.
  """

  use GenServer

  alias ApmV5.EventStream

  @table :ag_ui_agent_state
  @pubsub ApmV5.PubSub

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Gets the current state for an agent. Returns nil if no state tracked."
  @spec get_state(String.t()) :: map() | nil
  def get_state(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, state, _version}] -> state
      [] -> nil
    end
  end

  @doc "Gets state and version for an agent."
  @spec get_state_versioned(String.t()) :: {map(), non_neg_integer()} | nil
  def get_state_versioned(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, state, version}] -> {state, version}
      [] -> nil
    end
  end

  @doc """
  Sets the full state for an agent (snapshot).
  Emits a STATE_SNAPSHOT event.
  """
  @spec set_state(String.t(), map()) :: :ok
  def set_state(agent_id, state) when is_map(state) do
    GenServer.call(__MODULE__, {:set_state, agent_id, state})
  end

  @doc """
  Applies a JSON Patch delta to an agent's state.
  Emits a STATE_DELTA event on success.
  """
  @spec apply_delta(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def apply_delta(agent_id, operations) when is_list(operations) do
    GenServer.call(__MODULE__, {:apply_delta, agent_id, operations})
  end

  @doc "Lists all agents with tracked state."
  @spec list_agents() :: [String.t()]
  def list_agents do
    :ets.tab2list(@table)
    |> Enum.map(fn {agent_id, _state, _version} -> agent_id end)
  end

  @doc "Removes state tracking for an agent."
  @spec remove_state(String.t()) :: :ok
  def remove_state(agent_id) do
    GenServer.call(__MODULE__, {:remove_state, agent_id})
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set_state, agent_id, state}, _from, data) do
    version = current_version(agent_id) + 1
    :ets.insert(@table, {agent_id, state, version})

    # Emit STATE_SNAPSHOT
    EventStream.emit("STATE_SNAPSHOT", %{
      agent_id: agent_id,
      snapshot: state,
      version: version
    })

    # Broadcast to dashboard
    Phoenix.PubSub.broadcast(
      @pubsub,
      "dashboard:updates",
      {:agent_state_changed, agent_id, state}
    )

    {:reply, :ok, data}
  end

  def handle_call({:apply_delta, agent_id, operations}, _from, data) do
    case get_state(agent_id) do
      nil ->
        {:reply, {:error, :no_state}, data}

      current_state ->
        case apply_patch(current_state, operations) do
          {:ok, new_state} ->
            version = current_version(agent_id) + 1
            :ets.insert(@table, {agent_id, new_state, version})

            # Emit STATE_DELTA
            EventStream.emit("STATE_DELTA", %{
              agent_id: agent_id,
              delta: operations,
              version: version
            })

            {:reply, {:ok, new_state}, data}

          {:error, reason} ->
            {:reply, {:error, reason}, data}
        end
    end
  end

  def handle_call({:remove_state, agent_id}, _from, data) do
    :ets.delete(@table, agent_id)
    {:reply, :ok, data}
  end

  # -- JSON Patch (simplified) ------------------------------------------------

  defp apply_patch(state, operations) do
    Enum.reduce_while(operations, {:ok, state}, fn op, {:ok, current} ->
      case apply_operation(current, op) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_operation(state, %{"op" => "add", "path" => "/" <> key, "value" => value}) do
    {:ok, Map.put(state, key, value)}
  end

  defp apply_operation(state, %{"op" => "remove", "path" => "/" <> key}) do
    {:ok, Map.delete(state, key)}
  end

  defp apply_operation(state, %{"op" => "replace", "path" => "/" <> key, "value" => value}) do
    {:ok, Map.put(state, key, value)}
  end

  defp apply_operation(_state, op) do
    {:error, "unsupported operation: #{inspect(op)}"}
  end

  # -- Helpers ----------------------------------------------------------------

  defp current_version(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, _state, version}] -> version
      [] -> 0
    end
  end
end
