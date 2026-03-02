defmodule ApmV4.UPM.Adapters.GitHub do
  @moduledoc """
  VCS adapter for GitHub using `gh` CLI subprocesses.
  Requires the GitHub CLI to be installed and authenticated.
  """
  @behaviour ApmV4.UPM.Adapters.VCSAdapter

  require Logger

  @impl true
  def list_prs(integration) do
    repo = extract_repo(integration.repo_url)

    case System.cmd("gh", ["pr", "list", "--repo", repo, "--json",
                           "number,title,state,headRefName,url,createdAt"],
                    stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} -> {:ok, Enum.map(prs, &normalize_pr/1)}
          {:error, _} -> {:ok, []}
        end

      {error, _} ->
        {:error, "gh pr list failed: #{error}"}
    end
  end

  @impl true
  def create_pr(integration, attrs) do
    repo = extract_repo(integration.repo_url)
    title = Map.get(attrs, :title) || Map.get(attrs, "title") || "New PR"
    base = Map.get(attrs, :base) || Map.get(attrs, "base") || integration.default_branch || "main"
    head = Map.get(attrs, :head) || Map.get(attrs, "head") || "HEAD"

    args = ["pr", "create", "--repo", repo, "--title", title, "--base", base, "--head", head, "--body", ""]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, %{url: String.trim(output)}}
      {error, _} -> {:error, "gh pr create failed: #{error}"}
    end
  end

  @impl true
  def get_branch_status(integration, branch) do
    repo = extract_repo(integration.repo_url)
    base = integration.default_branch || "main"

    case System.cmd("gh", ["api", "repos/#{repo}/compare/#{base}...#{branch}",
                           "--jq", "{ahead: .ahead_by, behind: .behind_by, status: .status}"],
                    stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(String.trim(output)) do
          {:ok, status} -> {:ok, status}
          _ -> {:ok, %{ahead: 0, behind: 0, status: "unknown"}}
        end

      {error, _} ->
        {:error, "gh api failed: #{error}"}
    end
  end

  @impl true
  def sync_branch(integration, branch) do
    sync_type = integration.sync_type || :pull
    repo = extract_repo(integration.repo_url)

    case sync_type do
      :pull ->
        case System.cmd("gh", ["api", "--method", "POST",
                               "repos/#{repo}/merge-upstream",
                               "-f", "branch=#{branch}"],
                        stderr_to_stdout: true) do
          {_, 0} -> :ok
          {error, _} -> {:error, "sync failed: #{error}"}
        end

      _ ->
        Logger.info("[GitHub] sync_branch: #{sync_type} not implemented for branch #{branch}")
        :ok
    end
  end

  @impl true
  def test_connection(_integration) do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {output, 0} ->
        logged_in = output |> String.split("\n") |> Enum.find(&String.contains?(&1, "Logged in")) || "authenticated"
        {:ok, "GitHub CLI: #{String.trim(logged_in)}"}

      {error, _} ->
        {:error, "gh auth status failed: #{error}"}
    end
  end

  # Private

  defp extract_repo(nil), do: ""
  defp extract_repo(url) do
    # Support https://github.com/owner/repo and git@github.com:owner/repo
    url
    |> String.replace("https://github.com/", "")
    |> String.replace("git@github.com:", "")
    |> String.replace(".git", "")
    |> String.trim()
  end

  defp normalize_pr(pr) do
    %{
      platform_id: to_string(pr["number"] || ""),
      platform_key: "PR##{pr["number"]}",
      title: pr["title"],
      status: normalize_pr_state(pr["state"]),
      platform_url: pr["url"],
      branch_name: pr["headRefName"]
    }
  end

  defp normalize_pr_state("OPEN"), do: :in_progress
  defp normalize_pr_state("CLOSED"), do: :cancelled
  defp normalize_pr_state("MERGED"), do: :done
  defp normalize_pr_state(_), do: :backlog
end
