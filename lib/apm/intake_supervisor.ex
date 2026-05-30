defmodule Apm.IntakeSupervisor do
  @moduledoc """
  Sub-supervisor for API intake processing services.

  Uses `:one_for_one` strategy because these services are independent:
  a crash in one (e.g. CommandRunner) should not affect the others.

  Children:
  - ApiKeyStore       — manages API key validation state
  - CommandRunner     — executes CLI commands on behalf of agents
  - AlertRulesEngine  — evaluates configured alert rules
  - Intake.Store      — stores incoming request/event records
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Apm.ApiKeyStore,
      Apm.CommandRunner,
      Apm.AlertRulesEngine,
      {Apm.Intake.Store, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
