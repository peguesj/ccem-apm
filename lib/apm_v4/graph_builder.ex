defmodule ApmV4.GraphBuilder do
  @moduledoc """
  Transforms a flat agent list into a d3-hierarchy compatible tree structure.

  Pure function module (no GenServer) that builds hierarchical graph data
  suitable for D3.js visualization on the APM dashboard.

  ## Scopes

    * `:all_projects` - root > project nodes > formation nodes > agents
    * `:single_project` - root > formation nodes > agents
  """

  @status_priority %{
    "error" => 0,
    "warning" => 1,
    "active" => 2,
    "running" => 2,
    "idle" => 3,
    "completed" => 4,
    "discovered" => 5
  }

  @doc """
  Build a d3-hierarchy compatible tree from a flat list of agent maps.

  ## Options

    * `:scope` - `:all_projects` (default) or `:single_project`
  """
  @spec build_hierarchy(list(map()), keyword()) :: map()
  def build_hierarchy(agents, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all_projects)

    case scope do
      :all_projects -> build_all_projects(agents)
      :single_project -> build_single_project(agents)
    end
  end

  @doc """
  Return a list of node IDs that should start collapsed (depth > max_expanded_depth).
  """
  @spec collapse_state(map(), non_neg_integer()) :: list(String.t())
  def collapse_state(tree, max_expanded_depth \\ 1) do
    tree
    |> collect_collapsed_ids(0, max_expanded_depth)
    |> List.flatten()
  end

  # --- All-projects scope: root > projects > formations > agents ---

  defp build_all_projects(agents) do
    project_children =
      agents
      |> Enum.group_by(&(Map.get(&1, :project_name) || Map.get(&1, "project_name") || "unknown"))
      |> Enum.map(fn {project_name, project_agents} ->
        formation_children = build_formation_nodes(project_agents, project_name)

        make_node(
          id: "project-#{project_name}",
          name: project_name,
          type: "project",
          children: formation_children
        )
      end)
      |> Enum.sort_by(&get_in(&1, ["data", "name"]))

    make_node(id: "root", name: "APM", type: "root", children: project_children)
  end

  # --- Single-project scope: root > formations > agents ---

  defp build_single_project(agents) do
    project_name =
      agents
      |> List.first(%{})
      |> then(&(Map.get(&1, :project_name) || Map.get(&1, "project_name") || "unknown"))

    formation_children = build_formation_nodes(agents, project_name)
    make_node(id: "root", name: project_name, type: "root", children: formation_children)
  end

  # --- Formation grouping ---

  defp build_formation_nodes(agents, project_name) do
    agents
    |> Enum.group_by(&(Map.get(&1, :formation_id) || Map.get(&1, "formation_id") || "ungrouped"))
    |> Enum.map(fn {formation_id, formation_agents} ->
      squadron_children = build_squadron_nodes(formation_agents, project_name, formation_id)

      make_node(
        id: "formation-#{project_name}-#{formation_id}",
        name: formation_id,
        type: "formation",
        children: squadron_children
      )
    end)
    |> Enum.sort_by(fn node ->
      name = get_in(node, ["data", "name"])
      if name == "ungrouped", do: {1, name}, else: {0, name}
    end)
  end

  # --- Squadron grouping within formations ---

  defp build_squadron_nodes(agents, project_name, formation_id) do
    grouped = Enum.group_by(agents, &(Map.get(&1, :squadron) || Map.get(&1, "squadron")))

    case Map.keys(grouped) do
      [nil] ->
        build_agent_leaves(agents)

      _ ->
        grouped
        |> Enum.map(fn {squadron_id, squad_agents} ->
          sid = squadron_id || "ungrouped"
          agent_leaves = build_agent_leaves(squad_agents)

          make_node(
            id: "squadron-#{project_name}-#{formation_id}-#{sid}",
            name: sid,
            type: "squadron",
            children: agent_leaves
          )
        end)
        |> Enum.sort_by(fn node ->
          name = get_in(node, ["data", "name"])
          if name == "ungrouped", do: {1, name}, else: {0, name}
        end)
    end
  end

  # --- Agent leaf nodes ---

  defp build_agent_leaves(agents) do
    agents
    |> Enum.map(fn agent ->
      name = Map.get(agent, :name) || Map.get(agent, "name") || "unknown"
      id = Map.get(agent, :id) || Map.get(agent, "id") || "unknown"
      status = Map.get(agent, :status) || Map.get(agent, "status") || "idle"

      %{
        "name" => name,
        "children" => [],
        "data" => %{
          "id" => id,
          "name" => name,
          "type" => "agent",
          "status" => status,
          "agent_type" => Map.get(agent, :agent_type) || Map.get(agent, "agent_type") || "individual"
        }
      }
    end)
    |> Enum.sort_by(&get_in(&1, ["data", "name"]))
  end

  # --- Node constructor with status aggregation ---

  defp make_node(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    type = Keyword.fetch!(opts, :type)
    children = Keyword.get(opts, :children, [])

    %{
      "name" => name,
      "children" => children,
      "data" => %{
        "id" => id,
        "name" => name,
        "type" => type,
        "status" => aggregate_status(children),
        "agent_count" => count_agents(children)
      }
    }
  end

  defp aggregate_status([]), do: "idle"

  defp aggregate_status(children) do
    children
    |> Enum.map(&(get_in(&1, ["data", "status"]) || "idle"))
    |> Enum.min_by(&Map.get(@status_priority, &1, 99))
  end

  defp count_agents(children) do
    Enum.reduce(children, 0, fn node, acc ->
      case get_in(node, ["data", "type"]) do
        "agent" -> acc + 1
        _ -> acc + (get_in(node, ["data", "agent_count"]) || 0)
      end
    end)
  end

  # --- Collapse state collection ---

  defp collect_collapsed_ids(node, current_depth, max_expanded_depth) do
    node_id = get_in(node, ["data", "id"])
    children = Map.get(node, "children", [])

    own_id =
      if current_depth > max_expanded_depth and children != [] do
        [node_id]
      else
        []
      end

    child_ids =
      Enum.flat_map(children, fn child ->
        collect_collapsed_ids(child, current_depth + 1, max_expanded_depth)
      end)

    own_id ++ child_ids
  end
end
