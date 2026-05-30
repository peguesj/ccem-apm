defmodule Apm.Library.GraphBuilder do
  @moduledoc """
  Builds a relationship graph across the CCEM ecosystem by reading
  `Apm.LibraryStore` data (7 categories: agents, skills, mcp_servers, tools,
  commands, patterns, learnings).

  Returns a graph suitable for D3 rendering:

      %{
        nodes: [%{id, type, label, category, group, metadata}, ...],
        edges: [%{source, target, relationship, weight}, ...],
        metadata: %{node_count, edge_count, built_at}
      }

  Edge types:
    * `:calls`      — skill-to-skill or agent-to-skill reference
    * `:uses`       — skill/agent uses a tool or MCP server
    * `:implements` — skill implements a pattern
    * `:records`    — skill records a learning
    * `:wraps`      — command wraps a skill
  """

  @type node_type :: :skill | :agent | :command | :tool | :pattern | :learning | :mcp
  @type edge_rel :: :calls | :uses | :implements | :records | :wraps

  @type graph_node :: %{
          id: String.t(),
          type: node_type(),
          label: String.t(),
          category: String.t() | nil,
          group: String.t() | nil,
          metadata: map()
        }

  @type graph_edge :: %{
          source: String.t(),
          target: String.t(),
          relationship: edge_rel(),
          weight: number()
        }

  @type graph :: %{
          nodes: [graph_node()],
          edges: [graph_edge()],
          metadata: map()
        }

  @type filter_opts :: [
          focus: String.t() | nil,
          depth: pos_integer(),
          types: [node_type()]
        ]

  @doc """
  Build the full library graph.
  """
  @spec build_graph(keyword()) :: graph()
  def build_graph(opts \\ []) do
    data = fetch_library_data()

    nodes = build_nodes(data, opts)
    edges = build_edges(data, nodes, opts)

    %{
      nodes: nodes,
      edges: edges,
      metadata: %{
        node_count: length(nodes),
        edge_count: length(edges),
        built_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  @doc """
  Build the graph with filter opts.
  * `:focus` - node id to center on
  * `:depth` - neighborhood radius (default 2)
  * `:types` - limit to subset of node types
  """
  @spec build_graph(map() | keyword(), filter_opts()) :: graph()
  def build_graph(data, opts) when is_map(data) and is_list(opts) do
    # variant used by tests that pass data directly
    nodes = build_nodes(data, opts)
    edges = build_edges(data, nodes, opts)
    filtered = apply_filter(%{nodes: nodes, edges: edges}, opts)

    Map.put(filtered, :metadata, %{
      node_count: length(filtered.nodes),
      edge_count: length(filtered.edges),
      built_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      filter: Map.new(opts)
    })
  end

  def build_graph(opts, filter_opts) when is_list(opts) and is_list(filter_opts) do
    all = build_graph(opts)
    filtered = apply_filter(all, filter_opts)
    Map.put(filtered, :metadata, Map.merge(all.metadata, %{filter: Map.new(filter_opts)}))
  end

  # ── Data fetch ─────────────────────────────────────────────────────────────

  defp fetch_library_data do
    if ets_available?() do
      %{
        skills: safe_list(&Apm.LibraryStore.list_skills/0),
        agents: safe_list(&Apm.LibraryStore.list_agents/0),
        commands: safe_list(&Apm.LibraryStore.list_commands/0),
        tools: safe_list(&Apm.LibraryStore.list_tools/0),
        patterns: safe_list(&Apm.LibraryStore.list_patterns/0),
        learnings: safe_list(&Apm.LibraryStore.list_learnings/0),
        mcp_servers: safe_list(&Apm.LibraryStore.list_mcp_servers/0)
      }
    else
      %{skills: [], agents: [], commands: [], tools: [], patterns: [], learnings: [], mcp_servers: []}
    end
  end

  defp ets_available?, do: :ets.whereis(:library_store) != :undefined

  defp safe_list(fun) do
    try do
      fun.()
    rescue
      _ -> []
    end
  end

  # ── Nodes ───────────────────────────────────────────────────────────────────

  defp build_nodes(data, opts) do
    allowed_types = Keyword.get(opts, :types, all_types())

    []
    |> maybe_add_nodes(data[:skills] || [], :skill, allowed_types)
    |> maybe_add_nodes(data[:agents] || [], :agent, allowed_types)
    |> maybe_add_nodes(data[:commands] || [], :command, allowed_types)
    |> maybe_add_nodes(data[:tools] || [], :tool, allowed_types)
    |> maybe_add_nodes(data[:patterns] || [], :pattern, allowed_types)
    |> maybe_add_nodes(data[:learnings] || [], :learning, allowed_types)
    |> maybe_add_nodes(data[:mcp_servers] || [], :mcp, allowed_types)
  end

  defp maybe_add_nodes(acc, items, type, allowed_types) do
    if type in allowed_types do
      acc ++ Enum.map(items, &to_node(&1, type))
    else
      acc
    end
  end

  defp to_node(item, type) do
    name = Map.get(item, :name) || Map.get(item, "name") || "unknown"
    label = Map.get(item, :display_name) || Map.get(item, "display_name") || name
    category = Map.get(item, :category) || Map.get(item, "category")

    %{
      id: "#{type}:#{name}",
      type: type,
      label: to_string(label),
      category: category,
      group: to_string(type),
      metadata: take_metadata(item)
    }
  end

  defp take_metadata(item) when is_map(item) do
    keys = [:description, :source, :path, :triggers, :type]
    Enum.reduce(keys, %{}, fn k, acc ->
      case Map.fetch(item, k) do
        {:ok, v} -> Map.put(acc, k, v)
        :error -> acc
      end
    end)
  end

  defp take_metadata(_), do: %{}

  # ── Edges ───────────────────────────────────────────────────────────────────

  defp build_edges(data, nodes, _opts) do
    node_index = node_id_index(nodes)

    []
    |> Kernel.++(skill_to_skill_edges(data, node_index))
    |> Kernel.++(skill_to_tool_edges(data, node_index))
    |> Kernel.++(skill_to_pattern_edges(data, node_index))
    |> Kernel.++(skill_to_learning_edges(data, node_index))
    |> Kernel.++(agent_to_tool_edges(data, node_index))
    |> Kernel.++(command_to_skill_edges(data, node_index))
    |> Enum.uniq_by(fn e -> {e.source, e.target, e.relationship} end)
  end

  defp node_id_index(nodes), do: MapSet.new(Enum.map(nodes, & &1.id))

  # skill calls skill: parse triggers / description for other skill names
  defp skill_to_skill_edges(%{skills: skills}, index) do
    skill_names = Enum.map(skills, fn s -> Map.get(s, :name) end)

    for skill <- skills,
        other_name <- skill_names,
        other_name != Map.get(skill, :name),
        mentions?(skill, other_name),
        src = "skill:#{Map.get(skill, :name)}",
        tgt = "skill:#{other_name}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :calls, weight: 1.0}
    end
  end

  defp skill_to_skill_edges(_, _), do: []

  # skill uses tool
  defp skill_to_tool_edges(%{skills: skills, tools: tools}, index) do
    tool_names = Enum.map(tools, fn t -> Map.get(t, :name) end)

    for skill <- skills,
        tool_name <- tool_names,
        mentions?(skill, tool_name),
        src = "skill:#{Map.get(skill, :name)}",
        tgt = "tool:#{tool_name}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :uses, weight: 0.5}
    end
  end

  defp skill_to_tool_edges(_, _), do: []

  # skill implements pattern: pattern has related_skills
  defp skill_to_pattern_edges(%{patterns: patterns}, index) do
    for pattern <- patterns,
        related_skill <- Map.get(pattern, :related_skills, []),
        src = "skill:#{related_skill}",
        tgt = "pattern:#{Map.get(pattern, :name)}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :implements, weight: 0.8}
    end
  end

  defp skill_to_pattern_edges(_, _), do: []

  # skill records learning: mentioned in description
  defp skill_to_learning_edges(%{skills: skills, learnings: learnings}, index) do
    for skill <- skills,
        learning <- learnings,
        mentions?(skill, Map.get(learning, :name, "")),
        src = "skill:#{Map.get(skill, :name)}",
        tgt = "learning:#{Map.get(learning, :name)}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :records, weight: 0.3}
    end
  end

  defp skill_to_learning_edges(_, _), do: []

  # agent calls tool: by agent description mentioning tool
  defp agent_to_tool_edges(%{agents: agents, tools: tools}, index) do
    tool_names = Enum.map(tools, fn t -> Map.get(t, :name) end)

    for agent <- agents,
        tool_name <- tool_names,
        mentions?(agent, tool_name),
        src = "agent:#{Map.get(agent, :name)}",
        tgt = "tool:#{tool_name}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :uses, weight: 0.4}
    end
  end

  defp agent_to_tool_edges(_, _), do: []

  # command wraps skill: by command name matching skill name
  defp command_to_skill_edges(%{commands: commands, skills: skills}, index) do
    skill_names = skills |> Enum.map(&Map.get(&1, :name)) |> MapSet.new()

    for command <- commands,
        skill_name = resolve_wrapped_skill(command, skill_names),
        not is_nil(skill_name),
        src = "command:#{Map.get(command, :name)}",
        tgt = "skill:#{skill_name}",
        MapSet.member?(index, src) and MapSet.member?(index, tgt) do
      %{source: src, target: tgt, relationship: :wraps, weight: 0.9}
    end
  end

  defp command_to_skill_edges(_, _), do: []

  defp resolve_wrapped_skill(command, skill_names) do
    cmd_name = Map.get(command, :name, "") |> to_string() |> String.trim_leading("/")
    if MapSet.member?(skill_names, cmd_name), do: cmd_name, else: nil
  end

  # ── Text matching ───────────────────────────────────────────────────────────

  defp mentions?(item, term) when is_binary(term) and byte_size(term) > 2 do
    haystack =
      [
        Map.get(item, :description, ""),
        Map.get(item, :triggers, []) |> Enum.join(" "),
        Map.get(item, :display_name, "")
      ]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, String.downcase(term))
  end

  defp mentions?(_, _), do: false

  # ── Filtering (focus, depth) ───────────────────────────────────────────────

  defp apply_filter(%{nodes: nodes, edges: edges}, opts) do
    case Keyword.get(opts, :focus) do
      nil ->
        %{nodes: nodes, edges: edges}

      focus_id ->
        depth = Keyword.get(opts, :depth, 2)
        reachable = bfs(focus_id, edges, depth)

        filtered_nodes = Enum.filter(nodes, fn n -> MapSet.member?(reachable, n.id) end)

        filtered_edges =
          Enum.filter(edges, fn e ->
            MapSet.member?(reachable, e.source) and MapSet.member?(reachable, e.target)
          end)

        %{nodes: filtered_nodes, edges: filtered_edges}
    end
  end

  defp bfs(start_id, edges, max_depth) do
    initial = MapSet.new([start_id])
    do_bfs(initial, [start_id], edges, 0, max_depth)
  end

  defp do_bfs(visited, _frontier, _edges, depth, max_depth) when depth >= max_depth,
    do: visited

  defp do_bfs(visited, frontier, edges, depth, max_depth) do
    next =
      for e <- edges,
          e.source in frontier or e.target in frontier,
          neighbor <- [e.source, e.target],
          not MapSet.member?(visited, neighbor),
          do: neighbor

    next = Enum.uniq(next)

    if next == [] do
      visited
    else
      visited = Enum.reduce(next, visited, &MapSet.put(&2, &1))
      do_bfs(visited, next, edges, depth + 1, max_depth)
    end
  end

  defp all_types, do: [:skill, :agent, :command, :tool, :pattern, :learning, :mcp]
end

