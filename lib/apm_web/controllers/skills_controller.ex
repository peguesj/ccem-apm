defmodule ApmWeb.SkillsController do
  @moduledoc """
  REST API for the Skills Registry.

  Endpoints:
    GET  /api/skills/registry       — list all skills with health scores
    GET  /api/skills/:name          — single skill detail
    GET  /api/skills/:name/health   — health score breakdown
    POST /api/skills/audit          — trigger full rescan

  Broadcasts PubSub events on mutations to `"apm:skills"` topic.
  """
  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema
  alias Apm.SkillsRegistryStore

  operation :registry,
    summary: "List skill registry",
    description: "Returns all skills with health scores and aggregate counts.",
    tags: ["Skills"],
    responses: [
      ok: {"Skills registry", "application/json", Schemas.OkResponse}
    ]

  operation :show,
    summary: "Get skill by name",
    description: "Returns detail for a single skill by name.",
    tags: ["Skills"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Skill name"]
    ],
    responses: [
      ok: {"Skill detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  operation :health,
    summary: "Skill health score",
    description: "Returns a breakdown of the health score for a skill.",
    tags: ["Skills"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Skill name"]
    ],
    responses: [
      ok: {"Health breakdown", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  operation :audit,
    summary: "Trigger skills audit",
    description: "Triggers a full rescan of all skills and broadcasts an audit event.",
    tags: ["Skills"],
    responses: [
      ok: {"Audit started", "application/json", Schemas.OkResponse}
    ]

  operation :list_repositories,
    summary: "List skill repositories",
    description: "Returns all registered remote skill repositories (mcpmarket/skillfish).",
    tags: ["Skills"],
    responses: [
      ok: {"Repository list", "application/json", Schemas.OkResponse}
    ]

  operation :add_repository,
    summary: "Add skill repository",
    description: "Registers a new remote skill repository.",
    tags: ["Skills"],
    request_body: {"Repository payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Repository added", "application/json", Schemas.OkResponse}
    ]

  operation :remove_repository,
    summary: "Remove skill repository",
    description: "Removes a registered remote skill repository by ID.",
    tags: ["Skills"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Repository ID"]
    ],
    responses: [
      ok: {"Repository removed", "application/json", Schemas.OkResponse}
    ]

  operation :sync_repository,
    summary: "Sync skill repository",
    description: "Triggers a sync of a remote skill repository.",
    tags: ["Skills"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Repository ID"]
    ],
    responses: [
      ok: {"Sync result", "application/json", Schemas.OkResponse}
    ]

  operation :list_permissive,
    summary: "List permissive skills",
    description: "Returns the permissive skill list (bypasses AgentLock for named skills).",
    tags: ["Skills"],
    responses: [
      ok: {"Permissive skill list", "application/json", Schemas.OkResponse}
    ]

  operation :add_permissive,
    summary: "Add permissive skill",
    description: "Adds a skill to the permissive list.",
    tags: ["Skills"],
    request_body: {"Skill name payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Skill added to permissive list", "application/json", Schemas.OkResponse}
    ]

  operation :remove_permissive,
    summary: "Remove permissive skill",
    description: "Removes a skill from the permissive list by name.",
    tags: ["Skills"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Skill name"]
    ],
    responses: [
      ok: {"Skill removed from permissive list", "application/json", Schemas.OkResponse}
    ]

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  @pubsub Apm.PubSub
  @topic "apm:skills"

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

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skills_audit_started, %{
      triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }})

    json(conn, %{status: "scanning"})
  end
end
