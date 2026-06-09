defmodule ApmWeb.Components.Templates.PageShell do
  @moduledoc """
  Tier 5 template — PageShell (sidebar + topbar + main content area).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx (PageShell, Sidebar, Topbar).
  Used by every LiveView as the outermost layout wrapper.

  Layout: flex row, height 100%, overflow hidden.
  Sidebar (left, Tier 4 component): width 208px (56px collapsed), bg surface-sunken,
    borderRight 1px solid border-subtle, flex column, flexShrink 0.
    Contains: logo + project label + live badge, NAV sections (5 verb groups),
    footer status (Dot tone=success + "localhost:3032 · OTP").
    Collapsed mode: 56px, shows section icons only.
    Sidebar items: `apm-focusable`, borderLeft 2px solid (accent when active).
    Transition: width 200ms var(--apm-ease-out).

  Topbar (top bar in main column): height 48px, bg surface-sunken,
    borderBottom 1px solid border-subtle. Contains:
    - sidebar toggle (ghost button, I.grid icon)
    - project switcher (Dot decoration=iris + project name + chevron)
    - ⌘K search trigger (flex 1, maxWidth 440)
    - bell notification button (pending badge count)
    - presence stack (3 avatar circles with marginLeft -7)

  Main content: flex 1, overflow hidden, position relative — LiveView content.

  NAV structure mirrors apm-shell.jsx NAV constant:
    Live · Investigate · Decide · Tune · Operate (5 sections, each with items).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-shell.jsx → PageShell, Sidebar, Topbar, NAV
  """
  use Phoenix.Component

  attr :active, :string, required: true
  attr :project, :string, default: "CCEM"
  attr :pending, :integer, default: 0
  attr :sidebar_collapsed, :boolean, default: false
  attr :on_nav, :string, default: "navigate"
  attr :on_toggle_sidebar, :string, default: "toggle_sidebar"
  attr :on_cmd_k, :string, default: "open_cmd_k"
  attr :on_bell, :string, default: "open_notifications"
  attr :on_project, :string, default: "open_project_switcher"
  attr :rest, :global

  slot :inner_block, required: true

  @nav [
    %{
      id: "live",
      label: "Live",
      icon: "live",
      items: [
        %{id: "dashboard", label: "Dashboard", path: "/"},
        %{id: "fleet", label: "Fleet", path: "/live/fleet", badge: nil},
        %{id: "live-sessions", label: "Sessions", path: "/live/sessions"},
        %{id: "live-timeline", label: "Timeline", path: "/live/timeline"},
        %{id: "live-conversations", label: "Conversations", path: "/live/conversations"}
      ]
    },
    %{
      id: "investigate",
      label: "Investigate",
      icon: "invest",
      items: [
        %{id: "inv-sessions", label: "Sessions", path: "/investigate/sessions"},
        %{id: "inv-conversations", label: "Conversations", path: "/investigate/conversations"},
        %{id: "inv-toolcalls", label: "Tool Calls", path: "/investigate/tool-calls"},
        %{id: "inv-a2a", label: "A2A Messages", path: "/investigate/a2a"},
        %{id: "inv-timeline", label: "Timeline", path: "/investigate/timeline"},
        %{id: "inv-audit", label: "Audit Trail", path: "/investigate/audit"}
      ]
    },
    %{
      id: "decide",
      label: "Decide",
      icon: "decide",
      items: [
        %{id: "pending", label: "Pending", path: "/decide/pending", badge_tone: "warning"},
        %{id: "policies", label: "Policies", path: "/decide/policies"},
        %{id: "upm-gates", label: "UPM Gates", path: "/decide/upm"},
        %{id: "playground", label: "Playground", path: "/decide/test"}
      ]
    },
    %{
      id: "tune",
      label: "Tune",
      icon: "tune",
      items: [
        %{id: "tune-skills", label: "Skills", path: "/tune/skills"},
        %{id: "tune-memory", label: "Memory", path: "/tune/memory"},
        %{id: "orchestration", label: "Orchestration", path: "/tune/orchestration"},
        %{id: "tune-library", label: "Library", path: "/tune/library"},
        %{id: "tune-analytics", label: "Analytics", path: "/tune/analytics"},
        %{id: "tune-alignment", label: "Alignment", path: "/tune/alignment"}
      ]
    },
    %{
      id: "operate",
      label: "Operate",
      icon: "operate",
      items: [
        %{id: "health", label: "Health", path: "/operate/health"},
        %{id: "plugins", label: "Plugins", path: "/operate/plugins"},
        %{id: "integrations", label: "Integrations", path: "/operate/integrations"},
        %{id: "op-notifications", label: "Notifications", path: "/operate/notifications"},
        %{id: "docs", label: "Docs", path: "/operate/docs"}
      ]
    }
  ]

  def page_shell(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <div class="apm-page-shell" {@rest}>
      <%!-- Sidebar --%>
      <aside class={["apm-sidebar", @sidebar_collapsed && "apm-sidebar--collapsed"]}>
        <div class="apm-sidebar__brand">
          <ApmWeb.Components.Core.Logo.logo size={22} />
          <%= unless @sidebar_collapsed do %>
            <div class="apm-sidebar__brand-copy">
              <div class="apm-sidebar__app-name">APM</div>
              <div class="apm-sidebar__app-version apm-mono">AGENT J · v11</div>
            </div>
            <ApmWeb.Components.Core.Badge.badge tone="success" dot pulse>
              LIVE
            </ApmWeb.Components.Core.Badge.badge>
          <% end %>
        </div>

        <nav class="apm-sidebar__nav apm-scroll" aria-label="Main navigation">
          <%= for sec <- @nav do %>
            <div class="apm-sidebar__section">
              <%= unless @sidebar_collapsed do %>
                <div class="apm-sidebar__section-header apm-mono apm-upper">
                  <ApmWeb.Components.Core.Icon.icon name={sec.icon} size={11} />
                  {sec.label}
                </div>
                <div class="apm-sidebar__items">
                  <%= for item <- sec.items do %>
                    <button
                      class={[
                        "apm-sidebar__item",
                        "apm-focusable",
                        @active == item.id && "apm-sidebar__item--active"
                      ]}
                      type="button"
                      phx-click={@on_nav}
                      phx-value-id={item.id}
                      aria-current={if @active == item.id, do: "page", else: nil}
                    >
                      <span class="apm-sidebar__item-label">{item.label}</span>
                      <%= if item[:badge] do %>
                        <ApmWeb.Components.Core.Badge.badge tone={item[:badge_tone] || "neutral"}>
                          {item.badge}
                        </ApmWeb.Components.Core.Badge.badge>
                      <% end %>
                    </button>
                  <% end %>
                </div>
              <% else %>
                <div class="apm-sidebar__section-icon">
                  <ApmWeb.Components.Core.Icon.icon name={sec.icon} size={15} />
                </div>
              <% end %>
            </div>
          <% end %>
        </nav>

        <%= unless @sidebar_collapsed do %>
          <div class="apm-sidebar__footer">
            <ApmWeb.Components.Core.Dot.dot tone="success" />
            <span class="apm-mono">localhost:3032 · OTP</span>
          </div>
        <% end %>
      </aside>

      <%!-- Main column --%>
      <div class="apm-page-shell__main">
        <%!-- Topbar --%>
        <div class="apm-topbar">
          <button
            class="apm-topbar__sidebar-toggle apm-btn apm-btn--variant-ghost apm-btn--size-sm apm-focusable"
            type="button"
            phx-click={@on_toggle_sidebar}
            aria-label="Toggle sidebar"
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
            >
              <rect x="4" y="4" width="7" height="7" rx="1" /><rect
                x="13"
                y="4"
                width="7"
                height="7"
                rx="1"
              /><rect x="4" y="13" width="7" height="7" rx="1" /><rect
                x="13"
                y="13"
                width="7"
                height="7"
                rx="1"
              />
            </svg>
          </button>

          <button
            class="apm-topbar__project-switcher apm-focusable"
            type="button"
            phx-click={@on_project}
          >
            <ApmWeb.Components.Core.Dot.dot decoration="iris" size={7} />
            <span class="apm-topbar__project-name">{@project}</span>
            <svg
              width="11"
              height="11"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              style="transform:rotate(90deg)"
            >
              <path d="m9 6 6 6-6 6" />
            </svg>
          </button>

          <button
            class="apm-topbar__cmd-k apm-focusable"
            type="button"
            phx-click={@on_cmd_k}
            aria-label="Open command palette"
          >
            <svg
              width="13"
              height="13"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
            >
              <circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" />
            </svg>
            <span class="apm-topbar__cmd-k-placeholder">Search or ask anything…</span>
            <ApmWeb.Components.Core.Kbd.kbd>⌘K</ApmWeb.Components.Core.Kbd.kbd>
          </button>

          <div class="apm-topbar__right">
            <button
              class="apm-topbar__bell apm-focusable"
              type="button"
              phx-click={@on_bell}
              aria-label={"#{@pending} pending notifications"}
            >
              <svg
                width="15"
                height="15"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.6"
              >
                <path d="M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0" />
              </svg>
              <%= if @pending > 0 do %>
                <span class="apm-topbar__bell-badge apm-mono">{@pending}</span>
              <% end %>
            </button>
            <div class="apm-topbar__presence" aria-hidden="true">
              <%!-- Presence avatars: 3 initials in overlapping circles --%>
              <div class="apm-topbar__avatar apm-mono" style="background:var(--apm-accent)">JP</div>
              <div class="apm-topbar__avatar apm-mono" style="background:var(--apm-status-info)">
                A3
              </div>
              <div class="apm-topbar__avatar apm-mono" style="background:var(--apm-decoration-iris)">
                S
              </div>
            </div>
          </div>
        </div>

        <%!-- Content area --%>
        <main class="apm-page-shell__content">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end
end
