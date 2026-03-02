defmodule ApmV4.Intake.Watchers.NotificationWatcher do
  @moduledoc "Emits APM notifications for intake events based on severity."
  @behaviour ApmV4.Intake.Watcher

  alias ApmV4.AgentRegistry

  @impl true
  def name(), do: :notification

  @impl true
  def event_types(), do: [:all]

  @impl true
  def sources(), do: [:all]

  @impl true
  def enabled?(), do: true

  @impl true
  def handle(event, _config) do
    notification = %{
      id: System.unique_integer([:positive]),
      title: build_title(event),
      message: build_message(event),
      type: severity_to_type(event.severity),
      category: event.source,
      read: false,
      timestamp: DateTime.to_iso8601(event.received_at),
      formation_id: event.metadata["formation_id"],
      agent_id: event.metadata["agent_id"],
      project_name: event.project
    }

    try do
      AgentRegistry.add_notification(notification)
      {:ok, %{notification_id: notification.id}}
    rescue
      _ -> {:error, :agent_registry_offline}
    catch
      :exit, _ -> {:error, :agent_registry_offline}
    end
  end

  defp build_title(%{source: "uat", event_type: "context_fetch"} = event),
    do: "UAT Context Fetched — #{event.project}"
  defp build_title(%{source: "uat", event_type: "submission"} = event),
    do: "New UAT Submission — #{event.payload["severity"] || "unknown"} severity"
  defp build_title(event),
    do: "Intake: #{event.source}/#{event.event_type} — #{event.project}"

  defp build_message(event) do
    payload = event.payload
    "#{payload["title"] || payload["message"] || "Event received from #{event.source}"}"
  end

  defp severity_to_type("critical"), do: "error"
  defp severity_to_type("major"), do: "warning"
  defp severity_to_type("info"), do: "info"
  defp severity_to_type("success"), do: "success"
  defp severity_to_type(_), do: "info"
end
