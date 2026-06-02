defmodule Apm.RateLimitRedisBackendTest do
  @moduledoc """
  TDD tests for the config-driven Hammer backend (auth-v10.2-s1 / CP-296).

  The default backend in the test environment is :ets.  We do NOT attempt to
  connect to Redis in CI — instead we verify:

  1. The ETS backend behaves correctly (functional tests).
  2. The configured backend can be read at runtime.
  3. The EtsBackend submodule is always available.
  4. The module compiles cleanly with the :ets backend selected.

  ## Redis note

  To manually test Redis mode, start a Redis server and configure:

      config :apm, Apm.RateLimit, backend: :redis, redis_url: "redis://localhost:6379"

  Then run:

      mix test test/apm/rate_limit_redis_backend_test.exs --only rate_limit_redis

  Redis tests are tagged `:redis_live` and skipped in CI.

  Run with: mix test --only rate_limit_redis
  """

  use ExUnit.Case, async: false

  @moduletag :rate_limit_redis

  # ---------------------------------------------------------------------------
  # ETS backend functional tests (always runs)
  # ---------------------------------------------------------------------------

  describe "ETS backend (default, CI-safe)" do
    setup do
      # Apm.RateLimit is started by the application supervisor.
      # Hammer uses named ETS tables so we must reuse the running instance.
      # The supervisor starts it under :apm app — always available in test env.
      :ok
    end

    test "hit/3 returns {:allow, count} on first call" do
      key = "test-ets-#{:erlang.unique_integer([:positive])}"
      assert {:allow, 1} = Apm.RateLimit.hit(key, :timer.seconds(60), 100)
    end

    test "hit/3 increments count on repeated calls" do
      key = "test-ets-incr-#{:erlang.unique_integer([:positive])}"
      {:allow, 1} = Apm.RateLimit.hit(key, :timer.seconds(60), 100)
      {:allow, 2} = Apm.RateLimit.hit(key, :timer.seconds(60), 100)
      {:allow, 3} = Apm.RateLimit.hit(key, :timer.seconds(60), 100)
    end

    test "hit/3 returns {:deny, _} when limit exceeded" do
      key = "test-ets-limit-#{:erlang.unique_integer([:positive])}"
      # Set limit to 2
      {:allow, 1} = Apm.RateLimit.hit(key, :timer.seconds(60), 2)
      {:allow, 2} = Apm.RateLimit.hit(key, :timer.seconds(60), 2)
      result = Apm.RateLimit.hit(key, :timer.seconds(60), 2)
      assert match?({:deny, _retry_after_ms}, result)
    end

    test "different keys are independent" do
      key_a = "test-ets-a-#{:erlang.unique_integer([:positive])}"
      key_b = "test-ets-b-#{:erlang.unique_integer([:positive])}"
      {:allow, 1} = Apm.RateLimit.hit(key_a, :timer.seconds(60), 5)
      {:allow, 1} = Apm.RateLimit.hit(key_b, :timer.seconds(60), 5)
    end
  end

  # ---------------------------------------------------------------------------
  # EtsBackend submodule (always compiled)
  # ---------------------------------------------------------------------------

  describe "Apm.RateLimit.EtsBackend" do
    # EtsBackend is started in the supervision tree alongside Apm.RateLimit

    test "EtsBackend module is defined" do
      assert Code.ensure_loaded?(Apm.RateLimit.EtsBackend)
    end

    test "EtsBackend ETS table exists (supervision tree started it)" do
      # Hammer.ETS creates a named ETS table Apm.RateLimit.EtsBackend
      # The backing process is anonymous (no registered name) — verify via ETS
      table_info = :ets.info(Apm.RateLimit.EtsBackend)
      assert table_info != :undefined, "Expected ETS table Apm.RateLimit.EtsBackend to exist"
    end

    test "EtsBackend.hit/3 works independently of primary module" do
      key = "test-ets-backend-#{:erlang.unique_integer([:positive])}"
      assert {:allow, 1} = Apm.RateLimit.EtsBackend.hit(key, :timer.seconds(60), 10)
    end
  end

  # ---------------------------------------------------------------------------
  # Backend configuration
  # ---------------------------------------------------------------------------

  describe "backend configuration" do
    test "configured backend is :ets in test environment" do
      backend = Application.get_env(:apm, Apm.RateLimit, []) |> Keyword.get(:backend, :ets)
      assert backend == :ets
    end

    test "Apm.RateLimit module is defined" do
      assert Code.ensure_loaded?(Apm.RateLimit)
    end

    test "Apm.RateLimit responds to hit/3" do
      assert function_exported?(Apm.RateLimit, :hit, 3)
    end

    test "Apm.RateLimit responds to child_spec/1" do
      spec = Apm.RateLimit.child_spec([])
      assert is_map(spec)
      assert Map.has_key?(spec, :id)
    end
  end

  # ---------------------------------------------------------------------------
  # Redis live tests — skipped in CI, require tag :redis_live
  # ---------------------------------------------------------------------------

  @tag :redis_live
  @tag :skip
  test "Redis backend hit/3 works when Redis is available" do
    # This test is manually activated by removing @tag :skip and configuring:
    #   config :apm, Apm.RateLimit, backend: :redis
    # then running: mix test --only redis_live
    flunk("Enable this test manually with a running Redis instance")
  end
end
