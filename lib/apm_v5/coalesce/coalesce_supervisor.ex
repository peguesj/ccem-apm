defmodule ApmV5.Coalesce.CoalesceSupervisor do
  @moduledoc """
  OTP Supervisor for the Coalesce subsystem.

  Children:
  - DecisionGateStore  — ETS-backed gate state, per-run gate lifecycle
  - CoalesceOrchestrator — GenServer managing coalesce run state machine

  SwarmCoordinator and SkillLogicEngine are stateless modules and do not
  need supervision entries.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ApmV5.Coalesce.DecisionGateStore,
      ApmV5.Coalesce.CoalesceOrchestrator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
