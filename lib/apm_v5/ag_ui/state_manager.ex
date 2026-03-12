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
  @snapshot_interval_ms Application.compile_env(:apm_v5, :snapshot_interval_ms, 30_000)

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

  @doc "Returns a map of all agent states for bulk snapshot."
  @spec get_all_states() :: map()
  def get_all_states do
    :ets.tab2list(@table)
    |> Enum.into(%{}, fn {agent_id, state, version} ->
      {agent_id, %{state: state, version: version}}
    end)
  end

  @doc "Computes minimal JSON Patch operations between two state maps."
  @spec add_computed_delta(map(), map()) :: [map()]
  def add_computed_delta(old_state, new_state) when is_map(old_state) and is_map(new_state) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old_state)), MapSet.new(Map.keys(new_state)))

    Enum.flat_map(all_keys, fn key ->
      old_val = Map.get(old_state, key)
      new_val = Map.get(new_state, key)

      cond do
        is_nil(old_val) and not is_nil(new_val) ->
          [%{"op" => "add", "path" => "/#{key}", "value" => new_val}]

        not is_nil(old_val) and is_nil(new_val) ->
          [%{"op" => "remove", "path" => "/#{key}"}]

        old_val != new_val and is_map(old_val) and is_map(new_val) ->
          # Nested diff with path prefix
          add_computed_delta(old_val, new_val)
          |> Enum.map(fn op ->
            %{op | "path" => "/#{key}" <> op["path"]}
          end)

        old_val != new_val ->
          [%{"op" => "replace", "path" => "/#{key}", "value" => new_val}]

        true ->
          []
      end
    end)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_snapshot()
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

  @impl true
  def handle_info(:emit_snapshots, data) do
    # US-014: Periodic STATE_SNAPSHOT emission for all tracked agents
    :ets.tab2list(@table)
    |> Enum.each(fn {agent_id, state, version} ->
      EventStream.emit("STATE_SNAPSHOT", %{
        agent_id: agent_id,
        snapshot: state,
        version: version,
        periodic: true
      })
    end)

    schedule_snapshot()
    {:noreply, data}
  end

  def handle_info(_msg, data), do: {:noreply, data}

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

  defp schedule_snapshot do
    Process.send_after(self(), :emit_snapshots, @snapshot_interval_ms)
  end
end
