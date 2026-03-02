defmodule ApmV4.UPM.Adapters.Plane do
  @moduledoc """
  PM adapter for Plane project management platform.
  Delegates to ApmV4.PlaneClient for HTTP calls, normalizing responses
  to canonical WorkItem attribute maps.
  """
  @behaviour ApmV4.UPM.Adapters.PMAdapter

  require Logger

  @impl true
  def list_issues(integration) do
    project_id = integration.project_key || integration.workspace
    ApmV4.PlaneClient.list_issues(project_id)
  rescue
    e -> {:error, "PlaneClient error: #{inspect(e)}"}
  end

  @impl true
  def create_issue(integration, attrs) do
    project_id = integration.project_key || integration.workspace
    ApmV4.PlaneClient.create_issue(project_id, attrs)
  rescue
    e -> {:error, "PlaneClient error: #{inspect(e)}"}
  end

  @impl true
  def update_issue(integration, issue_id, attrs) do
    project_id = integration.project_key || integration.workspace
    ApmV4.PlaneClient.update_issue(project_id, issue_id, attrs)
  rescue
    e -> {:error, "PlaneClient error: #{inspect(e)}"}
  end

  @impl true
  def normalize(raw) do
    %{
      platform_id: to_string(raw["id"] || ""),
      platform_key: to_string(raw["sequence_id"] || ""),
      platform_url: build_url(raw),
      title: raw["name"] || raw["title"] || "Untitled",
      status: normalize_state(raw["state"] || raw["state_detail"]),
      priority: normalize_priority(raw["priority"]),
      passes: raw["is_draft"] == false && raw["completed_at"] != nil
    }
  end

  @impl true
  def test_connection(integration) do
    _project_id = integration.project_key || integration.workspace

    case ApmV4.PlaneClient.check_connection() do
      {:ok, _} -> {:ok, "Plane connection successful"}
      {:error, reason} -> {:error, "Plane connection failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Connection error: #{inspect(e)}"}
  end

  # Private helpers

  defp normalize_state(%{"name" => "Done"}), do: :done
  defp normalize_state(%{"name" => "In Progress"}), do: :in_progress
  defp normalize_state(%{"name" => "Todo"}), do: :todo
  defp normalize_state(%{"name" => "Cancelled"}), do: :cancelled
  defp normalize_state(%{"name" => "Backlog"}), do: :backlog
  defp normalize_state("done"), do: :done
  defp normalize_state("in_progress"), do: :in_progress
  defp normalize_state("todo"), do: :todo
  defp normalize_state("cancelled"), do: :cancelled
  defp normalize_state(_), do: :backlog

  defp normalize_priority(1), do: :urgent
  defp normalize_priority(2), do: :high
  defp normalize_priority(3), do: :medium
  defp normalize_priority(4), do: :low
  defp normalize_priority("urgent"), do: :urgent
  defp normalize_priority("high"), do: :high
  defp normalize_priority("medium"), do: :medium
  defp normalize_priority("low"), do: :low
  defp normalize_priority("none"), do: :none
  defp normalize_priority(_), do: :none

  defp build_url(%{"id" => id}) when is_binary(id) do
    "plane://issues/#{id}"
  end
  defp build_url(_), do: nil
end
