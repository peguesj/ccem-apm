defmodule ApmV5.Auth.RiskScoreAggregator do
  @moduledoc """
  Composite session/formation risk score aggregator.

  Subscribes to `"auth:decisions"` PubSub (broadcast by `PolicyDecisionStore`)
  and maintains two ETS tables keyed by session_id and formation_id respectively.

  ## Risk score formula

  For each entity (session or formation) the aggregator looks back over a
  rolling 5-minute window of decisions and computes:

      base_score   = mean(risk_severity(d.risk_level)) for d in window
      denial_boost = denial_rate * 1.5
      crit_boost   = min(critical_count * 0.25, 1.0)
      score        = min(base_score + denial_boost + crit_boost, 4.0)

  Where `risk_severity/1` returns 0–4 per `ApmV5.Auth.Types.risk_severity/1`.

  ## ETS layout

  Table `:risk_scores` (`:set`, `:protected`, `read_concurrency: true`):
    - Key: `{:session, session_id}` | `{:formation, formation_id}`
    - Value: `%{score: float, level: atom, tool_call_count: integer,
              critical_count: integer, denial_rate: float,
              last_updated: DateTime.t()}`

  ## PubSub broadcast

  Every time a score is recomputed the aggregator broadcasts a
  `{:risk_aggregated, key, aggregate}` message on `"auth:risks"`.

  Periodic full-sweep broadcast runs every 30 seconds so downstream
  LiveViews can refresh even when quiet.

  ## API

    - `for_session(session_id)` → `aggregate | nil`
    - `for_formation(formation_id)` → `aggregate | nil`
    - `top_sessions(limit \\\\ 10)` → `[{session_id, aggregate}]`
    - `top_formations(limit \\\\ 10)` → `[{formation_id, aggregate}]`

  Spec: CP-231 / US-463 / Plane 5ac6140f — v9.3.0 comp-map2.
  """

  use GenServer
  require Logger

  alias ApmV5.Auth.{PolicyDecisionStore, Types}

  @table :risk_scores
  @pubsub_in "auth:decisions"
  @pubsub_out "auth:risks"
  @window_ms 5 * 60 * 1_000
  @sweep_interval_ms 30_000

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type aggregate :: %{
          score: float(),
          level: Types.risk_level(),
          tool_call_count: non_neg_integer(),
          critical_count: non_neg_integer(),
          denial_rate: float(),
          last_updated: DateTime.t()
        }

  @type scope_key :: {:session, String.t()} | {:formation, String.t()}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current risk aggregate for `session_id`, or `nil` if no
  decisions have been recorded for that session.
  """
  @spec for_session(String.t()) :: aggregate() | nil
  def for_session(session_id) when is_binary(session_id) do
    lookup({:session, session_id})
  end

  @doc """
  Returns the current risk aggregate for `formation_id`, or `nil` if no
  decisions have been recorded for that formation.
  """
  @spec for_formation(String.t()) :: aggregate() | nil
  def for_formation(formation_id) when is_binary(formation_id) do
    lookup({:formation, formation_id})
  end

  @doc """
  Returns the top `limit` sessions by descending composite risk score.
  """
  @spec top_sessions(pos_integer()) :: [{String.t(), aggregate()}]
  def top_sessions(limit \\ 10) when is_integer(limit) and limit > 0 do
    top_by_prefix(:session, limit)
  end

  @doc """
  Returns the top `limit` formations by descending composite risk score.
  """
  @spec top_formations(pos_integer()) :: [{String.t(), aggregate()}]
  def top_formations(limit \\ 10) when is_integer(limit) and limit > 0 do
    top_by_prefix(:formation, limit)
  end

  @doc """
  Clear all risk scores. Test-only — raises in non-test environments.
  """
  @spec clear() :: :ok
  def clear do
    unless Mix.env() == :test do
      raise "RiskScoreAggregator.clear/0 is test-only. Refusing in #{Mix.env()}."
    end

    GenServer.call(__MODULE__, :clear)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, {:read_concurrency, true}])

    Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_in)
    schedule_sweep()

    Logger.debug("[RiskScoreAggregator] Started — subscribed to #{@pubsub_in}")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:policy_decision, record}, state) do
    recompute_for_record(record)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # Ignore unrecognised PubSub messages (e.g. :subscribed confirmation)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private — computation
  # ---------------------------------------------------------------------------

  defp recompute_for_record(record) do
    session_id = record.session_id
    formation_id = record.formation_id

    recompute({:session, session_id}, %{session_id: session_id})

    if formation_id do
      recompute({:formation, formation_id}, %{formation_id: formation_id})
    end
  end

  defp recompute(key, filter) do
    since = DateTime.add(DateTime.utc_now(), -@window_ms, :millisecond)
    decisions = PolicyDecisionStore.query(Map.merge(filter, %{since: since, limit: 1_000}))

    aggregate = compute_aggregate(decisions)
    :ets.insert(@table, {key, aggregate})

    Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_out, {:risk_aggregated, key, aggregate})

    Logger.debug(
      "[RiskScoreAggregator] #{inspect(key)} score=#{Float.round(aggregate.score, 3)} " <>
        "level=#{aggregate.level} calls=#{aggregate.tool_call_count}"
    )
  end

  defp compute_aggregate([]) do
    %{
      score: 0.0,
      level: :none,
      tool_call_count: 0,
      critical_count: 0,
      denial_rate: 0.0,
      last_updated: DateTime.utc_now()
    }
  end

  defp compute_aggregate(decisions) do
    total = length(decisions)

    severities = Enum.map(decisions, fn d -> Types.risk_severity(d.risk_level) end)
    base_score = Enum.sum(severities) / total

    denied = Enum.count(decisions, &(&1.outcome == :deny))
    denial_rate = denied / total

    critical_count = Enum.count(decisions, &(&1.risk_level == :critical))

    denial_boost = denial_rate * 1.5
    crit_boost = min(critical_count * 0.25, 1.0)

    raw_score = base_score + denial_boost + crit_boost
    score = min(raw_score, 4.0)

    %{
      score: score,
      level: score_to_level(score),
      tool_call_count: total,
      critical_count: critical_count,
      denial_rate: denial_rate,
      last_updated: DateTime.utc_now()
    }
  end

  # Map numeric score back to risk level atom
  defp score_to_level(s) when s < 0.5, do: :none
  defp score_to_level(s) when s < 1.5, do: :low
  defp score_to_level(s) when s < 2.5, do: :medium
  defp score_to_level(s) when s < 3.5, do: :high
  defp score_to_level(_), do: :critical

  defp do_sweep do
    all_keys =
      :ets.tab2list(@table)
      |> Enum.map(fn {key, _agg} -> key end)

    Enum.each(all_keys, fn key ->
      filter =
        case key do
          {:session, sid} -> %{session_id: sid}
          {:formation, fid} -> %{formation_id: fid}
        end

      since = DateTime.add(DateTime.utc_now(), -@window_ms, :millisecond)
      decisions = PolicyDecisionStore.query(Map.merge(filter, %{since: since, limit: 1_000}))
      aggregate = compute_aggregate(decisions)
      :ets.insert(@table, {key, aggregate})
      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_out, {:risk_aggregated, key, aggregate})
    end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # ---------------------------------------------------------------------------
  # Private — ETS helpers
  # ---------------------------------------------------------------------------

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, agg}] -> agg
      [] -> nil
    end
  end

  defp top_by_prefix(prefix, limit) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {{p, _}, _} -> p == prefix end)
    |> Enum.sort_by(fn {_, agg} -> agg.score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {{_prefix, id}, agg} -> {id, agg} end)
  end
end
