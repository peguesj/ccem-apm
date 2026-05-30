defmodule ApmWeb.Components.ConversationDrawer do
  @moduledoc """
  ConversationDrawer — resizable, keyboard-accessible bottom-tray component
  for the Conversation Inspector.

  ## Features

  - Drag-to-resize via `DrawerResize` JS hook (min 56px, max 90vh)
  - Four height states: collapsed (56px), default (40vh), expanded (70vh),
    fullscreen (calc(100vh - 48px))
  - Keyboard shortcuts handled via `drawer_collapse`, `drawer_toggle`, and
    `drawer_fullscreen` hook events pushed to the LiveView
  - Tab count badges and active-tab underline animation
  - Smooth height transitions (transition-[height] duration-200 ease-out)
  - ARIA: role="tablist" on tab bar, role="tab" on each button,
    role="tabpanel" on content pane, aria-selected, aria-controls
  """

  use Phoenix.Component

  import ApmWeb.CoreComponents, only: [icon: 1]

  # ---------------------------------------------------------------------------
  # Height helpers
  # ---------------------------------------------------------------------------

  @min_px 56
  @max_fraction 0.9

  @doc "Clamps a pixel height to the drawer's valid range."
  @spec clamp_height(integer()) :: integer()
  def clamp_height(px) when is_integer(px) do
    max_px = trunc(900 * @max_fraction)
    px |> max(@min_px) |> min(max_px)
  end

  @doc """
  Translates a `drawer_height` assign (integer px | :collapsed | :expanded |
  :fullscreen) into a CSS height string.
  """
  @spec height_style(integer() | atom()) :: String.t()
  def height_style(:collapsed), do: "#{@min_px}px"
  def height_style(:expanded), do: "70vh"
  def height_style(:fullscreen), do: "calc(100vh - 48px)"
  def height_style(px) when is_integer(px), do: "#{clamp_height(px)}px"
  def height_style(_), do: "40vh"

  @doc """
  Returns the data-drawer-state attribute value for the given height.
  Used by tests and JS to determine logical state.
  """
  @spec drawer_state(integer() | atom()) :: String.t()
  def drawer_state(:collapsed), do: "collapsed"
  def drawer_state(px) when is_integer(px) and px <= @min_px + 4, do: "collapsed"
  def drawer_state(:fullscreen), do: "fullscreen"
  def drawer_state(_), do: "expanded"

  # ---------------------------------------------------------------------------
  # Component
  # ---------------------------------------------------------------------------

  @doc """
  Renders the full conversation drawer tray.

  ## Assigns

  - `drawer_height` — integer px | :collapsed | :expanded | :fullscreen
  - `tray_tab` — currently active tab id string
  - `tray_tabs` — list of `%{id: String.t(), label: String.t(), count: non_neg_integer() | nil}`
  - `show_related` — boolean
  - `related_sessions` — list
  - `inner_block` — rendered tab content (passed via `<:inner_block>`)
  - All remaining assigns are forwarded to the tab-content slot.
  """
  attr :drawer_height, :any, default: :collapsed
  attr :tray_tab, :string, default: "live"
  attr :tray_tabs, :list, default: []
  attr :show_related, :boolean, default: false
  attr :related_sessions, :list, default: []
  slot :inner_block, required: true

  def conversation_drawer(assigns) do
    ~H"""
    <div
      id="conversation-drawer"
      data-drawer-root
      data-drawer-state={drawer_state(@drawer_height)}
      phx-hook="DrawerResize"
      data-default-height="400"
      class={[
        "absolute bottom-0 left-0 right-0 bg-base-200 border-t border-base-300 z-30",
        "transition-[height] duration-200 ease-out overflow-hidden"
      ]}
      style={"height: #{height_style(@drawer_height)};"}
    >
      <%!-- ── Resize handle (drag target at top edge) ────────────────── --%>
      <div
        data-resize-handle
        aria-hidden="true"
        class={[
          "absolute top-0 left-0 right-0 h-1 cursor-ns-resize z-10",
          "hover:bg-primary/40 transition-colors group-hover:bg-primary/60"
        ]}
      />

      <%!-- ── Title bar / toggle row ──────────────────────────────────── --%>
      <button
        phx-click="toggle_tray"
        aria-label="Conversation Inspector"
        aria-expanded={drawer_state(@drawer_height) != "collapsed"}
        class="flex w-full items-center justify-between cursor-pointer group h-8 border-b border-base-300/50 px-4 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary"
      >
        <span class="text-xs font-semibold text-base-content/60">Conversation Inspector</span>
        <div class="flex items-center gap-2">
          <span
            :if={@show_related and drawer_state(@drawer_height) == "collapsed"}
            class="badge badge-xs badge-info"
          >
            {length(@related_sessions)} related
          </span>
          <span class="text-base-content/40 group-hover:text-base-content/70 transition-colors">
            <.icon
              :if={drawer_state(@drawer_height) != "collapsed"}
              name="hero-chevron-down"
              class="size-4"
            />
            <.icon
              :if={drawer_state(@drawer_height) == "collapsed"}
              name="hero-chevron-up"
              class="size-4"
            />
          </span>
        </div>
      </button>

      <%!-- ── Tab bar ────────────────────────────────────────────────── --%>
      <div role="tablist" aria-label="Conversation Inspector tabs" class="flex items-center gap-1 px-3 h-6">
        <button
          :for={tab <- @tray_tabs}
          role="tab"
          id={"drawer-tab-#{tab.id}"}
          data-tab={tab.id}
          aria-selected={to_string(@tray_tab == tab.id)}
          aria-controls="conversation-drawer-panel"
          phx-click="select_tray_tab"
          phx-value-tab={tab.id}
          class={[
            "btn btn-xs rounded-full px-3 transition-colors relative",
            @tray_tab == tab.id && "btn-primary" || "btn-ghost text-base-content/60"
          ]}
        >
          {tab.label}
          <span
            :if={Map.get(tab, :count, 0) > 0}
            class="badge badge-xs badge-neutral ml-1"
          >
            {tab.count}
          </span>
          <%!-- Active underline animation --%>
          <span
            :if={@tray_tab == tab.id}
            class="absolute -bottom-0.5 left-2 right-2 h-0.5 bg-primary rounded-full"
          />
        </button>

        <button
          :if={@show_related}
          phx-click="include_related"
          class="btn btn-xs btn-ghost text-info ml-auto"
        >
          + {length(@related_sessions)} related sessions
        </button>
      </div>

      <%!-- ── Tab content panel ──────────────────────────────────────── --%>
      <div
        :if={drawer_state(@drawer_height) != "collapsed"}
        id="conversation-drawer-panel"
        role="tabpanel"
        aria-labelledby={"drawer-tab-#{@tray_tab}"}
        class="overflow-y-auto p-3"
        style={"height: calc(#{height_style(@drawer_height)} - 3.5rem);"}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
