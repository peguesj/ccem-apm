defmodule ApmV5.Architectures.Diligent do
  @moduledoc """
  Diligent architecture: Fleet → Formation → Squadron → Swarm → Agent.

  The canonical hierarchical agent composition for CCEM. Each level has
  specific responsibilities:

  - **Fleet**: Top-level container. One fleet per project/initiative.
  - **Formation**: A deployable unit of work (e.g., a Ralph PRD execution).
  - **Squadron**: A team within a formation, led by an orchestrator agent.
  - **Swarm**: A group of agents within a squadron working on related tasks.
  - **Agent**: Individual execution unit (leaf node).

  ## Graph Config

  Uses Railway-inspired glassmorphic aesthetics with level-based coloring
  and animated state transitions.
  """

  @behaviour ApmV5.Architectures.ArchitectureBehaviour

  @levels [:fleet, :formation, :squadron, :swarm, :agent]

  @level_config %{
    fleet:     %{color: "#e879f9", shape: :hexagon, size: 28, glow: true},
    formation: %{color: "#3b82f6", shape: :rounded_rect, size: 22, glow: true},
    squadron:  %{color: "#06b6d4", shape: :rounded_rect, size: 18, glow: false},
    swarm:     %{color: "#22c55e", shape: :circle, size: 14, glow: false},
    agent:     %{color: "#f97316", shape: :circle, size: 10, glow: false}
  }

  @impl true
  def architecture_name, do: "diligent"

  @impl true
  def architecture_description do
    "Hierarchical agent composition: Fleet → Formation → Squadron → Swarm → Agent"
  end

  @impl true
  def architecture_version, do: "1.0.0"

  @impl true
  def levels, do: @levels

  @impl true
  @spec build_tree([map()], keyword()) :: map()
  def build_tree(agents, opts \\ []) do
    fleet_name = Keyword.get(opts, :fleet_name, "default")

    # Group agents by formation → squadron → swarm
    formation_groups =
      agents
      |> Enum.group_by(&(Map.get(&1, :formation_id) || "ungrouped"))
      |> Enum.map(fn {fmt_id, fmt_agents} ->
        squadron_children = build_squadrons(fmt_agents, fmt_id)

        %{
          "id" => "formation-#{fmt_id}",
          "name" => fmt_id,
          "level" => "formation",
          "status" => aggregate_status(fmt_agents),
          "agent_count" => length(fmt_agents),
          "children" => squadron_children,
          "metadata" => extract_formation_meta(fmt_agents)
        }
      end)
      |> Enum.sort_by(&(&1["name"]))

    %{
      "id" => "fleet-#{fleet_name}",
      "name" => fleet_name,
      "level" => "fleet",
      "status" => aggregate_status(agents),
      "agent_count" => length(agents),
      "children" => formation_groups,
      "metadata" => %{"architecture" => "diligent", "version" => "1.0.0"}
    }
  end

  @impl true
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(tree) do
    cond do
      tree["level"] != "fleet" ->
        {:error, "Root node must be level=fleet, got #{tree["level"]}"}

      not is_list(tree["children"]) ->
        {:error, "Fleet must have children list"}

      Enum.any?(tree["children"], &(&1["level"] != "formation")) ->
        {:error, "Fleet children must all be formations"}

      true ->
        :ok
    end
  end

  @impl true
  def graph_config do
    %{
      "architecture" => "diligent",
      "levels" => Enum.map(@levels, fn level ->
        config = Map.get(@level_config, level)
        %{
          "name" => Atom.to_string(level),
          "color" => config.color,
          "shape" => Atom.to_string(config.shape),
          "size" => config.size,
          "glow" => config.glow
        }
      end),
      "layout" => %{
        "type" => "tree",
        "direction" => "TB",
        "node_spacing" => 60,
        "level_spacing" => 100,
        "connector" => "cubic_bezier",
        "animation" => %{
          "enter" => "fade_scale",
          "exit" => "fade_out",
          "duration_ms" => 500
        }
      },
      "aesthetics" => %{
        "background" => "#0f172a",
        "grid" => "radial_dots",
        "node_style" => "glassmorphic",
        "hover_glow" => true,
        "status_pulse" => true
      }
    }
  end

  # --- Private ---

  defp build_squadrons(agents, fmt_id) do
    agents
    |> Enum.group_by(&(Map.get(&1, :squadron) || Map.get(&1, :agent_type, "individual")))
    |> Enum.map(fn {squad_id, squad_agents} ->
      swarm_children = build_swarms(squad_agents, fmt_id, squad_id)

      %{
        "id" => "squadron-#{fmt_id}-#{squad_id}",
        "name" => to_string(squad_id),
        "level" => "squadron",
        "status" => aggregate_status(squad_agents),
        "agent_count" => length(squad_agents),
        "children" => swarm_children,
        "metadata" => %{}
      }
    end)
    |> Enum.sort_by(&(&1["name"]))
  end

  defp build_swarms(agents, fmt_id, squad_id) do
    agents
    |> Enum.group_by(&(Map.get(&1, :swarm_id) || "default"))
    |> Enum.map(fn {swarm_id, swarm_agents} ->
      agent_leaves = build_agent_leaves(swarm_agents)

      %{
        "id" => "swarm-#{fmt_id}-#{squad_id}-#{swarm_id}",
        "name" => to_string(swarm_id),
        "level" => "swarm",
        "status" => aggregate_status(swarm_agents),
        "agent_count" => length(swarm_agents),
        "children" => agent_leaves,
        "metadata" => %{}
      }
    end)
    |> Enum.sort_by(&(&1["name"]))
  end

  defp build_agent_leaves(agents) do
    Enum.map(agents, fn a ->
      %{
        "id" => Map.get(a, :id) || Map.get(a, "id", "unknown"),
        "name" => Map.get(a, :name) || Map.get(a, "name", "unknown"),
        "level" => "agent",
        "status" => Map.get(a, :status) || Map.get(a, "status", "idle"),
        "agent_count" => 0,
        "children" => [],
        "metadata" => %{
          "agent_type" => Map.get(a, :agent_type) || "individual",
          "role" => Map.get(a, :role) || "individual"
        }
      }
    end)
    |> Enum.sort_by(&(&1["name"]))
  end

  defp aggregate_status([]), do: "idle"

  defp aggregate_status(agents) do
    statuses = Enum.map(agents, &(Map.get(&1, :status) || "idle"))

    priority = %{"error" => 0, "active" => 1, "working" => 1, "idle" => 2, "completed" => 3}

    statuses
    |> Enum.min_by(&Map.get(priority, &1, 99))
  end

  defp extract_formation_meta(agents) do
    waves =
      agents
      |> Enum.map(&Map.get(&1, :wave))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "waves" => waves,
      "types" => agents |> Enum.map(&(Map.get(&1, :agent_type) || "individual")) |> Enum.uniq()
    }
  end
end
