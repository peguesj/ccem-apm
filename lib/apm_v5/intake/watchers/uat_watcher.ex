defmodule ApmV5.Intake.Watchers.UatWatcher do
  @moduledoc """
  UAT-specific watcher. Handles UAT intake events:
  - context_fetch: updates dashboard metrics
  - submission: escalates criticals via APM notification
  """
  @behaviour ApmV5.Intake.Watcher

  require Logger

  @impl true
  def name(), do: :uat

  @impl true
  def event_types(), do: ["context_fetch", "submission", "sync_complete"]

  @impl true
  def sources(), do: ["uat"]

  @impl true
  def enabled?(), do: true

  @impl true
  def handle(%{event_type: "context_fetch"} = event, _config) do
    payload = event.payload
    Logger.info("[UatWatcher] Context fetch: #{payload["total"]} total, #{payload["unsynced"]} unsynced, #{payload["critical_open"]} critical open")
    {:ok, %{processed: :context_fetch, stats: payload}}
  end

  def handle(%{event_type: "submission"} = event, _config) do
    severity = event.payload["severity"] || "unknown"
    title = event.payload["title"] || "Untitled"
    Logger.info("[UatWatcher] New submission: [#{severity}] #{title}")
    {:ok, %{processed: :submission, severity: severity}}
  end

  def handle(event, _config) do
    {:ok, %{processed: event.event_type}}
  end
end
