defmodule Apm.Governance.GovernanceKriPoller do
  @moduledoc """
  Periodic GenServer that emits the `[:apm, :governance, :risk_score_p95]`
  Telemetry event every 60 seconds.

  Computes the p95 risk score across all decisions stored in
  `PolicyDecisionStore` by mapping each risk level to a numeric severity via
  `Apm.Auth.Types.risk_severity/1` and then calculating the 95th percentile
  of that distribution.

  ## Risk → severity mapping (from Types.risk_severity/1)
    - :none      → 0
    - :low       → 1
    - :medium    → 2
    - :high      → 3
    - :critical  → 4

  ## Telemetry event

      [:apm, :governance, :risk_score_p95]
      measurements: %{value: float()}   # 0.0 – 4.0
      metadata:     %{sample_size: non_neg_integer()}

  ## Prometheus metric

  Registered in `ApmWeb.Telemetry` as a `last_value` → becomes
  `ccem_governance_risk_score_p95` in the metrics endpoint.

  Part of comp-ms1 / CP-232 / US-464.
  """

  use GenServer
  require Logger

  alias Apm.Auth.{PolicyDecisionStore, Types}

  @interval_ms 60_000

  # ── Client API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate p95 emission (useful in tests / on-demand dashboards)."
  @spec emit_now() :: :ok
  def emit_now do
    GenServer.cast(__MODULE__, :emit_now)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_next()
    Logger.debug("[GovernanceKriPoller] Started — p95 risk score emitted every #{@interval_ms}ms")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:emit, state) do
    do_emit()
    schedule_next()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:emit_now, state) do
    do_emit()
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp schedule_next do
    Process.send_after(self(), :emit, @interval_ms)
  end

  defp do_emit do
    decisions = PolicyDecisionStore.latest(10_000)

    sample_size = length(decisions)

    p95 =
      if sample_size == 0 do
        0.0
      else
        severities =
          decisions
          |> Enum.map(fn d -> Types.risk_severity(d.risk_level) * 1.0 end)
          |> Enum.sort()

        percentile_95(severities)
      end

    :telemetry.execute(
      [:apm, :governance, :risk_score_p95],
      %{value: p95},
      %{sample_size: sample_size}
    )

    Logger.debug(
      "[GovernanceKriPoller] risk_score_p95=#{Float.round(p95, 3)} sample_size=#{sample_size}"
    )
  end

  # Computes the 95th percentile of a sorted list of floats.
  # Uses the nearest-rank method (ceil of 0.95 * N).
  defp percentile_95([]), do: 0.0

  defp percentile_95(sorted) do
    n = length(sorted)
    idx = ceil(0.95 * n) - 1
    # Clamp to valid range
    Enum.at(sorted, max(0, min(idx, n - 1)), 0.0)
  end
end
