# CCEM UI — Dual-Section Sidebar and Management Hub

**Version**: v6.4.0
**Author**: Jeremiah Pegues
**Module**: `ApmV5Web.Components.SidebarNav`, `ApmV5Web.CcemOverviewLive`

---

## Overview

Since v6.0.0, CCEM APM ships a dual-section sidebar that draws a clear visual boundary between **CCEM Management** tooling and **APM Monitoring** pages. This architectural split was introduced as part of the v6.0.0 transformation (implementation checkpoints CP-106 and CP-107) and reflects the product's dual identity: CCEM is both an environment manager for Claude Code sessions *and* a real-time performance monitor for agentic workloads.

### Key Changes in v6.0.0

- Sidebar reorganized from a flat list into two labeled, visually distinct sections with `text-[10px]` uppercase section headers
- New `/ccem` management hub route and `CcemOverviewLive` LiveView added as the entry point to CCEM Management tools
- Dynamic header branding: CCEM Management pages display `"CCEM Management"` in the header; APM Monitoring pages display route-specific labels
- Icon-only collapsed sidebar mode persisted to `localStorage` under the key `apm:sidebar-collapsed`
- Sidebar collapse/expand handled entirely in client-side JavaScript (`window.apmSidebar.toggle()`) to avoid round-trips

---

## Dual-Section Sidebar Architecture

The sidebar is implemented as a single HEEx component (`sidebar_nav/1`) in `ApmV5Web.Components.SidebarNav`. It renders a fixed-width `<aside>` element containing two labeled navigation sections separated by section header labels.

### CCEM Management Section

These routes manage the CCEM environment itself. They appear at the top of the sidebar under the `CCEM Management` section header.

| Label | Route | Heroicon | Description |
|-------|-------|----------|-------------|
| Showcase | `/showcase` | `hero-presentation-chart-bar` | Project showcase dashboard with SVG diagrams |
| All Projects | `/apm-all` | `hero-globe-alt` | Multi-project overview across all registered projects |
| Ports | `/ports` | `hero-signal` | Port registry, conflict detection, namespace utilization |
| Actions | `/actions` | `hero-bolt` | ActionEngine catalog for automated CCEM operations |
| Project Scanner | `/scanner` | `hero-magnifying-glass` | Auto-discovery of projects in configured developer directories |

> Note: The `/ccem` overview hub does not appear as its own nav item — it is the default landing page accessible by clicking the CCEM brand or navigating directly. The section header itself serves as the visual anchor.

### APM Monitoring Section

These routes provide real-time observability into Claude Code agent activity. They appear below the `APM Monitoring` section header.

| Label | Route | Heroicon | Description |
|-------|-------|----------|-------------|
| Dashboard | `/` | `hero-squares-2x2` | Agent fleet overview, real-time metrics |
| Formations | `/formation` | `hero-rectangle-group` | Formation hierarchy: Session → Formation → Squadron → Swarm → Agent → Task |
| AG-UI | `/ag-ui` | `hero-cpu-chip` | AG-UI protocol event stream viewer |
| Conversations | `/conversations` | `hero-chat-bubble-left-right` | Conversation monitor for active Claude Code sessions |
| Skills | `/skills` | `hero-sparkles` | Skill registry, health dashboard, audit actions — badge shows count |
| Background Tasks | `/tasks` | `hero-queue-list` | Background task monitor with log viewer and stop controls |
| Health | `/health` | `hero-heart` | System health check across all APM subsystems |
| Notifications | `/notifications` | `hero-bell` | Notification center — badge shows unread count |
| Analytics | `/analytics` | `hero-chart-bar` | Session analytics and trend charts |
| Usage | `/usage` | `hero-cpu-chip` | Claude token usage tracking by project |
| Ralph | `/ralph` | `hero-arrow-path` | Ralph methodology flowchart visualizer |
| Timeline | `/timeline` | `hero-clock` | Session execution timeline with step-level detail |
| UAT | `/uat` | `hero-beaker` | User acceptance testing dashboard |
| Plugins | `/plugins` | `hero-puzzle-piece` | Plugin management and discovery |
| Docs | `/docs` | `hero-book-open` | In-app documentation (this wiki) |

### Section Headers

Section headers are rendered as non-interactive `<div>` elements using ultra-small, uppercase, wide-tracked text:

```html
<div class="px-2 pt-3 pb-1 sidebar-label">
  <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/30">
    CCEM Management
  </span>
</div>
```

The `.sidebar-label` class is part of the collapsed-mode visibility system — see the Collapse Behavior section below.

---

## Navigation Component API

The sidebar is a Phoenix Component defined in `ApmV5Web.Components.SidebarNav`. All LiveViews import and render it directly.

### Module Location

```
lib/apm_v5_web/components/sidebar_nav.ex
```

### Public Attributes

```elixir
attr :current_path, :string, required: true
attr :notification_count, :integer, default: 0
attr :skill_count, :integer, default: 0
```

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| `current_path` | `string` | yes | Current request path, used to highlight the active nav item |
| `notification_count` | `integer` | no | Badge count shown on the Notifications nav item (default: 0) |
| `skill_count` | `integer` | no | Badge count shown on the Skills nav item (default: 0) |

### Usage in a LiveView

```heex
<.sidebar_nav
  current_path="/formation"
  notification_count={@notification_count}
  skill_count={@skill_count}
/>
```

All LiveViews that want the standard sidebar simply call `<.sidebar_nav current_path="..." />`. The current path is typically passed from the LiveView's socket assigns, which are populated at mount from the connection or route parameters.

### Private `nav_item/1` Component

Individual nav items are rendered by the private `nav_item/1` component:

```elixir
attr :icon, :string, required: true
attr :label, :string, required: true
attr :href, :string, required: true
attr :current_path, :string, required: true
attr :badge, :integer, default: 0
```

Active state detection uses prefix matching to handle sub-routes:

```elixir
active =
  assigns.current_path == assigns.href ||
    (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))
```

The root path (`/`) uses exact matching only to avoid marking every page as active.

### Active Page Highlighting

An active nav item receives:

```
bg-primary/10 text-primary font-medium
```

An inactive nav item receives:

```
text-base-content/60 hover:text-base-content hover:bg-base-300
```

The transition is managed by Tailwind's `transition-colors` utility.

### Badge Rendering

Badges are conditionally rendered using `:if={@badge > 0}`:

```heex
<span :if={@badge > 0} class="badge badge-xs badge-primary ml-auto sidebar-badge">
  {@badge}
</span>
```

The `.sidebar-badge` class hides the badge in collapsed mode (icon-only).

---

## Sidebar Collapse Behavior

The sidebar supports a collapsed (icon-only) mode that persists across page navigations and Phoenix LiveView reconnections.

### Persistence

Collapsed state is stored in `localStorage` under the key `apm:sidebar-collapsed`. The value is `"1"` (collapsed) or `"0"` (expanded).

### Toggle

Collapse is triggered by the chevron button in the sidebar header:

```html
<button onclick="window.apmSidebar.toggle()" ...>
  <.icon name="hero-chevron-left" class="size-3 sidebar-arrow-collapse" />
  <.icon name="hero-chevron-right" class="size-3 sidebar-arrow-expand" />
</button>
```

`window.apmSidebar.toggle()` is defined in `root.html.heex` and toggles the `sidebar-collapsed` CSS class on `#apm-sidebar`. The root layout also restores collapsed state on `DOMContentLoaded` and on `phx:page-loading-stop` (which fires after every LiveView navigation).

### CSS Classes Involved

| Class | Purpose |
|-------|---------|
| `.sidebar-collapsed` | Applied to `#apm-sidebar` when collapsed |
| `.sidebar-label` | Text/labels hidden in collapsed mode |
| `.sidebar-badge` | Badges hidden in collapsed mode |
| `.sidebar-version` | Version label hidden in collapsed mode |
| `.sidebar-arrow-collapse` | Chevron shown in expanded state |
| `.sidebar-arrow-expand` | Chevron shown in collapsed state |
| `.sidebar-brand` | Brand container adjusted in collapsed mode |

In collapsed mode, the sidebar shrinks to icon-only width. The exact collapsed width is controlled by the `sidebar-collapsed` CSS rule in `app.css`. The expanded width is set inline on the `<aside>` element: `w-52` (208px).

---

## Dynamic Header Branding

Each LiveView renders its own `<header>` element within the page body — there is no shared layout header. This gives each page full control over branding and actions displayed in the header bar.

### CCEM Management Pages

Pages in the CCEM Management section display `"CCEM Management"` as the header title:

```heex
<header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center gap-3 flex-shrink-0">
  <h1 class="font-semibold text-sm flex-1">CCEM Management</h1>
  ...
</header>
```

This pattern is followed by `CcemOverviewLive` (`/ccem`), `ShowcaseLive` (`/showcase`), `PortsLive` (`/ports`), `ActionsLive` (`/actions`), and `ScannerLive` (`/scanner`).

### APM Monitoring Pages

Pages in the APM Monitoring section use route-specific titles, e.g. `"Agent Dashboard"`, `"Formations"`, `"AG-UI Events"`. The `page_title` assign also propagates to the browser tab via the root layout's `<.live_title>` tag with suffix `" · Agent Performance Monitor"`.

### Implementation Pattern

No shared layout component handles branding. Each LiveView's `render/1` function owns the header:

```elixir
def mount(_params, _session, socket) do
  socket = assign(socket, :page_title, "CCEM Management")
  {:ok, socket}
end
```

The browser tab title then reads: `CCEM Management · Agent Performance Monitor`.

---

## CcemOverviewLive — The /ccem Hub

**Route**: `GET /ccem`
**Module**: `ApmV5Web.CcemOverviewLive`
**File**: `lib/apm_v5_web/live/ccem_overview_live.ex`

The CCEM Management hub is the primary entry point for the management section of the sidebar. It provides quick-access navigation tiles to all management tools and hosts the CCEM Assistant — an AG-UI-backed natural language chat interface for live page customization.

### Page Layout

```
┌──────────────────────────────────────────────────────────────────┐
│  CCEM APM  [collapse]          │  CCEM Management  [? Getting Started] │
│  ─────────────────────────     │  ─────────────────────────────────────│
│  CCEM Management               │                                        │
│    Showcase                    │  ┌─────────────┬─────────────┐        │
│    All Projects                │  │  Showcase   │   Ports     │        │
│    Ports                       │  │  /showcase  │  /ports     │        │
│    Actions                     │  ├─────────────┼─────────────┤        │
│    Project Scanner             │  │  Actions    │  Scanner    │        │
│  APM Monitoring                │  │  /actions   │  /scanner   │        │
│    Dashboard                   │  └─────────────┴─────────────┘        │
│    Formations                  │                                        │
│    ...                         │  CCEM v6.4.0 • APM :3032 • Notifications • Agents │
│                                │                                        │
│                                │                              [◉ Chat FAB] │
└──────────────────────────────────────────────────────────────────┘
```

### Navigation Tiles

The main content area renders a 2-column grid (4-column on `md` breakpoint) of navigation tiles:

| Tile ID | Icon | Label | href |
|---------|------|-------|------|
| `ccem-tile-showcase` | `hero-presentation-chart-bar` | Showcase | `/showcase` |
| `ccem-tile-ports` | `hero-signal` | Ports | `/ports` |
| `ccem-tile-actions` | `hero-bolt` | Actions | `/actions` |
| `ccem-tile-scanner` | `hero-magnifying-glass` | Scanner | `/scanner` |

Each tile uses `group` hover state to scale its icon:

```heex
<a href="/showcase" class="bg-base-200 rounded-xl border border-base-300 p-4
   hover:border-primary/40 transition-colors flex flex-col items-center gap-2 group">
  <.icon name="hero-presentation-chart-bar"
    class="size-8 text-primary group-hover:scale-110 transition-transform" />
  <span class="text-sm font-medium text-base-content">Showcase</span>
</a>
```

### Status Strip

Below the tiles, a compact status strip displays:

- Current CCEM version (`Application.spec(:apm_v5, :vsn)`)
- APM port (`:3032`)
- Quick links to Notifications and Agents

### Mount Pattern and Assigns

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "ag_ui:events")
  end

  messages = ChatStore.list_messages("ccem:overview", 50)

  socket =
    socket
    |> assign(:page_title, "CCEM Management")
    |> assign(:chat_open, false)
    |> assign(:chat_messages, messages)
    |> assign(:chat_input, "")
    |> assign(:chat_assembling, %{})
    |> assign(:wizard_page, "welcome")
    |> assign(:wizard_visible, false)

  {:ok, socket}
end
```

| Assign | Type | Purpose |
|--------|------|---------|
| `page_title` | `string` | Browser tab title |
| `chat_open` | `boolean` | Whether the CCEM Assistant panel is visible |
| `chat_messages` | `[map()]` | Message history loaded from `ChatStore` |
| `chat_input` | `string` | Controlled input value for the chat form |
| `chat_assembling` | `map()` | In-progress streamed message tokens (keyed by message ID) |
| `wizard_page` | `string` | Current page of the Getting Started wizard (`"welcome"`, etc.) |
| `wizard_visible` | `boolean` | Whether the wizard overlay is rendered |

### PubSub Subscription

`CcemOverviewLive` subscribes to `"ag_ui:events"` when connected to receive streamed `TEXT_MESSAGE_CONTENT` tokens from the CCEM Assistant agent. The handler filters events by `agent_id == "ccem-assistant"` and pushes `"ccem:stream_token"` events to the `CcemAssistant` JS hook for progressive rendering.

### Getting Started Wizard

The wizard is a modal slideshow rendered via the `<.wizard>` component. It is hidden by default and toggled via the `"Getting Started"` button in the header, which fires `push_event/3` with `"ccem:wizard_trigger"`.

---

## CCEM Assistant — AG-UI Callout Chat

The CCEM Assistant is a fixed-position floating chat panel (`z-[900]`) anchored to the bottom-right corner of the `/ccem` page. It accepts natural language commands that modify page elements in real time via `ccem:style_update` JS events.

### Supported Commands

| Pattern | Example | Effect |
|---------|---------|--------|
| Color update | `"make the showcase card blue"` | Changes tile color/bg/border |
| Text size update | `"change the ports text size to xl"` | Changes tile label font size |
| Reset | `"reset all"` | Removes all inline style overrides |
| Help | `"help"` | Returns usage examples |

### Command Processing

Commands are processed server-side by `process_ccem_command/1`:

1. Input is lowercased and matched against regex patterns using `cond`
2. For color commands: `resolve_color_target/2` maps target name to CSS selector and property; `normalize_color/1` maps friendly names (e.g., `"blue"`) to hex values
3. For size commands: `resolve_tile_selector/1` maps target name to `#ccem-tile-{name}`; `normalize_size/1` maps Tailwind-style size names to rem values
4. Style events (`%{selector: ..., property: ..., value: ...}`) are pushed to the client via `push_event(socket, "ccem:style_update", evt)`

### Color Normalization

| Input | Hex Output |
|-------|-----------|
| `"blue"` | `#3b82f6` |
| `"red"` | `#ef4444` |
| `"green"` | `#22c55e` |
| `"orange"` | `#f97316` |
| `"purple"` | `#a855f7` |
| `"pink"` | `#ec4899` |
| `"yellow"` | `#eab308` |
| `"dark"` | `#1e293b` |
| `"gray"` | `#6b7280` |
| `"white"` | `#ffffff` |
| (any hex) | passed through |

### AG-UI Event Emission

When the user sends a message, `CcemOverviewLive` emits a `MESSAGES_SNAPSHOT` AG-UI event via `ApmV5.EventStream.emit/2` using `AgUi.Core.Events.EventType.messages_snapshot()`. This integrates the chat interaction into the AG-UI event stream and makes it visible on the `/ag-ui` monitor.

### JS Hook: CcemAssistant

The `phx-hook="CcemAssistant"` hook on `#ccem-assistant` handles:
- `ccem:style_update` — applies inline styles to the targeted DOM selector
- `ccem:stream_token` — appends streamed content tokens to the assembling message buffer
- `ccem:wizard_trigger` — shows the Getting Started wizard overlay

---

## Icon Convention

All icons in the sidebar and LiveViews use **Heroicons** via the `<.icon>` core component from `ApmV5Web.CoreComponents`.

### Naming Convention

Icons are referenced by their Heroicons v2 name prefixed with `hero-`:

```heex
<.icon name="hero-cpu-chip" class="size-4 flex-shrink-0" />
```

### Solid vs Outline

The default variant used throughout CCEM APM is the **solid** (filled) variant, which corresponds to the `hero-*` prefix without a `-outline` suffix. Use `hero-*-outline` (e.g., `hero-bell-outline`) for outline variants where visual weight needs to be reduced.

### Common Icons in Sidebar

| Heroicon Name | Usage Context |
|---------------|--------------|
| `hero-presentation-chart-bar` | Showcase |
| `hero-globe-alt` | All Projects |
| `hero-signal` | Ports |
| `hero-bolt` | Actions |
| `hero-magnifying-glass` | Project Scanner |
| `hero-squares-2x2` | Dashboard |
| `hero-rectangle-group` | Formations |
| `hero-cpu-chip` | AG-UI, Usage |
| `hero-chat-bubble-left-right` | Conversations |
| `hero-sparkles` | Skills |
| `hero-queue-list` | Background Tasks |
| `hero-heart` | Health |
| `hero-bell` | Notifications |
| `hero-chart-bar` | Analytics |
| `hero-arrow-path` | Ralph |
| `hero-clock` | Timeline |
| `hero-beaker` | UAT |
| `hero-puzzle-piece` | Plugins |
| `hero-book-open` | Docs |

---

## Tailwind CSS Architecture

CCEM APM uses **Tailwind CSS** (utility-first) with the **daisyUI** plugin for semantic component classes.

### Sidebar Layout Classes

| Element | Key Classes | Purpose |
|---------|-------------|---------|
| `<aside>` | `w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0` | Fixed 208px width, vertically stacked |
| Brand area | `p-3 border-b border-base-300` | Top brand block with bottom divider |
| Nav container | `flex-1 p-2 space-y-0.5 overflow-y-auto` | Scrollable nav with tight item spacing |
| Section header | `px-2 pt-3 pb-1` | Padding inside section header wrapper |
| Nav item | `flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors` | Consistent item layout |

### Active Item Classes

```
bg-primary/10 text-primary font-medium
```

- `bg-primary/10`: 10% opacity primary color background (adapts to theme)
- `text-primary`: Primary color text
- `font-medium`: Medium weight to visually distinguish from inactive items

### Hover Classes

```
text-base-content/60 hover:text-base-content hover:bg-base-300
```

### daisyUI Color Tokens

CCEM APM uses daisyUI semantic color tokens exclusively for all UI chrome — never raw hex values in component markup. This ensures dark mode and theme switching work without modification.

| Token | Meaning |
|-------|---------|
| `bg-base-100` | Page background |
| `bg-base-200` | Sidebar and card backgrounds |
| `bg-base-300` | Hover states and dividers |
| `border-base-300` | Borders throughout |
| `text-base-content` | Primary text |
| `text-base-content/60` | Muted text (60% opacity) |
| `text-base-content/30` | Very muted text (section headers) |
| `bg-primary/10` | Active nav item background |
| `text-primary` | Active nav item text and icon tint |

### Dark Mode

Dark mode is the default theme. The `data-theme` attribute is set on `<html>` using an inline script in `root.html.heex` that reads from `localStorage` under the key `phx:theme`. The default is `"dark"` if no preference is stored. Theme changes dispatch a `phx:set-theme` event.

```javascript
const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme");
    document.documentElement.removeAttribute("data-theme");
  } else {
    localStorage.setItem("phx:theme", theme);
    document.documentElement.setAttribute("data-theme", theme);
  }
};
```

daisyUI themes are configured in `tailwind.config.js`. The `dark` theme maps `bg-primary` to the configured primary color (violet/purple family in CCEM APM's palette, `#7c3aed`).

---

## CSS Architecture

### Asset Pipeline

All CSS is processed through the Phoenix asset pipeline:

- **Entry point**: `assets/css/app.css`
- **Output**: `priv/static/assets/css/app.css` (fingerprinted)
- **Loaded by**: `root.html.heex` via `<link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />`

### Scope Isolation

Showcase-specific styles (introduced in CP-100) are scoped to `/showcase` routes to avoid polluting the global stylesheet. This was implemented by conditionally loading `showcase-styles.css` only when navigating to showcase routes.

### Sidebar Collapse CSS

The sidebar collapse animation is driven by the `.sidebar-collapsed` class added to `#apm-sidebar`. In collapsed mode:

- `.sidebar-label` elements have `display: none` (text and section headers hidden)
- `.sidebar-badge` elements have `display: none` (badges hidden)
- `.sidebar-version` is hidden
- The `<aside>` shrinks to icon-only width (approximately 48px)
- `.sidebar-arrow-collapse` is hidden; `.sidebar-arrow-expand` is shown

The collapse transition uses CSS `transition` on `width` and `opacity` for smooth animation.

---

## Router — /ccem Route Definition

The `/ccem` route is defined in the browser scope in `lib/apm_v5_web/router.ex`:

```elixir
scope "/", ApmV5Web do
  pipe_through :browser

  live "/ccem", CcemOverviewLive, :index
  live "/showcase", ShowcaseLive, :index
  live "/ports", PortsLive, :index
  live "/actions", ActionsLive, :index
  live "/scanner", ScannerLive, :index
  # ... APM Monitoring routes ...
end
```

All browser routes pass through the `:browser` pipeline, which applies:

- `ApmV5Web.Plugs.CorrelationId` — attaches a correlation ID for request tracing
- `:put_root_layout` — sets `{ApmV5Web.Layouts, :root}` as the layout wrapper
- `:fetch_live_flash` — enables flash messages in LiveViews
- `:protect_from_forgery` — CSRF protection

---

## Adding a New CCEM Page

Follow these steps to add a new page to the CCEM Management section.

### Step 1 — Create the LiveView

Create `lib/apm_v5_web/live/my_feature_live.ex`:

```elixir
defmodule ApmV5Web.MyFeatureLive do
  @moduledoc "LiveView for the My Feature management page at /my-feature."

  use ApmV5Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "My Feature")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/my-feature" />
      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center gap-3 flex-shrink-0">
          <h1 class="font-semibold text-sm flex-1">My Feature</h1>
        </header>
        <div class="flex-1 overflow-y-auto p-6">
          <!-- Your content here -->
        </div>
      </div>
    </div>
    """
  end
end
```

Key conventions:
- `current_path` must match the route exactly so the nav item highlights correctly
- Page content uses `flex h-screen overflow-hidden` at the root, with sidebar + content side by side
- Header uses the same `bg-base-200 border-b border-base-300 px-4 py-2` pattern for visual consistency
- Content area uses `flex-1 overflow-y-auto p-6` to scroll independently of the sidebar

### Step 2 — Add the Route

In `lib/apm_v5_web/router.ex`, inside the browser scope:

```elixir
live "/my-feature", MyFeatureLive, :index
```

Place it after the existing CCEM Management routes (`/showcase`, `/ports`, `/actions`, `/scanner`) and before the APM Monitoring routes for organizational clarity.

### Step 3 — Add the Nav Item

In `lib/apm_v5_web/components/sidebar_nav.ex`, add a `<.nav_item>` inside the `CCEM Management` section block:

```elixir
# After the last existing CCEM Management nav_item:
<.nav_item
  icon="hero-wrench-screwdriver"
  label="My Feature"
  href="/my-feature"
  current_path={@current_path}
/>
```

Choose an icon from Heroicons v2 that best represents the feature. Use the `hero-` prefix for solid variant.

If the page needs a badge counter (e.g., count of pending items), add a `badge` attribute:

```elixir
<.nav_item
  icon="hero-wrench-screwdriver"
  label="My Feature"
  href="/my-feature"
  current_path={@current_path}
  badge={@my_feature_count}
/>
```

Then pass `my_feature_count` as an attribute to `sidebar_nav/1` and thread it through.

### Step 4 — Verify

```bash
cd ~/Developer/ccem/apm-v4
mix compile --warnings-as-errors
mix test
```

Navigate to `http://localhost:3032/my-feature` and verify:
- Sidebar highlights the new nav item as active
- Header displays the correct page title
- Browser tab shows `My Feature · Agent Performance Monitor`
- Sidebar section placement is correct (CCEM Management vs APM Monitoring)

---

## Version History for CCEM UI

| Version | Change |
|---------|--------|
| v6.0.0 | Dual-section sidebar, `/ccem` hub route, `CcemOverviewLive`, dynamic header branding |
| v6.0.0 | Sidebar collapse/expand with `localStorage` persistence (`apm:sidebar-collapsed`) |
| v6.0.0 | Showcase styles scoped to `/showcase` routes (CP-100) |
| v5.1.0 | Getting Started wizard modal (CP-57), guided tour tooltip overlay (CP-59) |
| v5.1.0 | AG-UI callout chat — `InspectorChatLive` pattern (CP-62) |
| v5.0.0 | Dual-section sidebar concept introduced (predecessor to v6.0.0 transformation) |
| v4.2.0 | Skills health dashboard, three-tier health view (CP-54) |
| v2.5.0 | Background tasks, scanner, actions LiveViews (CP-31–CP-33) |

---

## Related Documentation

- [Architecture](architecture.md) — GenServer supervision tree, ETS stores, PubSub topology
- [API Reference](api-reference.md) — REST endpoints for `/api/ports`, `/api/actions`, `/api/scanner`
- [AG-UI Integration](ag-ui-integration.md) — AG-UI protocol event types and stream endpoints
- [Showcase](showcase.md) — SVG diagram engine and project showcase configuration
