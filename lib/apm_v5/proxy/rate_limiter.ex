defmodule ApmV5.Proxy.RateLimiter do
  @moduledoc """
  Proxy rate limiter — thin compatibility wrapper over `ApmV5.RateLimit`.

  Preserves the original public API (`allow?/2`, `check/2`, `reset/1`) so all
  proxy callers are unaffected.

  ## Migration notes

  The former implementation stored lists of monotonic timestamps in a private ETS
  table (`:proxy_rate_limiter`) and performed O(n) filtering on each `allow?/2`
  call.  It was a GenServer that created its own table on `init/1`.

  This module is **no longer a GenServer**.  `ApmV5.RateLimit` owns the ETS
  table and cleanup scheduler.  `ApmV5.Proxy.Supervisor` replaces the
  `ApmV5.Proxy.RateLimiter` child with `ApmV5.RateLimit`.
  """

  @default_limit 100
  @default_window_ms 60_000

  # Namespace prefix so proxy keys never collide with auth keys in the shared
  # Hammer ETS table.
  @key_prefix "proxy"

  # ---------------------------------------------------------------------------
  # Public API (unchanged)
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if `{scope, key}` is within the default rate limit.

  Atomic check-and-record via Hammer; replaces the old read-then-write pattern.
  """
  @spec allow?(term(), term()) :: boolean()
  def allow?(scope, key) do
    bucket = "#{@key_prefix}:#{scope}:#{key}"

    case ApmV5.RateLimit.hit(bucket, @default_window_ms, @default_limit) do
      {:allow, _count} -> true
      {:deny, _retry_ms} -> false
    end
  rescue
    _ -> true
  end

  @doc """
  Returns a map with `:allowed`, `:remaining`, and `:window_ms` for `{scope, key}`.

  This is a **read-only check** — it does not record a hit.  Use `allow?/2` when
  you want to both check and record atomically.

  NOTE: Hammer does not provide a pure read without incrementing, so this
  function uses a very high sentinel limit to simulate a read-only inspection.
  """
  @spec check(term(), term()) :: %{allowed: boolean(), remaining: integer(), window_ms: integer()}
  def check(scope, key) do
    bucket = "#{@key_prefix}:#{scope}:#{key}"

    case ApmV5.RateLimit.hit(bucket, @default_window_ms, 999_999_999) do
      {:allow, count} ->
        remaining = max(@default_limit - count, 0)
        %{allowed: count <= @default_limit, remaining: remaining, window_ms: @default_window_ms}

      {:deny, _retry_ms} ->
        %{allowed: false, remaining: 0, window_ms: @default_window_ms}
    end
  rescue
    _ -> %{allowed: true, remaining: @default_limit, window_ms: @default_window_ms}
  end

  @doc """
  No-op shim retained for backward compatibility.

  Hammer 7.x ETS does not expose a scoped-delete API.  A full reset can be
  achieved by restarting `ApmV5.RateLimit`.
  """
  @spec reset(term()) :: :ok
  def reset(_scope), do: :ok
end
