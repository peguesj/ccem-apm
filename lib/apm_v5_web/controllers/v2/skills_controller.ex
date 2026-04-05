defmodule ApmV5Web.V2.SkillsController do
  use ApmV5Web, :controller

  @doc "GET /api/v2/skills/graph — Complete dependency graph"
  def graph(conn, _params) do
    graph = ApmV5.Skills.SkillAnalyzer.get_graph()

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
  def dependencies(conn, %{"id" => skill_id}) do
    graph = ApmV5.Skills.SkillAnalyzer.get_graph()
    skill = ApmV5.Skills.SkillAnalyzer.get_skill(skill_id)

    if skill do
      analysis = ApmV5.Skills.DependencyGraph.impact_analysis(graph, skill_id)

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
  def cycles(conn, _params) do
    graph = ApmV5.Skills.SkillAnalyzer.get_graph()
    cycles = ApmV5.Skills.DependencyGraph.detect_cycles(graph)

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
  def stats(conn, _params) do
    graph = ApmV5.Skills.SkillAnalyzer.get_graph()
    stats = ApmV5.Skills.DependencyGraph.stats(graph)

    json(conn, %{
      status: "ok",
      data: stats
    })
  end

  @doc "GET /api/v2/skills/health — All skill health scores"
  def health(conn, _params) do
    scores = ApmV5.Skills.SkillHealthScorer.all_scores()
    summary = ApmV5.Skills.SkillHealthScorer.summary()

    json(conn, %{
      status: "ok",
      data: scores,
      summary: summary
    })
  end

  @doc "GET /api/v2/skills/health/:id — Single skill health score"
  def health_single(conn, %{"id" => skill_id}) do
    score = ApmV5.Skills.SkillHealthScorer.score_skill(skill_id)

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
  def rescore(conn, _params) do
    ApmV5.Skills.SkillHealthScorer.rescore()

    json(conn, %{
      status: "ok",
      message: "Health scoring initiated"
    })
  end

  @doc "POST /api/v2/skills/analyze — Full skill analysis"
  def analyze(conn, _params) do
    case ApmV5.Skills.SkillAnalyzer.analyze() do
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
