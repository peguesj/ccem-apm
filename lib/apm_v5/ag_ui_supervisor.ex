defmodule ApmV5.AgUiSupervisor do
  @moduledoc """
  Sub-supervisor for the AG-UI event pipeline processes.

  Uses `:rest_for_one` strategy so that if an upstream process crashes
  (e.g. EventStream), all downstream subscribers (EventBus, EventRouter,
  V4Compat) are also restarted in dependency order.

  Children (in start order):
  1. EventStream   — core event ring buffer (upstream)
  2. EventBus      — pub/sub broadcast bus
  3. EventRouter   — routes events to typed handlers
  4. V4Compat      — translates v4 APM hook payloads to AG-UI events
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.EventStream,
      ApmV5.AgUi.EventBus,
      ApmV5.AgUi.EventRouter,
      ApmV5.AgUi.V4Compat
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
