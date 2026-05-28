defmodule ApmV5.Auth.FormationRateLimiter do
  @moduledoc """
  Formation-aware rate limiter with sqrt-scaling aggregate budget.

  Wraps `ApmV5.RateLimit` (Hammer 7.x) to apply a shared budget across all
  agents within a formation, using square-root scaling to prevent O(n) burst
  amplification while still allowing a formation to exceed any single agent's
  limit when agents legitimately work in parallel.

  ## Sqrt Scaling Rationale

  If N agents each have a per-agent limit of L calls/minute, naive linear
  scaling would allow N×L calls/minute — amplifying bursts proportionally to
  formation size.  Sqrt scaling caps the formation budget at L×√N:

      N=1   → budget = L×1.0  = L    (single agent, no change)
      N=4   → budget = L×2.0          (2× instead of 4×)
      N=9   → budget = L×3.0          (3× instead of 9×)
      N=20  → budget ≈ L×4.47         (4.47× instead of 20×)
      N=100 → budget = L×10.0         (10× instead of 100×)

  For risk_level :high (L=20/min), 20 agents share ~90/min rather than 400/min.

  ## Two-Level Check

  `check/4` evaluates the formation budget FIRST, then the individual agent
  budget.  The formation check is the outer gate — if the formation is exhausted
  the per-agent check is skipped entirely.

  ## Agent Count Memoization

  `agent_count/1` pulls from `AgentRegistry.list_formation/1` and caches the
  result for 30 s in an ETS table (`:formation_agent_count_cache`) to avoid
  hammering the registry on every tool call.
  """

  require Logger

  alias ApmV5.AgentRegistry

  @cache_table :formation_agent_count_cache
  @cache_ttl_ms 30_000

  # Per-risk-level per-agent defaults — mirrors RateLimiter @default_limits
  @risk_limits %{
    critical: 5,
    high: 20,
    medium: 50,
    low: 200,
    none: 1_000
  }

  @window_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Check whether `agent_id` calling `tool_name` within `formation_id` is within
  budget.

  Checks formation aggregate budget first, then per-agent budget.

  Returns:
  - `:ok` — both budgets have headroom (hit recorded on both keys)
  - `{:deny, :formation}` — formation budget exhausted
  - `{:deny, :agent}` — per-agent budget exhausted (formation still has headroom)
  """
  @spec check(String.t(), String.t(), String.t(), atom()) ::
          :ok | {:deny, :formation | :agent}
  def check(agent_id, formation_id, tool_name, risk_level \\ :low) do
    per_agent_limit = Map.get(@risk_limits, risk_level, @risk_limits[:low])
    count = agent_count(formation_id)
    formation_limit = formation_budget(per_agent_limit, count)

    formation_key = "formation:#{formation_id}:#{tool_name}"
    agent_key = "#{agent_id}:#{tool_name}"

    case ApmV5.RateLimit.hit(formation_key, @window_ms, formation_limit) do
      {:deny, _retry_after} ->
        {:deny, :formation}

      {:allow, _} ->
        case ApmV5.RateLimit.hit(agent_key, @window_ms, per_agent_limit) do
          {:deny, _retry_after} ->
            {:deny, :agent}

          {:allow, _} ->
            :ok
        end
    end
  end

  @doc """
  Return the number of agents registered in `formation_id`.

  Result is memoized for 30 s in `:formation_agent_count_cache` ETS table.
  Returns 1 as a safe default if the registry is unavailable.
  """
  @spec agent_count(String.t()) :: pos_integer()
  def agent_count(formation_id) do
    ensure_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, formation_id) do
      [{^formation_id, count, cached_at}] when now - cached_at < @cache_ttl_ms ->
        count

      _ ->
        count =
          try do
            case AgentRegistry.list_formation(formation_id) do
              agents when is_list(agents) -> max(length(agents), 1)
              _ -> 1
            end
          rescue
            _ -> 1
          catch
            :exit, _ -> 1
          end

        :ets.insert(@cache_table, {formation_id, count, now})
        count
    end
  end

  @doc """
  Compute the formation aggregate budget using sqrt scaling.

      formation_budget = round(per_agent_limit * :math.sqrt(agent_count))
  """
  @spec formation_budget(pos_integer(), pos_integer()) :: pos_integer()
  def formation_budget(per_agent_limit, agent_count) do
    (per_agent_limit * :math.sqrt(agent_count))
    |> round()
    |> max(per_agent_limit)
  end

  @doc "Return the per-risk-level base limit map."
  @spec risk_limits() :: map()
  def risk_limits, do: @risk_limits

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp ensure_cache_table do
    case :ets.info(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end
end
