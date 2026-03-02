defmodule ApmV4.BackfillRunner do
  @moduledoc """
  Executes UPM→Plane backfill: reads primary prd.json, syncs story states to Plane.
  Stories with passes:true → "Done" state. Stories with passes:false → "In Progress" or "Backlog".
  """
  require Logger

  @ccem_project_id "a20e1d2e-3139-406e-ae03-dc6d1d8cb995"
  @done_state_id "9bab16dd-4834-4a2a-a00c-3f25516535e1"
  @in_progress_state_id "0d7e0c82-f974-4678-856b-64fd6e993fab"
  @backlog_state_id "111ce4ff-eef9-4622-93e5-ff65d95dc77e"

  @spec run_primary() :: map()
  def run_primary do
    started_at = DateTime.utc_now()
    ApmV4.BackfillStore.add_run(%{status: :running, started_at: started_at, message: "Starting backfill..."})

    result = do_backfill()

    run = Map.merge(result, %{started_at: started_at, completed_at: DateTime.utc_now()})
    ApmV4.BackfillStore.add_run(run)
    run
  end

  @spec check_api_connection() :: {:ok, String.t()} | {:error, String.t()}
  def check_api_connection do
    :inets.start()
    :ssl.start()
    ApmV4.PlaneClient.check_connection()
  end

  # --- Private ---

  defp do_backfill do
    with {:ok, prd} <- ApmV4.PrdScanner.find_primary(),
         {:ok, stories} <- read_stories(prd.path),
         {:ok, issues} <- ApmV4.PlaneClient.list_issues(@ccem_project_id) do
      synced = sync_stories(stories, issues)
      %{status: :ok, prd_path: prd.path, stories_total: length(stories), synced: synced, errors: []}
    else
      {:error, :not_found} ->
        %{status: :error, message: "Primary prd.json not found at ~/.claude/skills/ralph/prd.json"}
      {:error, reason} ->
        %{status: :error, message: "Backfill failed: #{inspect(reason)}"}
    end
  end

  defp read_stories(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      {:ok, Map.get(parsed, "userStories", [])}
    end
  end

  defp sync_stories(stories, issues) do
    issue_map = Map.new(issues["results"] || issues || [], fn issue ->
      title = Map.get(issue, "name", "")
      {title, issue}
    end)

    Enum.map(stories, fn story ->
      story_title = "[#{Map.get(story, "id", "?")}] #{Map.get(story, "title", "")}"
      passes = Map.get(story, "passes", false)
      state_id = if passes, do: @done_state_id, else: determine_state(story)

      # Find matching Plane issue
      matching_issue = find_matching_issue(issue_map, story)

      case matching_issue do
        nil ->
          %{story_id: Map.get(story, "id"), status: :not_found, message: "No Plane issue found for: #{story_title}"}

        issue ->
          issue_id = Map.get(issue, "id")
          current_state = Map.get(issue, "state", "")
          if current_state == state_id do
            %{story_id: Map.get(story, "id"), status: :skipped, message: "Already in correct state"}
          else
            case ApmV4.PlaneClient.update_issue(@ccem_project_id, issue_id, %{"state" => state_id}) do
              {:ok, _} ->
                %{story_id: Map.get(story, "id"), status: :synced, message: "Updated to #{if passes, do: "Done", else: "In Progress"}"}
              {:error, reason} ->
                %{story_id: Map.get(story, "id"), status: :error, message: inspect(reason)}
            end
          end
      end
    end)
  end

  defp find_matching_issue(issue_map, story) do
    story_id = Map.get(story, "id", "")
    plane_issue_id = Map.get(story, "planeIssueId")

    cond do
      plane_issue_id ->
        Enum.find(Map.values(issue_map), fn i -> Map.get(i, "id") == plane_issue_id end)
      true ->
        Enum.find(Map.values(issue_map), fn i ->
          name = Map.get(i, "name", "")
          String.contains?(name, story_id)
        end)
    end
  end

  defp determine_state(story) do
    case Map.get(story, "status") do
      "in_progress" -> @in_progress_state_id
      _ -> @backlog_state_id
    end
  end
end
