defmodule ApmV4.UPM.Adapters.VCSAdapter do
  @moduledoc """
  Behaviour definition for VCS adapters (GitHub, AzureDevOps).
  Each adapter module must implement all callbacks and accept a VCSIntegration struct
  as its first argument.
  """

  @type integration :: ApmV4.UPM.VCSIntegrationStore.VCSIntegration.t()
  @type pr_attrs :: map()
  @type branch :: String.t()

  @doc "List open pull requests for the integration."
  @callback list_prs(integration()) :: {:ok, list(map())} | {:error, term()}

  @doc "Create a pull request."
  @callback create_pr(integration(), pr_attrs()) :: {:ok, map()} | {:error, term()}

  @doc "Get the status of a specific branch (ahead/behind counts, last commit, CI status)."
  @callback get_branch_status(integration(), branch()) :: {:ok, map()} | {:error, term()}

  @doc "Sync branch state (push/pull/bidirectional depending on integration config)."
  @callback sync_branch(integration(), branch()) :: :ok | {:error, term()}

  @doc "Test the connection to the VCS provider. Returns {:ok, message} | {:error, reason}."
  @callback test_connection(integration()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Return the adapter module for a given provider atom."
  @spec get_adapter(atom()) :: module() | nil
  def get_adapter(:github), do: ApmV4.UPM.Adapters.GitHub
  def get_adapter(:azure_devops), do: ApmV4.UPM.Adapters.AzureDevOps
  def get_adapter(_), do: nil
end
