defmodule ApmV5.Intake.Watchers.LogWatcher do
  @moduledoc "Logs all intake events to structured Logger output."
  @behaviour ApmV5.Intake.Watcher

  require Logger

  @impl true
  def name(), do: :log

  @impl true
  def event_types(), do: [:all]

  @impl true
  def sources(), do: [:all]

  @impl true
  def enabled?(), do: true

  @impl true
  def handle(event, _config) do
    Logger.info("[Intake] #{event.source}/#{event.event_type}",
      id: event.id,
      project: event.project,
      environment: event.environment,
      severity: event.severity
    )
    {:ok, %{logged: true}}
  end
end
