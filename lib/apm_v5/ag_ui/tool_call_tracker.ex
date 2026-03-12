defmodule ApmV5.AgUi.ToolCallTracker do
  @moduledoc """
  Tracks in-flight tool calls with start/args/end lifecycle.

  Computes duration and maintains per-agent call history with ETS-backed storage.
  Entries older than 1 hour are auto-pruned via periodic timer.

  ## US-010 Acceptance Criteria (DoD):
  - GenServer with ETS table :ag_ui_tool_calls
  - track_start/3 creates entry with status: :in_progress
  - track_args/2 updates entry with args data
  - track_end/2 marks :completed with duration_ms, emits TOOL_CALL_END via EventBus
  - track_result/3 stores result, emits TOOL_CALL_RESULT via EventBus
  - list_active/0 returns all in-progress; list_by_agent/1 returns agent history
  - Periodic 60s prune of entries older than 1 hour
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  @table :ag_ui_tool_calls
  @prune_interval_ms 60_000
  @max_age_ms 3_600_000

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Tracks a tool call start. Returns the generated tool_call_id."
  @spec track_start(String.t(), String.t(), String.t()) :: String.t()
  def track_start(agent_id, tool_name, tool_call_id \\ nil) do
    tc_id = tool_call_id || generate_tool_call_id()
    now = System.monotonic_time(:millisecond)

    entry = %{
      tool_call_id: tc_id,
      agent_id: agent_id,
      tool_name: tool_name,
      started_at: now,
      started_at_wall: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: :in_progress,
      args: nil,
      result: nil,
      duration_ms: nil
    }

    :ets.insert(@table, {tc_id, entry})

    EventBus.publish("TOOL_CALL_START", %{
      agent_id: agent_id,
      tool_call_id: tc_id,
      tool_name: tool_name
    })

    tc_id
  end

  @doc "Updates a tool call entry with args data."
  @spec track_args(String.t(), term()) :: :ok | :not_found
  def track_args(tool_call_id, args) do
    case :ets.lookup(@table, tool_call_id) do
      [{^tool_call_id, entry}] ->
        :ets.insert(@table, {tool_call_id, %{entry | args: args}})

        EventBus.publish("TOOL_CALL_ARGS", %{
          agent_id: entry.agent_id,
          tool_call_id: tool_call_id,
          args: args
        })

        :ok

      [] ->
        :not_found
    end
  end

  @doc "Marks a tool call as completed with duration_ms."
  @spec track_end(String.t(), map()) :: :ok | :not_found
  def track_end(tool_call_id, metadata \\ %{}) do
    case :ets.lookup(@table, tool_call_id) do
      [{^tool_call_id, entry}] ->
        now = System.monotonic_time(:millisecond)
        duration_ms = now - entry.started_at

        updated = %{entry | status: :completed, duration_ms: duration_ms}
        :ets.insert(@table, {tool_call_id, updated})

        EventBus.publish("TOOL_CALL_END", %{
          agent_id: entry.agent_id,
          tool_call_id: tool_call_id,
          tool_name: entry.tool_name,
          duration_ms: duration_ms,
          metadata: metadata
        })

        :ok

      [] ->
        :not_found
    end
  end

  @doc "Stores tool call result and emits TOOL_CALL_RESULT."
  @spec track_result(String.t(), String.t(), term()) :: :ok | :not_found
  def track_result(tool_call_id, result_type, result) do
    case :ets.lookup(@table, tool_call_id) do
      [{^tool_call_id, entry}] ->
        :ets.insert(@table, {tool_call_id, %{entry | result: result}})

        EventBus.publish("TOOL_CALL_RESULT", %{
          agent_id: entry.agent_id,
          tool_call_id: tool_call_id,
          tool_name: entry.tool_name,
          result_type: result_type,
          result: result
        })

        :ok

      [] ->
        :not_found
    end
  end

  @doc "Returns all in-progress tool calls."
  @spec list_active() :: [map()]
  def list_active do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, entry} -> entry.status == :in_progress end)
    |> Enum.map(fn {_id, entry} -> entry end)
  end

  @doc "Returns tool call history for a specific agent."
  @spec list_by_agent(String.t()) :: [map()]
  def list_by_agent(agent_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, entry} -> entry.agent_id == agent_id end)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.started_at, :desc)
  end

  @doc "Returns a specific tool call by ID."
  @spec get(String.t()) :: map() | nil
  def get(tool_call_id) do
    case :ets.lookup(@table, tool_call_id) do
      [{^tool_call_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Returns aggregate statistics."
  @spec stats() :: map()
  def stats do
    all = :ets.tab2list(@table) |> Enum.map(fn {_id, e} -> e end)
    active = Enum.count(all, & &1.status == :in_progress)
    completed = Enum.count(all, & &1.status == :completed)

    durations =
      all
      |> Enum.filter(& &1.duration_ms)
      |> Enum.map(& &1.duration_ms)

    avg_duration = if durations == [], do: 0, else: Enum.sum(durations) / length(durations)

    tool_counts =
      all
      |> Enum.group_by(& &1.tool_name)
      |> Enum.map(fn {name, calls} -> {name, length(calls)} end)
      |> Enum.sort_by(fn {_name, count} -> count end, :desc)
      |> Enum.take(10)
      |> Enum.into(%{})

    agent_counts =
      all
      |> Enum.group_by(& &1.agent_id)
      |> Enum.map(fn {id, calls} -> {id, length(calls)} end)
      |> Enum.into(%{})

    %{
      total: length(all),
      active: active,
      completed: completed,
      avg_duration_ms: Float.round(avg_duration / 1, 1),
      top_tools: tool_counts,
      calls_by_agent: agent_counts
    }
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_old_entries()
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp generate_tool_call_id do
    "tc-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_old_entries do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.each(fn {id, entry} ->
      if now - entry.started_at > @max_age_ms do
        :ets.delete(@table, id)
      end
    end)
  end
end
