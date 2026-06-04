defmodule ApmWeb.Components.SidebarNav do
  @moduledoc """
  Shared sidebar navigation component for all LiveViews.

  Organized into 6 sections matching the v9.1.3 redesign taxonomy:

  1. **OBSERVE**       — live monitoring surfaces (Dashboard, Fleet, Sessions, Conversations,
     Formations, Timeline, Tool Calls, A2A, Architecture)
  2. **GOVERN**        — policies/approvals (Authorization, Routing, Approvals, Coalesce, UPM)
  3. **MEASURE**       — metrics/usage (Analytics, Usage, Health, Ports, Tasks, Actions,
     Scanner, UAT, DRTW)
  4. **INTELLIGENCE**  — AI/knowledge (Skills, Skill Drift, Library, Memory, Orchestration,
     Intake, Alignment)
  5. **EXTEND**        — extensions (Plugins ▸ sub-items, Integrations ▸ sub-items,
     Notifications, Showcase, Docs)
  6. **AI PLATFORM**   — AI capabilities (All Projects, AG-UI, Ralph, Generative UI)

  Sections with sub-items (Plugins, Integrations) show a chevron caret on the parent
  row and are collapsible via client-side JS with localStorage persistence.

  The `plugins` and `integrations` attrs are populated via `assign_sidebar_nav_data/1`,
  which safely polls the registries with try/rescue guards.
  """
  use Phoenix.Component
  import ApmWeb.CoreComponents, only: [icon: 1]

  attr :current_path, :string, required: true
  attr :notification_count, :integer, default: 0
  attr :skill_count, :integer, default: 0
  attr :plugins, :list, default: []
  attr :integrations, :list, default: []

  def sidebar_nav(assigns) do
    plugins = if assigns[:plugins] in [nil, []], do: safe_list_plugins(), else: assigns[:plugins]
    integrations = if assigns[:integrations] in [nil, []], do: safe_list_integrations(), else: assigns[:integrations]

    assigns =
      assigns
      |> assign(:plugins, plugins)
      |> assign(:integrations, integrations)
      |> assign(:version, version())

    ~H"""
    <aside
      id="apm-sidebar"
      class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0 h-screen sticky top-0 overflow-hidden"
    >
      <%!-- Brand header REMOVED CP-331 (US-511): wordmark canonical in top_bar.ex; sidebar retains collapse control + version --%>
      <div class="p-2 border-b border-base-300 flex-shrink-0">
        <div class="flex items-center justify-between gap-2">
          <span class="text-xs text-base-content/40 sidebar-label sidebar-version font-mono">v{@version}</span>
          <button
            onclick="window.apmSidebar.toggle()"
            class="btn btn-ghost btn-xs p-0.5 flex-shrink-0 text-base-content/40 hover:text-base-content"
            title="Toggle sidebar"
          >
            <.icon name="hero-chevron-left" class="size-3 sidebar-arrow-collapse" />
            <.icon name="hero-chevron-right" class="size-3 sidebar-arrow-expand" />
          </button>
        </div>
      </div>

      <%!-- Scrollable nav body --%>
      <nav class="flex-1 p-2 space-y-0.5 overflow-y-auto" aria-label="Main navigation">
        <.observe_nav current_path={@current_path} />
        <.govern_nav current_path={@current_path} />
        <.measure_nav current_path={@current_path} />
        <.intelligence_nav current_path={@current_path} skill_count={@skill_count} />
        <.extend_nav
          current_path={@current_path}
          notification_count={@notification_count}
          plugins={@plugins}
          integrations={@integrations}
        />
        <.ai_platform_nav current_path={@current_path} />
      </nav>
    </aside>
    """
  end

  # ── Section: OBSERVE ─────────────────────────────────────────────────────────
  attr :current_path, :string, required: true

  defp observe_nav(assigns) do
    ~H"""
    <.section_header label="Observe" />
    <.nav_item icon="hero-squares-2x2"          label="Dashboard"     href="/"             current_path={@current_path} />
    <.nav_item icon="hero-user-group"           label="Fleet"         href="/fleet"        current_path={@current_path} />
    <.nav_item icon="hero-computer-desktop"     label="Sessions"      href="/sessions"     current_path={@current_path} />
    <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" href="/conversations" current_path={@current_path} />
    <.nav_item icon="hero-rectangle-group"      label="Formations"    href="/formation"    current_path={@current_path} />
    <.nav_item icon="hero-clock"                label="Timeline"      href="/timeline"     current_path={@current_path} />
    <.nav_item icon="hero-wrench-screwdriver"   label="Tool Calls"    href="/tool-calls"   current_path={@current_path} />
    <.nav_item icon="hero-arrows-right-left"    label="A2A"           href="/a2a"          current_path={@current_path} />
    <.nav_item icon="hero-circle-stack"         label="Architecture"  href="/architecture" current_path={@current_path} />
    """
  end

  # ── Section: GOVERN ──────────────────────────────────────────────────────────
  attr :current_path, :string, required: true

  defp govern_nav(assigns) do
    ~H"""
    <.section_header label="Govern" />
    <.nav_item icon="hero-globe-alt"                label="Governance"    href="/governance"        current_path={@current_path} />
    <.nav_item icon="hero-shield-check"             label="Authorization" href="/authorization"     current_path={@current_path} />
    <.nav_item icon="hero-map"                      label="Routing"       href="/routing"           current_path={@current_path} />
    <.nav_item icon="hero-clipboard-document-check" label="Approvals"     href="/approvals-history" current_path={@current_path} />
    <.nav_item icon="hero-funnel"                   label="Coalesce"      href="/coalesce"          current_path={@current_path} />
    <.nav_item icon="hero-calendar-days"            label="UPM"           href="/upm/module"        current_path={@current_path} />
    """
  end

  # ── Section: MEASURE ─────────────────────────────────────────────────────────
  attr :current_path, :string, required: true

  defp measure_nav(assigns) do
    ~H"""
    <.section_header label="Measure" />
    <.nav_item icon="hero-chart-bar"         label="Analytics" href="/analytics" current_path={@current_path} />
    <.nav_item icon="hero-cpu-chip"          label="Usage"     href="/usage"     current_path={@current_path} />
    <.nav_item icon="hero-heart"             label="Health"    href="/health"    current_path={@current_path} />
    <.nav_item icon="hero-signal"            label="Ports"     href="/ports"     current_path={@current_path} />
    <.nav_item icon="hero-queue-list"        label="Tasks"     href="/tasks"     current_path={@current_path} />
    <.nav_item icon="hero-bolt"              label="Actions"   href="/actions"   current_path={@current_path} />
    <.nav_item icon="hero-magnifying-glass"  label="Scanner"   href="/scanner"   current_path={@current_path} />
    <.nav_item icon="hero-beaker"            label="UAT"       href="/uat"       current_path={@current_path} />
    <.nav_item icon="hero-no-symbol"         label="DRTW"      href="/drtw"      current_path={@current_path} />
    """
  end

  # ── Section: INTELLIGENCE ────────────────────────────────────────────────────
  attr :current_path, :string, required: true
  attr :skill_count, :integer, default: 0

  defp intelligence_nav(assigns) do
    ~H"""
    <.section_header label="Intelligence" />
    <.nav_item icon="hero-sparkles"                 label="Skills"       href="/skills"        current_path={@current_path} badge={@skill_count} />
    <.nav_item icon="hero-arrows-pointing-out"      label="Skill Drift"  href="/skill-drift"   current_path={@current_path} />
    <.nav_item icon="hero-book-open"                label="Library"      href="/library"       current_path={@current_path} />
    <.nav_item icon="hero-light-bulb"               label="Memory"       href="/memory"        current_path={@current_path} />
    <.nav_item icon="hero-arrow-path-rounded-square" label="Orchestration" href="/orchestration" current_path={@current_path} />
    <.nav_item icon="hero-inbox"                    label="Intake"       href="/intake"        current_path={@current_path} />
    <.nav_item icon="hero-adjustments-horizontal"   label="Alignment"    href="/alignment"     current_path={@current_path} />
    <.nav_item icon="hero-document-check"           label="Provenance"   href="/intelligence/provenance" current_path={@current_path} />
    """
  end

  # ── Section: EXTEND ──────────────────────────────────────────────────────────
  attr :current_path, :string, required: true
  attr :notification_count, :integer, default: 0
  attr :plugins, :list, required: true
  attr :integrations, :list, required: true

  defp extend_nav(assigns) do
    plugins_expanded =
      String.starts_with?(assigns.current_path || "", "/plugins") or
        String.starts_with?(assigns.current_path || "", "/library")

    integrations_expanded =
      String.starts_with?(assigns.current_path || "", "/integrations") or
        String.starts_with?(assigns.current_path || "", "/ag-ui") or
        String.starts_with?(assigns.current_path || "", "/ralph")

    assigns =
      assigns
      |> assign(:plugins_expanded, plugins_expanded)
      |> assign(:integrations_expanded, integrations_expanded)

    ~H"""
    <.section_header label="Extend" />

    <%!-- Plugins parent row with caret ─────────── --%>
    <.expandable_nav_item
      icon="hero-puzzle-piece"
      label="Plugins"
      href="/plugins"
      current_path={@current_path}
      badge={length(@plugins)}
      group_id="nav-plugins"
      expanded={@plugins_expanded}
    />
    <div
      id="nav-plugins-children"
      class={["pl-3 border-l border-base-300 ml-5 space-y-0.5", !@plugins_expanded && "hidden"]}
    >
      <%= for plugin <- @plugins do %>
        <% name = plugin[:name] || plugin["name"] || "plugin" %>
        <% scope = plugin[:scope] || plugin["scope"] %>
        <.nav_sub_item
          icon={plugin_scope_icon(scope)}
          label={humanize_name(name)}
          href={plugin_href(plugin)}
          current_path={@current_path}
          badge_label={if scope == :apm, do: "APM", else: nil}
        />
      <% end %>
    </div>

    <%!-- Integrations parent row with caret ────── --%>
    <.expandable_nav_item
      icon="hero-circle-stack"
      label="Integrations"
      href="/integrations"
      current_path={@current_path}
      badge={length(@integrations)}
      group_id="nav-integrations"
      expanded={@integrations_expanded}
    />
    <div
      id="nav-integrations-children"
      class={["pl-3 border-l border-base-300 ml-5 space-y-0.5", !@integrations_expanded && "hidden"]}
    >
      <.nav_sub_item icon="hero-cpu-chip"    label="AG-UI"  href="/ag-ui"  current_path={@current_path} />
      <.nav_sub_item icon="hero-arrow-path"  label="Ralph"  href="/ralph"  current_path={@current_path} />
      <.nav_sub_item
        :for={integ <- filtered_integrations(@integrations)}
        icon="hero-circle-stack"
        label={humanize_name(integ[:name] || integ["name"] || "integration")}
        href={integration_href(integ)}
        current_path={@current_path}
      />
    </div>

    <.nav_item icon="hero-bell"              label="Notifications" href="/notifications" current_path={@current_path} badge={@notification_count} />
    <.nav_item icon="hero-presentation-chart-bar" label="Showcase" href="/showcase"     current_path={@current_path} />
    <.nav_item icon="hero-document-text"     label="Docs"          href="/docs"          current_path={@current_path} />
    """
  end

  # ── Section: AI PLATFORM ─────────────────────────────────────────────────────
  attr :current_path, :string, required: true

  defp ai_platform_nav(assigns) do
    ~H"""
    <.section_header label="AI Platform" />
    <.nav_item icon="hero-globe-alt"    label="All Projects"  href="/apm-all"       current_path={@current_path} />
    <.nav_item icon="hero-cpu-chip"     label="AG-UI"         href="/ag-ui"         current_path={@current_path} />
    <.nav_item icon="hero-arrow-path"   label="Ralph"         href="/ralph"         current_path={@current_path} />
    <.nav_item icon="hero-paint-brush"  label="Generative UI" href="/generative-ui" current_path={@current_path} />
    """
  end

  # ── Components ───────────────────────────────────────────────────────────────
  attr :label, :string, required: true

  defp section_header(assigns) do
    ~H"""
    <div class="px-2 pt-3 pb-1 sidebar-label">
      <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/30">{@label}</span>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0
  attr :badge_label, :string, default: nil

  defp nav_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span class="sidebar-label">{@label}</span>
      <span :if={@badge > 0} class="badge badge-xs badge-primary ml-auto sidebar-badge">{@badge}</span>
      <span :if={@badge_label} class="badge badge-xs badge-accent ml-auto sidebar-badge">{@badge_label}</span>
    </.link>
    """
  end

  # Nav item with an expandable chevron caret — used for Plugins and Integrations
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0
  attr :group_id, :string, required: true
  attr :expanded, :boolean, default: false

  defp expandable_nav_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <div class="flex items-center gap-0">
      <.link
        navigate={@href}
        class={[
          "flex flex-1 items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
          @active && "bg-primary/10 text-primary font-medium",
          !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
        ]}
      >
        <.icon name={@icon} class="size-4 flex-shrink-0" />
        <span class="sidebar-label">{@label}</span>
        <span :if={@badge > 0} class="badge badge-xs badge-primary ml-auto sidebar-badge">{@badge}</span>
      </.link>
      <button
        type="button"
        onclick={"window.apmSidebar.toggleGroup('#{@group_id}')"}
        class="p-1.5 rounded text-base-content/30 hover:text-base-content/70 transition-colors flex-shrink-0"
        aria-controls={@group_id <> "-children"}
        aria-expanded={to_string(@expanded)}
        title={"Toggle #{@label}"}
      >
        <.icon
          name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
          class="size-3"
        />
      </button>
    </div>
    """
  end

  # Indented sub-item for plugin/integration children
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge_label, :string, default: nil

  defp nav_sub_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/50 hover:text-base-content/80 hover:bg-base-300/50"
      ]}
    >
      <.icon name={@icon} class="size-3 flex-shrink-0" />
      <span class="sidebar-label truncate">{@label}</span>
      <span :if={@badge_label} class="badge badge-xs badge-accent ml-auto sidebar-badge">{@badge_label}</span>
    </.link>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @doc """
  Safely assigns sidebar nav data (plugins + integrations) to a LiveView socket.
  Call from `mount/3` to populate the dynamic sections.
  """
  def assign_sidebar_nav_data(socket) do
    socket
    |> Phoenix.Component.assign(:plugins, safe_list_plugins())
    |> Phoenix.Component.assign(:integrations, safe_list_integrations())
  end

  @doc "Safely list plugins; returns [] on any failure."
  @spec safe_list_plugins() :: [map()]
  def safe_list_plugins do
    try do
      Apm.Plugins.PluginRegistry.list_plugins()
    rescue
      _ -> []
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  @doc "Safely list integrations; returns [] on any failure."
  @spec safe_list_integrations() :: [map()]
  def safe_list_integrations do
    try do
      Apm.Integrations.IntegrationRegistry.list_integrations()
    rescue
      _ -> []
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  defp filtered_integrations(integrations) do
    Enum.reject(integrations, fn i ->
      name = i[:name] || i["name"] || ""
      slug = name |> to_string() |> String.downcase() |> String.replace(~r/[\s_-]/, "")
      slug in ["agui", "ralph"]
    end)
  end

  defp plugin_scope_icon(:apm), do: "hero-chart-bar"
  defp plugin_scope_icon(:ccem), do: "hero-cog-6-tooth"
  defp plugin_scope_icon(:claude_code), do: "hero-command-line"
  defp plugin_scope_icon(:security), do: "hero-shield-check"
  defp plugin_scope_icon(:memory), do: "hero-light-bulb"
  defp plugin_scope_icon(:orchestration), do: "hero-arrow-path-rounded-square"
  defp plugin_scope_icon(_), do: "hero-puzzle-piece"

  defp plugin_slug(plugin) do
    (plugin[:name] || plugin["name"] || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp plugin_href(plugin), do: "/plugins/#{plugin_slug(plugin)}"

  defp integration_slug(integ) do
    (integ[:name] || integ["name"] || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp integration_href(integ), do: "/integrations/#{integration_slug(integ)}"

  defp humanize_name(name) do
    name
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp version, do: to_string(Application.spec(:apm, :vsn))
end
