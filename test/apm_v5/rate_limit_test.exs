defmodule ApmV5.RateLimitTest do
  @moduledoc """
  Tests for ApmV5.RateLimit (Hammer 7.x ETS sliding window) and the
  two wrapper modules ApmV5.Auth.RateLimiter and ApmV5.Proxy.RateLimiter.

  CP-237 / rl-s2
  """
  use ExUnit.Case, async: false

  @moduletag :rate_limit

  # ---------------------------------------------------------------------------
  # ApmV5.RateLimit (Hammer core)
  # ---------------------------------------------------------------------------

  describe "ApmV5.RateLimit" do
    test "first hit returns {:allow, 1}" do
      key = unique_key("core-first")
      assert {:allow, 1} = ApmV5.RateLimit.hit(key, :timer.seconds(60), 5)
    end

    test "hits within limit are allowed and count increments" do
      key = unique_key("core-count")

      for expected_count <- 1..5 do
        assert {:allow, ^expected_count} = ApmV5.RateLimit.hit(key, :timer.seconds(60), 5)
      end
    end

    test "sixth hit beyond limit returns {:deny, retry_after_ms}" do
      key = unique_key("core-deny")

      for _ <- 1..5 do
        ApmV5.RateLimit.hit(key, :timer.seconds(60), 5)
      end

      assert {:deny, retry_after_ms} = ApmV5.RateLimit.hit(key, :timer.seconds(60), 5)
      assert is_integer(retry_after_ms)
      assert retry_after_ms > 0
    end

    test "short-window entries expire and allow again" do
      key = unique_key("core-expire")
      window_ms = 100

      # Fill the bucket
      for _ <- 1..3, do: ApmV5.RateLimit.hit(key, window_ms, 3)
      assert {:deny, _} = ApmV5.RateLimit.hit(key, window_ms, 3)

      # Wait for the window to pass
      Process.sleep(window_ms + 50)

      # Should be allowed again
      assert {:allow, _} = ApmV5.RateLimit.hit(key, window_ms, 3)
    end

    test "different keys are isolated" do
      key_a = unique_key("core-iso-a")
      key_b = unique_key("core-iso-b")

      for _ <- 1..5, do: ApmV5.RateLimit.hit(key_a, :timer.seconds(60), 5)
      assert {:deny, _} = ApmV5.RateLimit.hit(key_a, :timer.seconds(60), 5)

      # key_b untouched — must still be allowed
      assert {:allow, 1} = ApmV5.RateLimit.hit(key_b, :timer.seconds(60), 5)
    end
  end

  # ---------------------------------------------------------------------------
  # ApmV5.Auth.RateLimiter wrapper
  # ---------------------------------------------------------------------------

  describe "ApmV5.Auth.RateLimiter.check/2" do
    test "returns :ok when within default :low limit (200/60s)" do
      assert :ok = ApmV5.Auth.RateLimiter.check(unique_key("auth-ok"), "Bash")
    end

    test "returns {:error, :rate_limited, retry_after_ms} after limit exceeded" do
      user = unique_key("auth-deny")
      tool = "CriticalTool"

      # configure a tiny limit so the test is fast
      ApmV5.Auth.RateLimiter.configure(tool, 2, 60)

      assert :ok = ApmV5.Auth.RateLimiter.check(user, tool)
      assert :ok = ApmV5.Auth.RateLimiter.check(user, tool)

      assert {:error, :rate_limited, retry_after_ms} =
               ApmV5.Auth.RateLimiter.check(user, tool)

      assert is_integer(retry_after_ms)
      assert retry_after_ms >= 1_000
    end

    test "record/2 is a no-op (does not double-count)" do
      user = unique_key("auth-record-noop")
      ApmV5.Auth.RateLimiter.configure("Bash_noop", 2, 60)

      :ok = ApmV5.Auth.RateLimiter.check(user, "Bash_noop")
      # record is a no-op — should not consume the second slot
      :ok = ApmV5.Auth.RateLimiter.record(user, "Bash_noop")

      # second check should still succeed (bucket only used 1 of 2)
      assert :ok = ApmV5.Auth.RateLimiter.check(user, "Bash_noop")
    end

    test "configure/3 sets per-tool limits" do
      tool = unique_key("auth-configure-tool")
      ApmV5.Auth.RateLimiter.configure(tool, 1, 60)
      assert %{max_calls: 1, window_seconds: 60} = ApmV5.Auth.RateLimiter.get_tool_config(tool)
    end

    test "get_tool_config/1 returns :low defaults for unknown tools" do
      assert %{max_calls: 200, window_seconds: 60} =
               ApmV5.Auth.RateLimiter.get_tool_config("UnknownTool_#{System.unique_integer()}")
    end

    test "default_limits/0 returns all five risk levels" do
      limits = ApmV5.Auth.RateLimiter.default_limits()
      assert Map.has_key?(limits, :none)
      assert Map.has_key?(limits, :low)
      assert Map.has_key?(limits, :medium)
      assert Map.has_key?(limits, :high)
      assert Map.has_key?(limits, :critical)
    end

    test "stats/0 returns a list (empty in this implementation)" do
      assert is_list(ApmV5.Auth.RateLimiter.stats())
    end
  end

  # ---------------------------------------------------------------------------
  # ApmV5.Proxy.RateLimiter wrapper
  # ---------------------------------------------------------------------------

  describe "ApmV5.Proxy.RateLimiter.allow?/2" do
    test "returns true for new scope/key pair" do
      assert ApmV5.Proxy.RateLimiter.allow?(unique_key("proxy-scope"), "key1")
    end

    test "returns false after default limit (100) reached" do
      scope = unique_key("proxy-deny")

      for _ <- 1..100 do
        ApmV5.Proxy.RateLimiter.allow?(scope, "k")
      end

      refute ApmV5.Proxy.RateLimiter.allow?(scope, "k")
    end

    test "reset/1 is a no-op and does not crash" do
      assert :ok = ApmV5.Proxy.RateLimiter.reset(unique_key("proxy-reset"))
    end

    test "check/2 returns map with allowed/remaining/window_ms" do
      scope = unique_key("proxy-check")
      result = ApmV5.Proxy.RateLimiter.check(scope, "key")
      assert is_map(result)
      assert Map.has_key?(result, :allowed)
      assert Map.has_key?(result, :remaining)
      assert Map.has_key?(result, :window_ms)
      assert result.window_ms == 60_000
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp unique_key(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
