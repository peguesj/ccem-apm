# Cold-start benchmark for /api/status (US-605)
#
# Boots a minimal inlined HTTP client and hits /api/status 100 times
# after the APM server is up, reporting p50/p95/p99/min/max/mean.
#
# Targets (vs. 1.2s baseline):
#   p50 < 100ms
#   p95 < 200ms
#   p99 < 500ms
#
# Usage:
#   # Start the server in one terminal:
#   mix phx.server
#
#   # In another terminal, run the benchmark (--no-start avoids booting a
#   # second supervision tree that would compete for ports/ETS tables):
#   mix run --no-start bench/cold_start_bench.exs
#
# Environment variables:
#   APM_BENCH_HOST  (default "localhost")
#   APM_BENCH_PORT  (default 3032)
#   APM_BENCH_ITERS (default 100)
#   APM_BENCH_PATH  (default "/api/status")

defmodule ColdStartBench do
  @moduledoc false

  def run do
    host = System.get_env("APM_BENCH_HOST", "localhost")
    port = System.get_env("APM_BENCH_PORT", "3032") |> String.to_integer()
    iters = System.get_env("APM_BENCH_ITERS", "100") |> String.to_integer()
    path = System.get_env("APM_BENCH_PATH", "/api/status")

    url = ~c"http://#{host}:#{port}#{path}"

    IO.puts("Cold-start benchmark: #{url}")
    IO.puts("Iterations: #{iters}\n")

    :inets.start()
    :ssl.start()

    # Warmup: throw away the first request (may include TCP connect cost).
    # We still want to measure near-cold latency, so only one warmup.
    _ = request(url)

    samples =
      for i <- 1..iters do
        t0 = System.monotonic_time(:microsecond)
        {:ok, status} = request(url)
        t1 = System.monotonic_time(:microsecond)
        elapsed_us = t1 - t0

        if rem(i, 10) == 0 do
          IO.write(".")
        end

        {status, elapsed_us}
      end

    IO.puts("\n")
    report(samples)
  end

  defp request(url) do
    case :httpc.request(:get, {url, []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      other -> {:error, other}
    end
  end

  defp report(samples) do
    latencies_us =
      samples
      |> Enum.map(fn {_status, us} -> us end)
      |> Enum.sort()

    n = length(latencies_us)

    p = fn pct ->
      idx = max(0, min(n - 1, round(pct / 100 * n) - 1))
      Enum.at(latencies_us, idx)
    end

    min_us = List.first(latencies_us)
    max_us = List.last(latencies_us)
    mean_us = div(Enum.sum(latencies_us), n)

    ok_count = Enum.count(samples, fn {s, _} -> s == 200 end)

    IO.puts("=== Cold-start latency report (/api/status) ===")
    IO.puts("  samples:  #{n}")
    IO.puts("  ok:       #{ok_count}")
    IO.puts("  min:      #{ms(min_us)} ms")
    IO.puts("  mean:     #{ms(mean_us)} ms")
    IO.puts("  p50:      #{ms(p.(50))} ms")
    IO.puts("  p95:      #{ms(p.(95))} ms")
    IO.puts("  p99:      #{ms(p.(99))} ms")
    IO.puts("  max:      #{ms(max_us)} ms")
    IO.puts("")

    targets = %{p50: 100, p95: 200, p99: 500}
    p50 = p.(50) / 1000
    p95 = p.(95) / 1000
    p99 = p.(99) / 1000

    IO.puts("=== Target compliance ===")
    IO.puts("  p50 < #{targets.p50}ms: #{if p50 < targets.p50, do: "PASS", else: "FAIL"} (#{Float.round(p50, 1)}ms)")
    IO.puts("  p95 < #{targets.p95}ms: #{if p95 < targets.p95, do: "PASS", else: "FAIL"} (#{Float.round(p95, 1)}ms)")
    IO.puts("  p99 < #{targets.p99}ms: #{if p99 < targets.p99, do: "PASS", else: "FAIL"} (#{Float.round(p99, 1)}ms)")
  end

  defp ms(us), do: Float.round(us / 1000, 2)
end

ColdStartBench.run()
