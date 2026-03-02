defmodule ApmV4.UPM.Adapters.AzureDevOps do
  @moduledoc """
  VCS adapter for Azure DevOps using `az` CLI subprocesses.
  Requires the Azure CLI with the devops extension to be installed and authenticated.
  """
  @behaviour ApmV4.UPM.Adapters.VCSAdapter

  require Logger

  @impl true
  def list_prs(integration) do
    repo = integration.repo_url || ""
    rg = integration.resource_group

    args =
      ["devops", "repos", "pr", "list", "--output", "json"]
      |> maybe_add("--repository", repo)
      |> maybe_add("--resource-group", rg)

    case System.cmd("az", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} -> {:ok, Enum.map(prs, &normalize_pr/1)}
          _ -> {:ok, []}
        end

      {error, _} ->
        {:error, "az devops pr list failed: #{error}"}
    end
  end

  @impl true
  def create_pr(integration, attrs) do
    repo = integration.repo_url || ""
    title = Map.get(attrs, :title) || Map.get(attrs, "title") || "New PR"
    source = Map.get(attrs, :source_branch) || Map.get(attrs, "source_branch") || "HEAD"
    target = Map.get(attrs, :target_branch) || Map.get(attrs, "target_branch") || integration.default_branch || "main"

    args = ["devops", "repos", "pr", "create",
            "--repository", repo,
            "--title", title,
            "--source-branch", source,
            "--target-branch", target,
            "--output", "json"]

    case System.cmd("az", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, pr} -> {:ok, normalize_pr(pr)}
          _ -> {:ok, %{url: output}}
        end

      {error, _} ->
        {:error, "az devops pr create failed: #{error}"}
    end
  end

  @impl true
  def get_branch_status(integration, branch) do
    repo = integration.repo_url || ""

    args = ["devops", "repos", "ref", "list",
            "--repository", repo,
            "--filter", "heads/#{branch}",
            "--output", "json"]

    case System.cmd("az", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, [ref | _]} ->
            {:ok, %{name: branch, object_id: ref["objectId"], creator: ref["creator"]}}

          _ ->
            {:ok, %{name: branch, status: "not_found"}}
        end

      {error, _} ->
        {:error, "az devops refs failed: #{error}"}
    end
  end

  @impl true
  def sync_branch(_integration, _branch) do
    Logger.info("[AzureDevOps] sync_branch: manual sync required via Azure DevOps pipeline")
    :ok
  end

  @impl true
  def test_connection(_integration) do
    case System.cmd("az", ["account", "show", "--output", "json"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"name" => name}} ->
            {:ok, "Azure connected: #{name}"}

          _ ->
            {:ok, "Azure CLI authenticated"}
        end

      {error, _} ->
        {:error, "az account show failed: #{error}"}
    end
  end

  # Private

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, _flag, ""), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, value]

  defp normalize_pr(pr) do
    %{
      platform_id: to_string(pr["pullRequestId"] || pr["id"] || ""),
      platform_key: "PR!#{pr["pullRequestId"] || pr["id"]}",
      title: pr["title"],
      status: normalize_pr_state(pr["status"]),
      platform_url: pr["url"] || pr["remoteUrl"],
      branch_name: pr["sourceRefName"]
    }
  end

  defp normalize_pr_state("active"), do: :in_progress
  defp normalize_pr_state("completed"), do: :done
  defp normalize_pr_state("abandoned"), do: :cancelled
  defp normalize_pr_state(_), do: :backlog
end
