defmodule ApmV5Web.SkillsLive do
  @moduledoc """
  LiveView for skills tracking, UEBA analytics, and Skills Registry health dashboard.

  WCAG 2.1 AA compliant — skip links, ARIA landmarks, tablist/tab/tabpanel roles,
  aria-live regions, keyboard navigation (Escape to close drawer).

  Tabs:
  - Registry: card grid with health rings, search/filter, tier collapsing, slide-in detail drawer
  - Session:  active skills, catalog, co-occurrence matrix
  - AG-UI:    skill-to-event mapping, hook repair
  """

  use ApmV5Web, :live_view

  alias ApmV5.SkillTracker
  alias ApmV5.SkillsRegistryStore
  alias ApmV5.ActionEngine
  alias ApmV5.ConfigLoader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:skills")
      ApmV5.AgUi.EventBus.subscribe("special:custom")
    end

    active_session = current_session_id()
    session_skills = if active_session, do: SkillTracker.get_session_skills(active_session), else: %{}
    catalog = SkillTracker.get_skill_catalog()
    co_occurrence = SkillTracker.get_co_occurrence()
    methodology = if active_session, do: SkillTracker.active_methodology(active_session)

    registry_skills = SkillsRegistryStore.list_skills()

    socket =
      socket
      |> assign(:page_title, "Skills")
      |> assign(:active_nav, :skills)
      |> assign(:tab, :registry)
      |> assign(:active_session, active_session)
      |> assign(:session_skills, session_skills)
      |> assign(:catalog, catalog)
      |> assign(:co_occurrence, co_occurrence)
      |> assign(:methodology, methodology)
      |> assign(:active_skill_count, map_size(session_skills))
      |> assign(:registry_skills, registry_skills)
      |> assign(:filtered_skills, registry_skills)
      |> assign(:selected_skill, nil)
      |> assign(:audit_loading, false)
      |> assign(:search_query, "")
      |> assign(:filter_tier, "all")
      |> assign(:filter_methodology, "all")
      |> assign(:collapsed_tiers, %{healthy: true, needs_attention: false, critical: false})
      |> assign(:fix_wizard_step, nil)
      |> assign(:fix_wizard_selected_repairs, MapSet.new())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Skip link (WCAG 2.1 AA §2.4.1) --%>
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-[9999] focus:px-3 focus:py-2 focus:bg-primary focus:text-primary-content focus:rounded focus:outline-none focus:ring-2 focus:ring-primary-content"
    >
      Skip to main content
    </a>

    <div
      id="skills-view"
      phx-hook="Skills"
      class="flex h-screen bg-base-300 overflow-hidden"
      phx-window-keydown="keydown"
    >
      <%!-- Sidebar --%>
      <nav aria-label="Main navigation">
        <.sidebar_nav current_path="/skills" skill_count={@active_skill_count} />
      </nav>

      <%!-- Main area --%>
      <main
        id="main-content"
        role="main"
        aria-label="Skills dashboard"
        class="flex-1 flex flex-col overflow-hidden"
      >
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="text-sm font-semibold text-base-content">Skills</h1>
            <div
              role="tablist"
              aria-label="Skills views"
              class="tabs tabs-boxed tabs-xs bg-base-300"
            >
              <button
                role="tab"
                id="tab-registry"
                aria-selected={to_string(@tab == :registry)}
                aria-controls="tabpanel-registry"
                class={["tab", @tab == :registry && "tab-active"]}
                phx-click="set_tab"
                phx-value-tab="registry"
                tabindex={if @tab == :registry, do: "0", else: "-1"}
              >
                Registry
              </button>
              <button
                role="tab"
                id="tab-session"
                aria-selected={to_string(@tab == :session)}
                aria-controls="tabpanel-session"
                class={["tab", @tab == :session && "tab-active"]}
                phx-click="set_tab"
                phx-value-tab="session"
                tabindex={if @tab == :session, do: "0", else: "-1"}
              >
                Session
              </button>
              <button
                role="tab"
                id="tab-ag_ui"
                aria-selected={to_string(@tab == :ag_ui)}
                aria-controls="tabpanel-ag_ui"
                class={["tab", @tab == :ag_ui && "tab-active"]}
                phx-click="set_tab"
                phx-value-tab="ag_ui"
                tabindex={if @tab == :ag_ui, do: "0", else: "-1"}
              >
                AG-UI
              </button>
            </div>
          </div>

          <div :if={@tab == :registry} class="flex items-center gap-2">
            <span
              :if={active_filter_count(assigns) > 0}
              aria-live="polite"
              aria-atomic="true"
              class="badge badge-xs badge-info"
            >
              {active_filter_count(assigns)} filter{if active_filter_count(assigns) > 1, do: "s", else: ""} active
            </span>
            <button
              class={["btn btn-xs btn-primary", @audit_loading && "loading"]}
              phx-click="audit_all"
              disabled={@audit_loading}
              aria-busy={to_string(@audit_loading)}
            >
              {if @audit_loading, do: "Scanning…", else: "Audit All"}
            </button>
          </div>
        </header>

        <%!-- Search / filter bar (registry tab only) --%>
        <div
          :if={@tab == :registry}
          class="bg-base-200 border-b border-base-300 px-4 py-2 flex-shrink-0"
          role="search"
          aria-label="Filter skills"
        >
          <form phx-change="update_filters" class="flex items-center gap-2 flex-wrap">
            <label for="skill-search" class="sr-only">Search skills</label>
            <input
              id="skill-search"
              type="search"
              name="search"
              value={@search_query}
              placeholder="Search skills…"
              phx-debounce="200"
              class="input input-xs input-bordered flex-1 min-w-[10rem] max-w-xs"
              aria-label="Search skills by name or description"
              autocomplete="off"
            />

            <label for="filter-tier" class="sr-only">Filter by health tier</label>
            <select
              id="filter-tier"
              name="tier"
              class="select select-xs select-bordered"
              aria-label="Filter by health tier"
            >
              <option value="all" selected={@filter_tier == "all"}>All tiers</option>
              <option value="healthy" selected={@filter_tier == "healthy"}>Healthy</option>
              <option value="needs_attention" selected={@filter_tier == "needs_attention"}>Needs Attention</option>
              <option value="critical" selected={@filter_tier == "critical"}>Critical</option>
            </select>

            <label for="filter-methodology" class="sr-only">Filter by methodology</label>
            <select
              id="filter-methodology"
              name="methodology"
              class="select select-xs select-bordered"
              aria-label="Filter by methodology"
            >
              <option value="all" selected={@filter_methodology == "all"}>All methodologies</option>
              <option value="ralph" selected={@filter_methodology == "ralph"}>Ralph</option>
              <option value="tdd" selected={@filter_methodology == "tdd"}>TDD</option>
              <option value="elixir_architect" selected={@filter_methodology == "elixir_architect"}>Elixir Architect</option>
            </select>
          </form>

          <button
            :if={active_filter_count(assigns) > 0}
            phx-click="clear_filters"
            class="btn btn-xs btn-ghost mt-1"
            aria-label="Clear all active filters"
          >
            ✕ Clear filters
          </button>
        </div>

        <%!-- Body --%>
        <div class="flex-1 overflow-y-auto p-4">
          <%!-- Registry Tab --%>
          <div
            :if={@tab == :registry}
            id="tabpanel-registry"
            role="tabpanel"
            aria-labelledby="tab-registry"
            class="space-y-4"
            tabindex="0"
          >
            <%!-- Summary stats --%>
            <div class="stats shadow bg-base-200 w-full" aria-label="Skills health summary">
              <div class="stat">
                <div class="stat-title" id="stat-total">Total Skills</div>
                <div class="stat-value text-2xl" aria-labelledby="stat-total">{length(@registry_skills)}</div>
              </div>
              <div class="stat">
                <div class="stat-title" id="stat-healthy">Healthy</div>
                <div class="stat-value text-2xl text-success" aria-labelledby="stat-healthy">
                  {Enum.count(@registry_skills, &(&1.health_score >= 80))}
                </div>
                <div class="stat-desc">score ≥ 80</div>
              </div>
              <div class="stat">
                <div class="stat-title" id="stat-attention">Needs Attention</div>
                <div class="stat-value text-2xl text-warning" aria-labelledby="stat-attention">
                  {Enum.count(@registry_skills, &(&1.health_score in 50..79))}
                </div>
                <div class="stat-desc">score 50–79</div>
              </div>
              <div class="stat">
                <div class="stat-title" id="stat-critical">Critical</div>
                <div class="stat-value text-2xl text-error" aria-labelledby="stat-critical">
                  {Enum.count(@registry_skills, &(&1.health_score < 50))}
                </div>
                <div class="stat-desc">score &lt; 50</div>
              </div>
            </div>

            <%!-- Filter results count --%>
            <div
              :if={active_filter_count(assigns) > 0}
              aria-live="polite"
              aria-atomic="true"
              class="text-xs text-base-content/50"
            >
              Showing {length(@filtered_skills)} of {length(@registry_skills)} skills
            </div>

            <%!-- Tier card sections (critical → needs attention → healthy) --%>
            <% {healthy, needs_attention, critical} = split_tiers(@filtered_skills) %>

            <.skill_tier_cards
              tier={:critical}
              skills={critical}
              collapsed={Map.get(@collapsed_tiers, :critical, false)}
              selected={@selected_skill}
            />
            <.skill_tier_cards
              tier={:needs_attention}
              skills={needs_attention}
              collapsed={Map.get(@collapsed_tiers, :needs_attention, false)}
              selected={@selected_skill}
            />
            <.skill_tier_cards
              tier={:healthy}
              skills={healthy}
              collapsed={Map.get(@collapsed_tiers, :healthy, true)}
              selected={@selected_skill}
            />

            <div :if={@registry_skills == []} class="text-center py-12 text-base-content/30">
              <p>No skills found in ~/.claude/skills/</p>
              <button class="btn btn-primary btn-sm mt-4" phx-click="audit_all">Scan Now</button>
            </div>
          </div>

          <%!-- Session Tab --%>
          <div
            :if={@tab == :session}
            id="tabpanel-session"
            role="tabpanel"
            aria-labelledby="tab-session"
            class="space-y-6"
            tabindex="0"
          >
            <%!-- Invocation Timeline --%>
            <section aria-labelledby="timeline-heading">
              <h2
                id="timeline-heading"
                class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3"
              >
                Invocation Timeline
              </h2>
              <p
                :if={@session_skills == %{}}
                class="text-sm text-base-content/30 py-4"
                aria-live="polite"
              >
                No skills invoked in current session.
              </p>
              <div
                :if={@session_skills != %{}}
                role="list"
                aria-label="Skill invocation timeline"
                class="relative pl-6 space-y-3"
              >
                <%!-- Vertical timeline line --%>
                <div class="absolute left-2 top-0 bottom-0 w-0.5 bg-base-300" aria-hidden="true"></div>
                <article
                  :for={{skill, data} <- Enum.sort_by(@session_skills, fn {_k, v} -> v.last_seen end, :desc)}
                  role="listitem"
                  class="relative"
                  aria-label={"#{skill}: #{data.count} invocations, last #{format_time(data.last_seen)}"}
                >
                  <%!-- Timeline dot --%>
                  <div
                    class={[
                      "absolute -left-4 top-2 w-3 h-3 rounded-full border-2 border-base-200",
                      if(methodology_for_skill(skill), do: "bg-primary", else: "bg-base-content/30")
                    ]}
                    aria-hidden="true"
                  ></div>
                  <div class="card bg-base-200 border border-base-300 p-3 ml-2">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <span class="text-sm font-semibold">{skill}</span>
                        <span
                          :if={methodology_for_skill(skill)}
                          class={["badge badge-xs", methodology_badge(methodology_for_skill(skill))]}
                        >
                          {methodology_for_skill(skill)}
                        </span>
                      </div>
                      <div class="flex items-center gap-2 text-xs text-base-content/40">
                        <span
                          class="badge badge-xs badge-primary"
                          aria-label={"#{data.count} invocations"}
                        >
                          {data.count}×
                        </span>
                        <span>{format_time(data.last_seen)}</span>
                      </div>
                    </div>
                  </div>
                </article>
              </div>
            </section>

            <%!-- Skill Catalog --%>
            <section aria-labelledby="catalog-heading">
              <h2
                id="catalog-heading"
                class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3"
              >
                Skill Catalog
              </h2>
              <div class="overflow-x-auto">
                <table class="table table-xs w-full" aria-label="All tracked skills">
                  <caption class="sr-only">Skill usage statistics across all sessions</caption>
                  <thead>
                    <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                      <th scope="col">Skill</th>
                      <th scope="col" class="text-right">Total Invocations</th>
                      <th scope="col" class="text-right">Sessions</th>
                      <th scope="col">Source</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={{skill, data} <- Enum.sort_by(@catalog, fn {_k, v} -> -v.total_count end)}
                      class="hover"
                    >
                      <td class="font-medium">{skill}</td>
                      <td class="text-right tabular-nums">{data.total_count}</td>
                      <td class="text-right tabular-nums">{data.session_count}</td>
                      <td>
                        <span class={["badge badge-xs", source_badge(data.source)]}>{data.source}</span>
                      </td>
                    </tr>
                    <tr :if={@catalog == %{}}>
                      <td colspan="4" class="text-center text-base-content/30 py-6">
                        No skills tracked yet
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <%!-- Co-occurrence matrix --%>
            <section :if={@co_occurrence != %{}} aria-labelledby="cooccurrence-heading">
              <h2
                id="cooccurrence-heading"
                class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3"
              >
                Skill Co-occurrence
              </h2>
              <div class="overflow-x-auto">
                <table class="table table-xs w-full" aria-label="Skills used together">
                  <caption class="sr-only">
                    Skills that frequently appear in the same sessions
                  </caption>
                  <thead>
                    <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                      <th scope="col">Skill A</th>
                      <th scope="col">Skill B</th>
                      <th scope="col" class="text-right">Sessions Together</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={{{a, b}, count} <- Enum.sort_by(@co_occurrence, fn {_k, v} -> -v end)}
                      class="hover"
                    >
                      <td>{a}</td>
                      <td>{b}</td>
                      <td class="text-right tabular-nums">{count}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </div>

          <%!-- AG-UI Tab --%>
          <div
            :if={@tab == :ag_ui}
            id="tabpanel-ag_ui"
            role="tabpanel"
            aria-labelledby="tab-ag_ui"
            class="space-y-6"
            tabindex="0"
          >
            <%!-- AG-UI health summary stats --%>
            <div class="stats shadow bg-base-200 w-full" aria-label="AG-UI hook health summary">
              <div class="stat">
                <div class="stat-title">Connected</div>
                <div class="stat-value text-2xl text-success">
                  {Enum.count(@registry_skills, &(&1.health_score >= 80))}
                </div>
                <div class="stat-desc">healthy hooks</div>
              </div>
              <div class="stat">
                <div class="stat-title">Degraded</div>
                <div class="stat-value text-2xl text-warning">
                  {Enum.count(@registry_skills, &(&1.health_score in 50..79))}
                </div>
                <div class="stat-desc">partial connectivity</div>
              </div>
              <div class="stat">
                <div class="stat-title">Broken</div>
                <div class="stat-value text-2xl text-error">
                  {Enum.count(@registry_skills, &(&1.health_score < 50))}
                </div>
                <div class="stat-desc">need repair</div>
              </div>
            </div>

            <section aria-labelledby="ag-ui-emitters-heading">
              <h2
                id="ag-ui-emitters-heading"
                class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3"
              >
                Skills as AG-UI Event Emitters
              </h2>
              <p class="text-sm text-base-content/60 mb-4">
                Skills emit AG-UI events when invoked. Each skill connection shows event emission status.
              </p>
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3" role="list">
                <article
                  :for={skill <- @registry_skills}
                  class={["card bg-base-200 border p-3", ag_ui_border_class(skill.health_score)]}
                  role="listitem"
                  aria-label={"Skill #{skill.name}: #{ag_ui_status_label(skill.health_score)}"}
                >
                  <div class="flex items-center justify-between mb-1">
                    <span class="text-sm font-medium truncate">{skill.name}</span>
                    <div
                      class={["w-2 h-2 rounded-full animate-pulse", ag_ui_dot_class(skill.health_score)]}
                      aria-hidden="true"
                    ></div>
                  </div>
                  <div class={["text-[10px] mb-2", ag_ui_text_class(skill.health_score)]}>
                    {ag_ui_status_label(skill.health_score)}
                  </div>
                  <div class="flex gap-1 flex-wrap items-center justify-between">
                    <div class="flex gap-1">
                      <span class="badge badge-xs badge-ghost">CUSTOM</span>
                      <span
                        :if={skill.has_frontmatter}
                        class="badge badge-xs badge-success badge-outline"
                      >
                        valid
                      </span>
                    </div>
                    <button
                      :if={skill.health_score < 50}
                      class="btn btn-xs btn-error btn-outline"
                      phx-click="fix_frontmatter"
                      phx-value-skill={skill.name}
                      aria-label={"Repair #{skill.name} hook"}
                    >
                      Repair
                    </button>
                  </div>
                </article>
                <div
                  :if={@registry_skills == []}
                  class="col-span-full text-center text-base-content/30 py-8"
                >
                  No skills registered. Run Audit All to scan.
                </div>
              </div>
            </section>

            <section aria-labelledby="hook-repair-heading">
              <div class="flex items-center justify-between mb-3">
                <h2
                  id="hook-repair-heading"
                  class="text-xs font-semibold uppercase tracking-wider text-base-content/50"
                >
                  Hook Repair
                </h2>
                <button
                  phx-click="repair_hooks"
                  class="btn btn-xs btn-warning"
                  aria-label="Repair broken skill hooks and redeploy AG-UI event bridge"
                >
                  <.icon name="hero-wrench-screwdriver" class="size-3" /> Repair All Hooks
                </button>
              </div>
              <div class="bg-base-200 rounded-lg p-3 space-y-2">
                <div class="flex items-center gap-2 text-xs">
                  <div
                    class={[
                      "w-2 h-2 rounded-full",
                      if(Enum.count(@registry_skills, &(&1.health_score < 50)) == 0,
                        do: "bg-success",
                        else: "bg-error"
                      )
                    ]}
                    aria-hidden="true"
                  ></div>
                  <span class="font-medium">AG-UI Event Bridge</span>
                  <span class="text-base-content/50">
                    {if Enum.count(@registry_skills, &(&1.health_score < 50)) == 0,
                      do: "All hooks operational",
                      else:
                        "#{Enum.count(@registry_skills, &(&1.health_score < 50))} hook(s) need repair"}
                  </span>
                </div>
                <p class="text-xs text-base-content/50">
                  Triggers restart-to-reload action to repair broken skill hooks and re-deploy AG-UI event bridge.
                </p>
              </div>
            </section>
          </div>
        </div>
      </main>
    </div>

    <%!-- Skill detail drawer --%>
    <div :if={@selected_skill != nil}>
      <%!-- Backdrop --%>
      <div
        class="fixed inset-0 bg-black/40 z-40"
        phx-click="close_drawer"
        aria-hidden="true"
      ></div>

      <%!-- Drawer panel --%>
      <aside
        id="skill-drawer"
        role="dialog"
        aria-modal="true"
        aria-labelledby="drawer-title"
        class="fixed inset-y-0 right-0 w-96 bg-base-200 shadow-2xl z-50 flex flex-col"
      >
        <%!-- Drawer header --%>
        <div class="flex items-center justify-between p-4 border-b border-base-300 flex-shrink-0">
          <div class="flex items-center gap-3">
            {health_ring(@selected_skill.health_score)}
            <div>
              <h2 id="drawer-title" class="font-semibold text-base leading-tight">
                {@selected_skill.name}
              </h2>
              <span class={["badge badge-sm mt-1", health_badge_class(@selected_skill.health_score)]}>
                {health_label(@selected_skill.health_score)} — {@selected_skill.health_score}/100
              </span>
            </div>
          </div>
          <button
            class="btn btn-ghost btn-sm"
            phx-click="close_drawer"
            aria-label="Close skill details"
            autofocus
          >
            ✕
          </button>
        </div>

        <%!-- Drawer body --%>
        <div class="flex-1 p-4 space-y-4 overflow-y-auto">
          <%!-- Description --%>
          <section aria-labelledby="drawer-desc-heading">
            <h3
              id="drawer-desc-heading"
              class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2"
            >
              Description
            </h3>
            <p class="text-sm text-base-content/80">
              {if @selected_skill.description && @selected_skill.description != "",
                do: @selected_skill.description,
                else: "No description available."}
            </p>
          </section>

          <%!-- Health breakdown --%>
          <section aria-labelledby="drawer-health-heading">
            <h3
              id="drawer-health-heading"
              class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2"
            >
              Health Breakdown
            </h3>
            <div class="grid grid-cols-5 gap-2">
              <.health_bar
                label="Frontmatter"
                value={if @selected_skill.has_frontmatter, do: 30, else: 0}
                max={30}
              />
              <.health_bar
                label="Description"
                value={desc_score(@selected_skill.description_quality)}
                max={25}
              />
              <.health_bar
                label="Triggers"
                value={min(Map.get(@selected_skill, :trigger_count, 0) * 7, 20)}
                max={20}
              />
              <.health_bar
                label="Examples"
                value={if @selected_skill.has_examples, do: 15, else: 0}
                max={15}
              />
              <.health_bar
                label="Template"
                value={if @selected_skill.has_template, do: 10, else: 0}
                max={10}
              />
            </div>
          </section>

          <%!-- Frontmatter --%>
          <section
            :if={@selected_skill.raw_frontmatter != %{}}
            aria-labelledby="drawer-frontmatter-heading"
          >
            <h3
              id="drawer-frontmatter-heading"
              class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2"
            >
              Frontmatter
            </h3>
            <div class="bg-base-300 rounded p-3 text-xs font-mono space-y-1">
              <div :for={{k, v} <- @selected_skill.raw_frontmatter} class="flex gap-2">
                <span class="text-primary font-semibold">{k}:</span>
                <span class="text-base-content/80 break-all">{v}</span>
              </div>
            </div>
          </section>

          <%!-- Metadata --%>
          <section aria-labelledby="drawer-meta-heading">
            <h3
              id="drawer-meta-heading"
              class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2"
            >
              Metadata
            </h3>
            <dl class="text-xs space-y-1.5">
              <div class="flex gap-2">
                <dt class="text-base-content/50 w-32 flex-shrink-0">Files:</dt>
                <dd class="tabular-nums">{@selected_skill.file_count}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-base-content/50 w-32 flex-shrink-0">Description Quality:</dt>
                <dd>
                  <span class={["badge badge-xs", desc_quality_badge(@selected_skill.description_quality)]}>
                    {@selected_skill.description_quality}
                  </span>
                </dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-base-content/50 w-32 flex-shrink-0">Last Modified:</dt>
                <dd>{format_modified(@selected_skill.last_modified)}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-base-content/50 w-32 flex-shrink-0">Has Examples:</dt>
                <dd>{if @selected_skill.has_examples, do: "Yes", else: "No"}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-base-content/50 w-32 flex-shrink-0">Has Template:</dt>
                <dd>{if @selected_skill.has_template, do: "Yes", else: "No"}</dd>
              </div>
            </dl>
          </section>
        </div>

        <%!-- Drawer footer / actions --%>
        <div class="p-4 border-t border-base-300 flex-shrink-0">
          <%!-- Step: nil — Fix button or healthy indicator --%>
          <div :if={@fix_wizard_step == nil}>
            <button
              :if={@selected_skill.health_score < 80}
              class="btn btn-warning btn-sm w-full"
              phx-click="start_fix_wizard"
              aria-describedby="fix-hint"
            >
              <.icon name="hero-wrench-screwdriver" class="size-4" />
              Fix Skill
            </button>
            <p
              :if={@selected_skill.health_score < 80}
              id="fix-hint"
              class="text-[10px] text-base-content/40 mt-1 text-center"
            >
              Guided repair for frontmatter, description, and trigger issues
            </p>
            <p :if={@selected_skill.health_score >= 80} class="text-xs text-success text-center py-1">
              ✓ Skill is healthy — no fixes needed
            </p>
          </div>

          <%!-- Fix Wizard Step 1: Diagnose --%>
          <div :if={@fix_wizard_step == :diagnose} class="space-y-3">
            <div class="flex items-center gap-2 mb-1">
              <span class="badge badge-warning badge-sm">Step 1 of 3</span>
              <span class="text-sm font-medium">Detected Issues</span>
            </div>
            <ul class="space-y-1.5 text-xs" aria-label="Detected skill issues">
              <li
                :if={not @selected_skill.has_frontmatter}
                class="flex items-center gap-2 text-error"
              >
                <span aria-hidden="true">✗</span> Missing frontmatter (–30 pts)
              </li>
              <li
                :if={@selected_skill.description_quality in ["missing", "poor"]}
                class="flex items-center gap-2 text-warning"
              >
                <span aria-hidden="true">⚠</span>
                Poor description quality (–{desc_penalty(@selected_skill.description_quality)} pts)
              </li>
              <li
                :if={Map.get(@selected_skill, :trigger_count, 0) == 0}
                class="flex items-center gap-2 text-warning"
              >
                <span aria-hidden="true">⚠</span> No triggers defined (–20 pts)
              </li>
              <li :if={not @selected_skill.has_examples} class="flex items-center gap-2 text-base-content/50">
                <span aria-hidden="true">·</span> No examples (–15 pts)
              </li>
              <li :if={not @selected_skill.has_template} class="flex items-center gap-2 text-base-content/50">
                <span aria-hidden="true">·</span> No template (–10 pts)
              </li>
            </ul>
            <div class="flex gap-2 pt-1">
              <button class="btn btn-warning btn-sm flex-1" phx-click="wizard_next">
                Select Repairs →
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="cancel_fix">Cancel</button>
            </div>
          </div>

          <%!-- Fix Wizard Step 2: Select --%>
          <div :if={@fix_wizard_step == :select} class="space-y-3">
            <div class="flex items-center gap-2 mb-1">
              <span class="badge badge-warning badge-sm">Step 2 of 3</span>
              <span class="text-sm font-medium">Select Repairs</span>
            </div>
            <div class="space-y-2 text-xs">
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-warning"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "frontmatter")}
                  phx-click="toggle_repair"
                  phx-value-repair="frontmatter"
                  disabled={@selected_skill.has_frontmatter}
                />
                <span class={if @selected_skill.has_frontmatter, do: "line-through opacity-50"}>
                  Fix frontmatter
                </span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-warning"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "description")}
                  phx-click="toggle_repair"
                  phx-value-repair="description"
                  disabled={@selected_skill.description_quality == "good"}
                />
                <span class={if @selected_skill.description_quality == "good", do: "line-through opacity-50"}>
                  Improve description
                </span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  class="checkbox checkbox-xs checkbox-warning"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "triggers")}
                  phx-click="toggle_repair"
                  phx-value-repair="triggers"
                  disabled={Map.get(@selected_skill, :trigger_count, 0) > 0}
                />
                <span class={if Map.get(@selected_skill, :trigger_count, 0) > 0, do: "line-through opacity-50"}>
                  Add triggers
                </span>
              </label>
            </div>
            <div class="flex gap-2 pt-1">
              <button class="btn btn-ghost btn-xs" phx-click="wizard_back">← Back</button>
              <button
                class="btn btn-warning btn-sm flex-1"
                phx-click="wizard_next"
                disabled={MapSet.size(@fix_wizard_selected_repairs) == 0}
                aria-disabled={to_string(MapSet.size(@fix_wizard_selected_repairs) == 0)}
              >
                Preview →
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="cancel_fix">Cancel</button>
            </div>
          </div>

          <%!-- Fix Wizard Step 3: Preview --%>
          <div :if={@fix_wizard_step == :preview} class="space-y-3">
            <div class="flex items-center gap-2 mb-1">
              <span class="badge badge-warning badge-sm">Step 3 of 3</span>
              <span class="text-sm font-medium">Review & Run</span>
            </div>
            <p class="text-xs text-base-content/60">
              The following repairs will run on <strong>{@selected_skill.name}</strong>:
            </p>
            <ul class="text-xs space-y-1">
              <li
                :for={repair <- MapSet.to_list(@fix_wizard_selected_repairs)}
                class="flex items-center gap-2"
              >
                <span class="text-warning" aria-hidden="true">→</span>
                {repair_label(repair)}
              </li>
            </ul>
            <div class="flex gap-2 pt-1">
              <button class="btn btn-ghost btn-xs" phx-click="wizard_back">← Back</button>
              <button
                class="btn btn-warning btn-sm flex-1"
                phx-click="run_wizard_fix"
                phx-value-skill={@selected_skill.name}
              >
                Run Fixes
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="cancel_fix">Cancel</button>
            </div>
          </div>

          <%!-- Fix Wizard Step 4: Done --%>
          <div :if={@fix_wizard_step == :done} class="space-y-3 text-center">
            <div class="text-success text-2xl" aria-hidden="true">✓</div>
            <p class="text-sm font-medium text-success">Fix initiated</p>
            <p class="text-xs text-base-content/50">
              Repairs queued for <strong>{@selected_skill.name}</strong>. Run Audit All to rescan health.
            </p>
            <button class="btn btn-ghost btn-sm w-full" phx-click="cancel_fix">
              Close
            </button>
          </div>
        </div>
      </aside>
    </div>

    <.wizard page="skills" />
    """
  end

  # --- Event handlers ---

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ~w(registry session ag_ui) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("audit_all", _params, socket) do
    SkillsRegistryStore.refresh_all()
    {:noreply, assign(socket, :audit_loading, true)}
  end

  def handle_event("select_skill", %{"name" => name}, socket) do
    skill =
      case SkillsRegistryStore.get_skill(name) do
        {:ok, s} -> s
        _ -> nil
      end

    {:noreply, assign(socket, selected_skill: skill, fix_wizard_step: nil)}
  end

  def handle_event("clear_selected", _params, socket) do
    {:noreply, assign(socket, selected_skill: nil, fix_wizard_step: nil)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_skill: nil, fix_wizard_step: nil)}
  end

  def handle_event("start_fix_wizard", _params, socket) do
    {:noreply, assign(socket, fix_wizard_step: :diagnose, fix_wizard_selected_repairs: MapSet.new())}
  end

  def handle_event("wizard_next", _params, socket) do
    next =
      case socket.assigns.fix_wizard_step do
        :diagnose -> :select
        :select -> :preview
        step -> step
      end

    {:noreply, assign(socket, :fix_wizard_step, next)}
  end

  def handle_event("wizard_back", _params, socket) do
    prev =
      case socket.assigns.fix_wizard_step do
        :select -> :diagnose
        :preview -> :select
        step -> step
      end

    {:noreply, assign(socket, :fix_wizard_step, prev)}
  end

  def handle_event("toggle_repair", %{"repair" => repair}, socket) do
    selected = socket.assigns.fix_wizard_selected_repairs

    updated =
      if MapSet.member?(selected, repair),
        do: MapSet.delete(selected, repair),
        else: MapSet.put(selected, repair)

    {:noreply, assign(socket, :fix_wizard_selected_repairs, updated)}
  end

  def handle_event("run_wizard_fix", %{"skill" => skill_name}, socket) do
    selected = socket.assigns.fix_wizard_selected_repairs

    if MapSet.member?(selected, "frontmatter"),
      do: ActionEngine.run_action("fix_skill_frontmatter", "", %{"skill_name" => skill_name})

    if MapSet.member?(selected, "description"),
      do: ActionEngine.run_action("complete_skill_description", "", %{"skill_name" => skill_name})

    if MapSet.member?(selected, "triggers"),
      do: ActionEngine.run_action("add_skill_triggers", "", %{"skill_name" => skill_name})

    {:noreply, assign(socket, :fix_wizard_step, :done)}
  end

  def handle_event("cancel_fix", _params, socket) do
    {:noreply, assign(socket, fix_wizard_step: nil, fix_wizard_selected_repairs: MapSet.new())}
  end

  def handle_event("fix_frontmatter", %{"skill" => skill_name}, socket) do
    ActionEngine.run_action("fix_skill_frontmatter", "", %{"skill_name" => skill_name})
    {:noreply, socket}
  end

  def handle_event("repair_hooks", _params, socket) do
    ActionEngine.run_action("update_hooks", "", %{})
    {:noreply, socket}
  end

  def handle_event("toggle_tier", %{"tier" => tier_str}, socket) do
    tier =
      case tier_str do
        "healthy" -> :healthy
        "needs_attention" -> :needs_attention
        "critical" -> :critical
        _ -> nil
      end

    if tier do
      collapsed = socket.assigns.collapsed_tiers
      {:noreply, assign(socket, :collapsed_tiers, Map.update!(collapsed, tier, &(!&1)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_filters", params, socket) do
    socket =
      socket
      |> assign(:search_query, Map.get(params, "search", ""))
      |> assign(:filter_tier, Map.get(params, "tier", "all"))
      |> assign(:filter_methodology, Map.get(params, "methodology", "all"))
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:search_query, "")
      |> assign(:filter_tier, "all")
      |> assign(:filter_methodology, "all")
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    cond do
      socket.assigns.fix_wizard_step not in [nil, :done] ->
        prev = wizard_prev(socket.assigns.fix_wizard_step)
        {:noreply, assign(socket, :fix_wizard_step, prev)}

      socket.assigns.selected_skill != nil ->
        {:noreply,
         assign(socket,
           selected_skill: nil,
           fix_wizard_step: nil,
           fix_wizard_selected_repairs: MapSet.new()
         )}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # --- PubSub ---

  @impl true
  def handle_info({:skill_tracked, _session_id, _skill_name}, socket) do
    active_session = socket.assigns.active_session
    session_skills = if active_session, do: SkillTracker.get_session_skills(active_session), else: %{}
    catalog = SkillTracker.get_skill_catalog()
    co_occurrence = SkillTracker.get_co_occurrence()
    methodology = if active_session, do: SkillTracker.active_methodology(active_session)

    registry_skills = SkillsRegistryStore.list_skills()

    socket =
      socket
      |> assign(:session_skills, session_skills)
      |> assign(:catalog, catalog)
      |> assign(:co_occurrence, co_occurrence)
      |> assign(:methodology, methodology)
      |> assign(:active_skill_count, map_size(session_skills))
      |> assign(:registry_skills, registry_skills)
      |> assign(:audit_loading, false)
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Components ---

  attr :tier, :atom, required: true
  attr :skills, :list, required: true
  attr :collapsed, :boolean, default: false
  attr :selected, :any, default: nil

  defp skill_tier_cards(assigns) do
    ~H"""
    <section
      :if={@skills != []}
      aria-labelledby={"tier-heading-#{@tier}"}
      class="space-y-2"
    >
      <button
        id={"tier-heading-#{@tier}"}
        class={[
          "w-full flex items-center justify-between px-3 py-2 rounded-lg hover:bg-base-300 transition-colors",
          "text-xs font-semibold uppercase tracking-wider",
          tier_color_class(@tier)
        ]}
        phx-click="toggle_tier"
        phx-value-tier={@tier}
        aria-expanded={to_string(not @collapsed)}
        aria-controls={"tier-grid-#{@tier}"}
      >
        <span class="flex items-center gap-2">
          <span>{tier_label(@tier)}</span>
          <span class={["badge badge-sm", tier_badge_class(@tier)]}>{length(@skills)}</span>
        </span>
        <span aria-hidden="true">{if @collapsed, do: "▶", else: "▼"}</span>
      </button>

      <div
        :if={not @collapsed}
        id={"tier-grid-#{@tier}"}
        role="list"
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3"
      >
        <article
          :for={skill <- @skills}
          role="listitem"
          class={[
            "card bg-base-200 border border-base-300 p-3 cursor-pointer",
            "hover:border-primary/50 hover:bg-base-300 transition-colors",
            @selected && @selected.name == skill.name && "border-primary bg-primary/5"
          ]}
          phx-click="select_skill"
          phx-value-name={skill.name}
          tabindex="0"
          phx-keydown={JS.push("select_skill", value: %{name: skill.name})}
          phx-key="Enter"
          aria-label={"#{skill.name}: #{health_label(skill.health_score)}, score #{skill.health_score}"}
        >
          <div class="flex items-start gap-3">
            <div class="flex-shrink-0 mt-0.5">
              {health_ring(skill.health_score)}
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="text-sm font-semibold truncate">{skill.name}</span>
              </div>
              <p class="text-[11px] text-base-content/60 line-clamp-2 mb-2">
                {skill.description || "No description"}
              </p>
              <div class="flex items-center gap-1 flex-wrap">
                <span class={["badge badge-xs", desc_quality_badge(skill.description_quality)]}>
                  {skill.description_quality}
                </span>
                <span class="text-[10px] text-base-content/40">
                  {format_modified(skill.last_modified)}
                </span>
              </div>
            </div>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true

  defp health_bar(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-[10px] text-base-content/50 mb-1">{@label}</div>
      <div
        class="w-full bg-base-300 rounded-full h-2"
        role="progressbar"
        aria-valuenow={@value}
        aria-valuemin={0}
        aria-valuemax={@max}
        aria-label={@label}
      >
        <div
          class={[
            "h-2 rounded-full",
            @value == @max && "bg-success",
            @value > 0 && @value < @max && "bg-warning",
            @value == 0 && "bg-base-300"
          ]}
          style={"width: #{if @max > 0, do: round(@value / @max * 100), else: 0}%"}
        ></div>
      </div>
      <div class="text-[10px] text-base-content/50 mt-1">{@value}/{@max}</div>
    </div>
    """
  end

  # --- Private helpers ---

  defp apply_filters(socket) do
    skills = socket.assigns.registry_skills
    query = String.downcase(socket.assigns.search_query)
    tier = socket.assigns.filter_tier
    methodology = socket.assigns.filter_methodology

    filtered =
      skills
      |> filter_by_search(query)
      |> filter_by_tier(tier)
      |> filter_by_methodology(methodology)

    assign(socket, :filtered_skills, filtered)
  end

  defp filter_by_search(skills, ""), do: skills

  defp filter_by_search(skills, query) do
    Enum.filter(skills, fn skill ->
      String.contains?(String.downcase(skill.name), query) or
        String.contains?(String.downcase(skill.description || ""), query)
    end)
  end

  defp filter_by_tier(skills, "all"), do: skills
  defp filter_by_tier(skills, "healthy"), do: Enum.filter(skills, &(&1.health_score >= 80))
  defp filter_by_tier(skills, "needs_attention"), do: Enum.filter(skills, &(&1.health_score in 50..79))
  defp filter_by_tier(skills, "critical"), do: Enum.filter(skills, &(&1.health_score < 50))
  defp filter_by_tier(skills, _), do: skills

  defp filter_by_methodology(skills, "all"), do: skills

  defp filter_by_methodology(skills, methodology) do
    target =
      case methodology do
        "ralph" -> :ralph
        "tdd" -> :tdd
        "elixir_architect" -> :elixir_architect
        _ -> nil
      end

    Enum.filter(skills, fn skill ->
      methodology_for_skill(skill.name) == target
    end)
  end

  defp split_tiers(skills) do
    healthy = Enum.filter(skills, &(&1.health_score >= 80))
    needs_attention = Enum.filter(skills, &(&1.health_score in 50..79))
    critical = Enum.filter(skills, &(&1.health_score < 50))
    {healthy, needs_attention, critical}
  end

  defp active_filter_count(assigns) do
    [
      assigns.search_query != "",
      assigns.filter_tier != "all",
      assigns.filter_methodology != "all"
    ]
    |> Enum.count(& &1)
  end

  defp tier_label(:healthy), do: "Healthy"
  defp tier_label(:needs_attention), do: "Needs Attention"
  defp tier_label(:critical), do: "Critical"

  defp tier_badge_class(:healthy), do: "badge-success"
  defp tier_badge_class(:needs_attention), do: "badge-warning"
  defp tier_badge_class(:critical), do: "badge-error"

  defp tier_color_class(:healthy), do: "text-success"
  defp tier_color_class(:needs_attention), do: "text-warning"
  defp tier_color_class(:critical), do: "text-error"

  # SVG donut health ring — uses Phoenix.HTML.raw/1 (not ~H) to avoid compile-time recursion
  defp health_ring(score) do
    radius = 16
    circumference = 2 * :math.pi() * radius
    offset = circumference * (1 - score / 100)
    dash = Float.round(circumference, 2)
    off = Float.round(offset, 2)

    color =
      cond do
        score >= 80 -> "#22c55e"
        score >= 50 -> "#f59e0b"
        true -> "#ef4444"
      end

    Phoenix.HTML.raw("""
    <svg width="40" height="40" viewBox="0 0 40 40" aria-hidden="true" focusable="false">
      <circle cx="20" cy="20" r="#{radius}" fill="none" stroke="currentColor" stroke-width="3" opacity="0.15"/>
      <circle cx="20" cy="20" r="#{radius}" fill="none" stroke="#{color}" stroke-width="3"
        stroke-dasharray="#{dash}" stroke-dashoffset="#{off}"
        stroke-linecap="round" transform="rotate(-90 20 20)"/>
      <text x="20" y="24" text-anchor="middle" font-size="10" font-weight="bold" fill="#{color}">#{score}</text>
    </svg>
    """)
  end

  defp current_session_id do
    try do
      config = ConfigLoader.get_config()

      config
      |> Map.get("projects", [])
      |> Enum.flat_map(&Map.get(&1, "sessions", []))
      |> List.last()
      |> then(fn
        nil -> nil
        s -> s["session_id"]
      end)
    catch
      :exit, _ -> nil
    end
  end

  defp format_time(nil), do: "—"

  defp format_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> "#{div(diff, 3600)}h ago"
        end

      _ ->
        "—"
    end
  end

  defp format_time(_), do: "—"

  defp methodology_badge(:ralph), do: "badge-success"
  defp methodology_badge(:tdd), do: "badge-info"
  defp methodology_badge(:elixir_architect), do: "badge-accent"
  defp methodology_badge(_), do: "badge-ghost"

  defp methodology_for_skill("ralph"), do: :ralph
  defp methodology_for_skill("tdd:spawn"), do: :tdd
  defp methodology_for_skill("spawn"), do: :tdd
  defp methodology_for_skill("elixir-architect"), do: :elixir_architect
  defp methodology_for_skill(_), do: nil

  defp source_badge(:observed), do: "badge-success"
  defp source_badge(:filesystem), do: "badge-ghost"
  defp source_badge(_), do: "badge-ghost"

  defp health_badge_class(score) when score >= 80, do: "badge-success"
  defp health_badge_class(score) when score >= 50, do: "badge-warning"
  defp health_badge_class(_), do: "badge-error"

  defp health_label(score) when score >= 80, do: "healthy"
  defp health_label(score) when score >= 50, do: "needs attention"
  defp health_label(_), do: "critical"

  defp desc_score("good"), do: 25
  defp desc_score("truncated"), do: 10
  defp desc_score(_), do: 0

  defp desc_quality_badge("good"), do: "badge-success"
  defp desc_quality_badge("truncated"), do: "badge-warning"
  defp desc_quality_badge(_), do: "badge-error"

  defp format_modified(nil), do: "—"

  defp format_modified(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp format_modified(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> format_modified()
  end

  defp format_modified(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> format_modified(dt)
      _ -> "—"
    end
  end

  defp format_modified(_), do: "—"

  # Fix Wizard helpers

  defp wizard_prev(:select), do: :diagnose
  defp wizard_prev(:preview), do: :select
  defp wizard_prev(step), do: step

  defp desc_penalty("missing"), do: 25
  defp desc_penalty("poor"), do: 15
  defp desc_penalty(_), do: 5

  defp repair_label("frontmatter"), do: "Fix frontmatter (add missing YAML header)"
  defp repair_label("description"), do: "Improve description quality"
  defp repair_label("triggers"), do: "Add trigger keywords"
  defp repair_label(r), do: "Fix #{r}"

  # AG-UI helpers

  defp ag_ui_status_label(score) when score >= 80, do: "Connected"
  defp ag_ui_status_label(score) when score >= 50, do: "Degraded"
  defp ag_ui_status_label(_), do: "Broken"

  defp ag_ui_border_class(score) when score >= 80, do: "border-success/30"
  defp ag_ui_border_class(score) when score >= 50, do: "border-warning/30"
  defp ag_ui_border_class(_), do: "border-error/30"

  defp ag_ui_dot_class(score) when score >= 80, do: "bg-success"
  defp ag_ui_dot_class(score) when score >= 50, do: "bg-warning"
  defp ag_ui_dot_class(_), do: "bg-error"

  defp ag_ui_text_class(score) when score >= 80, do: "text-success"
  defp ag_ui_text_class(score) when score >= 50, do: "text-warning"
  defp ag_ui_text_class(_), do: "text-error"
end
