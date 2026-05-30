defmodule ApmWeb.SkillsLive do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  LiveView for skills tracking, UEBA analytics, and Skills Registry health dashboard.

  WCAG 2.1 AA compliant — skip links, ARIA landmarks, tablist/tab/tabpanel roles,
  aria-live regions, keyboard navigation (Escape to close drawer).

  Tabs:
  - Registry: card grid with health rings, search/filter, tier collapsing, slide-in detail drawer
  - Session:  active skills, catalog, co-occurrence matrix
  - AG-UI:    skill-to-event mapping, hook repair
  """

  use ApmWeb, :live_view

  alias Apm.SkillTracker
  alias Apm.SkillsRegistryStore
  alias Apm.ActionEngine
  alias Apm.ConfigLoader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:skills")
      Apm.AgUi.EventBus.subscribe("special:custom")
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
      |> assign(:agentlock_status, nil)
      |> assign(:audit_loading, false)
      |> assign(:search_query, "")
      |> assign(:filter_tier, "all")
      |> assign(:filter_methodology, "all")
      |> assign(:collapsed_tiers, %{healthy: true, needs_attention: false, critical: false})
      |> assign(:fix_wizard_step, nil)
      |> assign(:fix_wizard_selected_repairs, MapSet.new())
      |> assign(:fix_preview, nil)
      |> assign(:fix_preview_loading, false)
      |> assign(:page, 1)
      |> assign(:per_page, 25)
      |> assign(:selected_skills, MapSet.new())
      |> assign(:show_dry_run_modal, false)
      |> assign(:dry_run_skill, nil)
      |> assign(:dry_run_preview, "")
      |> assign(:view_mode, "grid")
      |> assign(:group_by, "none")
      |> assign(:fix_in_progress, false)
      |> assign(:fix_progress, [])
      |> assign(:fix_current, nil)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)

    {:ok, socket |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Skip link (WCAG 2.1 AA §2.4.1) --%>
    <a
      href="#main-content"
      style="position: absolute; top: -9999px; left: -9999px; z-index: 9999; padding: 6px 12px; background: var(--ccem-accent); color: #fff; border-radius: 4px;"
    >
      Skip to main content
    </a>

    <div
      id="skills-view"
      phx-hook="Skills"
      phx-window-keydown="keydown"
    >
      <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
        <:sidebar><.sidebar_nav current_path="/skills" skill_count={@active_skill_count} /></:sidebar>
        <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
        <:main>
          <%!-- Page header --%>
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
            <div style="display: flex; align-items: center; gap: 12px;">
              <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Skills</h1>
              <.badge tone="accent"><%= to_string(length(@registry_skills)) %></.badge>

              <%!-- Tab list --%>
              <div
                role="tablist"
                aria-label="Skills views"
                style="display: flex; gap: 4px;"
              >
                <button
                  role="tab"
                  id="tab-registry"
                  aria-selected={to_string(@tab == :registry)}
                  aria-controls="tabpanel-registry"
                  phx-click="set_tab"
                  phx-value-tab="registry"
                  tabindex={if @tab == :registry, do: "0", else: "-1"}
                  style={"padding: 4px 10px; border-radius: 4px; font-size: 12px; border: none; cursor: pointer; #{if @tab == :registry, do: "background: var(--ccem-accent); color: #fff;", else: "background: transparent; color: var(--ccem-fg-muted);"}"}
                >
                  Registry
                </button>
                <button
                  role="tab"
                  id="tab-session"
                  aria-selected={to_string(@tab == :session)}
                  aria-controls="tabpanel-session"
                  phx-click="set_tab"
                  phx-value-tab="session"
                  tabindex={if @tab == :session, do: "0", else: "-1"}
                  style={"padding: 4px 10px; border-radius: 4px; font-size: 12px; border: none; cursor: pointer; #{if @tab == :session, do: "background: var(--ccem-accent); color: #fff;", else: "background: transparent; color: var(--ccem-fg-muted);"}"}
                >
                  Session
                </button>
                <button
                  role="tab"
                  id="tab-ag_ui"
                  aria-selected={to_string(@tab == :ag_ui)}
                  aria-controls="tabpanel-ag_ui"
                  phx-click="set_tab"
                  phx-value-tab="ag_ui"
                  tabindex={if @tab == :ag_ui, do: "0", else: "-1"}
                  style={"padding: 4px 10px; border-radius: 4px; font-size: 12px; border: none; cursor: pointer; #{if @tab == :ag_ui, do: "background: var(--ccem-accent); color: #fff;", else: "background: transparent; color: var(--ccem-fg-muted);"}"}
                >
                  AG-UI
                </button>
              </div>
            </div>

            <%!-- Header actions --%>
            <div style="display: flex; align-items: center; gap: 8px;">
              <%!-- View toggle (registry tab only) --%>
              <div :if={@tab == :registry} style="display: flex; gap: 2px;">
                <.btn
                  variant={if @view_mode == "grid", do: "primary", else: "ghost"}
                  size="xs"
                  phx-click="set_view_mode"
                  phx-value-mode="grid"
                  aria-label="Grid view"
                  aria-pressed={to_string(@view_mode == "grid")}
                >
                  <.icon name="hero-squares-2x2" class="size-3.5" />
                </.btn>
                <.btn
                  variant={if @view_mode == "list", do: "primary", else: "ghost"}
                  size="xs"
                  phx-click="set_view_mode"
                  phx-value-mode="list"
                  aria-label="List view"
                  aria-pressed={to_string(@view_mode == "list")}
                >
                  <.icon name="hero-list-bullet" class="size-3.5" />
                </.btn>
              </div>
              <.badge :if={@tab == :registry and active_filter_count(assigns) > 0} tone="info">
                {active_filter_count(assigns)} filter{if active_filter_count(assigns) > 1, do: "s", else: ""} active
              </.badge>
              <.btn :if={@tab == :registry} variant="primary" size="sm" phx-click="audit_all" disabled={@audit_loading} aria-busy={to_string(@audit_loading)}>
                {if @audit_loading, do: "Scanning…", else: "Audit All"}
              </.btn>
            </div>
          </div>

          <%!-- Search / filter bar (registry tab only) --%>
          <div
            :if={@tab == :registry}
            role="search"
            aria-label="Filter skills"
            style="margin-bottom: 16px;"
          >
            <form phx-change="update_filters" style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
              <label for="skill-search" class="sr-only">Search skills</label>
              <.ds_input
                id="skill-search"
                type="search"
                name="search"
                value={@search_query}
                placeholder="Search skills…"
                phx-debounce="200"
                aria-label="Search skills by name or description"
                autocomplete="off"
              />

              <label for="filter-tier" class="sr-only">Filter by health tier</label>
              <select
                id="filter-tier"
                name="tier"
                aria-label="Filter by health tier"
                style="padding: 4px 8px; border-radius: 4px; background: var(--ccem-surface); color: var(--ccem-fg); border: 1px solid var(--ccem-border); font-size: 12px;"
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
                aria-label="Filter by methodology"
                style="padding: 4px 8px; border-radius: 4px; background: var(--ccem-surface); color: var(--ccem-fg); border: 1px solid var(--ccem-border); font-size: 12px;"
              >
                <option value="all" selected={@filter_methodology == "all"}>All methodologies</option>
                <option value="ralph" selected={@filter_methodology == "ralph"}>Ralph</option>
                <option value="tdd" selected={@filter_methodology == "tdd"}>TDD</option>
                <option value="elixir_architect" selected={@filter_methodology == "elixir_architect"}>Elixir Architect</option>
              </select>

              <label for="group-by" class="sr-only">Group by</label>
              <select
                id="group-by"
                name="group_by"
                aria-label="Group skills by"
                style="padding: 4px 8px; border-radius: 4px; background: var(--ccem-surface); color: var(--ccem-fg); border: 1px solid var(--ccem-border); font-size: 12px;"
              >
                <option value="none" selected={@group_by == "none"}>No grouping</option>
                <option value="tier" selected={@group_by == "tier"}>By Tier</option>
                <option value="source" selected={@group_by == "source"}>By Source</option>
                <option value="methodology" selected={@group_by == "methodology"}>By Methodology</option>
              </select>
            </form>

            <.btn :if={active_filter_count(assigns) > 0} variant="ghost" size="xs" phx-click="clear_filters" aria-label="Clear all active filters" style="margin-top: 4px;">
              ✕ Clear filters
            </.btn>
          </div>

          <%!-- Main content area --%>
          <main id="main-content" role="main" aria-label="Skills dashboard">
            <%!-- Registry Tab --%>
            <div
              :if={@tab == :registry}
              id="tabpanel-registry"
              role="tabpanel"
              aria-labelledby="tab-registry"
              tabindex="0"
            >
              <%!-- Summary stat tiles --%>
              <div
                style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 16px;"
                aria-label="Skills health summary"
              >
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile label="Total Skills" value={to_string(length(@registry_skills))} />
                </.card>
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Healthy"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score >= 80)))}
                  />
                </.card>
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Needs Attention"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score in 50..79)))}
                  />
                </.card>
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Critical"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score < 50)))}
                  />
                </.card>
              </div>

              <%!-- Filter results count --%>
              <div
                :if={active_filter_count(assigns) > 0}
                aria-live="polite"
                aria-atomic="true"
                style="font-size: 11px; color: var(--ccem-fg-subtle); margin-bottom: 8px;"
              >
                Showing {length(@filtered_skills)} of {length(@registry_skills)} skills
              </div>

              <%!-- Batch action bar --%>
              <%= if MapSet.size(@selected_skills) > 0 do %>
                <div style="display: flex; align-items: center; justify-content: space-between; padding: 8px 16px; margin-bottom: 12px; background: color-mix(in srgb, var(--ccem-accent) 10%, transparent); border: 1px solid color-mix(in srgb, var(--ccem-accent) 20%, transparent); border-radius: 6px;">
                  <span style="font-size: 13px; color: var(--ccem-fg);">{MapSet.size(@selected_skills)} selected</span>
                  <div style="display: flex; gap: 6px;">
                    <.btn variant="secondary" size="xs" phx-click="batch_fix">Fix Selected</.btn>
                    <.btn variant="secondary" size="xs" phx-click="batch_audit">Audit Selected</.btn>
                    <.btn variant="ghost" size="xs" phx-click="clear_selection">Clear</.btn>
                  </div>
                </div>
              <% end %>

              <%!-- Fix progress panel --%>
              <%= if @fix_in_progress do %>
                <.card padded={true} style="margin-bottom: 12px;">
                  <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
                    <span style="font-size: 12px; font-weight: 600; color: var(--ccem-fg);">Fixing skills...</span>
                    <span style="font-size: 11px; color: var(--ccem-fg-subtle);">
                      {length(Enum.filter(@fix_progress, fn {_, s, _} -> s == :done end))}/{length(@fix_progress)}
                    </span>
                  </div>
                  <%= for {name, status, msg} <- @fix_progress do %>
                    <div style="display: flex; align-items: center; gap: 8px; font-size: 11px; margin-bottom: 4px;">
                      <%= case status do %>
                        <% :done -> %><span style="color: var(--ccem-ok);"><.icon name="hero-check-circle" class="h-4 w-4" /></span>
                        <% :running -> %><span style="color: var(--ccem-accent);">⟳</span>
                        <% :pending -> %><span style="color: var(--ccem-fg-subtle);"><.icon name="hero-clock" class="h-4 w-4" /></span>
                        <% :error -> %><.icon name="hero-x-circle" class="h-4 w-4 text-err" />
                      <% end %>
                      <span style="font-family: monospace;">{name}</span>
                      <span style="color: var(--ccem-fg-subtle);">{msg}</span>
                    </div>
                  <% end %>
                </.card>
              <% end %>

              <%!-- Grouped or flat rendering --%>
              <%= if @group_by != "none" do %>
                <%= for {group_name, group_skills} <- group_skills(@filtered_skills, @group_by) do %>
                  <.card padded={false} style="margin-bottom: 8px;">
                    <details open>
                      <summary style="padding: 10px 14px; font-size: 12px; font-weight: 600; color: var(--ccem-fg); cursor: pointer; display: flex; align-items: center; gap: 8px;">
                        {group_name}
                        <.badge tone="neutral">{to_string(length(group_skills))}</.badge>
                      </summary>
                      <div style="padding: 0 14px 14px;">
                        <%= if @view_mode == "list" do %>
                          <.skill_list_view skills={group_skills} selected_skills={@selected_skills} selected_skill={@selected_skill} />
                        <% else %>
                          <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 10px;" role="list">
                            <.skill_card :for={skill <- group_skills} skill={skill} selected_skill={@selected_skill} selected_skills={@selected_skills} />
                          </div>
                        <% end %>
                      </div>
                    </details>
                  </.card>
                <% end %>
              <% else %>
                <%!-- Flat rendering (no grouping) --%>
                <%= if @view_mode == "list" do %>
                  <.skill_list_view skills={@filtered_skills} selected_skills={@selected_skills} selected_skill={@selected_skill} />
                <% else %>
                  <%!-- Tier card sections (critical -> needs attention -> healthy) --%>
                  <% {healthy, needs_attention, critical} = split_tiers(@filtered_skills) %>

                  <.skill_tier_cards
                    tier={:critical}
                    skills={critical}
                    collapsed={Map.get(@collapsed_tiers, :critical, false)}
                    selected={@selected_skill}
                    selected_skills={@selected_skills}
                  />
                  <.skill_tier_cards
                    tier={:needs_attention}
                    skills={needs_attention}
                    collapsed={Map.get(@collapsed_tiers, :needs_attention, false)}
                    selected={@selected_skill}
                    selected_skills={@selected_skills}
                  />
                  <.skill_tier_cards
                    tier={:healthy}
                    skills={healthy}
                    collapsed={Map.get(@collapsed_tiers, :healthy, true)}
                    selected={@selected_skill}
                    selected_skills={@selected_skills}
                  />
                <% end %>
              <% end %>

              <div :if={@registry_skills == []} style="text-align: center; padding: 48px 0; color: var(--ccem-fg-subtle);">
                <p style="margin: 0 0 16px;">No skills found in ~/.claude/skills/</p>
                <.btn variant="primary" size="sm" phx-click="audit_all">Scan Now</.btn>
              </div>
            </div>

            <%!-- Session Tab --%>
            <div
              :if={@tab == :session}
              id="tabpanel-session"
              role="tabpanel"
              aria-labelledby="tab-session"
              tabindex="0"
            >
              <%!-- Invocation Timeline --%>
              <section aria-labelledby="timeline-heading" style="margin-bottom: 24px;">
                <h2
                  id="timeline-heading"
                  style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 12px;"
                >
                  Invocation Timeline
                </h2>
                <p
                  :if={@session_skills == %{}}
                  style="font-size: 13px; color: var(--ccem-fg-subtle); padding: 16px 0;"
                  aria-live="polite"
                >
                  No skills invoked in current session.
                </p>
                <div
                  :if={@session_skills != %{}}
                  role="list"
                  aria-label="Skill invocation timeline"
                  style="position: relative; padding-left: 24px;"
                >
                  <div style="position: absolute; left: 8px; top: 0; bottom: 0; width: 2px; background: var(--ccem-border);" aria-hidden="true"></div>
                  <article
                    :for={{skill, data} <- Enum.sort_by(@session_skills, fn {_k, v} -> v.last_seen end, :desc)}
                    role="listitem"
                    style="position: relative; margin-bottom: 10px;"
                    aria-label={"#{skill}: #{data.count} invocations, last #{format_time(data.last_seen)}"}
                  >
                    <div
                      style={"position: absolute; left: -20px; top: 8px; width: 10px; height: 10px; border-radius: 50%; border: 2px solid var(--ccem-surface); #{if methodology_for_skill(skill), do: "background: var(--ccem-accent);", else: "background: var(--ccem-fg-subtle);"}"}
                      aria-hidden="true"
                    ></div>
                    <.card padded={true} style="margin-left: 8px;">
                      <div style="display: flex; align-items: center; justify-content: space-between;">
                        <div style="display: flex; align-items: center; gap: 8px;">
                          <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">{skill}</span>
                          <.badge :if={methodology_for_skill(skill)} tone={methodology_tone(methodology_for_skill(skill))}>
                            {methodology_for_skill(skill)}
                          </.badge>
                        </div>
                        <div style="display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--ccem-fg-subtle);">
                          <.badge tone="accent" aria-label={"#{data.count} invocations"}>
                            {data.count}×
                          </.badge>
                          <span>{format_time(data.last_seen)}</span>
                        </div>
                      </div>
                    </.card>
                  </article>
                </div>
              </section>

              <%!-- Skill Catalog --%>
              <section aria-labelledby="catalog-heading" style="margin-bottom: 24px;">
                <h2
                  id="catalog-heading"
                  style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 12px;"
                >
                  Skill Catalog
                </h2>
                <.card padded={false}>
                  <.data_table id="skill-catalog-table" rows={Enum.sort_by(@catalog, fn {_k, v} -> -v.total_count end)}>
                    <:col :let={row} label="Skill">
                      <span style="font-weight: 500; color: var(--ccem-fg);">{elem(row, 0)}</span>
                    </:col>
                    <:col :let={row} label="Total Invocations">
                      <span style="font-variant-numeric: tabular-nums;">{elem(row, 1).total_count}</span>
                    </:col>
                    <:col :let={row} label="Sessions">
                      <span style="font-variant-numeric: tabular-nums;">{elem(row, 1).session_count}</span>
                    </:col>
                    <:col :let={row} label="Source">
                      <.badge tone={source_tone(elem(row, 1).source)}>{elem(row, 1).source}</.badge>
                    </:col>
                  </.data_table>
                  <%= if @catalog == %{} do %>
                    <div style="text-align: center; color: var(--ccem-fg-subtle); padding: 24px; font-size: 13px;">
                      No skills tracked yet
                    </div>
                  <% end %>
                </.card>
              </section>

              <%!-- Co-occurrence matrix --%>
              <section :if={@co_occurrence != %{}} aria-labelledby="cooccurrence-heading">
                <h2
                  id="cooccurrence-heading"
                  style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 12px;"
                >
                  Skill Co-occurrence
                </h2>
                <.card padded={false}>
                  <.data_table id="cooccurrence-table" rows={Enum.sort_by(@co_occurrence, fn {_k, v} -> -v end)}>
                    <:col :let={row} label="Skill A">{elem(elem(row, 0), 0)}</:col>
                    <:col :let={row} label="Skill B">{elem(elem(row, 0), 1)}</:col>
                    <:col :let={row} label="Sessions Together">
                      <span style="font-variant-numeric: tabular-nums;">{elem(row, 1)}</span>
                    </:col>
                  </.data_table>
                </.card>
              </section>
            </div>

            <%!-- AG-UI Tab --%>
            <div
              :if={@tab == :ag_ui}
              id="tabpanel-ag_ui"
              role="tabpanel"
              aria-labelledby="tab-ag_ui"
              tabindex="0"
            >
              <%!-- AG-UI health summary stats --%>
              <div
                style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px;"
                aria-label="AG-UI hook health summary"
              >
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Connected"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score >= 80)))}
                  />
                </.card>
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Degraded"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score in 50..79)))}
                  />
                </.card>
                <.card padded={true} style="flex: 1; min-width: 120px;">
                  <.stat_tile
                    label="Broken"
                    value={to_string(Enum.count(@registry_skills, &(&1.health_score < 50)))}
                  />
                </.card>
              </div>

              <section aria-labelledby="ag-ui-emitters-heading" style="margin-bottom: 24px;">
                <h2
                  id="ag-ui-emitters-heading"
                  style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;"
                >
                  Skills as AG-UI Event Emitters
                </h2>
                <p style="font-size: 13px; color: var(--ccem-fg-muted); margin: 0 0 16px;">
                  Skills emit AG-UI events when invoked. Each skill connection shows event emission status.
                </p>
                <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px;" role="list">
                  <article
                    :for={skill <- @registry_skills}
                    style={"padding: 12px; border-radius: 6px; background: var(--ccem-surface); border: 1px solid #{ag_ui_border_color(skill.health_score)};"}
                    role="listitem"
                    aria-label={"Skill #{skill.name}: #{ag_ui_status_label(skill.health_score)}"}
                  >
                    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px;">
                      <span style="font-size: 13px; font-weight: 500; color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{skill.name}</span>
                      <div
                        style={"width: 8px; height: 8px; border-radius: 50%; animation: pulse 2s infinite; background: #{ag_ui_dot_color(skill.health_score)};"}
                        aria-hidden="true"
                      ></div>
                    </div>
                    <div style={"font-size: 10px; margin-bottom: 8px; color: #{ag_ui_text_color(skill.health_score)};"}>
                      {ag_ui_status_label(skill.health_score)}
                    </div>
                    <div style="display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 4px;">
                      <div style="display: flex; gap: 4px;">
                        <.badge tone="neutral">CUSTOM</.badge>
                        <.badge :if={skill.has_frontmatter} tone="success">valid</.badge>
                      </div>
                      <.btn
                        :if={skill.health_score < 50}
                        variant="destructive"
                        size="xs"
                        phx-click="fix_frontmatter"
                        phx-value-skill={skill.name}
                        aria-label={"Repair #{skill.name} hook"}
                      >
                        Repair
                      </.btn>
                    </div>
                  </article>
                  <div
                    :if={@registry_skills == []}
                    style="grid-column: 1 / -1; text-align: center; color: var(--ccem-fg-subtle); padding: 32px;"
                  >
                    No skills registered. Run Audit All to scan.
                  </div>
                </div>
              </section>

              <section aria-labelledby="hook-repair-heading">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
                  <h2
                    id="hook-repair-heading"
                    style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0;"
                  >
                    Hook Repair
                  </h2>
                  <.btn variant="secondary" size="xs" phx-click="repair_hooks" aria-label="Repair broken skill hooks and redeploy AG-UI event bridge">
                    <.icon name="hero-wrench-screwdriver" class="size-3" /> Repair All Hooks
                  </.btn>
                </div>
                <.card padded={true}>
                  <div style="display: flex; align-items: center; gap: 8px; font-size: 12px; margin-bottom: 8px;">
                    <div
                      style={"width: 8px; height: 8px; border-radius: 50%; background: #{if Enum.count(@registry_skills, &(&1.health_score < 50)) == 0, do: "var(--ccem-ok)", else: "var(--ccem-err)"};"}
                      aria-hidden="true"
                    ></div>
                    <span style="font-weight: 500; color: var(--ccem-fg);">AG-UI Event Bridge</span>
                    <span style="color: var(--ccem-fg-subtle);">
                      {if Enum.count(@registry_skills, &(&1.health_score < 50)) == 0,
                        do: "All hooks operational",
                        else:
                          "#{Enum.count(@registry_skills, &(&1.health_score < 50))} hook(s) need repair"}
                    </span>
                  </div>
                  <p style="font-size: 11px; color: var(--ccem-fg-subtle); margin: 0;">
                    Triggers restart-to-reload action to repair broken skill hooks and re-deploy AG-UI event bridge.
                  </p>
                </.card>
              </section>
            </div>
          </main>
        </:main>
      </.page_layout>
    </div>

    <%!-- Skill detail drawer — outside page_layout so it overlays correctly --%>
    <div :if={@selected_skill != nil}>
      <%!-- Backdrop --%>
      <div
        style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); z-index: 40;"
        phx-click="close_drawer"
        aria-hidden="true"
      ></div>

      <%!-- Drawer panel --%>
      <aside
        id="skill-drawer"
        role="dialog"
        aria-modal="true"
        aria-labelledby="drawer-title"
        style="position: fixed; inset-block: 0; right: 0; width: 384px; background: var(--ccem-surface); box-shadow: -4px 0 24px rgba(0,0,0,0.3); z-index: 50; display: flex; flex-direction: column;"
      >
        <%!-- Drawer header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; padding: 16px; border-bottom: 1px solid var(--ccem-border); flex-shrink: 0;">
          <div style="display: flex; align-items: center; gap: 12px;">
            {health_ring(@selected_skill.health_score)}
            <div>
              <h2 id="drawer-title" style="font-weight: 600; font-size: 14px; margin: 0 0 4px; color: var(--ccem-fg);">
                {@selected_skill.name}
              </h2>
              <.badge tone={health_tone(@selected_skill.health_score)}>
                {health_label(@selected_skill.health_score)} — {@selected_skill.health_score}/100
              </.badge>
            </div>
          </div>
          <.btn variant="ghost" size="sm" phx-click="close_drawer" aria-label="Close skill details" autofocus>
            ✕
          </.btn>
        </div>

        <%!-- Drawer body --%>
        <div style="flex: 1; padding: 16px; overflow-y: auto; display: flex; flex-direction: column; gap: 16px;">
          <%!-- Description --%>
          <section aria-labelledby="drawer-desc-heading">
            <h3
              id="drawer-desc-heading"
              style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;"
            >
              Description
            </h3>
            <p style="font-size: 13px; color: var(--ccem-fg-muted); margin: 0;">
              {if @selected_skill.description && @selected_skill.description != "",
                do: @selected_skill.description,
                else: "No description available."}
            </p>
          </section>

          <%!-- Health breakdown --%>
          <section aria-labelledby="drawer-health-heading">
            <h3
              id="drawer-health-heading"
              style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;"
            >
              Health Breakdown
            </h3>
            <div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px;">
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
              style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;"
            >
              Frontmatter
            </h3>
            <div style="background: var(--ccem-bg); border-radius: 4px; padding: 10px; font-family: monospace; font-size: 11px; display: flex; flex-direction: column; gap: 4px;">
              <div :for={{k, v} <- @selected_skill.raw_frontmatter} style="display: flex; gap: 8px;">
                <span style="color: var(--ccem-accent); font-weight: 600;">{k}:</span>
                <span style="color: var(--ccem-fg-muted); word-break: break-all;">{v}</span>
              </div>
            </div>
          </section>

          <%!-- Metadata --%>
          <section aria-labelledby="drawer-meta-heading">
            <h3
              id="drawer-meta-heading"
              style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;"
            >
              Metadata
            </h3>
            <dl style="font-size: 11px; display: flex; flex-direction: column; gap: 6px;">
              <div style="display: flex; gap: 8px;">
                <dt style="color: var(--ccem-fg-subtle); width: 128px; flex-shrink: 0;">Files:</dt>
                <dd style="font-variant-numeric: tabular-nums;">{@selected_skill.file_count}</dd>
              </div>
              <div style="display: flex; gap: 8px;">
                <dt style="color: var(--ccem-fg-subtle); width: 128px; flex-shrink: 0;">Description Quality:</dt>
                <dd>
                  <.badge tone={desc_quality_tone(@selected_skill.description_quality)}>
                    {@selected_skill.description_quality}
                  </.badge>
                </dd>
              </div>
              <div style="display: flex; gap: 8px;">
                <dt style="color: var(--ccem-fg-subtle); width: 128px; flex-shrink: 0;">Last Modified:</dt>
                <dd>{format_modified(@selected_skill.last_modified)}</dd>
              </div>
              <div style="display: flex; gap: 8px;">
                <dt style="color: var(--ccem-fg-subtle); width: 128px; flex-shrink: 0;">Has Examples:</dt>
                <dd>{if @selected_skill.has_examples, do: "Yes", else: "No"}</dd>
              </div>
              <div style="display: flex; gap: 8px;">
                <dt style="color: var(--ccem-fg-subtle); width: 128px; flex-shrink: 0;">Has Template:</dt>
                <dd>{if @selected_skill.has_template, do: "Yes", else: "No"}</dd>
              </div>
            </dl>
          </section>
        </div>

        <%!-- AgentLock Authorization Gate --%>
        <section style="padding: 12px 16px 16px; border-top: 1px solid var(--ccem-border);" aria-label="Authorization gate status">
          <h3 style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 8px;">
            AgentLock Authorization
          </h3>
          <div :if={@selected_skill.auth_gated} style="display: flex; align-items: center; gap: 8px;">
            <.badge tone="success">
              <.icon name="hero-shield-check" class="size-3" />
              Auth Gated
            </.badge>
            <span style="font-size: 11px; color: var(--ccem-fg-subtle);">agentlock_pre_tool.sh active</span>
          </div>
          <div :if={not @selected_skill.auth_gated} style="display: flex; flex-direction: column; gap: 8px;">
            <.badge tone="warning">
              <.icon name="hero-shield-exclamation" class="size-3" />
              Auth Missing
            </.badge>
            <div :if={length(@selected_skill.auth_missing_tools || []) > 0} style="display: flex; flex-wrap: wrap; gap: 4px;">
              <.badge :for={tool <- @selected_skill.auth_missing_tools || []} tone="neutral">
                {tool}
              </.badge>
            </div>
            <.btn variant="secondary" size="xs" phx-click="gate_with_agentlock" phx-value-skill={@selected_skill.name} style="width: 100%;">
              <.icon name="hero-shield-exclamation" class="size-3" />
              Gate with AgentLock
            </.btn>
          </div>
          <%!-- Recent Auth Decisions (CCEM-266) --%>
          <div :if={@agentlock_status && @agentlock_status.decision_count > 0} style="margin-top: 12px; padding-top: 8px; border-top: 1px solid color-mix(in srgb, var(--ccem-border) 50%, transparent);">
            <p style="font-size: 10px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ccem-fg-subtle); margin: 0 0 4px;">Recent Auth Decisions</p>
            <div style="display: flex; flex-direction: column; gap: 4px;">
              <div :for={decision <- @agentlock_status.recent_decisions} style="display: flex; align-items: center; gap: 4px; font-size: 11px;">
                <.badge tone={if decision.event == "authorized", do: "success", else: "warning"} dot={true}></.badge>
                <span style="font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 120px;">{decision.tool}</span>
                <span style="color: var(--ccem-fg-subtle); margin-left: auto;">{decision.event}</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- Drawer footer / actions --%>
        <div style="padding: 16px; border-top: 1px solid var(--ccem-border); flex-shrink: 0;">
          <%!-- Step: nil — Fix button or healthy indicator --%>
          <div :if={@fix_wizard_step == nil}>
            <.btn
              :if={@selected_skill.health_score < 80}
              variant="secondary"
              size="sm"
              phx-click="start_fix_wizard"
              aria-describedby="fix-hint"
              style="width: 100%;"
            >
              <.icon name="hero-wrench-screwdriver" class="size-4" />
              Fix Skill <.badge tone="iris" style="margin-left: 4px;">CCEM</.badge>
            </.btn>
            <p
              :if={@selected_skill.health_score < 80}
              id="fix-hint"
              style="font-size: 10px; color: var(--ccem-fg-subtle); margin: 4px 0 0; text-align: center;"
            >
              Guided repair for frontmatter, description, triggers, templates, and examples
            </p>
            <p :if={@selected_skill.health_score >= 80} style="font-size: 12px; color: var(--ccem-ok); text-align: center; padding: 4px 0;">
              ✓ Skill is healthy — no fixes needed
            </p>
          </div>

          <%!-- Fix Wizard Step 1: Diagnose --%>
          <div :if={@fix_wizard_step == :diagnose} style="display: flex; flex-direction: column; gap: 10px;">
            <div style="display: flex; align-items: center; gap: 4px;" role="navigation" aria-label="Fix wizard steps">
              <.btn variant="primary" size="xs" phx-click="wizard_step" phx-value-step="1" aria-current="step" aria-label="Step 1: Diagnose (current)">1 Diagnose</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="2" aria-label="Step 2: Select Repairs">2 Select</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="3" aria-label="Step 3: Preview">3 Preview</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" disabled aria-label="Step 4: Done (not yet available)">4 Done</.btn>
            </div>
            <ul style="font-size: 11px; display: flex; flex-direction: column; gap: 6px; margin: 0; padding: 0; list-style: none;" aria-label="Detected skill issues">
              <li
                :if={not @selected_skill.has_frontmatter}
                style="display: flex; align-items: center; gap: 8px; color: var(--ccem-err);"
              >
                <span aria-hidden="true">✗</span> Missing frontmatter (–30 pts)
              </li>
              <li
                :if={@selected_skill.description_quality in ["missing", "poor"]}
                style="display: flex; align-items: center; gap: 8px; color: var(--ccem-warn);"
              >
                <span aria-hidden="true">⚠</span>
                Poor description quality (–{desc_penalty(@selected_skill.description_quality)} pts)
              </li>
              <li
                :if={Map.get(@selected_skill, :trigger_count, 0) == 0}
                style="display: flex; align-items: center; gap: 8px; color: var(--ccem-warn);"
              >
                <span aria-hidden="true">⚠</span> No triggers defined (–20 pts)
              </li>
              <li :if={not @selected_skill.has_examples} style="display: flex; align-items: center; gap: 8px; color: var(--ccem-fg-subtle);">
                <span aria-hidden="true">·</span> No examples (–15 pts)
              </li>
              <li :if={not @selected_skill.has_template} style="display: flex; align-items: center; gap: 8px; color: var(--ccem-fg-subtle);">
                <span aria-hidden="true">·</span> No template (–10 pts)
              </li>
            </ul>
            <div style="display: flex; gap: 8px;">
              <.btn variant="primary" size="sm" phx-click="wizard_next" style="flex: 1;">Select Repairs →</.btn>
              <.btn variant="ghost" size="sm" phx-click="cancel_fix">Cancel</.btn>
            </div>
          </div>

          <%!-- Fix Wizard Step 2: Select --%>
          <div :if={@fix_wizard_step == :select} style="display: flex; flex-direction: column; gap: 10px;">
            <div style="display: flex; align-items: center; gap: 4px;" role="navigation" aria-label="Fix wizard steps">
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="1" aria-label="Step 1: Diagnose">1 Diagnose</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="primary" size="xs" phx-click="wizard_step" phx-value-step="2" aria-current="step" aria-label="Step 2: Select Repairs (current)">2 Select</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="3" aria-label="Step 3: Preview">3 Preview</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" disabled aria-label="Step 4: Done (not yet available)">4 Done</.btn>
            </div>
            <div style="font-size: 11px; display: flex; flex-direction: column; gap: 8px;">
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "frontmatter")}
                  phx-click="toggle_repair"
                  phx-value-repair="frontmatter"
                />
                <span>
                  Fix frontmatter
                  <%= if @selected_skill.has_frontmatter do %>
                    <.badge tone="success" style="margin-left: 4px;">OK</.badge>
                  <% else %>
                    <.badge tone="warning" style="margin-left: 4px;">needs fix</.badge>
                  <% end %>
                </span>
              </label>
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "description")}
                  phx-click="toggle_repair"
                  phx-value-repair="description"
                />
                <span>
                  Improve description
                  <%= if @selected_skill.description_quality == "good" do %>
                    <.badge tone="success" style="margin-left: 4px;">OK</.badge>
                  <% else %>
                    <.badge tone="warning" style="margin-left: 4px;">needs fix</.badge>
                  <% end %>
                </span>
              </label>
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "triggers")}
                  phx-click="toggle_repair"
                  phx-value-repair="triggers"
                />
                <span>
                  Add triggers
                  <%= if Map.get(@selected_skill, :trigger_count, 0) > 0 do %>
                    <.badge tone="success" style="margin-left: 4px;">OK (<%= Map.get(@selected_skill, :trigger_count, 0) %>)</.badge>
                  <% else %>
                    <.badge tone="warning" style="margin-left: 4px;">none</.badge>
                  <% end %>
                </span>
              </label>
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "templates")}
                  phx-click="toggle_repair"
                  phx-value-repair="templates"
                />
                <span>
                  Add templates
                  <%= if Map.get(@selected_skill, :has_templates_section, false) do %>
                    <.badge tone="success" style="margin-left: 4px;">OK</.badge>
                  <% else %>
                    <.badge tone="warning" style="margin-left: 4px;">missing</.badge>
                  <% end %>
                </span>
              </label>
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@fix_wizard_selected_repairs, "examples")}
                  phx-click="toggle_repair"
                  phx-value-repair="examples"
                />
                <span>
                  Add examples
                  <%= if Map.get(@selected_skill, :has_examples_section, false) do %>
                    <.badge tone="success" style="margin-left: 4px;">OK</.badge>
                  <% else %>
                    <.badge tone="warning" style="margin-left: 4px;">missing</.badge>
                  <% end %>
                </span>
              </label>
              <p style="font-size: 10px; color: var(--ccem-fg-subtle); margin: 0;">Items marked OK can still be re-run to regenerate.</p>
            </div>
            <div style="display: flex; gap: 8px;">
              <.btn variant="ghost" size="xs" phx-click="wizard_back">← Back</.btn>
              <.btn
                variant="primary"
                size="sm"
                phx-click="wizard_next"
                disabled={MapSet.size(@fix_wizard_selected_repairs) == 0}
                aria-disabled={to_string(MapSet.size(@fix_wizard_selected_repairs) == 0)}
                style="flex: 1;"
              >
                Preview →
              </.btn>
              <.btn variant="ghost" size="sm" phx-click="cancel_fix">Cancel</.btn>
            </div>
          </div>

          <%!-- Fix Wizard Step 3: Preview --%>
          <div :if={@fix_wizard_step == :preview} style="display: flex; flex-direction: column; gap: 10px;">
            <div style="display: flex; align-items: center; gap: 4px;" role="navigation" aria-label="Fix wizard steps">
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="1" aria-label="Step 1: Diagnose">1 Diagnose</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="2" aria-label="Step 2: Select Repairs">2 Select</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="primary" size="xs" phx-click="wizard_step" phx-value-step="3" aria-current="step" aria-label="Step 3: Preview (current)">3 Preview</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" disabled aria-label="Step 4: Done (not yet available)">4 Done</.btn>
            </div>
            <p style="font-size: 11px; color: var(--ccem-fg-muted);">
              The following repairs will run on <strong style="color: var(--ccem-fg);">{@selected_skill.name}</strong>:
            </p>
            <%!-- Async diff preview --%>
            <div :if={@fix_preview_loading} style="display: flex; align-items: center; gap: 8px; padding: 8px 0;" aria-live="polite" aria-busy="true">
              <span style="color: var(--ccem-accent);">⟳</span>
              <span style="font-size: 11px; color: var(--ccem-fg-subtle);">Loading diff preview…</span>
            </div>
            <div :if={not @fix_preview_loading and @fix_preview != nil} style="background: var(--ccem-bg); border-radius: 4px; padding: 8px; font-family: monospace; font-size: 11px; display: flex; flex-direction: column; gap: 4px;" aria-label="Diff preview" aria-live="polite">
              <div style="color: var(--ccem-fg-muted); font-family: sans-serif; margin-bottom: 4px;">{@fix_preview.summary}</div>
              <div style="color: var(--ccem-ok); font-size: 10px;">
                Health: {@fix_preview.health_before} → {@fix_preview.health_after}
              </div>
              <div :for={change <- @fix_preview.changes} style="border-left: 2px solid var(--ccem-warn); padding-left: 8px; margin-top: 4px;">
                <div style="color: var(--ccem-warn);">{change.field}: {change.issue}</div>
                <div style="color: var(--ccem-ok);">+ {change.fix}</div>
              </div>
            </div>
            <ul style="font-size: 11px; display: flex; flex-direction: column; gap: 4px; margin: 0; padding: 0; list-style: none;">
              <li
                :for={repair <- MapSet.to_list(@fix_wizard_selected_repairs)}
                style="display: flex; align-items: center; gap: 8px;"
              >
                <span style="color: var(--ccem-warn);" aria-hidden="true">→</span>
                {repair_label(repair)}
              </li>
            </ul>
            <div style="display: flex; gap: 8px;">
              <.btn variant="ghost" size="xs" phx-click="wizard_back">← Back</.btn>
              <.btn
                variant="primary"
                size="sm"
                phx-click="run_wizard_fix"
                phx-value-skill={@selected_skill.name}
                style="flex: 1;"
              >
                Run Fixes
              </.btn>
              <.btn variant="ghost" size="sm" phx-click="cancel_fix">Cancel</.btn>
            </div>
          </div>

          <%!-- Fix Wizard Step 4: Done --%>
          <div :if={@fix_wizard_step == :done} style="display: flex; flex-direction: column; gap: 10px; text-align: center;">
            <div style="display: flex; align-items: center; gap: 4px; justify-content: center;" role="navigation" aria-label="Fix wizard steps">
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="1" aria-label="Step 1: Diagnose">1 Diagnose</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="2" aria-label="Step 2: Select Repairs">2 Select</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="ghost" size="xs" phx-click="wizard_step" phx-value-step="3" aria-label="Step 3: Preview">3 Preview</.btn>
              <span style="color: var(--ccem-fg-subtle); font-size: 11px;">→</span>
              <.btn variant="primary" size="xs" aria-current="step" aria-label="Step 4: Done (current)" disabled>4 Done</.btn>
            </div>
            <div style="color: var(--ccem-ok); font-size: 24px;" aria-hidden="true">✓</div>
            <p style="font-size: 13px; font-weight: 500; color: var(--ccem-ok); margin: 0;">Fix initiated</p>
            <p style="font-size: 11px; color: var(--ccem-fg-subtle); margin: 0;">
              Repairs queued for <strong style="color: var(--ccem-fg);">{@selected_skill.name}</strong>. Run Audit All to rescan health.
            </p>
            <.btn variant="ghost" size="sm" phx-click="cancel_fix" style="width: 100%;">
              Close
            </.btn>
          </div>
        </div>
      </aside>
    </div>

    <%!-- Dry-run fix preview modal --%>
    <div :if={@show_dry_run_modal} style="position: fixed; inset: 0; z-index: 60; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,0.5);" role="dialog" aria-modal="true">
      <.card padded={true} style="width: 90%; max-width: 600px;">
        <h3 style="font-weight: 700; font-size: 16px; margin: 0 0 4px; color: var(--ccem-fg);">Fix Preview</h3>
        <p style="font-size: 13px; color: var(--ccem-fg-muted); margin: 0 0 16px;">
          Review proposed changes for <strong style="color: var(--ccem-fg);">{@dry_run_skill && @dry_run_skill.name}</strong>
        </p>
        <div style="background: var(--ccem-bg); border-radius: 6px; padding: 16px; font-family: monospace; font-size: 11px; white-space: pre-wrap; overflow: auto; max-height: 256px; border: 1px solid var(--ccem-border);">
          {@dry_run_preview}
        </div>
        <div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px;">
          <.btn variant="ghost" size="sm" phx-click="cancel_dry_run">Cancel</.btn>
          <.btn variant="primary" size="sm" phx-click="confirm_fix">
            <.icon name="hero-wrench-screwdriver" class="size-3.5" />
            Confirm & Apply Fix
          </.btn>
        </div>
      </.card>
      <div style="position: fixed; inset: 0; z-index: -1;" phx-click="cancel_dry_run"></div>
    </div>
    """
  end

  # --- Event handlers ---

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ~w(registry session ag_ui) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ~w(grid list) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("toggle_skill_select", %{"name" => name}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_skills, name),
        do: MapSet.delete(socket.assigns.selected_skills, name),
        else: MapSet.put(socket.assigns.selected_skills, name)

    {:noreply, assign(socket, :selected_skills, selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_skills, MapSet.new())}
  end

  def handle_event("batch_fix", _params, socket) do
    skills = MapSet.to_list(socket.assigns.selected_skills)

    case skills do
      [] ->
        {:noreply, socket}

      [first | _] ->
        progress = Enum.map(skills, fn name -> {name, :pending, "waiting..."} end)
        progress = List.replace_at(progress, 0, {first, :running, "fixing..."})
        parent = self()

        Task.start(fn ->
          result = ActionEngine.run_action("fix_skill_frontmatter", "", %{"skill_name" => first})
          send(parent, {:fix_step_complete, first, result})
        end)

        {:noreply,
         assign(socket,
           fix_in_progress: true,
           fix_progress: progress,
           fix_current: first
         )}
    end
  end

  def handle_event("batch_audit", _params, socket) do
    SkillsRegistryStore.refresh_all()
    {:noreply, assign(socket, audit_loading: true, selected_skills: MapSet.new())}
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

    agentlock = fetch_agentlock_status(name)

    {:noreply,
     assign(socket,
       selected_skill: skill,
       agentlock_status: agentlock,
       fix_wizard_step: nil,
       fix_preview: nil,
       fix_preview_loading: false
     )}
  end

  def handle_event("clear_selected", _params, socket) do
    {:noreply, assign(socket, selected_skill: nil, fix_wizard_step: nil, fix_preview: nil, fix_preview_loading: false)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply,
     assign(socket,
       selected_skill: nil,
       fix_wizard_step: nil,
       fix_preview: nil,
       fix_preview_loading: false
     )}
  end

  def handle_event("change_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    total = max(1, ceil(length(socket.assigns.filtered_skills) / max(socket.assigns.per_page, 1)))
    clamped = max(1, min(page, total))
    {:noreply, assign(socket, page: clamped, selected_skills: MapSet.new())}
  end

  def handle_event("select_all", _params, socket) do
    names = Enum.map(socket.assigns.filtered_skills, & &1.name) |> MapSet.new()

    selected =
      if MapSet.subset?(names, socket.assigns.selected_skills),
        do: MapSet.difference(socket.assigns.selected_skills, names),
        else: MapSet.union(socket.assigns.selected_skills, names)

    {:noreply, assign(socket, selected_skills: selected)}
  end

  def handle_event("show_dry_run", %{"skill" => skill_name}, socket) do
    skill = Enum.find(socket.assigns.registry_skills, &(&1.name == skill_name))
    preview = build_dry_run_preview(skill)

    {:noreply,
     socket
     |> assign(:show_dry_run_modal, true)
     |> assign(:dry_run_skill, skill)
     |> assign(:dry_run_preview, preview)}
  end

  def handle_event("cancel_dry_run", _params, socket) do
    {:noreply, assign(socket, show_dry_run_modal: false, dry_run_skill: nil, dry_run_preview: "")}
  end

  def handle_event("confirm_fix", _params, socket) do
    socket =
      if socket.assigns.dry_run_skill do
        assign(socket, fix_wizard_step: :diagnose, fix_wizard_selected_repairs: MapSet.new(), selected_skill: socket.assigns.dry_run_skill)
      else
        socket
      end

    {:noreply, assign(socket, show_dry_run_modal: false, dry_run_skill: nil, dry_run_preview: "")}
  end

  def handle_event("gate_with_agentlock", %{"skill" => skill_name}, socket) do
    Task.start(fn ->
      body = Jason.encode!(%{action_type: "create_authorization_hooks", params: %{skill_name: skill_name}})
      url = ~c"http://localhost:3032/api/actions/run"
      headers = [{~c"content-type", ~c"application/json"}]
      :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(body)}, [{:timeout, 5_000}], [])
    end)

    {:noreply,
     put_flash(socket, :info, "AgentLock gating initiated for #{skill_name} — check Actions for status")}
  end

  def handle_event("start_fix_wizard", _params, socket) do
    {:noreply,
     assign(socket,
       fix_wizard_step: :diagnose,
       fix_wizard_selected_repairs: MapSet.new(),
       fix_preview: nil,
       fix_preview_loading: false
     )}
  end

  def handle_event("wizard_step", %{"step" => step_str}, socket) do
    step_atom =
      case step_str do
        "1" -> :diagnose
        "2" -> :select
        "3" -> :preview
        "4" -> :done
        _ -> socket.assigns.fix_wizard_step
      end

    socket = assign(socket, fix_wizard_step: step_atom)

    socket =
      if step_atom == :preview and socket.assigns.fix_preview == nil do
        skill = socket.assigns.selected_skill
        parent = self()

        Task.start(fn ->
          preview = generate_fix_preview(skill)
          send(parent, {:fix_preview_ready, preview})
        end)

        assign(socket, fix_preview_loading: true)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("wizard_next", _params, socket) do
    next =
      case socket.assigns.fix_wizard_step do
        :diagnose -> :select
        :select -> :preview
        step -> step
      end

    socket = assign(socket, :fix_wizard_step, next)

    socket =
      if next == :preview and socket.assigns.fix_preview == nil do
        skill = socket.assigns.selected_skill
        parent = self()

        Task.start(fn ->
          preview = generate_fix_preview(skill)
          send(parent, {:fix_preview_ready, preview})
        end)

        assign(socket, fix_preview_loading: true)
      else
        socket
      end

    {:noreply, socket}
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

    if MapSet.member?(selected, "templates"),
      do: ActionEngine.run_action("add_skill_templates", "", %{"skill_name" => skill_name})

    if MapSet.member?(selected, "examples"),
      do: ActionEngine.run_action("add_skill_examples", "", %{"skill_name" => skill_name})

    {:noreply, assign(socket, :fix_wizard_step, :done)}
  end

  def handle_event("cancel_fix", _params, socket) do
    {:noreply,
     assign(socket,
       fix_wizard_step: nil,
       fix_wizard_selected_repairs: MapSet.new(),
       fix_preview: nil,
       fix_preview_loading: false
     )}
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
      |> assign(:group_by, Map.get(params, "group_by", socket.assigns.group_by))
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:search_query, "")
      |> assign(:filter_tier, "all")
      |> assign(:filter_methodology, "all")
      |> assign(:group_by, "none")
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

  # --- PubSub + async ---

  @impl true
  def handle_info({:fix_preview_ready, preview}, socket) do
    {:noreply, assign(socket, fix_preview: preview, fix_preview_loading: false)}
  end

  def handle_info({:fix_step_complete, name, _result}, socket) do
    progress = socket.assigns.fix_progress
    # Mark completed skill as done
    progress =
      Enum.map(progress, fn
        {^name, :running, _msg} -> {name, :done, "complete"}
        other -> other
      end)

    # Find next pending skill
    next =
      Enum.find(progress, fn
        {_n, :pending, _m} -> true
        _ -> false
      end)

    case next do
      {next_name, :pending, _msg} ->
        progress =
          Enum.map(progress, fn
            {^next_name, :pending, _m} -> {next_name, :running, "fixing..."}
            other -> other
          end)

        parent = self()

        Task.start(fn ->
          result = ActionEngine.run_action("fix_skill_frontmatter", "", %{"skill_name" => next_name})
          send(parent, {:fix_step_complete, next_name, result})
        end)

        {:noreply, assign(socket, fix_progress: progress, fix_current: next_name)}

      nil ->
        # All done
        {:noreply, assign(socket, fix_progress: progress, fix_in_progress: false, fix_current: nil)}
    end
  end

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
  attr :selected_skills, :any, default: nil

  defp skill_tier_cards(assigns) do
    assigns = assign(assigns, :selected_skills, assigns[:selected_skills] || MapSet.new())

    ~H"""
    <section
      :if={@skills != []}
      aria-labelledby={"tier-heading-#{@tier}"}
      style="margin-bottom: 8px;"
    >
      <button
        id={"tier-heading-#{@tier}"}
        style={"width: 100%; display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; border-radius: 6px; border: none; cursor: pointer; background: var(--ccem-surface); font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: #{tier_color(@tier)};"}
        phx-click="toggle_tier"
        phx-value-tier={@tier}
        aria-expanded={to_string(not @collapsed)}
        aria-controls={"tier-grid-#{@tier}"}
      >
        <span style="display: flex; align-items: center; gap: 8px;">
          <span>{tier_label(@tier)}</span>
          <.badge tone={tier_badge_tone(@tier)}>{to_string(length(@skills))}</.badge>
        </span>
        <span aria-hidden="true">{if @collapsed, do: "▶", else: "▼"}</span>
      </button>

      <div
        :if={not @collapsed}
        id={"tier-grid-#{@tier}"}
        role="list"
        style="display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 10px; margin-top: 8px;"
      >
        <.skill_card :for={skill <- @skills} skill={skill} selected_skill={@selected} selected_skills={@selected_skills} />
      </div>
    </section>
    """
  end

  attr :skill, :map, required: true
  attr :selected_skill, :any, default: nil
  attr :selected_skills, :any, default: nil

  defp skill_card(assigns) do
    assigns = assign(assigns, :selected_skills, assigns[:selected_skills] || MapSet.new())

    ~H"""
    <article
      role="listitem"
      style={"padding: 12px; border-radius: 6px; background: var(--ccem-surface); border: 1px solid #{if @selected_skill && @selected_skill.name == @skill.name, do: "var(--ccem-accent)", else: "var(--ccem-border)"}; cursor: pointer; #{if MapSet.member?(@selected_skills, @skill.name), do: "outline: 1px solid color-mix(in srgb, var(--ccem-accent) 40%, transparent);", else: ""}"}
      phx-click="select_skill"
      phx-value-name={@skill.name}
      tabindex="0"
      phx-keydown={JS.push("select_skill", value: %{name: @skill.name})}
      phx-key="Enter"
      aria-label={"#{@skill.name}: #{health_label(@skill.health_score)}, score #{@skill.health_score}"}
    >
      <div style="display: flex; align-items: flex-start; gap: 10px;">
        <div style="flex-shrink: 0; margin-top: 2px;">
          <input
            type="checkbox"
            checked={MapSet.member?(@selected_skills, @skill.name)}
            phx-click="toggle_skill_select"
            phx-value-name={@skill.name}
          />
        </div>
        <div style="flex-shrink: 0; margin-top: 0;">
          {health_ring(@skill.health_score)}
        </div>
        <div style="flex: 1; min-width: 0;">
          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 4px;">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{@skill.name}</span>
          </div>
          <p style="font-size: 11px; color: var(--ccem-fg-muted); margin: 0 0 8px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;">
            {@skill.description || "No description"}
          </p>
          <div style="display: flex; align-items: center; gap: 4px; flex-wrap: wrap;">
            <.badge tone={desc_quality_tone(@skill.description_quality)}>
              {@skill.description_quality}
            </.badge>
            <span style="font-size: 10px; color: var(--ccem-fg-subtle);">
              {format_modified(@skill.last_modified)}
            </span>
          </div>
        </div>
      </div>
    </article>
    """
  end

  attr :skills, :list, required: true
  attr :selected_skills, :any, required: true
  attr :selected_skill, :any, default: nil

  defp skill_list_view(assigns) do
    ~H"""
    <.data_table id="skills-list-table" rows={@skills}>
      <:col :let={row} label="">
        <input
          type="checkbox"
          checked={MapSet.member?(@selected_skills, row.name)}
          phx-click="toggle_skill_select"
          phx-value-name={row.name}
        />
      </:col>
      <:col :let={row} label="Name">
        <span
          style="font-family: monospace; font-size: 11px; color: var(--ccem-fg); cursor: pointer;"
          phx-click="select_skill"
          phx-value-name={row.name}
        >{row.name}</span>
      </:col>
      <:col :let={row} label="Tier">
        <.badge tone={skill_tier_tone(row)}>{skill_tier_label(row)}</.badge>
      </:col>
      <:col :let={row} label="Health">
        <span style="font-variant-numeric: tabular-nums;">{row.health_score || "-"}</span>
      </:col>
      <:col :let={row} label="Source">
        <span style="font-size: 11px; color: var(--ccem-fg-subtle);">{Map.get(row, :source, "user")}</span>
      </:col>
      <:col :let={row} label="Triggers">
        <span style="font-variant-numeric: tabular-nums;">{Map.get(row, :trigger_count, 0)}</span>
      </:col>
      <:col :let={row} label="Description">
        <span style="font-size: 11px; color: var(--ccem-fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: block; max-width: 240px;">{row.description || "-"}</span>
      </:col>
    </.data_table>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true

  defp health_bar(assigns) do
    ~H"""
    <div style="text-align: center;">
      <div style="font-size: 10px; color: var(--ccem-fg-subtle); margin-bottom: 4px;">{@label}</div>
      <div
        style="width: 100%; background: var(--ccem-bg); border-radius: 9999px; height: 6px;"
        role="progressbar"
        aria-valuenow={@value}
        aria-valuemin={0}
        aria-valuemax={@max}
        aria-label={@label}
      >
        <div
          style={"height: 6px; border-radius: 9999px; width: #{if @max > 0, do: round(@value / @max * 100), else: 0}%; background: #{cond do @value == @max -> "var(--ccem-ok)"; @value > 0 -> "var(--ccem-warn)"; true -> "var(--ccem-bg)" end};"}
        ></div>
      </div>
      <div style="font-size: 10px; color: var(--ccem-fg-subtle); margin-top: 4px;">{@value}/{@max}</div>
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

  defp group_skills(skills, "tier") do
    skills
    |> Enum.group_by(fn skill ->
      cond do
        skill.health_score >= 80 -> "Healthy"
        skill.health_score >= 50 -> "Needs Attention"
        true -> "Critical"
      end
    end)
    |> Enum.sort_by(fn {group, _} ->
      case group do
        "Critical" -> 0
        "Needs Attention" -> 1
        "Healthy" -> 2
        _ -> 3
      end
    end)
  end

  defp group_skills(skills, "source") do
    skills
    |> Enum.group_by(fn skill -> Map.get(skill, :source, "user") |> to_string() end)
    |> Enum.sort_by(fn {group, _} -> group end)
  end

  defp group_skills(skills, "methodology") do
    skills
    |> Enum.group_by(fn skill ->
      case methodology_for_skill(skill.name) do
        nil -> "None"
        m -> m |> to_string() |> String.capitalize()
      end
    end)
    |> Enum.sort_by(fn {group, _} -> group end)
  end

  defp group_skills(skills, _), do: [{"All", skills}]

  defp skill_tier_tone(skill) do
    cond do
      skill.health_score >= 80 -> "success"
      skill.health_score >= 50 -> "warning"
      true -> "error"
    end
  end

  defp skill_tier_label(skill) do
    cond do
      skill.health_score >= 80 -> "healthy"
      skill.health_score >= 50 -> "attention"
      true -> "critical"
    end
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
      assigns.filter_methodology != "all",
      assigns.group_by != "none"
    ]
    |> Enum.count(& &1)
  end

  defp tier_label(:healthy), do: "Healthy"
  defp tier_label(:needs_attention), do: "Needs Attention"
  defp tier_label(:critical), do: "Critical"

  defp tier_badge_tone(:healthy), do: "success"
  defp tier_badge_tone(:needs_attention), do: "warning"
  defp tier_badge_tone(:critical), do: "error"

  defp tier_color(:healthy), do: "var(--ccem-ok)"
  defp tier_color(:needs_attention), do: "var(--ccem-warn)"
  defp tier_color(:critical), do: "var(--ccem-err)"

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

  defp methodology_tone(:ralph), do: "success"
  defp methodology_tone(:tdd), do: "info"
  defp methodology_tone(:elixir_architect), do: "accent"
  defp methodology_tone(_), do: "neutral"

  defp methodology_for_skill("ralph"), do: :ralph
  defp methodology_for_skill("tdd:spawn"), do: :tdd
  defp methodology_for_skill("spawn"), do: :tdd
  defp methodology_for_skill("elixir-architect"), do: :elixir_architect
  defp methodology_for_skill(_), do: nil

  defp source_tone(:observed), do: "success"
  defp source_tone(:filesystem), do: "neutral"
  defp source_tone(_), do: "neutral"

  defp health_tone(score) when score >= 80, do: "success"
  defp health_tone(score) when score >= 50, do: "warning"
  defp health_tone(_), do: "error"

  defp health_label(score) when score >= 80, do: "healthy"
  defp health_label(score) when score >= 50, do: "needs attention"
  defp health_label(_), do: "critical"

  defp desc_score("good"), do: 25
  defp desc_score("truncated"), do: 10
  defp desc_score(_), do: 0

  defp desc_quality_tone("good"), do: "success"
  defp desc_quality_tone("truncated"), do: "warning"
  defp desc_quality_tone(_), do: "error"

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
  defp repair_label("templates"), do: "Generate skill templates"
  defp repair_label("examples"), do: "Generate usage examples"
  defp repair_label(r), do: "Fix #{r}"

  # AG-UI helpers

  defp ag_ui_status_label(score) when score >= 80, do: "Connected"
  defp ag_ui_status_label(score) when score >= 50, do: "Degraded"
  defp ag_ui_status_label(_), do: "Broken"

  defp ag_ui_border_color(score) when score >= 80, do: "color-mix(in srgb, var(--ccem-ok) 30%, transparent)"
  defp ag_ui_border_color(score) when score >= 50, do: "color-mix(in srgb, var(--ccem-warn) 30%, transparent)"
  defp ag_ui_border_color(_), do: "color-mix(in srgb, var(--ccem-err) 30%, transparent)"

  defp ag_ui_dot_color(score) when score >= 80, do: "var(--ccem-ok)"
  defp ag_ui_dot_color(score) when score >= 50, do: "var(--ccem-warn)"
  defp ag_ui_dot_color(_), do: "var(--ccem-err)"

  defp ag_ui_text_color(score) when score >= 80, do: "var(--ccem-ok)"
  defp ag_ui_text_color(score) when score >= 50, do: "var(--ccem-warn)"
  defp ag_ui_text_color(_), do: "var(--ccem-err)"

  defp build_dry_run_preview(nil), do: "No skill selected."

  defp build_dry_run_preview(skill) do
    issues =
      []
      |> then(fn acc -> if skill.has_frontmatter, do: acc, else: ["- Add YAML frontmatter (name, description, version)" | acc] end)
      |> then(fn acc -> if skill.description_quality == "good", do: acc, else: ["- Expand description to 100+ chars with trigger keywords" | acc] end)
      |> then(fn acc -> if skill.has_examples, do: acc, else: ["- Create examples/ subdirectory with sample invocations" | acc] end)
      |> then(fn acc -> if skill.has_template, do: acc, else: ["- Create template.md file" | acc] end)
      |> then(fn acc ->
          missing = skill.auth_missing_tools || []
          if skill.auth_gated or missing == [], do: acc, else: ["- Gate high-risk tools (#{Enum.join(missing, ", ")}) with AgentLock" | acc]
        end)
      |> Enum.reverse()

    header = "Proposed changes for: #{skill.name} (score: #{skill.health_score}/100)\n\n"

    if issues == [] do
      header <> "No fixes required — skill health is good."
    else
      header <> Enum.join(issues, "\n")
    end
  end

  defp generate_fix_preview(nil),
    do: %{
      changes: [],
      summary: "No skill selected",
      health_before: 0,
      health_after: 0,
      skill_name: "",
      skill_path: ""
    }

  defp generate_fix_preview(skill) do
    skill_path = Map.get(skill, :path, "")
    health = Map.get(skill, :health_score, 0)

    changes =
      []
      |> then(fn acc ->
        if not Map.get(skill, :has_frontmatter, true) do
          [%{field: "frontmatter", issue: "Missing YAML frontmatter", fix: "Add name/description/version header"} | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        quality = Map.get(skill, :description_quality, "good")

        if quality in ["missing", "poor"] do
          [%{field: "description", issue: "Description too short or missing", fix: "Add comprehensive description with 100+ chars"} | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        trigger_count = Map.get(skill, :trigger_count, 0)
        has_triggers = Map.get(skill, :has_triggers, trigger_count > 0)

        if not has_triggers or trigger_count == 0 do
          [%{field: "triggers", issue: "No trigger keywords defined", fix: "Add relevant trigger keywords"} | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        if not Map.get(skill, :has_templates_section, false) do
          [%{field: "templates", issue: "No templates section in SKILL.md", fix: "Generate skill templates and boilerplate"} | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        if not Map.get(skill, :has_examples_section, false) do
          [%{field: "examples", issue: "No examples section in SKILL.md", fix: "Generate usage examples"} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    %{
      skill_name: Map.get(skill, :name, ""),
      skill_path: skill_path,
      health_before: health,
      health_after: min(health + length(changes) * 15, 100),
      changes: changes,
      summary: "#{length(changes)} improvement#{if length(changes) == 1, do: "", else: "s"} identified"
    }
  end

  # -- AgentLock status for skill inspector (CCEM-266) -------------------------

  defp fetch_agentlock_status(skill_name) do
    # Check if skill has associated hooks with AgentLock protection
    hooks_protected =
      try do
        settings_path = Path.join([System.get_env("HOME"), ".claude", "settings.json"])

        case File.read(settings_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, settings} ->
                hooks = Map.get(settings, "hooks", %{})

                Enum.any?(hooks, fn {_event, hook_list} ->
                  hook_list
                  |> List.wrap()
                  |> Enum.any?(fn hook ->
                    command = Map.get(hook, "command", "")
                    String.contains?(command, "agentlock")
                  end)
                end)

              _ ->
                false
            end

          _ ->
            false
        end
      rescue
        _ -> false
      end

    # Fetch recent auth decisions related to this skill's tools
    recent_decisions =
      try do
        audit = Apm.AuditLog.tail(20)

        audit
        |> Enum.filter(fn entry ->
          resource = Map.get(entry, :resource, "")
          String.contains?(to_string(resource), skill_name)
        end)
        |> Enum.take(5)
        |> Enum.map(fn entry ->
          %{
            event: Map.get(entry, :event_type, "unknown"),
            tool: Map.get(entry, :resource, "unknown"),
            timestamp: Map.get(entry, :timestamp, ""),
            actor: Map.get(entry, :actor, "unknown")
          }
        end)
      rescue
        _ -> []
      end

    %{
      hooks_protected: hooks_protected,
      recent_decisions: recent_decisions,
      decision_count: length(recent_decisions)
    }
  end

end
