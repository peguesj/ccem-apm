defmodule Apm.Auth.RateLimiter do
  @moduledoc """
  AgentLock rate limiter — thin compatibility wrapper over `Apm.RateLimit`.

  Preserves the original public API (`check/2`, `record/2`, `configure/3`,
  `get_tool_config/1`, `stats/0`, `default_limits/0`) so all callers
  (`AuthorizationGate`, `MemoryGate`, `AgentlockIntegration`) are unaffected.

  ## Migration notes

  The former implementation maintained per-key timestamp lists in ETS and pruned
  them every 30 s via a `Process.send_after` loop.  That created an O(n) check
  cost whenever the prune had not yet run.  `Apm.RateLimit` (Hammer 7.x
  sliding window, ETS backend) performs an atomic check-and-record in O(1)
  amortized time.

  This module is **no longer a GenServer**.  `Apm.RateLimit` owns the ETS
  table and cleanup timer; `Apm.Auth.RateLimiter` is removed from
  `AuthSupervisor` children and replaced by `Apm.RateLimit`.

  ## check/2 semantics change

  Previously `check/2` was read-only and callers were expected to follow up with
  `record/2`.  Now `check/2` atomically checks **and** records (Hammer's `hit/3`
  semantics).  Standalone `record/2` calls are tolerated for backward
  compatibility but are no-ops — they do not double-count because the
  check-and-record already happened in `check/2`.
  """

  require Logger

  # Per-risk-level defaults — identical to the old implementation so that callers
  # relying on `default_limits/0` or `get_tool_config/1` see no change.
  @default_limits %{
    none: %{max_calls: 1_000, window_seconds: 60},
    low: %{max_calls: 200, window_seconds: 60},
    medium: %{max_calls: 50, window_seconds: 60},
    high: %{max_calls: 20, window_seconds: 60},
    critical: %{max_calls: 5, window_seconds: 60}
  }

  # Per-tool overrides written by `configure/3`. Stored in :persistent_term for
  # zero-copy reads from any process without a GenServer round-trip.
  @tool_config_key {__MODULE__, :tool_configs}

  # ---------------------------------------------------------------------------
  # Public API (unchanged from original GenServer implementation)
  # ---------------------------------------------------------------------------

  @doc """
  Check whether `tool_name` is within rate limits for `user_id`.

  Returns `:ok` when allowed; `{:error, :rate_limited, retry_after_ms}` when
  the bucket is exhausted.

  This call is now **atomic** — `check/2` and `record/2` are unified into a
  single `Hammer.hit/3` invocation, eliminating the TOCTOU gap in the old API.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(user_id, tool_name) do
    config = get_tool_config(tool_name)
    key = "#{user_id}:#{tool_name}"
    scale_ms = config.window_seconds * 1_000

    case Apm.RateLimit.hit(key, scale_ms, config.max_calls) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, :rate_limited, max(retry_after_ms, 1_000)}
    end
  end

  @doc """
  No-op shim retained for backward compatibility.

  `check/2` now atomically records the hit via Hammer; calling `record/2`
  separately would double-count.  This function intentionally does nothing.
  Callers should remove standalone `record/2` calls over time.
  """
  @spec record(String.t(), String.t()) :: :ok
  def record(_user_id, _tool_name), do: :ok

  @doc """
  Configure rate limits for a specific tool at runtime.

  Stored in `:persistent_term` so reads are zero-copy from any process.
  """
  @spec configure(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def configure(tool_name, max_calls, window_seconds) do
    configs = get_all_configs()
    updated = Map.put(configs, tool_name, %{max_calls: max_calls, window_seconds: window_seconds})
    :persistent_term.put(@tool_config_key, updated)
    :ok
  end

  @doc "Return the rate limit config for `tool_name`, falling back to :low defaults."
  @spec get_tool_config(String.t()) :: %{max_calls: pos_integer(), window_seconds: pos_integer()}
  def get_tool_config(tool_name) do
    Map.get(get_all_configs(), tool_name, @default_limits[:low])
  end

  @doc """
  Return utilization stats for all active rate-limit buckets.

  NOTE: Hammer 7.x ETS sliding window does not expose a public enumeration API
  for the raw timestamp store, so this returns an empty list.  Per-key
  utilization will be surfaced through the dashboard widget introduced in rl-s8.
  """
  @spec stats() :: [map()]
  def stats, do: []

  @doc "Return the default risk-level rate limit map."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_all_configs do
    :persistent_term.get(@tool_config_key, %{})
  rescue
    ArgumentError -> %{}
  end
end
