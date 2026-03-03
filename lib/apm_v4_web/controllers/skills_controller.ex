defmodule ApmV4Web.SkillsController do
  @moduledoc """
  REST API for the Skills Registry.

  Endpoints:
    GET  /api/skills/registry       — list all skills with health scores
    GET  /api/skills/:name          — single skill detail
    GET  /api/skills/:name/health   — health score breakdown
    POST /api/skills/audit          — trigger full rescan
  """
  use ApmV4Web, :controller

  alias ApmV4.SkillsRegistryStore

  @doc "GET /api/skills/registry"
  def registry(conn, _params) do
    skills = SkillsRegistryStore.list_skills()
    total = length(skills)
    healthy = Enum.count(skills, &(&1.health_score >= 80))
    needs_attention = Enum.count(skills, &(&1.health_score in 50..79))
    critical = Enum.count(skills, &(&1.health_score < 50))

    json(conn, %{
      skills: skills,
      total: total,
      healthy: healthy,
      needs_attention: needs_attention,
      critical: critical
    })
  end

  @doc "GET /api/skills/:name"
  def show(conn, %{"name" => name}) do
    case SkillsRegistryStore.get_skill(name) do
      {:ok, skill} ->
        json(conn, %{skill: skill})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "skill not found: #{name}"})
    end
  end

  @doc "GET /api/skills/:name/health"
  def health(conn, %{"name" => name}) do
    case SkillsRegistryStore.get_skill(name) do
      {:ok, skill} ->
        breakdown = %{
          frontmatter: if(skill.has_frontmatter, do: 30, else: 0),
          description:
            case skill.description_quality do
              "good" -> 25
              "truncated" -> 10
              _ -> 0
            end,
          triggers: min(Map.get(skill, :trigger_count, 0) * 7, 20),
          examples: if(skill.has_examples, do: 15, else: 0),
          template: if(skill.has_template, do: 10, else: 0)
        }

        json(conn, %{
          name: skill.name,
          score: skill.health_score,
          breakdown: breakdown,
          description_quality: skill.description_quality
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "skill not found: #{name}"})
    end
  end

  @doc "POST /api/skills/audit"
  def audit(conn, _params) do
    SkillsRegistryStore.refresh_all()
    json(conn, %{status: "scanning"})
  end
end
