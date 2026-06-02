defmodule ApmWeb.V2.SkillsController do
  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  @doc "GET /api/v2/skills/graph — Complete dependency graph"
  operation :graph,
    summary: "Graph",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def graph(conn, _params) do
    graph = Apm.Skills.SkillAnalyzer.get_graph()

    # Convert graph to JSON-friendly format
    graph_data =
      graph
      |> Enum.map(fn {skill_id, deps} ->
        %{
          id: skill_id,
          dependencies: deps
        }
      end)

    json(conn, %{
      status: "ok",
      data: graph_data,
      meta: %{
        total_skills: map_size(graph),
        total_edges: graph |> Map.values() |> Enum.concat() |> length()
      }
    })
  end

  @doc "GET /api/v2/skills/dependencies/:id — Get skill's dependencies and dependents"
  operation :dependencies,
    summary: "Dependencies",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def dependencies(conn, %{"id" => skill_id}) do
    graph = Apm.Skills.SkillAnalyzer.get_graph()
    skill = Apm.Skills.SkillAnalyzer.get_skill(skill_id)

    if skill do
      analysis = Apm.Skills.DependencyGraph.impact_analysis(graph, skill_id)

      json(conn, %{
        status: "ok",
        data: %{
          skill_id: skill_id,
          direct_dependencies: analysis.direct_deps,
          transitive_dependencies: analysis.transitive_deps,
          direct_dependents: analysis.direct_dependents,
          transitive_dependents: analysis.transitive_dependents,
          impact_scope: analysis.impact_scope,
          skill: skill
        }
      })
    else
      json(conn, %{status: "error", error: "Skill not found"})
    end
  end

  @doc "GET /api/v2/skills/cycles — Detect circular dependencies"
  operation :cycles,
    summary: "Cycles",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def cycles(conn, _params) do
    graph = Apm.Skills.SkillAnalyzer.get_graph()
    cycles = Apm.Skills.DependencyGraph.detect_cycles(graph)

    json(conn, %{
      status: "ok",
      data: %{
        has_cycles: length(cycles) > 0,
        cycles: cycles,
        count: length(cycles)
      }
    })
  end

  @doc "GET /api/v2/skills/stats — Graph statistics"
  operation :stats,
    summary: "Statistics",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def stats(conn, _params) do
    graph = Apm.Skills.SkillAnalyzer.get_graph()
    stats = Apm.Skills.DependencyGraph.stats(graph)

    json(conn, %{
      status: "ok",
      data: stats
    })
  end

  @doc "GET /api/v2/skills/health — All skill health scores"
  operation :health,
    summary: "Health check",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def health(conn, _params) do
    scores = Apm.Skills.SkillHealthScorer.all_scores()
    summary = Apm.Skills.SkillHealthScorer.summary()

    json(conn, %{
      status: "ok",
      data: scores,
      summary: summary
    })
  end

  @doc "GET /api/v2/skills/health/:id — Single skill health score"
  operation :health_single,
    summary: "Health single",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def health_single(conn, %{"id" => skill_id}) do
    score = Apm.Skills.SkillHealthScorer.score_skill(skill_id)

    if score do
      json(conn, %{
        status: "ok",
        data: score
      })
    else
      json(conn, %{status: "error", error: "Skill health data not found"})
    end
  end

  @doc "POST /api/v2/skills/rescore — Manually trigger health rescoring"
  operation :rescore,
    summary: "Rescore",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def rescore(conn, _params) do
    Apm.Skills.SkillHealthScorer.rescore()

    json(conn, %{
      status: "ok",
      message: "Health scoring initiated"
    })
  end

  @doc "POST /api/v2/skills/analyze — Full skill analysis"
  operation :analyze,
    summary: "Analyze",
    tags: ["Skills"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def analyze(conn, _params) do
    case Apm.Skills.SkillAnalyzer.analyze() do
      {:ok, stats} ->
        json(conn, %{
          status: "ok",
          data: stats,
          message: "Skill analysis complete"
        })

      {:error, reason} ->
        json(conn, %{
          status: "error",
          error: inspect(reason)
        })
    end
  end
end
