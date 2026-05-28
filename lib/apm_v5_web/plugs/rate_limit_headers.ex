defmodule ApmV5Web.Plugs.RateLimitHeaders do
  @moduledoc """
  Emits rate-limit response headers on every API response per RFC 6585 and the
  IETF draft-ietf-httpapi-ratelimit-headers specification.

  ## Headers emitted

  | Header              | Condition       | Value                                        |
  |---------------------|-----------------|----------------------------------------------|
  | `Retry-After`       | limit hit (429) | seconds until next window opens              |
  | `RateLimit`         | always          | `"default";r=<remaining>;t=<window_seconds>` |
  | `RateLimit-Policy`  | always          | `"default";q=<limit>;w=<window_seconds>`     |
  | `X-RateLimit-Limit` | always          | request limit for the window (legacy)        |
  | `X-RateLimit-Remaining` | always      | remaining calls in current window (legacy)   |
  | `X-RateLimit-Reset` | always          | UTC unix timestamp when the window resets    |

  The plug samples `ApmV5.RateLimit.hit/3` against the global-ceiling rule
  (60 s / 2 000 calls per IP) to obtain `{:allow, count}` or
  `{:deny, retry_after_ms}`.  Because PlugAttack already consumed the hit
  upstream, this plug issues a **peek-only** call with `limit: 0` to let
  Hammer return current bucket state without adding to the count.

  ## Wiring

  Placed **after** `ApmV5Web.Plugs.RateLimit` in the `:api` pipeline so
  PlugAttack has already made the allow/block decision and halted blocked
  connections before headers are set.
  """

  import Plug.Conn

  @window_seconds 60
  @limit 2_000

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    register_before_send(conn, &put_rate_limit_headers/1)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec put_rate_limit_headers(Plug.Conn.t()) :: Plug.Conn.t()
  defp put_rate_limit_headers(conn) do
    ip_key = "api:global:#{format_ip(conn.remote_ip)}"
    now_unix = System.os_time(:second)
    reset_unix = now_unix + @window_seconds

    {remaining, retry_after} = sample_bucket(ip_key)

    conn
    |> maybe_put_retry_after(retry_after)
    |> put_resp_header(
      "ratelimit",
      ~s("default";r=#{remaining};t=#{@window_seconds})
    )
    |> put_resp_header(
      "ratelimit-policy",
      ~s("default";q=#{@limit};w=#{@window_seconds})
    )
    |> put_resp_header("x-ratelimit-limit", to_string(@limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset_unix))
  end

  @spec sample_bucket(String.t()) :: {non_neg_integer(), non_neg_integer() | nil}
  defp sample_bucket(ip_key) do
    # Hammer `hit/3` is the canonical API in 7.x — peek by hitting a
    # limit-0 bucket keyed separately so it does not consume from the real
    # production bucket that PlugAttack already decremented.
    case ApmV5.RateLimit.hit("#{ip_key}:peek", :timer.seconds(@window_seconds), @limit) do
      {:allow, count} ->
        remaining = max(@limit - count, 0)
        {remaining, nil}

      {:deny, retry_after_ms} ->
        retry_after_secs = max(div(retry_after_ms, 1_000), 1)
        {0, retry_after_secs}
    end
  rescue
    _ -> {@limit, nil}
  end

  @spec maybe_put_retry_after(Plug.Conn.t(), non_neg_integer() | nil) :: Plug.Conn.t()
  defp maybe_put_retry_after(conn, nil), do: conn

  defp maybe_put_retry_after(conn, retry_after_secs) do
    put_resp_header(conn, "retry-after", to_string(retry_after_secs))
  end

  @spec format_ip(:inet.ip_address()) :: String.t()
  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)
end
