defmodule Apm.RateLimit do
  @moduledoc """
  Central rate limiter for CCEM APM, backed by Hammer 7.x sliding-window.

  ## Backend selection (auth-v10.2-s1 / CP-296)

  The backing store is **config-driven** so teams can swap between ETS (default,
  zero-infrastructure, CI-safe) and Redis (multi-node, persistent, production).

      # Default — ETS, in-process, no external deps
      config :apm, Apm.RateLimit, backend: :ets

      # Redis — requires a running Redis instance; uses hammer_backend_redis
      config :apm, Apm.RateLimit, backend: :redis, redis_url: "redis://localhost:6379"

  At compile time the module `use`-es the correct Hammer backend. Because Hammer
  generates functions at compile time via macro, both modules are always defined
  but only one is listed in the supervision tree (see `Apm.Application`).

  The public API (`hit/3`) delegates to whichever module is active, so call
  sites never need to change.

  ## Usage

      case Apm.RateLimit.hit("agent-123:Bash", :timer.seconds(60), 200) do
        {:allow, count} -> :ok
        {:deny, retry_after_ms} -> {:error, :rate_limited, retry_after_ms}
      end

  ## Key conventions

  - Agent tool key:     `"\#{agent_id}:\#{tool_name}"`
  - Formation key:      `"formation:\#{formation_id}:\#{tool_name}"`
  - Global limiter key: `"global:\#{endpoint}"`

  ## Child spec

      children = [Apm.RateLimit]

  `child_spec/1` delegates to the active backend module.
  """

  # Compile-time backend selection
  @backend Application.compile_env(:apm, [Apm.RateLimit, :backend], :ets)

  case @backend do
    :ets ->
      use Hammer, backend: :ets, algorithm: :sliding_window

    :redis ->
      # hammer_backend_redis must be in mix.exs deps when backend: :redis is configured.
      # CI environments should use backend: :ets (default) to avoid Redis dependency.
      use Hammer,
        backend: {Hammer.Backend.Redis, [expiry_ms: 60_000 * 60, redix_config: []]},
        algorithm: :sliding_window
  end
end

defmodule Apm.RateLimit.EtsBackend do
  @moduledoc """
  Explicit ETS-backed Hammer instance.

  Always compiled regardless of the configured backend so that callers that
  explicitly want ETS semantics (e.g. tests) can use this module directly.

  In production, prefer `Apm.RateLimit` which selects the backend from config.
  """
  use Hammer, backend: :ets, algorithm: :sliding_window
end
