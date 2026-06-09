defmodule Apm.FormationDot do
  @moduledoc """
  Generates Graphviz DOT source from formation agent trees.

  Produces a `digraph formation` with:
  - Nodes colored by hierarchy level (formation, squadron, swarm, cluster, agent)
  - Edges typed as hierarchy (black solid), pubsub (blue dashed), or data_export (orange bold)
  - rankdir=TB layout with Space Grotesk font
  """

  @type agent :: map()

  @formation_color "#2d5016"
  @squadron_color "#4a7c2e"
  @swarm_color "#1a4a6e"
  @cluster_color "#6e3a1a"
  @agent_color "#e8f5e9"

  @doc """
  Generate DOT source for a single formation identified by `formation_id` from
  a flat list of `agents` belonging to that formation.

  ## Example

      iex> Apm.FormationDot.generate("my-formation", agents)
      "digraph formation {\\n  rankdir=TB;\\n  ..."
  """
  @spec generate(String.t(), [agent()]) :: String.t()
  def generate(formation_id, agents) do
    tree = build_tree(formation_id, agents)
    render(tree)
  end

  # ---------------------------------------------------------------------------
  # Tree builder — mirrors the logic in FormationLive.build_formation_tree/2
  # but operates on a flat agent list for a single formation.
  # ---------------------------------------------------------------------------

  defp build_tree(formation_id, agents) do
    squadron_groups = Enum.group_by(agents, &(agent_val(&1, :squadron) || "default"))

    squadrons =
      Enum.map(squadron_groups, fn {squadron_name, sq_agents} ->
        {direct_agents, swarm_map} =
          sq_agents
          |> Enum.group_by(&agent_val(&1, :swarm))
          |> Map.pop(nil, [])

        swarms =
          Enum.map(swarm_map, fn {swarm_name, sw_agents} ->
            {direct_sw, cluster_map} =
              sw_agents
              |> Enum.group_by(&agent_val(&1, :cluster))
              |> Map.pop(nil, [])

            clusters =
              Enum.map(cluster_map, fn {cluster_name, cl_agents} ->
                %{name: cluster_name, agents: cl_agents}
              end)
              |> Enum.sort_by(& &1.name)

            %{name: swarm_name, clusters: clusters, agents: direct_sw}
          end)
          |> Enum.sort_by(& &1.name)

        %{name: squadron_name, swarms: swarms, agents: direct_agents}
      end)
      |> Enum.sort_by(& &1.name)

    %{id: formation_id, squadrons: squadrons}
  end

  # ---------------------------------------------------------------------------
  # DOT renderer
  # ---------------------------------------------------------------------------

  defp render(%{id: formation_id, squadrons: squadrons}) do
    f_node_id = dot_id(formation_id)

    lines =
      [
        "digraph formation {",
        "  rankdir=TB;",
        ~s'  node [shape=box, style="rounded,filled", fontname="Space Grotesk"];',
        ~s'  edge [fontname="Space Grotesk", fontsize=10];',
        "",
        "  // Formation root",
        ~s'  #{f_node_id} [label=#{dot_label(formation_id)}, fillcolor="#{@formation_color}", fontcolor="white", color="#{@formation_color}"];'
      ]
      |> render_squadrons(f_node_id, squadrons)
      |> Kernel.++(["}", ""])

    Enum.join(lines, "\n")
  end

  defp render_squadrons(lines, parent_id, squadrons) do
    Enum.reduce(squadrons, lines, fn squadron, acc ->
      sq_raw = "#{parent_id}/#{squadron.name}"
      sq_id = dot_id(sq_raw)

      acc
      |> append(
        ~s'  #{sq_id} [label=#{dot_label(squadron.name)}, fillcolor="#{@squadron_color}", fontcolor="white", color="#{@squadron_color}"];'
      )
      |> append(~s'  #{parent_id} -> #{sq_id} [color="black"];')
      |> render_direct_agents(sq_id, squadron.agents)
      |> render_swarms(sq_id, squadron.swarms)
    end)
  end

  defp render_swarms(lines, parent_id, swarms) do
    Enum.reduce(swarms, lines, fn swarm, acc ->
      sw_raw = "#{parent_id}/#{swarm.name}"
      sw_id = dot_id(sw_raw)

      acc
      |> append(
        ~s'  #{sw_id} [label=#{dot_label(swarm.name)}, fillcolor="#{@swarm_color}", fontcolor="white", color="#{@swarm_color}"];'
      )
      |> append(~s'  #{parent_id} -> #{sw_id} [color="black"];')
      |> render_direct_agents(sw_id, swarm.agents)
      |> render_clusters(sw_id, swarm.clusters)
    end)
  end

  defp render_clusters(lines, parent_id, clusters) do
    Enum.reduce(clusters, lines, fn cluster, acc ->
      cl_raw = "#{parent_id}/#{cluster.name}"
      cl_id = dot_id(cl_raw)

      acc
      |> append(
        ~s'  #{cl_id} [label=#{dot_label(cluster.name)}, fillcolor="#{@cluster_color}", fontcolor="white", color="#{@cluster_color}"];'
      )
      |> append(~s'  #{parent_id} -> #{cl_id} [color="black"];')
      |> render_direct_agents(cl_id, cluster.agents)
    end)
  end

  defp render_direct_agents(lines, parent_id, agents) do
    Enum.reduce(agents, lines, fn agent, acc ->
      agent_id = dot_id(agent_val(agent, :id) || "unknown")
      label = agent_val(agent, :name) || agent_val(agent, :id) || "agent"

      acc
      |> append(
        ~s'  #{agent_id} [label=#{dot_label(label)}, fillcolor="#{@agent_color}", fontcolor="#1a2e0a", color="#4a7c2e"];'
      )
      |> append(~s'  #{parent_id} -> #{agent_id} [color="black"];')
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp append(list, item), do: list ++ [item]

  # Produce a safe DOT node identifier (alphanumeric + underscores only)
  defp dot_id(raw) do
    sanitized =
      raw
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> then(fn s ->
        if String.match?(s, ~r/^[0-9]/) do
          "n_" <> s
        else
          s
        end
      end)

    "\"#{sanitized}\""
  end

  # Produce a quoted DOT label, escaping double quotes
  defp dot_label(text) do
    escaped = String.replace(text || "", "\"", "\\\"")
    "\"#{escaped}\""
  end

  # Access agent field regardless of atom vs string keys
  defp agent_val(agent, key) when is_map(agent) do
    agent[key] || agent[to_string(key)]
  end
end
