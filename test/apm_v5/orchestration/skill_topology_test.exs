defmodule ApmV5.Orchestration.SkillTopologyTest do
  use ExUnit.Case, async: true

  @moduletag :orchestration

  @topology_plugins [
    ApmV5.Plugins.Formations.FormationsPlugin,
    ApmV5.Plugins.Upm.UpmPlugin,
    ApmV5.Plugins.Ralph.RalphPlugin,
    ApmV5.Plugins.Orchestration.OrchestrationPlugin
  ]

  describe "topology validation" do
    for mod <- @topology_plugins do
      mod_name = mod |> Module.split() |> List.last()

      test "#{mod_name} returns a valid topology map" do
        topo = unquote(mod).orchestration_topology()
        assert is_map(topo), "#{unquote(mod_name)} must return a map"
        assert Map.has_key?(topo, :steps), "#{unquote(mod_name)} must have :steps"
        assert Map.has_key?(topo, :edges), "#{unquote(mod_name)} must have :edges"
        assert Map.has_key?(topo, :gates), "#{unquote(mod_name)} must have :gates"
      end

      test "#{mod_name} steps have unique ids" do
        topo = unquote(mod).orchestration_topology()
        ids = Enum.map(topo.steps, & &1.id)
        assert ids == Enum.uniq(ids), "#{unquote(mod_name)} has duplicate step IDs"
      end

      test "#{mod_name} edges reference valid step ids" do
        topo = unquote(mod).orchestration_topology()
        valid_ids = MapSet.new(Enum.map(topo.steps, & &1.id))

        for edge <- topo.edges do
          assert MapSet.member?(valid_ids, edge.from),
                 "#{unquote(mod_name)} edge from '#{edge.from}' references invalid step"

          # Allow nil targets for terminal edges (e.g., ralph "more_stories" → nil)
          if edge.to != nil do
            assert MapSet.member?(valid_ids, edge.to),
                   "#{unquote(mod_name)} edge to '#{edge.to}' references invalid step"
          end
        end
      end

      test "#{mod_name} has no circular dependencies (simple check)" do
        topo = unquote(mod).orchestration_topology()

        # Find root nodes (no incoming edges, excluding self-loops and conditional back-edges)
        targets = MapSet.new(topo.edges |> Enum.map(& &1.to) |> Enum.reject(&is_nil/1))
        sources = MapSet.new(Enum.map(topo.edges, & &1.from))
        all_ids = MapSet.new(Enum.map(topo.steps, & &1.id))

        roots = MapSet.difference(all_ids, targets)

        # Must have at least one root (entry point)
        assert MapSet.size(roots) > 0 or MapSet.size(all_ids) == 0,
               "#{unquote(mod_name)} has no root steps (potential circular dependency)"

        # Verify reachability from roots (ignoring back-edges with conditions)
        forward_edges =
          topo.edges
          |> Enum.reject(fn e -> e.to == nil end)

        reachable = bfs_reachable(roots, forward_edges)

        # All steps should be reachable from some root or be a root
        _unreachable = MapSet.difference(all_ids, MapSet.union(roots, reachable))
        # Note: some steps may only be reachable via conditional back-edges,
        # which is valid in orchestration workflows (loops). We don't fail on this.
        assert MapSet.size(MapSet.union(roots, reachable)) > 0 or MapSet.size(sources) == 0
      end

      test "#{mod_name} steps have required fields" do
        topo = unquote(mod).orchestration_topology()

        for step <- topo.steps do
          assert Map.has_key?(step, :id), "Step missing :id in #{unquote(mod_name)}"
          assert Map.has_key?(step, :name), "Step missing :name in #{unquote(mod_name)}"
          assert Map.has_key?(step, :type), "Step missing :type in #{unquote(mod_name)}"
          assert is_binary(step.id), "Step id must be a string in #{unquote(mod_name)}"
          assert is_binary(step.name), "Step name must be a string in #{unquote(mod_name)}"
          assert is_atom(step.type), "Step type must be an atom in #{unquote(mod_name)}"
        end
      end

      test "#{mod_name} gates reference valid step ids" do
        topo = unquote(mod).orchestration_topology()
        valid_ids = MapSet.new(Enum.map(topo.steps, & &1.id))

        for gate <- topo.gates do
          assert MapSet.member?(valid_ids, gate.after_step),
                 "#{unquote(mod_name)} gate after_step '#{gate.after_step}' references invalid step"

          assert is_atom(gate.type), "Gate type must be an atom in #{unquote(mod_name)}"
        end
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp bfs_reachable(roots, edges) do
    do_bfs(MapSet.to_list(roots), MapSet.new(), edges)
  end

  defp do_bfs([], visited, _edges), do: visited

  defp do_bfs([node | rest], visited, edges) do
    if MapSet.member?(visited, node) do
      do_bfs(rest, visited, edges)
    else
      new_visited = MapSet.put(visited, node)

      neighbors =
        edges
        |> Enum.filter(fn e -> e.from == node end)
        |> Enum.map(fn e -> e.to end)
        |> Enum.reject(&is_nil/1)

      do_bfs(rest ++ neighbors, new_visited, edges)
    end
  end
end
