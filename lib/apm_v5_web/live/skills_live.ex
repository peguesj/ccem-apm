defmodule ApmV5Web.SkillsLive do
  @moduledoc """
  LiveView for skills tracking, UEBA analytics, and Skills Registry health dashboard.

  Tabs:
  - Registry: health tier list (healthy/needs_attention/critical), Audit All, Fix buttons
  - Session:  active skills, catalog, co-occurrence matrix
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
      # US-021: EventBus subscription for AG-UI events
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
      |> assign(:selected_skill, nil)
      |> assign(:audit_loading, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <.sidebar_nav current_path="/skills" skill_count={@active_skill_count} />

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Skills</h2>
            <div class="tabs tabs-boxed tabs-xs bg-base-300">
              <button class={["tab", @tab == :registry && "tab-active"]} phx-click="set_tab" phx-value-tab="registry">
                Registry
              </button>
              <button class={["tab", @tab == :session && "tab-active"]} phx-click="set_tab" phx-value-tab="session">
                Session
              </button>
              <button class={["tab", @tab == :ag_ui && "tab-active"]} phx-click="set_tab" phx-value-tab="ag_ui">
                AG-UI
              </button>
            </div>
          </div>
          <div :if={@tab == :registry} class="flex items-center gap-2">
            <button
              class={["btn btn-xs btn-primary", @audit_loading && "loading"]}
              phx-click="audit_all"
              disabled={@audit_loading}
            >
              {if @audit_loading, do: "Scanning…", else: "Audit All"}
            </button>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 overflow-y-auto p-4">
          <%!-- Registry Tab --%>
          <div :if={@tab == :registry} class="space-y-6">
            <%!-- Summary stats --%>
            <div class="stats shadow bg-base-200 w-full">
              <div class="stat">
                <div class="stat-title">Total Skills</div>
                <div class="stat-value text-2xl">{length(@registry_skills)}</div>
              </div>
              <div class="stat">
                <div class="stat-title">Healthy</div>
                <div class="stat-value text-2xl text-success">{Enum.count(@registry_skills, &(&1.health_score >= 80))}</div>
                <div class="stat-desc">score ≥ 80</div>
              </div>
              <div class="stat">
                <div class="stat-title">Needs Attention</div>
                <div class="stat-value text-2xl text-warning">{Enum.count(@registry_skills, &(&1.health_score in 50..79))}</div>
                <div class="stat-desc">score 50–79</div>
              </div>
              <div class="stat">
                <div class="stat-title">Critical</div>
                <div class="stat-value text-2xl text-error">{Enum.count(@registry_skills, &(&1.health_score < 50))}</div>
                <div class="stat-desc">score &lt; 50</div>
              </div>
            </div>

            <%!-- Detail panel --%>
            <div :if={@selected_skill} class="card bg-base-200 border border-base-300 p-4 mb-4">
              <div class="flex items-start justify-between mb-3">
                <div>
                  <h3 class="font-semibold text-base">{@selected_skill.name}</h3>
                  <p class="text-xs text-base-content/60 mt-1">{@selected_skill.description}</p>
                </div>
                <div class="flex items-center gap-2">
                  <span class={["badge badge-sm", health_badge_class(@selected_skill.health_score)]}>
                    {health_label(@selected_skill.health_score)}
                  </span>
                  <div class="text-2xl font-bold tabular-nums">{@selected_skill.health_score}</div>
                  <button class="btn btn-ghost btn-xs" phx-click="clear_selected">✕</button>
                </div>
              </div>
              <div class="grid grid-cols-5 gap-2 mb-3">
                <.health_bar label="Frontmatter" value={if @selected_skill.has_frontmatter, do: 30, else: 0} max={30} />
                <.health_bar label="Description" value={desc_score(@selected_skill.description_quality)} max={25} />
                <.health_bar label="Triggers" value={min(Map.get(@selected_skill, :trigger_count, 0) * 7, 20)} max={20} />
                <.health_bar label="Examples" value={if @selected_skill.has_examples, do: 15, else: 0} max={15} />
                <.health_bar label="Template" value={if @selected_skill.has_template, do: 10, else: 0} max={10} />
              </div>
              <div :if={@selected_skill.raw_frontmatter != %{}} class="bg-base-300 rounded p-2 text-xs font-mono">
                <div :for={{k, v} <- @selected_skill.raw_frontmatter}>{k}: {v}</div>
              </div>
            </div>

            <%!-- Three-tier health list --%>
            <.skill_tier
              title="Healthy"
              color="success"
              skills={Enum.filter(@registry_skills, &(&1.health_score >= 80))}
              selected={@selected_skill}
            />
            <.skill_tier
              title="Needs Attention"
              color="warning"
              skills={Enum.filter(@registry_skills, &(&1.health_score in 50..79))}
              selected={@selected_skill}
            />
            <.skill_tier
              title="Critical"
              color="error"
              skills={Enum.filter(@registry_skills, &(&1.health_score < 50))}
              selected={@selected_skill}
            />

            <div :if={@registry_skills == []} class="text-center py-12 text-base-content/30">
              <p>No skills found in ~/.claude/skills/</p>
              <button class="btn btn-primary btn-sm mt-4" phx-click="audit_all">Scan Now</button>
            </div>
          </div>

          <%!-- Session Tab --%>
          <div :if={@tab == :session} class="space-y-6">
            <section>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Active Session Skills
              </h3>
              <div :if={@session_skills == %{}} class="text-sm text-base-content/30 py-4">
                No skills invoked in current session.
              </div>
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
                <div
                  :for={{skill, data} <- @session_skills}
                  class="card bg-base-200 border border-base-300 p-3"
                >
                  <div class="flex items-center justify-between mb-1">
                    <span class="text-sm font-medium truncate">{skill}</span>
                    <span class="badge badge-xs badge-primary">{data.count}x</span>
                  </div>
                  <div class="text-[10px] text-base-content/40">Last: {format_time(data.last_seen)}</div>
                  <div :if={methodology_for_skill(skill)} class="mt-1">
                    <span class={["badge badge-xs", methodology_badge(methodology_for_skill(skill))]}>
                      {methodology_for_skill(skill)}
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <section>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Skill Catalog
              </h3>
              <div class="overflow-x-auto">
                <table class="table table-xs w-full">
                  <thead>
                    <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                      <th>Skill</th>
                      <th class="text-right">Total Invocations</th>
                      <th class="text-right">Sessions</th>
                      <th>Source</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{skill, data} <- Enum.sort_by(@catalog, fn {_k, v} -> -v.total_count end)} class="hover">
                      <td class="font-medium">{skill}</td>
                      <td class="text-right tabular-nums">{data.total_count}</td>
                      <td class="text-right tabular-nums">{data.session_count}</td>
                      <td>
                        <span class={["badge badge-xs", source_badge(data.source)]}>{data.source}</span>
                      </td>
                    </tr>
                    <tr :if={@catalog == %{}}>
                      <td colspan="4" class="text-center text-base-content/30 py-6">No skills tracked yet</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section :if={@co_occurrence != %{}}>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Skill Co-occurrence
              </h3>
              <div class="overflow-x-auto">
                <table class="table table-xs w-full">
                  <thead>
                    <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                      <th>Skill A</th><th>Skill B</th><th class="text-right">Sessions Together</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{{a, b}, count} <- Enum.sort_by(@co_occurrence, fn {_k, v} -> -v end)} class="hover">
                      <td>{a}</td><td>{b}</td><td class="text-right tabular-nums">{count}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </div>

          <%!-- AG-UI Tab --%>
          <div :if={@tab == :ag_ui} class="space-y-6">
            <section>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Skills as AG-UI Event Emitters
              </h3>
              <p class="text-sm text-base-content/60 mb-4">
                Skills emit AG-UI events when invoked. Each skill connection shows event emission status.
              </p>
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
                <div
                  :for={skill <- @registry_skills}
                  class="card bg-base-200 border border-base-300 p-3"
                >
                  <div class="flex items-center justify-between mb-1">
                    <span class="text-sm font-medium truncate">{skill.name}</span>
                    <div class={["w-2 h-2 rounded-full", if(skill.health_score >= 80, do: "bg-success", else: "bg-base-content/20")]}></div>
                  </div>
                  <div class="text-[10px] text-base-content/40 mb-2">
                    {if skill.health_score >= 80, do: "Connected", else: "Disconnected"}
                  </div>
                  <div class="flex gap-1 flex-wrap">
                    <span class="badge badge-xs badge-ghost">CUSTOM</span>
                    <span :if={skill.has_frontmatter} class="badge badge-xs badge-success badge-outline">valid</span>
                  </div>
                </div>
                <div :if={@registry_skills == []} class="col-span-full text-center text-base-content/30 py-8">
                  No skills registered. Run Audit All to scan.
                </div>
              </div>
            </section>

            <section>
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Hook Repair
                </h3>
                <button
                  phx-click="repair_hooks"
                  class="btn btn-xs btn-warning"
                >
                  <.icon name="hero-wrench-screwdriver" class="size-3" /> Repair Hooks
                </button>
              </div>
              <p class="text-xs text-base-content/50">
                Triggers restart-to-reload action to repair broken skill hooks and re-deploy AG-UI event bridge.
              </p>
            </section>
          </div>
        </div>
      </div>
    </div>
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

    {:noreply, assign(socket, :selected_skill, skill)}
  end

  def handle_event("clear_selected", _params, socket) do
    {:noreply, assign(socket, :selected_skill, nil)}
  end

  def handle_event("fix_frontmatter", %{"skill" => skill_name}, socket) do
    ActionEngine.run_action("fix_skill_frontmatter", "", %{"skill_name" => skill_name})
    {:noreply, socket}
  end

  def handle_event("repair_hooks", _params, socket) do
    ActionEngine.run_action("update_hooks", "", %{})
    {:noreply, socket}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:skill_tracked, _session_id, _skill_name}, socket) do
    active_session = socket.assigns.active_session
    session_skills = if active_session, do: SkillTracker.get_session_skills(active_session), else: %{}
    catalog = SkillTracker.get_skill_catalog()
    co_occurrence = SkillTracker.get_co_occurrence()
    methodology = if active_session, do: SkillTracker.active_methodology(active_session)

    registry_skills = SkillsRegistryStore.list_skills()

    {:noreply,
     socket
     |> assign(:session_skills, session_skills)
     |> assign(:catalog, catalog)
     |> assign(:co_occurrence, co_occurrence)
     |> assign(:methodology, methodology)
     |> assign(:active_skill_count, map_size(session_skills))
     |> assign(:registry_skills, registry_skills)
     |> assign(:audit_loading, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Components ---

  attr :title, :string, required: true
  attr :color, :string, required: true
  attr :skills, :list, required: true
  attr :selected, :any, default: nil

  defp skill_tier(assigns) do
    ~H"""
    <section :if={@skills != []}>
      <h3 class={["text-xs font-semibold uppercase tracking-wider mb-3", "text-#{@color}"]}>
        {@title} ({length(@skills)})
      </h3>
      <div class="overflow-x-auto">
        <table class="table table-xs w-full">
          <thead>
            <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
              <th>Skill</th>
              <th class="text-right">Score</th>
              <th>Quality</th>
              <th>Files</th>
              <th>Last Modified</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={skill <- @skills}
              class={["hover cursor-pointer", @selected && @selected.name == skill.name && "bg-primary/10"]}
              phx-click="select_skill"
              phx-value-name={skill.name}
            >
              <td class="font-medium">{skill.name}</td>
              <td class="text-right">
                <span class={["badge badge-xs", health_badge_class(skill.health_score)]}>
                  {skill.health_score}
                </span>
              </td>
              <td>
                <span class={["badge badge-xs", desc_quality_badge(skill.description_quality)]}>
                  {skill.description_quality}
                </span>
              </td>
              <td class="tabular-nums">{skill.file_count}</td>
              <td class="text-base-content/40">{format_modified(skill.last_modified)}</td>
              <td>
                <button
                  :if={skill.health_score < 80}
                  class="btn btn-xs btn-ghost"
                  phx-click="fix_frontmatter"
                  phx-value-skill={skill.name}
                  title="Fix Frontmatter"
                >
                  Fix
                </button>
              </td>
            </tr>
          </tbody>
        </table>
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
      <div class="w-full bg-base-300 rounded-full h-2">
        <div
          class={["h-2 rounded-full", @value == @max && "bg-success", @value > 0 && @value < @max && "bg-warning", @value == 0 && "bg-base-300"]}
          style={"width: #{if @max > 0, do: round(@value / @max * 100), else: 0}%"}
        ></div>
      </div>
      <div class="text-[10px] text-base-content/50 mt-1">{@value}/{@max}</div>
    </div>
    """
  end

  # --- Helpers ---

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

  defp format_modified(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86400)}d ago"
        end

      _ ->
        "—"
    end
  end

  defp format_modified(_), do: "—"
end
