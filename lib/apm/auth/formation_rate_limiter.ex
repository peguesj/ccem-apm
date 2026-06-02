defmodule Apm.Auth.FormationRateLimiter do
  @moduledoc """
  Formation-aware rate limiter with sqrt-scaling aggregate budget.

  Wraps `Apm.RateLimit` (Hammer 7.x) to apply a shared budget across all
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

  alias Apm.AgentRegistry

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

    case Apm.RateLimit.hit(formation_key, @window_ms, formation_limit) do
      {:deny, _retry_after} ->
        {:deny, :formation}

      {:allow, _} ->
        case Apm.RateLimit.hit(agent_key, @window_ms, per_agent_limit) do
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

  @doc """
  Return the top `n` agents in `formation_id` ordered by descending Hammer
  bucket usage for the current 60-second window.

  Each entry is a map with keys `:agent_id`, `:tool_name`, and `:used`.

  Agents whose bucket count is zero (no hits in the current window) are
  excluded from the result.

  ## Two-arity form (registry-backed)

      FormationRateLimiter.top_n_agents("fmn-abc", 10)

  Resolves agents via `AgentRegistry.list_formation/1` and queries each
  agent's bucket across all tools they have used.  Because Hammer's ETS
  backend does not expose a native full-scan API, this overload falls back
  to inspecting the `:hammer_ets` table directly.

  ## Three-arity form (explicit agent/tool pairs — preferred in tests)

      FormationRateLimiter.top_n_agents("fmn-abc", 10, [{"agent-1", "Bash"}, ...])

  Skips registry lookup and queries Hammer for each `{agent_id, tool_name}`
  pair provided.  Useful when the caller already knows which tools agents
  are using.
  """
  @spec top_n_agents(String.t(), pos_integer()) :: [
          %{agent_id: String.t(), tool_name: String.t(), used: non_neg_integer()}
        ]
  def top_n_agents(formation_id, n \\ 10) do
    agents =
      try do
        case AgentRegistry.list_formation(formation_id) do
          list when is_list(list) -> list
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    pairs =
      Enum.flat_map(agents, fn agent ->
        agent_id = if is_map(agent), do: agent[:id] || agent[:agent_id], else: to_string(agent)
        # Probe all known risk-level tools as well as a wildcard scan
        for tool <- probe_tools_for_agent(agent_id), do: {agent_id, tool}
      end)

    top_n_agents(formation_id, n, pairs)
  end

  @spec top_n_agents(String.t(), pos_integer(), [{String.t(), String.t()}]) :: [
          %{agent_id: String.t(), tool_name: String.t(), used: non_neg_integer()}
        ]
  def top_n_agents(_formation_id, n, agent_tool_pairs) do
    agent_tool_pairs
    |> Enum.map(fn {agent_id, tool_name} ->
      used = get_bucket_count(agent_id, tool_name)
      %{agent_id: agent_id, tool_name: tool_name, used: used}
    end)
    |> Enum.filter(fn %{used: used} -> used > 0 end)
    |> Enum.sort_by(fn %{used: used} -> used end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Return a utilization heat-map for `formation_id`.

  For each `tool_name` that has accumulated hits against the formation-level
  Hammer key (`"formation:<formation_id>:<tool_name>"`), returns the
  percentage of the current formation budget that has been consumed:

      utilization_pct = min(used / budget, 1.0) * 100.0

  The budget is computed with `formation_budget/2` using the `:low` risk
  level default and the current `agent_count/1` for the formation.

  Returns a map of `%{tool_name => float()}` where values are in `[0.0, 100.0]`.
  An empty map is returned when no hits have been recorded for the formation.

  ## Example

      iex> Apm.Auth.FormationRateLimiter.heatmap_data("fmn-abc")
      %{"Bash" => 45.0, "Write" => 12.0}
  """
  @spec heatmap_data(String.t()) :: %{String.t() => float()}
  def heatmap_data(formation_id) do
    per_agent_limit = Map.get(@risk_limits, :low)
    count = agent_count(formation_id)
    budget = formation_budget(per_agent_limit, count)

    formation_prefix = "formation:#{formation_id}:"

    scan_formation_keys(formation_prefix)
    |> Enum.reduce(%{}, fn {key, used}, acc ->
      tool_name = String.replace_prefix(key, formation_prefix, "")
      pct = min(used / budget, 1.0) * 100.0
      Map.put(acc, tool_name, Float.round(pct, 2))
    end)
  end

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

  # Returns the current used count for `agent_id:tool_name` from Hammer's
  # sliding-window bucket without recording a new hit.
  # `Apm.RateLimit.get/2` returns the current counter value for the key.
  @spec get_bucket_count(String.t(), String.t()) :: non_neg_integer()
  defp get_bucket_count(agent_id, tool_name) do
    key = "#{agent_id}:#{tool_name}"

    try do
      Apm.RateLimit.get(key, @window_ms)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  # Scan the Hammer ETS table for all keys matching `prefix`.
  # Returns `[{key_string, used}]` pairs.
  #
  # Hammer 7.x with the `:ets` backend names the ETS table after the module
  # that called `use Hammer`.  In this project that module is `Apm.RateLimit`,
  # so the table atom is `Apm.RateLimit`.
  #
  # Sliding-window ETS entries have shape: `{key, window_id, count}` where
  # `window_id` is an integer sub-bucket index.  Fixed-window entries may use
  # a tuple key `{key, bucket}`.  We handle both shapes defensively.
  #
  # This scan is only called for dashboard/reporting purposes (not on the hot
  # authorization path), so a linear ETS scan is acceptable.
  @hammer_table Apm.RateLimit

  @spec scan_formation_keys(String.t()) :: [{String.t(), non_neg_integer()}]
  defp scan_formation_keys(prefix) do
    scan_ets_keys(prefix)
  end

  @spec scan_ets_keys(String.t()) :: [{String.t(), non_neg_integer()}]
  defp scan_ets_keys(prefix) do
    case :ets.info(@hammer_table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@hammer_table)
        |> extract_key_counts(prefix)
    end
  end

  # Extract `{key_string, count}` from raw ETS entries whose string key
  # starts with `prefix`.
  #
  # Hammer 7.x sliding-window ETS entry shape:
  #   `{{key_string, timestamp_us}, expires_at_us}`
  # Each individual hit is its own row.  We count the number of rows per
  # key_string (equivalent to what `get/3` does via `select_count`), but
  # only for rows that have not yet expired.
  @spec extract_key_counts(list(), String.t()) :: [{String.t(), non_neg_integer()}]
  defp extract_key_counts(entries, prefix) do
    # Hammer sliding window uses System.system_time(:microsecond) for timestamps.
    now_us = System.system_time(:microsecond)

    entries
    |> Enum.flat_map(fn
      # Sliding-window: {{key_string, _ts_us}, expires_at_us}
      {{key, _ts}, expires_at}
      when is_binary(key) and is_integer(expires_at) and expires_at > now_us ->
        if String.starts_with?(key, prefix), do: [key], else: []

      _ ->
        []
    end)
    |> Enum.frequencies()
    |> Enum.to_list()
  end

  # Returns a list of tool names to probe for a given agent_id when
  # no explicit pairs are provided (two-arity top_n_agents fallback).
  # Scans the Hammer ETS table for any key matching `"agent_id:*"`.
  @spec probe_tools_for_agent(String.t()) :: [String.t()]
  defp probe_tools_for_agent(agent_id) do
    prefix = "#{agent_id}:"

    case :ets.info(@hammer_table) do
      :undefined ->
        []

      _ ->
        @hammer_table
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {{key, _ts}, _expires_at} when is_binary(key) ->
            if String.starts_with?(key, prefix),
              do: [String.replace_prefix(key, prefix, "")],
              else: []

          _ ->
            []
        end)
        |> Enum.uniq()
    end
  end
end
