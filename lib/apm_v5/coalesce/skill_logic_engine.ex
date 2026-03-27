defmodule ApmV5.Coalesce.SkillLogicEngine do
  @moduledoc """
  Stateless engine that drives skill analysis and diff generation.

  Responsibilities:
  1. analyze_sources/1 — parse fetched source content into structured findings
  2. resolve_affected_skills/3 — map scope selector + findings → skill names
  3. generate_diff/3 — produce a proposed skill diff from findings
  4. validate_diff/1 — frontmatter + content integrity check

  This module is intentionally stateless — it is called by CoalesceOrchestrator
  and SwarmCoordinator, not via GenServer messages.
  """

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Parse one or more source payloads into a structured findings map.

  Sources are pre-fetched content strings (not URLs). The orchestrator
  calls SourceFetcher.fetch/1 before invoking this function.
  """
  @spec analyze_sources([map()]) :: map()
  def analyze_sources(sources) when is_list(sources) do
    combined = Enum.map_join(sources, "\n\n", & &1[:content] || "")

    frameworks = _extract_frameworks(combined)
    insights = _extract_insights(combined)
    domain_signals = _extract_domain_signals(combined)
    confidence = _score_source_confidence(sources)

    %{
      frameworks: frameworks,
      insights: insights,
      domain_signals: domain_signals,
      confidence: confidence,
      raw_content: combined,
      source_count: length(sources)
    }
  end

  def analyze_sources(_), do: %{frameworks: [], insights: [], confidence: 0.0}

  @doc """
  Resolve which skills are affected given a scope selector string and findings.

  Scope examples:
  - "all skills"
  - "product management"
  - "all product management skills and dep skills"
  - "customer-journey-map positioning-statement"
  - "engineering"
  """
  @spec resolve_affected_skills(String.t(), String.t(), map()) :: [String.t()]
  def resolve_affected_skills(skills_path, scope, findings) do
    all_skills = _list_skill_names(skills_path)
    domain_signals = findings[:domain_signals] || []

    cond do
      scope =~ ~r/all skills/i ->
        _filter_by_domain(all_skills, domain_signals, skills_path, :all)

      scope =~ ~r/product management|pm skills/i ->
        pm_skills = _pm_skill_names()
        dep_skills = if scope =~ ~r/dep skills/, do: _dep_skill_names(pm_skills, skills_path), else: []
        Enum.uniq(pm_skills ++ dep_skills)

      scope =~ ~r/engineering/i ->
        _engineering_skill_names()

      scope =~ ~r/operations/i ->
        _ops_skill_names()

      true ->
        # Treat scope as space-separated skill names
        scope
        |> String.split(~r/\s+/)
        |> Enum.filter(&Enum.member?(all_skills, &1))
    end
  end

  @doc """
  Generate a proposed diff for a single skill against source findings.
  Returns nil if the skill is not found or no changes warranted.
  """
  @spec generate_diff(String.t(), String.t(), map()) :: map() | nil
  def generate_diff(skill_name, skills_path, intel_results) do
    skill_path = Path.join(skills_path, "#{skill_name}/SKILL.md")

    case File.read(skill_path) do
      {:ok, current_content} ->
        additions = _compute_additions(skill_name, current_content, intel_results)
        confidence = _score_diff_confidence(skill_name, additions, intel_results)
        impact = _classify_impact(additions)

        %{
          skill_name: skill_name,
          current_content: current_content,
          new_content: _apply_additions(current_content, additions),
          additions: additions,
          confidence: confidence,
          impact: impact,
          approved: false,
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      {:error, :enoent} ->
        Logger.warning("[SkillLogicEngine] Skill file not found: #{skill_path}")
        nil

      {:error, reason} ->
        Logger.error("[SkillLogicEngine] Error reading #{skill_path}: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Validate a proposed diff for frontmatter integrity and content quality.
  Returns a validation result map with :passes, :confidence, :issues.
  """
  @spec validate_diff(map()) :: map()
  def validate_diff(diff) do
    issues = []

    issues = if String.starts_with?(diff.new_content, "---"), do: issues, else: ["missing YAML frontmatter" | issues]
    issues = if String.contains?(diff.new_content, "name:"), do: issues, else: ["missing name field" | issues]
    issues = if String.contains?(diff.new_content, "description:"), do: issues, else: ["missing description field" | issues]
    issues = if String.length(diff.new_content) > String.length(diff.current_content), do: issues, else: ["no content added" | issues]
    issues = if diff.confidence >= 0.40, do: issues, else: ["low confidence #{diff.confidence}" | issues]

    passes = Enum.empty?(issues)
    confidence = if passes, do: diff.confidence, else: max(0.0, diff.confidence - 0.20)

    %{
      skill_name: diff.skill_name,
      passes: passes,
      confidence: confidence,
      issues: issues
    }
  end

  # ── Private: Source Analysis ───────────────────────────────────────────────

  defp _extract_frameworks(content) do
    # Known framework patterns to detect in source text
    known = [
      "Customer Decision Journey", "CDJ", "Three-Goal Marketing Model",
      "Jobs-to-be-Done", "JTBD", "C4 Model", "Double Diamond",
      "Lean UX", "OKR", "RICE", "WSJF", "Kano", "MoSCoW",
      "PESTEL", "Porter's Five Forces", "Value Proposition Canvas",
      "Opportunity Solution Tree", "OST", "Story Mapping",
      "Geoffrey Moore", "Crossing the Chasm", "Demand Creation",
      "Demand Capture", "Demand Conversion", "Answer Audit",
      "Behavioral Pillars", "Stream Search Shop Convert"
    ]

    content_lower = String.downcase(content)

    Enum.filter(known, fn f ->
      String.contains?(content_lower, String.downcase(f))
    end)
  end

  defp _extract_insights(content) do
    # Extract key sentences containing strategic signals
    content
    |> String.split(~r/\n/)
    |> Enum.filter(fn line ->
      line =~ ~r/\b(shift|replace|replace|evolve|new|key|critical|important|transform)\b/i
      and String.length(line) > 40
    end)
    |> Enum.take(20)
  end

  defp _extract_domain_signals(content) do
    signals = []
    content_lower = String.downcase(content)

    signals = if String.contains?(content_lower, "product manag"), do: [:product_management | signals], else: signals
    signals = if String.contains?(content_lower, "customer journey"), do: [:customer_journey | signals], else: signals
    signals = if String.contains?(content_lower, "ai"), do: [:artificial_intelligence | signals], else: signals
    signals = if String.contains?(content_lower, "search"), do: [:search | signals], else: signals
    signals = if String.contains?(content_lower, "market"), do: [:market | signals], else: signals
    signals = if String.contains?(content_lower, "position"), do: [:positioning | signals], else: signals
    signals = if String.contains?(content_lower, "discovery"), do: [:discovery | signals], else: signals
    signals = if String.contains?(content_lower, "engineer"), do: [:engineering | signals], else: signals

    signals
  end

  defp _score_source_confidence(sources) do
    cond do
      Enum.empty?(sources) -> 0.0
      Enum.any?(sources, & &1[:domain] in ["google.com", "hbr.org", "mckinsey.com", "gartner.com"]) -> 0.95
      Enum.any?(sources, & String.contains?(to_string(&1[:url] || ""), "think.google")) -> 0.92
      length(sources) >= 3 -> 0.80
      length(sources) == 2 -> 0.75
      true -> 0.70
    end
  end

  # ── Private: Skill Resolution ──────────────────────────────────────────────

  defp _list_skill_names(skills_path) do
    case File.ls(skills_path) do
      {:ok, entries} ->
        Enum.filter(entries, fn e ->
          File.dir?(Path.join(skills_path, e)) and
            File.exists?(Path.join([skills_path, e, "SKILL.md"]))
        end)

      {:error, _} ->
        []
    end
  end

  defp _filter_by_domain(all_skills, domain_signals, _skills_path, :all) do
    if :product_management in domain_signals do
      # Prioritize PM skills when source is PM-domain
      pm = MapSet.new(_pm_skill_names())
      pm_first = Enum.filter(all_skills, &MapSet.member?(pm, &1))
      others = Enum.reject(all_skills, &MapSet.member?(pm, &1))
      pm_first ++ others
    else
      all_skills
    end
  end

  defp _pm_skill_names do
    [
      "customer-journey-map", "customer-journey-mapping-workshop",
      "discovery-process", "discovery-interview-prep",
      "jobs-to-be-done", "positioning-statement", "positioning-workshop",
      "proto-persona", "prd", "prd-development", "product-strategy-session",
      "press-release", "storyboard", "user-story", "user-story-mapping",
      "user-story-mapping-workshop", "user-story-splitting",
      "epic-hypothesis", "epic-breakdown-advisor",
      "roadmap-planning", "prioritization-advisor",
      "acquisition-channel-advisor", "tam-sam-som-calculator",
      "business-health-diagnostic", "company-research",
      "opportunity-solution-tree", "lean-ux-canvas",
      "problem-statement", "problem-framing-canvas",
      "recommendation-canvas", "eol-message", "workshop-facilitation"
    ]
  end

  defp _dep_skill_names(base_skills, skills_path) do
    # Dep skills: mentioned or cross-referenced in base skill files
    dep_candidates = [
      "context-engineering-advisor", "ai-shaped-readiness-advisor",
      "pestel-analysis", "pol-probe", "pol-probe-advisor",
      "saas-revenue-growth-metrics", "finance-metrics-quickref",
      "feature-investment-advisor", "double-verify"
    ]

    base_set = MapSet.new(base_skills)

    Enum.filter(dep_candidates, fn dep ->
      not MapSet.member?(base_set, dep) and
        File.exists?(Path.join(skills_path, "#{dep}/SKILL.md"))
    end)
  end

  defp _engineering_skill_names do
    [
      "claude-api", "ag-ui", "formation", "orchestrator", "ralph",
      "ship", "upm", "feature-dev", "swiftui-expert", "elixir-architect",
      "frontend-design", "prototype", "refactor-max", "simplify",
      "drtw", "double-verify", "tdd-spawn"
    ]
  end

  defp _ops_skill_names do
    [
      "ccem", "ccem-apm", "apm", "azure", "lfg", "docksock",
      "safesecret", "screenshot", "live-integration-testing",
      "gandi", "porkbun", "setup"
    ]
  end

  # ── Private: Diff Generation ───────────────────────────────────────────────

  defp _compute_additions(skill_name, _current_content, intel_results) do
    frameworks = intel_results[:frameworks] || []
    insights = intel_results[:insights] || []

    # Determine which frameworks are relevant to this skill
    relevant_frameworks = _frameworks_for_skill(skill_name, frameworks)

    # Build additions list
    additions = []

    additions = if length(relevant_frameworks) > 0 do
      [%{
        section: "AI-Native & CDJ Alignment",
        type: :new_section,
        content: _build_cdj_section(skill_name, relevant_frameworks, insights)
      } | additions]
    else
      additions
    end

    additions = if skill_name in ["customer-journey-map", "customer-journey-mapping-workshop"] do
      [%{
        section: "CDJ Behavioral Pillars",
        type: :enhancement,
        content: _build_cdj_pillars_addition()
      } | additions]
    else
      additions
    end

    additions = if skill_name in ["positioning-statement", "positioning-workshop"] do
      [%{
        section: "Solution Precision Positioning",
        type: :enhancement,
        content: _build_solution_precision_addition()
      } | additions]
    else
      additions
    end

    additions = if skill_name in ["jobs-to-be-done"] do
      [%{
        section: "AI-Native Context Queries",
        type: :enhancement,
        content: _build_jtbd_ai_addition()
      } | additions]
    else
      additions
    end

    additions = if skill_name in ["discovery-process", "discovery-interview-prep"] do
      [%{
        section: "Answer Audit Methodology",
        type: :new_section,
        content: _build_answer_audit_addition()
      } | additions]
    else
      additions
    end

    additions
  end

  defp _frameworks_for_skill(skill_name, frameworks) do
    skill_framework_map = %{
      "customer-journey-map" => ["Customer Decision Journey", "CDJ", "Behavioral Pillars"],
      "customer-journey-mapping-workshop" => ["Customer Decision Journey", "CDJ"],
      "discovery-process" => ["Answer Audit", "CDJ"],
      "discovery-interview-prep" => ["Answer Audit"],
      "jobs-to-be-done" => ["Jobs-to-be-Done", "JTBD", "Three-Goal Marketing Model"],
      "positioning-statement" => ["Demand Creation", "Demand Capture"],
      "acquisition-channel-advisor" => ["Behavioral Pillars", "Stream Search Shop Convert"],
      "proto-persona" => ["Behavioral Pillars", "CDJ"],
      "prd" => ["Demand Creation", "Three-Goal Marketing Model"],
      "product-strategy-session" => ["Three-Goal Marketing Model", "CDJ"]
    }

    relevant = Map.get(skill_framework_map, skill_name, [])
    Enum.filter(frameworks, &Enum.member?(relevant, &1))
  end

  defp _build_cdj_section(skill_name, relevant_frameworks, _insights) do
    """

    ### AI-Native & CDJ Alignment

    > Updated 2026-03-27 via `/coalesce` from Google Think — Customer Decision Journey and AI Search

    This skill has been refined to reflect the **Customer Decision Journey (CDJ)** framework
    as consumers increasingly use AI-native search (long, descriptive, contextual queries)
    rather than keyword-based search. Key implications for #{skill_name}:

    **Frameworks incorporated**: #{Enum.join(relevant_frameworks, ", ")}

    **AI-search behavior shifts:**
    - Consumers describe entire situations, constraints, and preferences in queries
    - Brands evaluated as **solutions to specific situations**, not category products
    - Journey is **compressed** — higher-consideration purchases happen faster
    - **Answer Audit** discipline: map what consumers encounter across all discovery touchpoints

    **Three-Goal Model** (replaces funnel framing):
    1. **Create demand** — Make problems and solutions vivid across discovery ecosystem
    2. **Capture demand** — Win moments when consumers describe their full context
    3. **Convert demand** — Remove friction at confidence peaks (not just checkout)
    """
  end

  defp _build_cdj_pillars_addition do
    """

    ### CDJ Behavioral Pillars (AI-Native Update)

    The traditional Awareness→Consideration→Decision→Service→Loyalty funnel
    has been **superseded by the CDJ behavioral model**. Map customer journeys
    across these four concurrent (not sequential) pillars:

    | Pillar | Role | Discovery Tools |
    |--------|------|-----------------|
    | **Streaming / Scrolling** | Possibility creation, passive discovery | Social feeds, video platforms |
    | **Searching** | Active intent structuring | AI assistants, search engines, video search |
    | **Shopping** | Comparison and decision support | Retail/marketplace, review sites |
    | **Converting** | Happens wherever confidence peaks | Not just checkout — can be any touchpoint |

    **Mapping instruction**: For each persona, document which pillar dominates each
    job-stage, what platform they use, and what information gap would accelerate
    journey compression (faster decision at same or higher confidence).
    """
  end

  defp _build_solution_precision_addition do
    """

    ### Solution Precision Positioning (AI-Native Update)

    Traditional category-based positioning ("we are the best CRM") is insufficient
    in AI-native search contexts. Algorithms and consumers both evaluate brands as
    **solutions to specific situations**. Refine the Moore framework with:

    **Old:** "For [segment] that need [underserved category need]..."
    **New:** "For [persona] **in the situation of** [specific context + constraints]..."

    **Signal-based brand audit**: Your brand = the sum of signals recognizable as
    the right solution. Audit signals across:
    - Product quality evidence (reviews, benchmarks)
    - Creator and customer advocacy (UGC, influencer endorsements)
    - Community reputation (forums, social mentions)
    - Content clarity (is your solution findable in AI-native queries?)

    **Positioning precision test**: Can your positioning statement answer a
    long, descriptive AI query? If not, it's too generic for 2026 discovery.
    """
  end

  defp _build_jtbd_ai_addition do
    """

    ### AI-Native Context Queries (JTBD Update)

    Customers in AI-native contexts describe jobs very differently than keyword searches.
    When conducting JTBD interviews and analysis, capture **situation-rich query patterns**:

    **Old job statement format:** "Send an invoice to my client"
    **AI-native format:** "Best way to send an invoice to a freelance client in France who needs
     VAT details and pays via Stripe, on a tight deadline"

    **Implication for JTBD discovery:**
    - Probe for **full situation context**, not just the core job
    - Ask: "How would you describe your problem to an AI assistant?"
    - Map jobs at the **ecosystem level** — what complementary solutions surround the core job?
    - Identify jobs that have been **compressed** (decisions made faster with AI assistance)

    **Competitive substitution in AI-native contexts:**
    AI assistants synthesize across categories — your competition is now any solution
    that answers the customer's full situation, not just your product category.
    """
  end

  defp _build_answer_audit_addition do
    """

    ### Answer Audit Methodology

    > From David Edelman, Google Think / HBS — March 2026

    The **Answer Audit** is a recurring discovery discipline that maps what information
    consumers encounter when researching problems relevant to your product area.

    **Process:**
    1. Identify your 10 most common customer decision scenarios
    2. For each scenario, examine what consumers encounter across:
       - Social discovery (TikTok, Instagram, LinkedIn)
       - Video search (YouTube, Shorts)
       - AI assistants (ChatGPT, Gemini, Claude)
       - Retail/marketplace listings (Amazon, G Shopping)
       - Forums (Reddit, Quora, niche communities)
    3. Map: consistency of messaging, completeness of information, presence/absence
    4. Score: gaps, inconsistencies, competitor advantage points
    5. Prioritize: fill highest-traffic information voids first

    **Integrate into discovery cadence**: Run Answer Audits quarterly alongside
    customer interviews. They reveal **passive** discovery gaps (what customers
    encounter before they contact you) that interviews alone cannot surface.
    """
  end

  defp _apply_additions(current_content, []), do: current_content

  defp _apply_additions(current_content, additions) do
    # Append additions as new sections at the end of the skill file
    extra = additions
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n---\n\n")

    separator = "\n\n---\n\n## Coalesce Refinements\n\n"
    current_content <> separator <> extra
  end

  defp _score_diff_confidence(skill_name, additions, _intel_results) do
    base = 0.70

    # Higher confidence for skills with direct framework alignment
    high_alignment = [
      "customer-journey-map", "customer-journey-mapping-workshop",
      "jobs-to-be-done", "positioning-statement", "discovery-process"
    ]

    base = if skill_name in high_alignment, do: base + 0.15, else: base
    base = if length(additions) > 0, do: base + 0.05, else: base - 0.10
    base = if length(additions) > 2, do: base + 0.05, else: base

    min(0.98, max(0.0, base))
  end

  defp _classify_impact(additions) do
    cond do
      length(additions) >= 3 -> :high
      length(additions) >= 1 -> :medium
      true -> :low
    end
  end
end
