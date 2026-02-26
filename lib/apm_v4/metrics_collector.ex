defmodule ApmV4.MetricsCollector do
  @moduledoc """
  GenServer for collecting and aggregating agent performance metrics.
  Uses ETS for per-agent per-minute metrics and fleet-wide aggregates.
  Phase 2.1 of CCEM APM v5.
  """

  use GenServer

  @pubsub ApmV4.PubSub
  @topic "apm:metrics"
  @agent_metrics_table :apm_agent_metrics
  @fleet_metrics_table :apm_fleet_metrics
  @fleet_interval_ms 30_000
  @prune_interval_ms 300_000
  @retention_seconds 86_400

  @metric_types ~w(response_time_ms error_count token_input token_output tool_calls task_duration_ms)a

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a metric value for an agent. Async cast, zero latency."
  @spec record(String.t(), atom(), number()) :: :ok
  def record(agent_id, metric_type, value) when metric_type in @metric_types do
    GenServer.cast(__MODULE__, {:record, agent_id, metric_type, value})
  end

  @doc "Get metrics for a specific agent."
  @spec get_agent_metrics(String.t(), keyword()) :: [map()]
  def get_agent_metrics(agent_id, opts \\ []) do
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit)

    min_bucket =
      if since do
        DateTime.to_unix(since, :second) |> div(60)
      else
        0
      end

    match_spec = [
      {{{agent_id, :"$1"}, :"$2"},
       [{:>=, :"$1", min_bucket}],
       [{{:"$1", :"$2"}}]}
    ]

    results =
      :ets.select(@agent_metrics_table, match_spec)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    results =
      if limit, do: Enum.take(results, limit), else: results

    Enum.map(results, fn {bucket, metrics} ->
      Map.merge(metrics, %{
        agent_id: agent_id,
        bucket: bucket,
        timestamp: DateTime.from_unix!(bucket * 60)
      })
    end)
  end

  @doc "Get latest fleet-wide aggregate metrics."
  @spec get_fleet_metrics() :: map()
  def get_fleet_metrics do
    case :ets.lookup(@fleet_metrics_table, :latest) do
      [{:latest, metrics}] -> metrics
      [] -> %{}
    end
  end

  @doc "Compute a health score (0..100) for an agent."
  @spec compute_health_score(String.t()) :: float()
  def compute_health_score(agent_id) do
    recent_metrics = get_agent_metrics(agent_id, since: ago(300))
    fleet = get_fleet_metrics()

    error_score = compute_error_score(recent_metrics)
    completion_score = compute_completion_score(agent_id)
    heartbeat_score = compute_heartbeat_score(agent_id)
    response_score = compute_response_score(recent_metrics, fleet)

    score = error_score * 0.4 + completion_score * 0.3 + heartbeat_score * 0.2 + response_score * 0.1

    score |> max(0.0) |> min(100.0) |> Float.round(1)
  end

  @doc "Get top N agents by health score."
  @spec get_top_agents(pos_integer()) :: [map()]
  def get_top_agents(n \\ 10) do
    agent_ids =
      :ets.tab2list(@agent_metrics_table)
      |> Enum.map(fn {{aid, _}, _} -> aid end)
      |> Enum.uniq()

    agent_ids
    |> Enum.map(fn aid ->
      %{agent_id: aid, health_score: compute_health_score(aid)}
    end)
    |> Enum.sort_by(& &1.health_score, :desc)
    |> Enum.take(n)
  end

  @doc "Prune metrics older than 24 hours."
  @spec prune() :: :ok
  def prune do
    GenServer.call(__MODULE__, :prune)
  end

  @doc "Manually trigger fleet aggregate recomputation."
  @spec recompute_fleet_metrics() :: :ok
  def recompute_fleet_metrics do
    GenServer.call(__MODULE__, :recompute_fleet)
  end

  @doc "Clear all metrics data (for testing)."
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@agent_metrics_table, [:ordered_set, :named_table, :public, read_concurrency: true])
    :ets.new(@fleet_metrics_table, [:set, :named_table, :public, read_concurrency: true])

    schedule_fleet_recompute()
    schedule_prune()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, agent_id, metric_type, value}, state) do
    bucket = current_minute_bucket()
    key = {agent_id, bucket}

    existing =
      case :ets.lookup(@agent_metrics_table, key) do
        [{^key, metrics}] -> metrics
        [] -> new_bucket_metrics()
      end

    updated = accumulate_metric(existing, metric_type, value)
    :ets.insert(@agent_metrics_table, {key, updated})

    {:noreply, state}
  end

  @impl true
  def handle_call(:prune, _from, state) do
    do_prune()
    {:reply, :ok, state}
  end

  def handle_call(:recompute_fleet, _from, state) do
    do_recompute_fleet()
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@agent_metrics_table)
    :ets.delete_all_objects(@fleet_metrics_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:fleet_recompute, state) do
    do_recompute_fleet()
    schedule_fleet_recompute()
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    do_prune()
    schedule_prune()
    {:noreply, state}
  end

  # --- Internal ---

  defp current_minute_bucket do
    System.system_time(:second) |> div(60)
  end

  defp new_bucket_metrics do
    %{
      response_time_ms: 0.0,
      response_time_count: 0,
      error_count: 0,
      token_input: 0,
      token_output: 0,
      tool_calls: 0,
      task_duration_ms: 0.0,
      task_duration_count: 0
    }
  end

  defp accumulate_metric(metrics, :response_time_ms, value) do
    count = metrics.response_time_count + 1
    total = metrics.response_time_ms * metrics.response_time_count + value
    %{metrics | response_time_ms: total / count, response_time_count: count}
  end

  defp accumulate_metric(metrics, :task_duration_ms, value) do
    count = metrics.task_duration_count + 1
    total = metrics.task_duration_ms * metrics.task_duration_count + value
    %{metrics | task_duration_ms: total / count, task_duration_count: count}
  end

  defp accumulate_metric(metrics, :error_count, value) do
    %{metrics | error_count: metrics.error_count + value}
  end

  defp accumulate_metric(metrics, :token_input, value) do
    %{metrics | token_input: metrics.token_input + value}
  end

  defp accumulate_metric(metrics, :token_output, value) do
    %{metrics | token_output: metrics.token_output + value}
  end

  defp accumulate_metric(metrics, :tool_calls, value) do
    %{metrics | tool_calls: metrics.tool_calls + value}
  end

  defp do_recompute_fleet do
    all = :ets.tab2list(@agent_metrics_table)

    agent_ids = all |> Enum.map(fn {{aid, _}, _} -> aid end) |> Enum.uniq()

    total_errors = all |> Enum.map(fn {_, m} -> m.error_count end) |> Enum.sum()
    total_tokens_in = all |> Enum.map(fn {_, m} -> m.token_input end) |> Enum.sum()
    total_tokens_out = all |> Enum.map(fn {_, m} -> m.token_output end) |> Enum.sum()
    total_tool_calls = all |> Enum.map(fn {_, m} -> m.tool_calls end) |> Enum.sum()

    response_times =
      all
      |> Enum.filter(fn {_, m} -> m.response_time_count > 0 end)
      |> Enum.map(fn {_, m} -> m.response_time_ms end)

    avg_response_time =
      if response_times == [],
        do: 0.0,
        else: Enum.sum(response_times) / length(response_times)

    health_scores =
      Enum.map(agent_ids, &compute_health_score/1)

    avg_health =
      if health_scores == [],
        do: 0.0,
        else: Enum.sum(health_scores) / length(health_scores)

    metrics = %{
      total_agents: length(agent_ids),
      avg_health_score: Float.round(avg_health, 1),
      total_errors: total_errors,
      total_tokens_input: total_tokens_in,
      total_tokens_output: total_tokens_out,
      total_tool_calls: total_tool_calls,
      avg_response_time_ms: Float.round(avg_response_time, 2),
      computed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@fleet_metrics_table, {:latest, metrics})

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:fleet_metrics_updated, metrics})

    metrics
  end

  defp do_prune do
    cutoff_bucket = (System.system_time(:second) - @retention_seconds) |> div(60)

    :ets.tab2list(@agent_metrics_table)
    |> Enum.each(fn {{_aid, bucket} = key, _} ->
      if bucket < cutoff_bucket, do: :ets.delete(@agent_metrics_table, key)
    end)
  end

  defp schedule_fleet_recompute do
    Process.send_after(self(), :fleet_recompute, @fleet_interval_ms)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second)
  end

  defp compute_error_score(metrics) do
    total_errors = metrics |> Enum.map(fn m -> m.error_count end) |> Enum.sum()
    # Fewer errors = higher score. 0 errors = 100, 10+ errors = 0
    max(0.0, 100.0 - total_errors * 10.0)
  end

  defp compute_completion_score(agent_id) do
    agent = ApmV4.AgentRegistry.get_agent(agent_id)

    case agent do
      nil -> 50.0
      %{status: status} ->
        case status do
          s when s in ["completed", "finished"] -> 100.0
          "running" -> 75.0
          "idle" -> 50.0
          "error" -> 10.0
          _ -> 50.0
        end
    end
  end

  defp compute_heartbeat_score(agent_id) do
    agent = ApmV4.AgentRegistry.get_agent(agent_id)

    case agent do
      nil -> 0.0
      %{last_seen: last_seen} ->
        case DateTime.from_iso8601(last_seen) do
          {:ok, dt, _} ->
            seconds_ago = DateTime.diff(DateTime.utc_now(), dt, :second)
            # Within 60s = 100, decays to 0 over 10 min
            max(0.0, 100.0 - seconds_ago / 6.0)

          _ -> 0.0
        end
    end
  end

  defp compute_response_score(metrics, fleet) do
    response_times =
      metrics
      |> Enum.filter(fn m -> m[:response_time_count] && m[:response_time_count] > 0 end)
      |> Enum.map(fn m -> m.response_time_ms end)

    if response_times == [] do
      50.0
    else
      avg = Enum.sum(response_times) / length(response_times)
      fleet_avg = Map.get(fleet, :avg_response_time_ms, avg)

      if fleet_avg == 0.0 do
        50.0
      else
        ratio = avg / fleet_avg
        # If at fleet avg = 50, faster = higher, slower = lower
        max(0.0, min(100.0, 100.0 - (ratio - 0.5) * 100.0))
      end
    end
  end
end
