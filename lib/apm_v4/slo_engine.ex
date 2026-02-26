defmodule ApmV4.SloEngine do
  @moduledoc """
  GenServer for tracking Service Level Objectives (SLOs).

  Maintains 5 SLIs with targets, records success/failure events,
  computes error budgets and burn rates, and snapshots hourly history.
  """

  use GenServer

  @pubsub ApmV4.PubSub
  @topic "apm:slo"
  @current_table :apm_slo_current
  @history_table :apm_slo_history
  @snapshot_interval_ms 60_000
  @history_retention_hours 30 * 24

  @sli_definitions %{
    agent_availability: %{target: 99.0, description: "% of agents with status != error"},
    task_completion_rate: %{target: 95.0, description: "% of tasks completed vs started"},
    api_latency_p99: %{target: 99.0, description: "99th percentile API response time < 200ms"},
    error_free_rate: %{target: 97.0, description: "% of requests without errors"},
    fleet_heartbeat_health: %{target: 99.5, description: "% of agents with heartbeat < 5min old"}
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns current value, target, and status for a single SLI."
  @spec get_sli(atom()) :: map() | nil
  def get_sli(name) do
    case :ets.lookup(@current_table, name) do
      [{^name, sli}] -> sli
      [] -> nil
    end
  end

  @doc "Returns all 5 SLIs with current values."
  @spec get_all_slis() :: [map()]
  def get_all_slis do
    :ets.tab2list(@current_table)
    |> Enum.map(fn {_k, sli} -> sli end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns remaining error budget and burn rate for an SLI."
  @spec get_error_budget(atom()) :: map() | nil
  def get_error_budget(name) do
    case get_sli(name) do
      nil ->
        nil

      sli ->
        total = sli.total_events
        errors = sli.error_events
        target = sli.target

        budget_fraction = (100.0 - target) / 100.0
        allowed_errors = if total > 0, do: budget_fraction * total, else: budget_fraction
        remaining = max(allowed_errors - errors, 0.0)
        remaining_pct = if allowed_errors > 0, do: remaining / allowed_errors * 100.0, else: 100.0

        burn_rate_1h = compute_burn_rate(name, 1, budget_fraction)
        burn_rate_6h = compute_burn_rate(name, 6, budget_fraction)

        %{
          name: name,
          target: target,
          budget_total: allowed_errors,
          budget_remaining: remaining,
          budget_remaining_pct: Float.round(remaining_pct, 2),
          burn_rate_1h: burn_rate_1h,
          burn_rate_6h: burn_rate_6h
        }
    end
  end

  @doc "Returns hourly history for sparkline display."
  @spec get_history(atom(), non_neg_integer()) :: [map()]
  def get_history(name, hours \\ 24) do
    now_hour = current_hour_timestamp()
    start_hour = now_hour - hours * 3600

    # Scan the ordered_set for keys in range {name, start_hour} to {name, now_hour}
    :ets.select(@history_table, [
      {{{:"$1", :"$2"}, :"$3"},
       [{:==, :"$1", name}, {:>=, :"$2", start_hour}, {:"=<", :"$2", now_hour}],
       [:"$3"]}
    ])
    |> Enum.sort_by(& &1.hour)
  end

  @doc "Record a success/failure event for an SLI."
  @spec record_event(atom(), :ok | :error) :: :ok
  def record_event(sli_name, outcome) do
    GenServer.call(__MODULE__, {:record_event, sli_name, outcome})
  end

  @doc "Force a snapshot (for testing)."
  @spec snapshot_now() :: :ok
  def snapshot_now do
    GenServer.call(__MODULE__, :snapshot_now)
  end

  @doc "Clear all SLO data and re-seed defaults (for testing)."
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    create_tables()
    seed_slis()

    unless Keyword.get(opts, :skip_timer, false) do
      Process.send_after(self(), :snapshot, @snapshot_interval_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:record_event, sli_name, outcome}, _from, state) do
    case :ets.lookup(@current_table, sli_name) do
      [{^sli_name, sli}] ->
        new_total = sli.total_events + 1
        new_errors = if outcome == :error, do: sli.error_events + 1, else: sli.error_events
        new_value = if new_total > 0, do: Float.round((new_total - new_errors) / new_total * 100.0, 2), else: 100.0
        old_status = sli.status
        new_status = if new_value >= sli.target, do: :met, else: :breached

        now = System.system_time(:second)

        # Track event in recent window for burn rate
        recent = [{now, outcome} | Enum.take(sli.recent_events, 9_999)]

        updated = %{sli |
          current_value: new_value,
          total_events: new_total,
          error_events: new_errors,
          status: new_status,
          recent_events: recent,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(@current_table, {sli_name, updated})

        if old_status != new_status do
          try do
            Phoenix.PubSub.broadcast(@pubsub, @topic, {:slo_transition, sli_name, old_status, new_status})
          rescue
            ArgumentError -> :ok
          end
        end

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :unknown_sli}, state}
    end
  end

  def handle_call(:snapshot_now, _from, state) do
    do_snapshot()
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@current_table)
    :ets.delete_all_objects(@history_table)
    seed_slis()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:snapshot, state) do
    do_snapshot()
    prune_history()
    Process.send_after(self(), :snapshot, @snapshot_interval_ms)
    {:noreply, state}
  end

  # --- Internal ---

  defp create_tables do
    if :ets.whereis(@current_table) == :undefined do
      :ets.new(@current_table, [:set, :named_table, :public, read_concurrency: true])
    end

    if :ets.whereis(@history_table) == :undefined do
      :ets.new(@history_table, [:ordered_set, :named_table, :public, read_concurrency: true])
    end
  end

  defp seed_slis do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    for {name, def} <- @sli_definitions do
      sli = %{
        name: name,
        description: def.description,
        target: def.target,
        current_value: 100.0,
        total_events: 0,
        error_events: 0,
        status: :met,
        recent_events: [],
        updated_at: now
      }

      :ets.insert(@current_table, {name, sli})
    end
  end

  defp do_snapshot do
    hour = current_hour_timestamp()

    :ets.tab2list(@current_table)
    |> Enum.each(fn {name, sli} ->
      snapshot = %{
        name: name,
        hour: hour,
        value: sli.current_value,
        target: sli.target,
        status: sli.status,
        total_events: sli.total_events,
        error_events: sli.error_events
      }

      :ets.insert(@history_table, {{name, hour}, snapshot})
    end)
  end

  defp prune_history do
    cutoff = current_hour_timestamp() - @history_retention_hours * 3600

    :ets.select_delete(@history_table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp current_hour_timestamp do
    now = System.system_time(:second)
    div(now, 3600) * 3600
  end

  defp compute_burn_rate(name, window_hours, budget_fraction) do
    case get_sli(name) do
      nil ->
        0.0

      sli ->
        cutoff = System.system_time(:second) - window_hours * 3600
        window_events = Enum.filter(sli.recent_events, fn {ts, _} -> ts >= cutoff end)
        window_total = length(window_events)
        window_errors = Enum.count(window_events, fn {_, o} -> o == :error end)

        if window_total > 0 and budget_fraction > 0 do
          error_rate = window_errors / window_total
          # burn rate = (error_rate / budget) normalized to 30-day window
          Float.round(error_rate / budget_fraction * (30 * 24 / window_hours), 2)
        else
          0.0
        end
    end
  end
end
