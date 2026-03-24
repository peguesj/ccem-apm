defmodule ApmV5.Plugins.Plane.PlanePlugin do
  @moduledoc """
  APM Plugin for the Plane project management API.

  Uses the existing `ApmV5.PlaneClient` (:httpc based, no external deps).
  Exposes the following actions:
    - "list_issues"   — paginated issues for a project
    - "get_issue"     — single issue by ID
    - "list_projects" — all workspace projects
    - "board_state"   — issues grouped by state (Kanban view)
    - "search_issues" — filter by project_name or search string

  CCEM Plane config (from project CLAUDE.md):
    Project ID : a20e1d2e-3139-406e-ae03-dc6d1d8cb995
    Workspace  : lgtm
    States:
      Backlog     => 111ce4ff-eef9-4622-93e5-ff65d95dc77e
      Todo        => 8904905c-0b3f-4f97-ab5c-e22747134d77
      In Progress => 0d7e0c82-f974-4678-856b-64fd6e993fab
      Done        => 9bab16dd-4834-4a2a-a00c-3f25516535e1
      Cancelled   => 80645a72-1150-4fc1-af9c-b1e85c30cd86
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.PlaneClient

  @ccem_project_id "a20e1d2e-3139-406e-ae03-dc6d1d8cb995"

  @state_map %{
    "111ce4ff-eef9-4622-93e5-ff65d95dc77e" => "Backlog",
    "8904905c-0b3f-4f97-ab5c-e22747134d77" => "Todo",
    "0d7e0c82-f974-4678-856b-64fd6e993fab" => "In Progress",
    "9bab16dd-4834-4a2a-a00c-3f25516535e1" => "Done",
    "80645a72-1150-4fc1-af9c-b1e85c30cd86" => "Cancelled"
  }

  @state_order ["Backlog", "Todo", "In Progress", "Done", "Cancelled"]

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  def plugin_name, do: "plane"

  @impl true
  def plugin_description,
    do: "Plane PM integration — list/search issues, board state, project list"

  @impl true
  def plugin_version, do: "1.0.0"

  @impl true
  def list_endpoints do
    [
      %{
        action: "list_issues",
        description: "List issues for a project (defaults to CCEM project)",
        params: %{project_id: "string (optional)", per_page: "integer (optional, default 50)"}
      },
      %{
        action: "get_issue",
        description: "Get a single issue by ID",
        params: %{project_id: "string (optional)", issue_id: "string (required)"}
      },
      %{
        action: "list_projects",
        description: "List all Plane projects in the lgtm workspace",
        params: %{}
      },
      %{
        action: "board_state",
        description: "Return issues grouped by state for Kanban display",
        params: %{project_id: "string (optional)"}
      },
      %{
        action: "search_issues",
        description: "Filter issues by project_name or search string",
        params: %{
          project_id: "string (optional)",
          query: "string (optional — matches sequence/name/description)",
          state_name: "string (optional — one of Backlog|Todo|In Progress|Done|Cancelled)"
        }
      }
    ]
  end

  @impl true
  def handle_action("list_issues", params, _opts) do
    project_id = Map.get(params, "project_id", @ccem_project_id)

    case PlaneClient.list_issues(project_id) do
      {:ok, data} ->
        issues = normalize_issues(extract_results(data))
        {:ok, %{issues: issues, count: length(issues), project_id: project_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("get_issue", %{"issue_id" => issue_id} = params, _opts) do
    project_id = Map.get(params, "project_id", @ccem_project_id)

    case PlaneClient.get_issue(project_id, issue_id) do
      {:ok, issue} -> {:ok, normalize_issue(issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("get_issue", _params, _opts) do
    {:error, {:missing_param, "issue_id is required"}}
  end

  def handle_action("list_projects", _params, _opts) do
    case PlaneClient.list_projects() do
      {:ok, data} ->
        projects =
          extract_results(data)
          |> Enum.map(fn p ->
            %{
              id: p["id"],
              name: p["name"],
              identifier: p["identifier"],
              network: p["network"],
              description: p["description"]
            }
          end)

        {:ok, %{projects: projects, count: length(projects)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("board_state", params, _opts) do
    project_id = Map.get(params, "project_id", @ccem_project_id)

    case PlaneClient.list_issues(project_id) do
      {:ok, data} ->
        issues = normalize_issues(extract_results(data))

        grouped =
          issues
          |> Enum.group_by(& &1.state_name)

        board =
          @state_order
          |> Enum.map(fn state ->
            %{state: state, issues: Map.get(grouped, state, []), count: length(Map.get(grouped, state, []))}
          end)

        {:ok, %{board: board, total: length(issues), project_id: project_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("search_issues", params, _opts) do
    project_id = Map.get(params, "project_id", @ccem_project_id)
    query = Map.get(params, "query", "") |> String.downcase()
    state_filter = Map.get(params, "state_name")

    case PlaneClient.list_issues(project_id) do
      {:ok, data} ->
        issues =
          extract_results(data)
          |> normalize_issues()
          |> Enum.filter(fn issue ->
            query_match =
              query == "" or
                String.contains?(String.downcase(issue.sequence_id || ""), query) or
                String.contains?(String.downcase(issue.name || ""), query) or
                String.contains?(String.downcase(issue.description || ""), query)

            state_match =
              is_nil(state_filter) or issue.state_name == state_filter

            query_match and state_match
          end)

        {:ok, %{issues: issues, count: length(issues), project_id: project_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp extract_results(%{"results" => results}) when is_list(results), do: results
  defp extract_results(data) when is_list(data), do: data
  defp extract_results(_), do: []

  defp normalize_issues(issues) when is_list(issues) do
    Enum.map(issues, &normalize_issue/1)
  end

  defp normalize_issue(issue) when is_map(issue) do
    state_id = issue["state"] || issue["state_id"]
    state_name = Map.get(@state_map, state_id, state_id || "Unknown")

    %{
      id: issue["id"],
      sequence_id: issue["sequence_id"] && "CCEM-#{issue["sequence_id"]}",
      name: issue["name"],
      description: issue["description_stripped"] || issue["description"] || "",
      state_id: state_id,
      state_name: state_name,
      priority: issue["priority"],
      assignees: issue["assignees"] || [],
      labels: issue["label_details"] || issue["labels"] || [],
      created_at: issue["created_at"],
      updated_at: issue["updated_at"],
      completed_at: issue["completed_at"]
    }
  end
end
