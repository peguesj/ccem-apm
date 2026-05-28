defmodule ApmV5Web.Plugs.RateLimit do
  @moduledoc """
  HTTP pipeline rate limiting via PlugAttack.

  Applied to the `:api` pipeline in `router.ex` AFTER `ApiAuth` so that
  authenticated requests still hit the same per-IP buckets — this prevents
  token theft from bypassing limits.

  ## Rules (per remote IP)

  | Rule               | Period (ms) | Limit  | Notes                                  |
  |--------------------|-------------|--------|----------------------------------------|
  | `api:register`     | 10_000      | 200    | Agent registration burst (20-agent fmt) |
  | `api:heartbeat`    | 5_000       | 500    | High-frequency heartbeat traffic        |
  | `api:global`       | 60_000      | 2_000  | Global per-IP ceiling across all routes |

  All blocked requests return HTTP 429 with a `Retry-After: 10` header and
  a JSON body `{"ok": false, "error": "rate_limited"}` per RFC 6585 §4.

  ## ETS storage

  `PlugAttack.Storage.Ets` requires a named ETS table. The table is started
  as a supervised child via `PlugAttack.Storage.Ets.child_spec/2` — see
  `ApmV5.Application` for the supervision entry.
  """

  use PlugAttack

  @table ApmV5.RateLimit.ETS

  @doc false
  rule "api:register", conn do
    throttle conn.remote_ip,
      period: 10_000,
      limit: 200,
      storage: {PlugAttack.Storage.Ets, @table}
  end

  @doc false
  rule "api:heartbeat", conn do
    throttle conn.remote_ip,
      period: 5_000,
      limit: 500,
      storage: {PlugAttack.Storage.Ets, @table}
  end

  @doc false
  rule "api:global", conn do
    throttle conn.remote_ip,
      period: 60_000,
      limit: 2_000,
      storage: {PlugAttack.Storage.Ets, @table}
  end

  @doc false
  def allow_action(conn, _data, _opts) do
    conn
  end

  @doc false
  def block_action(conn, _data, _opts) do
    conn
    |> Plug.Conn.put_status(429)
    |> Plug.Conn.put_resp_header("retry-after", "10")
    |> Phoenix.Controller.json(%{ok: false, error: "rate_limited"})
    |> Plug.Conn.halt()
  end
end
