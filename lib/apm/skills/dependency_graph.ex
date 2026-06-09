defmodule Apm.Skills.DependencyGraph do
  @moduledoc """
  Pure Elixir module providing graph algorithms for skill dependency analysis.

  Supports:
  - Building directed acyclic graphs from skill manifests
  - Detecting cycles via DFS with path tracking
  - Computing transitive closure via BFS with distance metrics
  - Topological sorting for dependency ordering
  - Impact analysis for understanding upstream/downstream effects
  - Comprehensive statistics and reporting
  """

  @type skill_id :: String.t()
  @type skill :: %{
          id: skill_id,
          name: String.t(),
          dependencies: [skill_id],
          triggers: [String.t()],
          type: String.t()
        }
  @type graph :: %{skill_id => [skill_id]}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Build a dependency graph from a list of skills."
  @spec build_graph([skill]) :: graph
  def build_graph(skills) when is_list(skills) do
    Enum.reduce(skills, %{}, fn skill, acc ->
      Map.put(acc, skill.id, skill.dependencies)
    end)
  end

  @doc "Get all transitive dependencies of a skill (including itself)."
  @spec get_transitive_closure(graph, skill_id) :: %{skill_id => non_neg_integer()}
  def get_transitive_closure(graph, start_skill) do
    bfs(graph, start_skill)
  end

  @doc "Get all dependents of a skill (things that depend on it)."
  @spec get_dependents(graph, skill_id) :: %{skill_id => non_neg_integer()}
  def get_dependents(graph, target_skill) do
    reverse_graph = reverse_graph(graph)
    bfs(reverse_graph, target_skill)
  end

  @doc "Detect cycles in the dependency graph. Returns list of cycles (each cycle is a path)."
  @spec detect_cycles(graph) :: [[skill_id]]
  def detect_cycles(graph) do
    graph
    |> Map.keys()
    |> Enum.reduce([], fn node, acc ->
      case dfs_cycle(graph, node, [], MapSet.new()) do
        nil -> acc
        cycle -> [cycle | acc]
      end
    end)
    |> Enum.uniq()
  end

  @doc "Topological sort of the dependency graph."
  @spec topological_sort(graph) :: {:ok, [skill_id]} | {:error, :has_cycles}
  def topological_sort(graph) do
    case detect_cycles(graph) do
      [] ->
        sorted =
          graph
          |> Map.keys()
          |> Enum.sort_by(&compute_depth(graph, &1))
          |> Enum.reverse()

        {:ok, sorted}

      cycles ->
        {:error, {:has_cycles, cycles}}
    end
  end

  @doc "Analyze impact of a skill change (all downstream effects)."
  @spec impact_analysis(graph, skill_id) :: %{
          direct_deps: [skill_id],
          transitive_deps: [skill_id],
          direct_dependents: [skill_id],
          transitive_dependents: [skill_id],
          impact_scope: :local | :moderate | :critical
        }
  def impact_analysis(graph, skill_id) do
    direct_deps = Map.get(graph, skill_id, [])

    transitive_deps =
      get_transitive_closure(graph, skill_id) |> Map.keys() |> List.delete(skill_id)

    dependents = get_dependents(graph, skill_id)

    direct_dependents =
      [skill_id | direct_deps] |> Enum.filter(&direct_dependent?(graph, skill_id, &1))

    transitive_dependents =
      dependents
      |> Map.keys()
      |> List.delete(skill_id)

    impact_scope =
      cond do
        length(transitive_dependents) > 10 -> :critical
        length(transitive_dependents) > 3 -> :moderate
        true -> :local
      end

    %{
      direct_deps: direct_deps,
      transitive_deps: transitive_deps,
      direct_dependents: direct_dependents,
      transitive_dependents: transitive_dependents,
      impact_scope: impact_scope
    }
  end

  @doc "Generate comprehensive statistics about the graph."
  @spec stats(graph) :: %{
          total_skills: non_neg_integer(),
          total_edges: non_neg_integer(),
          avg_deps_per_skill: float(),
          max_depth: non_neg_integer(),
          has_cycles: boolean(),
          isolated_skills: [skill_id],
          critical_paths: [[skill_id]]
        }
  def stats(graph) do
    total_skills = map_size(graph)
    total_edges = graph |> Map.values() |> Enum.concat() |> length()
    avg_deps = if total_skills > 0, do: total_edges / total_skills, else: 0.0

    max_depth =
      graph
      |> Map.keys()
      |> Enum.map(&compute_depth(graph, &1))
      |> Enum.max(fn -> 0 end)

    cycles = detect_cycles(graph)
    has_cycles = length(cycles) > 0

    isolated =
      graph
      |> Enum.filter(fn {_k, v} -> length(v) == 0 end)
      |> Enum.map(fn {k, _v} -> k end)

    critical = find_critical_paths(graph, 3)

    %{
      total_skills: total_skills,
      total_edges: total_edges,
      avg_deps_per_skill: Float.round(avg_deps, 2),
      max_depth: max_depth,
      has_cycles: has_cycles,
      isolated_skills: isolated,
      critical_paths: critical
    }
  end

  # ── Private Helpers ────────────────────────────────────────────────────────

  @spec bfs(graph, skill_id) :: %{skill_id => non_neg_integer()}
  defp bfs(graph, start) do
    queue = :queue.from_list([{start, 0}])
    visited = MapSet.new([start])
    distances = %{start => 0}
    bfs_loop(graph, queue, visited, distances)
  end

  @spec bfs_loop(graph, :queue.queue(), MapSet.t(), map()) :: map()
  defp bfs_loop(graph, queue, visited, distances) do
    case :queue.out(queue) do
      {:empty, _} ->
        distances

      {{:value, {node, dist}}, rest_queue} ->
        neighbors = Map.get(graph, node, [])

        {new_queue, new_visited, new_distances} =
          Enum.reduce(neighbors, {rest_queue, visited, distances}, fn neighbor, {q, v, d} ->
            if MapSet.member?(v, neighbor) do
              {q, v, d}
            else
              new_dist = dist + 1

              {
                :queue.in({neighbor, new_dist}, q),
                MapSet.put(v, neighbor),
                Map.put(d, neighbor, new_dist)
              }
            end
          end)

        bfs_loop(graph, new_queue, new_visited, new_distances)
    end
  end

  @spec dfs_cycle(graph, skill_id, [skill_id], MapSet.t()) :: [skill_id] | nil
  defp dfs_cycle(_graph, _node, path, _visiting) when length(path) > 20 do
    nil
  end

  defp dfs_cycle(graph, node, path, visiting) do
    cond do
      MapSet.member?(visiting, node) ->
        # Found cycle: extract path from node to node
        case Enum.split_while(path, &(&1 != node)) do
          {_before, [^node | rest]} -> [node | rest]
          _ -> nil
        end

      true ->
        neighbors = Map.get(graph, node, [])
        new_visiting = MapSet.put(visiting, node)
        new_path = [node | path]

        Enum.find_value(neighbors, nil, fn neighbor ->
          dfs_cycle(graph, neighbor, new_path, new_visiting)
        end)
    end
  end

  @spec reverse_graph(graph) :: graph
  defp reverse_graph(graph) do
    Enum.reduce(graph, %{}, fn {node, neighbors}, acc ->
      # Ensure node exists in reversed graph
      acc = Map.put_new(acc, node, [])

      # Add reverse edges
      Enum.reduce(neighbors, acc, fn neighbor, inner_acc ->
        Map.update(inner_acc, neighbor, [node], &[node | &1])
      end)
    end)
  end

  @spec compute_depth(graph, skill_id) :: non_neg_integer()
  defp compute_depth(graph, node) do
    case Map.get(graph, node, []) do
      [] -> 0
      deps -> 1 + (deps |> Enum.map(&compute_depth(graph, &1)) |> Enum.max(fn -> 0 end))
    end
  end

  @spec direct_dependent?(graph, skill_id, skill_id) :: boolean()
  defp direct_dependent?(graph, source, target) do
    graph
    |> Map.get(target, [])
    |> Enum.member?(source)
  end

  @spec find_critical_paths(graph, non_neg_integer()) :: [[skill_id]]
  defp find_critical_paths(graph, limit) do
    graph
    |> Map.keys()
    |> Enum.map(&build_paths(graph, &1, limit))
    |> Enum.concat()
    |> Enum.uniq()
    |> Enum.sort_by(&length/1, :desc)
    |> Enum.take(limit)
  end

  @spec build_paths(graph, skill_id, non_neg_integer(), [skill_id]) :: [[skill_id]]
  defp build_paths(graph, node, limit, path \\ [])

  defp build_paths(_graph, _node, limit, path) when length(path) >= limit do
    [Enum.reverse(path)]
  end

  defp build_paths(graph, node, limit, path) do
    new_path = [node | path]

    case Map.get(graph, node, []) do
      [] ->
        [Enum.reverse(new_path)]

      deps ->
        deps
        |> Enum.flat_map(&build_paths(graph, &1, limit, new_path))
        |> Enum.uniq()
    end
  end
end
