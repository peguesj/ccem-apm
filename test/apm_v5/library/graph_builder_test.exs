defmodule ApmV5.Library.GraphBuilderTest do
  use ExUnit.Case, async: true

  alias ApmV5.Library.GraphBuilder

  defp sample_data do
    %{
      skills: [
        %{name: "upm", display_name: "UPM", description: "Calls formation and ralph skills. Uses session hook."},
        %{name: "formation", display_name: "Formation", description: "Agent deployment"},
        %{name: "ralph", display_name: "Ralph", description: "Autonomous loop"}
      ],
      agents: [
        %{name: "tdd-squadron-lead", display_name: "TDD Squadron Lead", description: "Uses session hook for tracking"}
      ],
      commands: [
        %{name: "upm", display_name: "/upm", description: "UPM workflow"},
        %{name: "ralph", display_name: "/ralph", description: "Ralph loop"}
      ],
      tools: [
        %{name: "session", display_name: "Session", description: "Session hook"}
      ],
      patterns: [
        %{name: "formation-topology", display_name: "Formation Topology",
          description: "Hierarchical deployment", related_skills: ["formation", "upm"]}
      ],
      learnings: [
        %{name: "formation-lessons", display_name: "Formation Lessons", description: "Lessons from formation deploys"}
      ],
      mcp_servers: []
    }
  end

  describe "build_graph/2 with sample data" do
    test "returns nodes, edges, metadata struct" do
      g = GraphBuilder.build_graph(sample_data(), [])
      assert is_list(g.nodes)
      assert is_list(g.edges)
      assert is_map(g.metadata)
      assert g.metadata.node_count == length(g.nodes)
      assert g.metadata.edge_count == length(g.edges)
    end

    test "includes nodes from every provided category" do
      g = GraphBuilder.build_graph(sample_data(), [])
      types = g.nodes |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()
      assert :skill in types
      assert :agent in types
      assert :command in types
      assert :tool in types
      assert :pattern in types
      assert :learning in types
    end

    test "emits :calls edge between skills when one mentions another" do
      g = GraphBuilder.build_graph(sample_data(), [])
      calls = Enum.filter(g.edges, &(&1.relationship == :calls))
      assert Enum.any?(calls, &(&1.source == "skill:upm" and &1.target == "skill:formation"))
      assert Enum.any?(calls, &(&1.source == "skill:upm" and &1.target == "skill:ralph"))
    end

    test "emits :uses edge from skill to tool" do
      g = GraphBuilder.build_graph(sample_data(), [])
      uses = Enum.filter(g.edges, &(&1.relationship == :uses))
      assert Enum.any?(uses, &(&1.source == "skill:upm" and &1.target == "tool:session"))
    end

    test "emits :implements edge from skill to pattern via related_skills" do
      g = GraphBuilder.build_graph(sample_data(), [])
      impl = Enum.filter(g.edges, &(&1.relationship == :implements))
      assert Enum.any?(impl, &(&1.source == "skill:formation" and &1.target == "pattern:formation-topology"))
      assert Enum.any?(impl, &(&1.source == "skill:upm" and &1.target == "pattern:formation-topology"))
    end

    test "emits :wraps edge from command to skill with same name" do
      g = GraphBuilder.build_graph(sample_data(), [])
      wraps = Enum.filter(g.edges, &(&1.relationship == :wraps))
      assert Enum.any?(wraps, &(&1.source == "command:upm" and &1.target == "skill:upm"))
      assert Enum.any?(wraps, &(&1.source == "command:ralph" and &1.target == "skill:ralph"))
    end

    test "filters types via :types opt" do
      g = GraphBuilder.build_graph(sample_data(), types: [:skill])
      types = g.nodes |> Enum.map(& &1.type) |> Enum.uniq()
      assert types == [:skill]
    end

    test "filter focus + depth limits reachable nodes" do
      g = GraphBuilder.build_graph(sample_data(), focus: "skill:upm", depth: 1)
      # should include upm and its direct neighbors only
      ids = Enum.map(g.nodes, & &1.id)
      assert "skill:upm" in ids
    end
  end

  describe "build_graph/1 with no LibraryStore" do
    test "returns an empty graph when ETS table is unavailable" do
      g = GraphBuilder.build_graph([])
      assert is_list(g.nodes)
      assert is_list(g.edges)
      assert is_map(g.metadata)
    end
  end
end
