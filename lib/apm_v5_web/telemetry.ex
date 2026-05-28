defmodule ApmV5Web.Telemetry do
  @moduledoc """
  Telemetry supervisor that attaches Phoenix and VM metrics reporters.

  Configures Telemetry.Metrics and attaches them to the Phoenix.LiveDashboard
  metrics reporter for real-time performance monitoring.

  ## Prometheus reporter (obs-s2 / CP-217)

  `ApmV5.Metrics` is started here as a supervised `Peep` reporter child.
  The peep ETS storage backing `:ccem_apm_metrics` is scraped via
  `Peep.Plug` mounted at `/metrics` in the router.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller — periodic VM measurements every 10 s.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Peep Prometheus reporter — serves ccem_apm_* metrics at /metrics.
      # Named :ccem_apm_metrics so Peep.Plug can resolve it by name.
      ApmV5.Metrics.child_spec()
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {ApmV5Web, :count_users, []}
    ]
  end
end
