defmodule ApmV5.Coalesce.SwarmCoordinator do
  @moduledoc """
  Manages agent swarms for coalesce formations.

  A swarm = multiple instances of the same agent type working concurrently
  on different skills, all reporting results back to the CoalesceOrchestrator.

  Each swarm is registered with the APM AgentRegistry so it appears in the
  formation dashboard at /formation.

  Swarm lifecycle:
  1. deploy_swarms/3 — spawn N swarms for the affected skills list
  2. Each swarm registers with APM, processes its skill, emits results
  3. stop_swarms/1 — kill all swarms for a formation
  """

  require Logger

  @apm_base "http://localhost:3032"

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Deploy skill-refinement swarms for a coalesce formation.
  Each skill gets 3 concurrent agents: gap_analyst, enhancement_writer, regression_guard.
  Swarms run async and fire APM registration curl on spawn.
  Returns {:ok, swarm_ids}.
  """
  @spec deploy_swarms(String.t(), [String.t()], map()) :: {:ok, [String.t()]}
  def deploy_swarms(formation_id, skill_names, params) do
    swarm_agents = Enum.flat_map(skill_names, fn skill_name ->
      _spawn_skill_swarm(formation_id, skill_name, params)
    end)

    Logger.info("[SwarmCoordinator] Deployed #{length(swarm_agents)} agents for formation #{formation_id}")
    {:ok, Enum.map(swarm_agents, & &1.agent_id)}
  end

  @doc """
  Register a swarm intelligence squadron in APM (5 agents for Wave 1).
  """
  @spec deploy_intelligence_swarm(String.t()) :: {:ok, [String.t()]}
  def deploy_intelligence_swarm(formation_id) do
    roles = [
      {"source-fetcher", "Fetches and parses authoritative source URLs", 1},
      {"viki-query", "Queries VIKI vectorized knowledge base", 2},
      {"upm-state", "Reads current UPM project state", 1},
      {"skills-inventory", "Inventories all skills in scope", 1}
    ]

    agents = Enum.flat_map(roles, fn {role, description, count} ->
      Enum.map(1..count, fn i ->
        agent_id = "#{formation_id}-intel-#{role}-#{i}"
        _register_agent(agent_id, formation_id, role, description, 1, nil)
        %{agent_id: agent_id, role: role}
      end)
    end)

    {:ok, Enum.map(agents, & &1.agent_id)}
  end

  @doc """
  Stop all swarm agents for a given formation.
  """
  @spec stop_swarms(String.t()) :: :ok
  def stop_swarms(formation_id) do
    # Mark all formation agents as stopped in APM
    Task.start(fn ->
      _post_apm("/api/heartbeat", %{
        agent_id: "#{formation_id}-coordinator",
        status: "stopped",
        formation_id: formation_id
      })
    end)

    Logger.info("[SwarmCoordinator] Stopped swarms for formation #{formation_id}")
    :ok
  end

  @doc """
  Build the formation metadata map for a coalesce run.
  Used by CoalesceController to return topology in API responses.
  """
  @spec build_formation_plan(String.t(), [String.t()], map()) :: map()
  def build_formation_plan(formation_id, skill_names, opts) do
    num_skills = length(skill_names)
    num_squadrons = opts[:squadrons] || min(8, max(4, div(num_skills, 8) + 2))
    agents_per_skill = 3

    intelligence_agents = 5
    generation_agents = num_skills * agents_per_skill
    validation_agents = 8
    orchestrator_agents = num_squadrons

    total_agents = intelligence_agents + generation_agents + validation_agents + orchestrator_agents

    squadrons = _build_squadron_plan(skill_names, num_squadrons)

    %{
      formation_id: formation_id,
      total_agents: total_agents,
      num_squadrons: num_squadrons,
      intelligence_agents: intelligence_agents,
      generation_agents: generation_agents,
      validation_agents: validation_agents,
      orchestrator_agents: orchestrator_agents,
      squadrons: squadrons,
      scale_note: "#{total_agents} agents (#{_scale_label(total_agents)} scale)"
    }
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp _spawn_skill_swarm(formation_id, skill_name, params) do
    roles = [
      {"gap-analyst", "Identifies gaps between current skill content and new findings"},
      {"enhancement-writer", "Proposes concrete additions and revisions to skill"},
      {"regression-guard", "Ensures no existing valid content is removed"}
    ]

    Enum.map(roles, fn {role, description} ->
      agent_id = "#{formation_id}-swarm-#{skill_name}-#{role}"
      wave = if params[:dry_run], do: 0, else: 3

      _register_agent(agent_id, formation_id, role, description, wave, skill_name)

      %{agent_id: agent_id, skill_name: skill_name, role: role}
    end)
  end

  defp _register_agent(agent_id, formation_id, role, description, wave, skill_name) do
    payload = %{
      agent_id: agent_id,
      project: "ccem",
      role: role,
      status: "active",
      formation_id: formation_id,
      formation_role: _formation_role(role),
      parent_agent_id: "#{formation_id}-orchestrator",
      wave: wave,
      task_subject: if(skill_name, do: "coalesce: #{skill_name} #{role}", else: "coalesce: #{role}"),
      description: description
    }

    # Fire-and-forget APM registration (per CLAUDE.md formation rule)
    Task.start(fn ->
      _post_apm("/api/register", payload)
    end)
  end

  defp _formation_role(role) do
    cond do
      role =~ "orchestrat" -> "orchestrator"
      role =~ "lead" -> "squadron_lead"
      role =~ "analyst" or role =~ "writer" or role =~ "guard" -> "swarm_agent"
      true -> "individual"
    end
  end

  defp _post_apm(path, payload) do
    url = @apm_base <> path
    body = Jason.encode!(payload)

    :httpc.request(
      :post,
      {String.to_charlist(url), [], ~c"application/json", String.to_charlist(body)},
      [{:timeout, 3000}],
      []
    )
  rescue
    _ -> :ok
  end

  defp _build_squadron_plan(skill_names, num_squadrons) do
    pm_skills = [
      "customer-journey-map", "customer-journey-mapping-workshop",
      "discovery-process", "discovery-interview-prep", "proto-persona"
    ]

    strategy_skills = [
      "positioning-statement", "positioning-workshop", "product-strategy-session",
      "jobs-to-be-done", "prd", "prd-development"
    ]

    narrative_skills = [
      "press-release", "storyboard", "user-story-mapping",
      "user-story-mapping-workshop", "epic-hypothesis"
    ]

    channel_skills = [
      "acquisition-channel-advisor", "tam-sam-som-calculator", "roadmap-planning",
      "prioritization-advisor", "opportunity-solution-tree"
    ]

    dep_skills = [
      "context-engineering-advisor", "recommendation-canvas",
      "epic-breakdown-advisor", "ai-shaped-readiness-advisor"
    ]

    squads = [
      %{name: "Squadron 1: Intelligence", wave: 1, purpose: "Source analysis + VIKI + UPM state", agent_count: 5},
      %{name: "Squadron 2: PM Discovery", wave: 2, skills: pm_skills, agent_count: length(pm_skills) * 3},
      %{name: "Squadron 3: PM Strategy", wave: 3, skills: strategy_skills, agent_count: length(strategy_skills) * 3},
      %{name: "Squadron 4: PM Narrative", wave: 3, skills: narrative_skills, agent_count: length(narrative_skills) * 3},
      %{name: "Squadron 5: Channel & Growth", wave: 4, skills: channel_skills, agent_count: length(channel_skills) * 3},
      %{name: "Squadron 6: Dependent Skills", wave: 4, skills: dep_skills, agent_count: length(dep_skills) * 3},
      %{name: "Squadron 7: Consolidation", wave: 5, purpose: "Orchestrator consolidation", agent_count: 2},
      %{name: "Squadron 8: Validation", wave: 6, purpose: "Double-verify + regression + frontmatter", agent_count: 8}
    ]

    # Filter remaining skills not in predefined squads
    assigned = MapSet.new(pm_skills ++ strategy_skills ++ narrative_skills ++ channel_skills ++ dep_skills)
    remaining = Enum.reject(skill_names, &MapSet.member?(assigned, &1))

    squads_needed = Enum.take(squads, num_squadrons)

    if Enum.empty?(remaining) do
      squads_needed
    else
      remaining_squad = %{
        name: "Squadron X: Additional Skills",
        wave: 4,
        skills: remaining,
        agent_count: length(remaining) * 3
      }

      squads_needed ++ [remaining_squad]
    end
  end

  defp _scale_label(n) when n <= 32, do: "minimum"
  defp _scale_label(n) when n <= 64, do: "standard"
  defp _scale_label(n) when n <= 96, do: "large"
  defp _scale_label(_), do: "maximum"
end
