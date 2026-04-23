defmodule ApmV5.Skills.SkillHealthScorer do
  @moduledoc """
  GenServer for scoring skill health across 5 dimensions.

  Health dimensions:
  1. Frontmatter Completeness (0-100) — presence of required metadata fields
  2. Trigger Coverage (0-100) — number of active, distinct triggers
  3. Type Alignment (0-100) — whether type is properly categorized
  4. Dependency Health (0-100) — health of upstream dependencies
  5. Recency (0-100) — file modification freshness (100 if <30 days old)

  Overall Health: 50% frontmatter + 20% triggers + 10% type + 10% deps + 10% recency

  Scored skills cached with 10-minute TTL.
  """

  use GenServer
  require Logger

  @table :skill_health_cache
  @health_refresh_interval 10 * 60 * 1000  # 10 minutes

  @required_frontmatter_fields [:name, :description, :type, :triggers]
  @valid_types ~w(general utility transformation analysis quality deployment integration utility_pattern behavioral_pattern)

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Score a single skill's health."
  @spec score_skill(String.t()) :: map() | nil
  def score_skill(skill_id) do
    case :ets.lookup(@table, {:score, skill_id}) do
      [{{:score, ^skill_id}, score}] -> score
      [] -> nil
    end
  end

  @doc "Get all skill scores."
  @spec all_scores() :: [map()]
  def all_scores do
    case :ets.lookup(@table, :all_scores) do
      [{:all_scores, scores}] -> scores
      [] -> []
    end
  end

  @doc "Get health summary statistics."
  @spec summary() :: map()
  def summary do
    case :ets.lookup(@table, :summary) do
      [{:summary, stats}] -> stats
      [] -> %{}
    end
  end

  @doc "Manually trigger health scoring."
  @spec rescore() :: :ok
  def rescore do
    GenServer.call(__MODULE__, :rescore)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Defer initial scoring so init returns immediately (APM-001 fix)
    send(self(), :initial_score)

    {:ok, %{last_refresh: nil}}
  end

  @impl true
  def handle_call(:rescore, _from, state) do
    _ = perform_scoring()
    {:reply, :ok, %{state | last_refresh: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info(:initial_score, state) do
    _ = perform_scoring()
    Process.send_after(self(), :refresh, @health_refresh_interval)
    {:noreply, %{state | last_refresh: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info(:refresh, state) do
    _ = perform_scoring()
    Logger.debug("[SkillHealthScorer] Health scoring refresh complete")
    Process.send_after(self(), :refresh, @health_refresh_interval)
    {:noreply, %{state | last_refresh: System.monotonic_time(:second)}}
  end

  # ── Private Helpers ────────────────────────────────────────────────────────

  @spec perform_scoring() :: :ok
  defp perform_scoring do
    graph = ApmV5.Skills.SkillAnalyzer.get_graph()
    all_skills = graph |> Map.keys() |> Enum.map(&ApmV5.Skills.SkillAnalyzer.get_skill/1) |> Enum.filter(& &1)

    scores =
      all_skills
      |> Enum.map(&score_skill_internal(graph, &1))
      |> Enum.sort_by(fn s -> s.overall_health end, :desc)

    # Cache individual scores
    Enum.each(scores, fn score ->
      :ets.insert(@table, {{:score, score.id}, score})
    end)

    # Cache all scores
    :ets.insert(@table, {:all_scores, scores})

    # Cache summary
    summary = compute_summary(scores)
    :ets.insert(@table, {:summary, summary})

    :ok
  rescue
    e ->
      Logger.error("[SkillHealthScorer] Scoring failed: #{inspect(e)}")
      :ok
  end

  @spec score_skill_internal(map(), map()) :: map()
  defp score_skill_internal(graph, skill) do
    frontmatter_score = score_frontmatter_completeness(skill)
    trigger_score = score_trigger_coverage(skill)
    type_score = score_type_alignment(skill)
    dependency_score = score_dependency_health(graph, skill)
    recency_score = score_recency(skill)

    overall =
      Float.round(
        frontmatter_score * 0.5 + trigger_score * 0.2 + type_score * 0.1 +
          dependency_score * 0.1 + recency_score * 0.1,
        1
      )

    health_level =
      cond do
        overall >= 80 -> :excellent
        overall >= 60 -> :good
        overall >= 40 -> :fair
        true -> :poor
      end

    %{
      id: skill.id,
      name: skill.name,
      overall_health: overall,
      health_level: health_level,
      dimensions: %{
        frontmatter: Float.round(frontmatter_score, 1),
        triggers: Float.round(trigger_score, 1),
        type: Float.round(type_score, 1),
        dependencies: Float.round(dependency_score, 1),
        recency: Float.round(recency_score, 1)
      },
      issues: identify_issues(skill, graph)
    }
  end

  @spec score_frontmatter_completeness(map()) :: float()
  defp score_frontmatter_completeness(skill) do
    present = @required_frontmatter_fields |> Enum.count(&(&1 in Map.keys(skill)))
    total = length(@required_frontmatter_fields)
    (present / total) * 100
  end

  @spec score_trigger_coverage(map()) :: float()
  defp score_trigger_coverage(skill) do
    triggers = Map.get(skill, :triggers, [])
    trigger_count = length(triggers)

    case trigger_count do
      0 -> 0.0
      1 -> 33.0
      2 -> 66.0
      3 -> 80.0
      4 -> 90.0
      n when n >= 5 -> 100.0
    end
  end

  @spec score_type_alignment(map()) :: float()
  defp score_type_alignment(skill) do
    type = Map.get(skill, :type, "")

    if type in @valid_types do
      100.0
    else
      25.0
    end
  end

  @spec score_dependency_health(map(), map()) :: float()
  defp score_dependency_health(_graph, skill) do
    # Dependencies are assumed healthy if they exist and are registered
    deps = Map.get(skill, :dependencies, [])

    if Enum.empty?(deps) do
      100.0
    else
      healthy_count =
        deps
        |> Enum.count(fn dep ->
          ApmV5.Skills.SkillAnalyzer.get_skill(dep) != nil
        end)

      (healthy_count / length(deps)) * 100
    end
  end

  @spec score_recency(map()) :: float()
  defp score_recency(skill) do
    mtime = Map.get(skill, :updated_at, System.os_time(:second))
    now = System.os_time(:second)
    days_old = (now - mtime) / 86400

    case days_old do
      d when d <= 7 -> 100.0
      d when d <= 14 -> 90.0
      d when d <= 30 -> 80.0
      d when d <= 60 -> 60.0
      d when d <= 90 -> 40.0
      _ -> 20.0
    end
  end

  @spec identify_issues(map(), map()) :: [String.t()]
  defp identify_issues(skill, graph) do
    issues = []

    issues =
      if Map.get(skill, :description, "") |> String.trim() |> String.length() < 20 do
        ["Description too brief" | issues]
      else
        issues
      end

    issues =
      if Enum.empty?(Map.get(skill, :triggers, [])) do
        ["No triggers defined" | issues]
      else
        issues
      end

    issues =
      if Map.get(skill, :type, "") not in @valid_types do
        ["Invalid or missing type" | issues]
      else
        issues
      end

    deps = Map.get(skill, :dependencies, [])

    missing_deps =
      deps
      |> Enum.filter(fn dep -> is_nil(ApmV5.Skills.SkillAnalyzer.get_skill(dep)) end)
      |> length()

    issues =
      if missing_deps > 0 do
        ["#{missing_deps} unresolved dependencies" | issues]
      else
        issues
      end

    # Check for circular dependencies
    cycles = ApmV5.Skills.DependencyGraph.detect_cycles(graph)

    has_cycle =
      Enum.any?(cycles, fn cycle ->
        Enum.member?(cycle, skill.id)
      end)

    if has_cycle do
      ["Circular dependency detected" | issues]
    else
      issues
    end
  end

  @spec compute_summary([map()]) :: map()
  defp compute_summary(scores) do
    total = length(scores)

    level_counts =
      scores
      |> Enum.group_by(fn s -> s.health_level end)
      |> Enum.map(fn {level, list} -> {level, length(list)} end)
      |> Enum.into(%{}, fn {level, count} -> {level, count} end)

    avg_health =
      if total > 0 do
        Float.round(
          (scores |> Enum.map(fn s -> s.overall_health end) |> Enum.sum()) / total,
          1
        )
      else
        0.0
      end

    %{
      total_skills: total,
      average_health: avg_health,
      health_distribution: level_counts,
      excellent: Map.get(level_counts, :excellent, 0),
      good: Map.get(level_counts, :good, 0),
      fair: Map.get(level_counts, :fair, 0),
      poor: Map.get(level_counts, :poor, 0),
      last_updated: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
