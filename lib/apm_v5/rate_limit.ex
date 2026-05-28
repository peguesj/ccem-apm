defmodule ApmV5.RateLimit do
  @moduledoc """
  Central rate limiter for CCEM APM, backed by Hammer 7.x ETS sliding window.

  Uses an atomic check-and-record (`hit/3`) — O(1) amortized — replacing the
  two hand-rolled timestamp-list accumulators that had an O(n) per-check
  accumulation bug (prune ran every 30s, writes were continuous).

  ## Usage

      # Allow up to 200 calls in any 60-second window for a given key
      case ApmV5.RateLimit.hit("agent-123:Bash", :timer.seconds(60), 200) do
        {:allow, count} -> :ok
        {:deny, retry_after_ms} -> {:error, :rate_limited, retry_after_ms}
      end

  ## Key conventions

  - Agent tool key: `"\#{agent_id}:\#{tool_name}"`
  - Formation key (reserved for rl-s6): `"formation:\#{formation_id}:\#{tool_name}"`

  ## Child spec

  Add `ApmV5.RateLimit` to a supervisor:

      children = [
        {ApmV5.RateLimit, clean_period: :timer.minutes(2)}
      ]
  """

  use Hammer, backend: :ets, algorithm: :sliding_window
end
