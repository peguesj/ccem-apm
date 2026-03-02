defmodule ApmV4.UPM.Adapters.PMAdapter do
  @moduledoc """
  Behaviour definition for PM platform adapters (Plane, Linear, Jira, Monday, MSProject).
  Each adapter module must implement all callbacks and accept a PMIntegration struct
  as its first argument.
  """

  @type integration :: ApmV4.UPM.PMIntegrationStore.PMIntegration.t()
  @type work_item_attrs :: map()
  @type issue_id :: String.t()

  @doc "List all issues from the PM platform for the given integration."
  @callback list_issues(integration()) :: {:ok, list(map())} | {:error, term()}

  @doc "Create a new issue on the PM platform."
  @callback create_issue(integration(), work_item_attrs()) :: {:ok, map()} | {:error, term()}

  @doc "Update an existing issue on the PM platform."
  @callback update_issue(integration(), issue_id(), work_item_attrs()) :: {:ok, map()} | {:error, term()}

  @doc "Normalize a platform-native issue map to a canonical WorkItem attribute map."
  @callback normalize(map()) :: map()

  @doc "Test the connection to the PM platform. Returns {:ok, message} | {:error, reason}."
  @callback test_connection(integration()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Return the adapter module for a given platform atom."
  @spec get_adapter(atom()) :: module() | nil
  def get_adapter(:plane), do: ApmV4.UPM.Adapters.Plane
  def get_adapter(:linear), do: ApmV4.UPM.Adapters.Linear
  def get_adapter(:jira), do: ApmV4.UPM.Adapters.Jira
  def get_adapter(:monday), do: ApmV4.UPM.Adapters.Monday
  def get_adapter(:ms_project), do: ApmV4.UPM.Adapters.MSProject
  def get_adapter(_), do: nil
end
