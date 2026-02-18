defmodule ApmV4Web.SkillsLive do
  @moduledoc """
  LiveView for skills tracking and UEBA analytics.

  Displays active skills, skill catalog, co-occurrence matrix,
  and methodology detection with real-time PubSub updates.
  """

  use ApmV4Web, :live_view

  alias ApmV4.SkillTracker
  alias ApmV4.ConfigLoader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:skills")
    end

    active_session = current_session_id()
    session_skills = if active_session, do: SkillTracker.get_session_skills(active_session), else: %{}
    catalog = SkillTracker.get_skill_catalog()
    co_occurrence = SkillTracker.get_co_occurrence()
    methodology = if active_session, do: SkillTracker.active_methodology(active_session)

    socket =
      socket
      |> assign(:page_title, "Skills")
      |> assign(:active_nav, :skills)
      |> assign(:active_session, active_session)
      |> assign(:session_skills, session_skills)
      |> assign(:catalog, catalog)
      |> assign(:co_occurrence, co_occurrence)
      |> assign(:methodology, methodology)
      |> assign(:active_skill_count, map_size(session_skills))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-sparkles" label="Skills" active={true} href="/skills" badge={@active_skill_count} />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Skills Tracking</h2>
            <div :if={@methodology} class={["badge badge-sm", methodology_badge(@methodology)]}>
              {@methodology}
            </div>
            <div class="badge badge-sm badge-ghost">
              {map_size(@catalog)} known skills
            </div>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-6">
          <%!-- Active Skills --%>
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
                <div class="text-[10px] text-base-content/40">
                  Last: {format_time(data.last_seen)}
                </div>
                <div :if={methodology_for_skill(skill)} class="mt-1">
                  <span class={["badge badge-xs", methodology_badge(methodology_for_skill(skill))]}>
                    {methodology_for_skill(skill)}
                  </span>
                </div>
              </div>
            </div>
          </section>

          <%!-- Skill Catalog --%>
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
                      <span class={["badge badge-xs", source_badge(data.source)]}>
                        {data.source}
                      </span>
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

          <%!-- Co-occurrence Matrix --%>
          <section :if={@co_occurrence != %{}}>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
              Skill Co-occurrence
            </h3>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                    <th>Skill A</th>
                    <th>Skill B</th>
                    <th class="text-right">Sessions Together</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{{a, b}, count} <- Enum.sort_by(@co_occurrence, fn {_k, v} -> -v end)} class="hover">
                    <td>{a}</td>
                    <td>{b}</td>
                    <td class="text-right tabular-nums">{count}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <%!-- Ralph Integration --%>
          <section>
            <div class="card bg-base-200 border border-base-300 p-4">
              <div class="flex items-center justify-between">
                <div>
                  <h3 class="text-sm font-semibold">Ralph Methodology</h3>
                  <p class="text-xs text-base-content/50 mt-1">
                    Ralph is a sub-feature of Skills. View the PRD flowchart for detailed story tracking.
                  </p>
                </div>
                <a href="/ralph" class="btn btn-primary btn-sm">
                  Open Flowchart
                </a>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  # --- PubSub ---

  @impl true
  def handle_info({:skill_tracked, _session_id, _skill_name}, socket) do
    active_session = socket.assigns.active_session
    session_skills = if active_session, do: SkillTracker.get_session_skills(active_session), else: %{}
    catalog = SkillTracker.get_skill_catalog()
    co_occurrence = SkillTracker.get_co_occurrence()
    methodology = if active_session, do: SkillTracker.active_methodology(active_session)

    {:noreply,
     socket
     |> assign(:session_skills, session_skills)
     |> assign(:catalog, catalog)
     |> assign(:co_occurrence, co_occurrence)
     |> assign(:methodology, methodology)
     |> assign(:active_skill_count, map_size(session_skills))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
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
  defp methodology_badge(:custom), do: "badge-ghost"
  defp methodology_badge(_), do: "badge-ghost"

  defp methodology_for_skill("ralph"), do: :ralph
  defp methodology_for_skill("tdd:spawn"), do: :tdd
  defp methodology_for_skill("spawn"), do: :tdd
  defp methodology_for_skill("elixir-architect"), do: :elixir_architect
  defp methodology_for_skill(_), do: nil

  defp source_badge(:observed), do: "badge-success"
  defp source_badge(:filesystem), do: "badge-ghost"
  defp source_badge(_), do: "badge-ghost"
end
