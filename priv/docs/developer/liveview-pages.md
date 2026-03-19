# LiveView Pages

CCEM APM v6.4.0 uses Phoenix LiveView for real-time, interactive web pages. Each page maintains a WebSocket connection with the server for live updates without page refresh.

**Author**: Jeremiah Pegues
**Version**: v6.4.0

## LiveView Architecture

Every LiveView page follows the same mount-subscribe-handle pattern.

```elixir
defmodule ApmV5Web.DashboardLive do
  use ApmV5Web, :live_view

  def render(assigns), do: ~H"""..."""

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to PubSub topics
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:notifications")
    end

    # Load initial data
    {:ok, assign(socket, data: fetch_data())}
  end

  def handle_info({:agent_updated, agent}, socket) do
    # Handle real-time updates
    {:noreply, assign(socket, :agents, updated_agents)}
  end
end
```

> **Pattern:** Use `Phoenix.PubSub.subscribe/2` in `mount/3` only when `connected?(socket)` is true. This prevents double-subscriptions during the static render pass.

> **Warning:** Never call GenServer directly from LiveView render -- use assigns. The render function must be pure and only reference `assigns`.

## DashboardLive

**Route**: `/`
**Module**: `ApmV5Web.DashboardLive`

The main dashboard showing all agents, metrics, and real-time data.

### DashboardLive Components

- **Stats Cards**: Agent count, session count, project count, skill count
- **Agent Fleet List**: Filterable table of all agents
- **D3 Dependency Graph**: Visual agent relationships
- **Filter Bar**: Status, type, search filters
- **Right Panel Tabs**: Inspector, Ralph, UPM, Commands, TODOs

### DashboardLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:agents")         # Agent registration, updates
subscribe("apm:notifications")  # New alerts
subscribe("apm:config")         # Config changes
subscribe("apm:skills")         # Skill events
```

### DashboardLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:agent_registered, agent}, socket)
handle_info({:agent_updated, agent}, socket)
handle_info({:agent_discovered, id, project}, socket)
handle_info({:notification_added, notif}, socket)
handle_info({:config_reloaded, config}, socket)
```

### DashboardLive JS Hooks

Client-side hooks for interactive elements:

```javascript
// Clock hook - updates relative timestamps
Hooks.Clock

// DependencyGraph hook - renders D3 graph
Hooks.DependencyGraph
```

## AllProjectsLive

**Route**: `/apm-all`
**Module**: `ApmV5Web.AllProjectsLive`

Multi-project overview and management page.

### AllProjectsLive Features

- **Project List**: All configured projects with stats
- **Project Selector**: Switch active project
- **Cross-Project Metrics**: Aggregate stats across projects
- **Project Configuration**: Add/remove projects
- **Session Summary**: Sessions per project

### AllProjectsLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:config")    # Config reload, project changes
subscribe("apm:agents")    # Agent registration
```

### AllProjectsLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:config_reloaded, config}, socket)
handle_info({:agent_registered, agent}, socket)
```

## SkillsLive

**Route**: `/skills`
**Module**: `ApmV5Web.SkillsLive`
**Added**: v4.2.0 | **Redesigned**: v6.4.0

Skills Registry health dashboard, UEBA session analytics, and AG-UI hook connectivity monitor. WCAG 2.1 AA compliant — skip links, ARIA landmarks, `tablist`/`tab`/`tabpanel` roles, `aria-live` regions, Escape-key drawer dismissal.

### SkillsLive Tabs (v6.4.0)

The page is organised into three tabs selectable from the top bar:

| Tab | aria-controls | Content |
|-----|---------------|---------|
| Registry | `tabpanel-registry` | Card grid with health rings, search/filter bar, tier collapsing, slide-in detail drawer, Fix Wizard |
| Session | `tabpanel-session` | Skill invocation timeline, skill catalog table, co-occurrence matrix |
| AG-UI | `tabpanel-ag_ui` | Skill-to-AG-UI event mapping, hook connectivity health, repair actions |

### SkillsLive Components (v6.4.0)

**Registry tab:**
- **Summary Stats Bar**: Total / Healthy (score ≥ 80) / Needs Attention (50–79) / Critical (< 50) stat cards
- **Filter Bar**: Debounced search input (200 ms), tier selector (all / healthy / needs_attention / critical), methodology selector (all / ralph / tdd / elixir_architect), inline active-filter badge, "Clear filters" button
- **Tier Card Grid**: Three collapsible sections — Critical, Needs Attention, Healthy — each rendered by the `skill_tier_cards/1` component with health-ring SVGs and per-card "Fix" button
- **Detail Drawer**: Slide-in panel showing selected skill metadata, health score breakdown, and repair options
- **Fix Wizard**: Multi-step state machine (`fix_wizard_step` assign) with `fix_wizard_selected_repairs` (`MapSet`) — guides user through selecting and applying automated repairs
- **Audit All Button**: Triggers `ActionEngine` skill audit across all discovered skills; shows `loading` spinner while `audit_loading: true`

**Session tab:**
- **Invocation Timeline**: Vertical timeline of skills invoked in the current session, sorted descending by `last_seen`, with methodology badge overlay (primary-colored dot for methodology-linked skills)
- **Skill Catalog Table**: All-time tracked skills — name, total invocations, session count, source badge
- **Co-occurrence Matrix**: Table of skill pairs that co-appear in sessions with count

**AG-UI tab:**
- **AG-UI Health Summary**: Connected / Degraded / Broken stat cards derived from `registry_skills` health scores
- **Skills as AG-UI Emitters**: Card grid showing each skill's AG-UI event emission status with animated connectivity dot

### SkillsLive Key Assigns

```elixir
:tab                      # :registry | :session | :ag_ui
:registry_skills          # [%{name, health_score, ...}] from SkillsRegistryStore
:filtered_skills          # registry_skills after search/tier/methodology filters
:selected_skill           # nil | skill map — controls detail drawer
:search_query             # debounced string (phx-debounce="200")
:filter_tier              # "all" | "healthy" | "needs_attention" | "critical"
:filter_methodology       # "all" | "ralph" | "tdd" | "elixir_architect"
:collapsed_tiers          # %{healthy: bool, needs_attention: bool, critical: bool}
:fix_wizard_step          # nil | :select_repairs | :confirm | :applying | :done
:fix_wizard_selected_repairs # MapSet of repair action keys
:audit_loading            # boolean — true while ActionEngine audit is running
:session_skills           # %{skill_name => %{count, last_seen}} for current session
:catalog                  # %{skill_name => %{total_count, session_count, source}}
:co_occurrence            # %{{skill_a, skill_b} => count}
:methodology              # active methodology atom for the current session
:active_skill_count       # integer shown as sidebar badge
```

### SkillsLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:skills")          # Skill tracking events
ApmV5.AgUi.EventBus.subscribe("special:custom")  # AG-UI custom events
```

### SkillsLive Event Handlers

User interaction events:

```elixir
handle_event("set_tab", %{"tab" => tab}, socket)
handle_event("update_filters", %{"search" => _, "tier" => _, "methodology" => _}, socket)
handle_event("clear_filters", _params, socket)
handle_event("select_skill", %{"name" => name}, socket)
handle_event("close_drawer", _params, socket)
handle_event("keydown", %{"key" => "Escape"}, socket)   # closes drawer
handle_event("toggle_tier", %{"tier" => tier}, socket)
handle_event("audit_all", _params, socket)
handle_event("fix_skill", %{"name" => name}, socket)
handle_event("fix_wizard_next", _params, socket)
handle_event("fix_wizard_back", _params, socket)
handle_event("fix_wizard_toggle_repair", %{"key" => key}, socket)
handle_event("fix_wizard_apply", _params, socket)
```

PubSub handlers:

```elixir
handle_info({:skill_tracked, skill}, socket)
handle_info({:methodology_detected, methodology}, socket)
```

### SkillsLive JS Hooks

```javascript
// Skills hook — keyboard navigation, Escape-to-close-drawer
Hooks.Skills
```

## RalphFlowchartLive

**Route**: `/ralph`
**Module**: `ApmV5Web.RalphFlowchartLive`

Ralph methodology flowchart and story tracking visualization.

### RalphFlowchartLive Components

- **Flowchart**: Vertical swim lanes per story with timeline
- **Color Coding**: Status indicators (complete, in-progress, blocked)
- **Dependencies**: Arrows showing story dependencies
- **Agent Assignments**: Icons showing assigned agents per story
- **Legend**: Status color reference

### RalphFlowchartLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:agents")    # Agent status changes
subscribe("apm:upm")       # Story and wave progress
subscribe("apm:tasks")     # Task completions
```

### RalphFlowchartLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:upm_event, event}, socket)
handle_info({:agent_updated, agent}, socket)
handle_info({:tasks_synced, project, tasks}, socket)
```

### RalphFlowchartLive JS Hooks

Client-side hooks for SVG rendering:

```javascript
// RalphFlowchart hook - renders SVG flowchart
Hooks.RalphFlowchart

// DependencyArrows hook - draws dependency relationships
Hooks.DependencyArrows
```

## SessionTimelineLive

**Route**: `/timeline`
**Module**: `ApmV5Web.SessionTimelineLive`

Session execution timeline with event log.

### SessionTimelineLive Components

- **Timeline Visualization**: Horizontal or vertical timeline
- **Event Entries**: Each event with timestamp, agent, action
- **Filtering**: By event type, agent, date range
- **Zoom/Pan**: Navigate time periods
- **Export**: Download session log

### SessionTimelineLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:agents")    # All agent events
subscribe("apm:upm")       # UPM execution events
subscribe("apm:audit")     # Audit log entries
subscribe("apm:tasks")     # Task events
```

### SessionTimelineLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:audit_entry, entry}, socket)
handle_info({:upm_event, event}, socket)
handle_info({:agent_updated, agent}, socket)
```

### SessionTimelineLive JS Hooks

Client-side hooks for timeline rendering:

```javascript
// Timeline hook - renders timeline visualization
Hooks.Timeline

// EventFilter hook - client-side event filtering
Hooks.EventFilter
```

## FormationLive

**Route**: `/formation`
**Module**: `ApmV5Web.FormationLive`

Formation hierarchy visualization using a D3.js tree layout. Displays the formation > squadron > agent hierarchy with real-time PubSub updates.

### FormationLive Components

- **D3 Tree Graph**: Interactive force-directed graph of formation hierarchy rendered via the `FormationGraph` JS hook
- **Inspector Panel**: Click any node (formation, squadron, or agent) to inspect details including ID, status, member count, story assignment, wave, and role
- **Formation Tree Sidebar**: Collapsible tree listing all formations, squadrons, and agents with status indicators
- **Empty State**: Guidance on creating formations when none are registered

### FormationLive Features

- Agents are grouped into formations by `formation_id` metadata
- Within formations, agents are grouped into squadrons by `squadron` metadata
- Nodes are color-coded by level (formation=accent, squadron=info, agent=primary)
- Status badges indicate active/error/idle state at every level
- Real-time updates when agents register or change status

### FormationLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:agents")    # Agent registration and updates
subscribe("apm:upm")       # Formation and UPM session events
```

### FormationLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:agent_registered, _agent}, socket)
handle_info({:agent_updated, _agent}, socket)
handle_info({:agent_discovered, _, _}, socket)
handle_info({:upm_session_registered, _}, socket)
handle_info({:upm_agent_registered, _}, socket)
```

### FormationLive JS Hooks

Client-side hook for D3 tree rendering:

```javascript
// FormationGraph hook - renders D3 tree layout
Hooks.FormationGraph
```

## PortsLive

**Route**: `/ports`
**Module**: `ApmV5Web.PortsLive`
**Added**: v6.0.0

Port management dashboard for viewing and managing port assignments across all CCEM projects via `ApmV5.PortManager`.

### PortsLive Components

- **Header Summary Bar**: Total projects badge, active count badge (success), clash count badge (error, conditional) with "Scan Ports" button
- **Filter Bar**: Status pills (all / active / clashes) and namespace pills (all / web / api / service / tool); active selection highlighted with `btn-primary`
- **Port Cards Grid**: Responsive grid (1 → 2 → 3 columns). Each card shows: project name, namespace badge (color-coded by namespace), large monospace port number, active/inactive status dot (green = active). Cards in clash state show an error banner with inline "Reassign" button
- **Port Ranges Sidebar**: 64-unit wide sidebar listing each namespace with port range (`first`-`last`) and a colored progress bar showing utilization
- **Clash Resolution Panel**: Appears when `clash_count > 0`; lists each clash with port number and affected project names

### PortsLive Key Assigns

```elixir
:port_map        # raw map from PortManager.get_port_map()
:clashes         # [%{port, projects}] from PortManager.detect_clashes()
:port_ranges     # map of namespace => range from PortManager.get_port_ranges()
:all_projects    # derived list of %{name, port, namespace, active}
:filtered        # all_projects after status/namespace filters
:clash_ports     # MapSet of project names involved in any clash
:status_filter   # "all" | "active" | "clashes"
:namespace_filter# "all" | "web" | "api" | "service" | "tool"
:total           # integer — total project count
:active_count    # integer — active project count
:clash_count     # integer — number of clash groups
```

### PortsLive Features

- Real-time updates via `apm:ports` PubSub topic
- One-click "Scan Ports" triggers `PortManager.scan_active_ports/0` and refreshes
- Per-card "Reassign" calls `PortManager.assign_port/1` — assigns the next available port in the project's namespace range; shows flash error if no port available
- Client-side derived filtering via `refilter/1` private helper — no additional server round-trip needed after filter change
- Namespace color coding: web=blue, api=purple, service=amber, tool=emerald

### PortsLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:ports")    # Port assignment events
```

### PortsLive Event Handlers

User interaction events:

```elixir
handle_event("scan_ports", _params, socket)
handle_event("filter", %{"status" => status}, socket)
handle_event("namespace_filter", %{"namespace" => ns}, socket)
handle_event("assign_port", %{"project" => project}, socket)
```

PubSub handlers:

```elixir
handle_info({:port_assigned, _, _}, socket)
```

### PortsLive JS Hooks

None — all interactivity is handled via server-side `handle_event` and LiveView re-renders. The Getting Started wizard is rendered via the `<.wizard page="ports" />` component.

## DocsLive

**Route**: `/docs` and `/docs/*path`
**Module**: `ApmV5Web.DocsLive`

Industry-standard documentation viewer with search, navigation, and responsive layout.

### DocsLive Components

- **Left TOC Panel**: Collapsible category tree (Overview, User Guide, Developer, Administration) with category icons
- **Search Box**: Full-text search with Cmd+K shortcut, debounced input, grouped results by category with snippets
- **Content Area**: Rendered markdown with Tailwind Typography (prose) styling, syntax-highlighted code blocks
- **Breadcrumbs**: Current doc path navigation
- **On-Page TOC**: Right sidebar listing h2/h3 headings from current page with anchor links (desktop only)
- **Prev/Next Navigation**: Links to previous and next pages based on TOC order
- **Mobile Support**: Responsive with mobile TOC overlay and hamburger menu

### DocsLive Features

- **Markdown Rendering**: Converts `.md` files from `priv/docs/` to HTML via `DocsStore`
- **Read Time Estimation**: Estimated reading time based on word count
- **Category Organization**: Pages grouped into root, user, developer, admin categories
- **Search**: Full-text search across all documentation pages with highlighted snippets
- **Collapsible Categories**: Toggle category visibility in the TOC
- **Static Content**: No PubSub subscriptions -- docs are loaded from `DocsStore` GenServer

### DocsLive PubSub Subscriptions

None -- docs are static content served from the `DocsStore` cache.

## ShowcaseLive

**Route**: `/showcase` and `/showcase/:project`
**Module**: `ApmV5Web.ShowcaseLive`

GIMME-style project showcase dashboard integrated into the APM chrome. Displays IP-safe architecture diagrams, feature roadmaps, and live agent/UPM data for any CCEM-managed project that has showcase data.

### ShowcaseLive Components

- **Project Selector**: Dropdown listing all projects that have showcase data (detected via `ShowcaseDataStore.filter_showcase_projects/1`)
- **Feature Grid**: Cards per story/feature grouped by wave, sourced from `showcase/data/features.json`
- **Live Stats Bar**: Real-time agent count, session count, active UPM session indicator
- **Fullscreen Toggle**: Covers APM chrome; press Esc to exit
- **Iframe Mode**: Falls back to serving a standalone `showcase.js` when project has `showcase/client/showcase.js` but no full data directory

### ShowcaseLive Features

- **Project switching**: Navigate to `/showcase/:project` via `push_patch` — updates URL without full page reload
- **Active project detection**: Defaults to the project set in `apm_config.json` `active_project` field
- **Showcase data resolution**: `ShowcaseDataStore` checks (in order) `showcase_data_path`, `project_root/showcase/data/`, `project_root/showcase/client/showcase.js`
- **Live heartbeat**: Pushes 5-second heartbeat events to JS hook for animated status indicators
- **PubSub-driven updates**: Reacts to agent, config, UPM, AG-UI, and showcase data reload events

### ShowcaseLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:agents")     # Agent registration and fleet stats
subscribe("apm:config")     # Config reload, active project change
subscribe("apm:upm")        # UPM session events
subscribe("ag_ui:events")   # AG-UI event stream integration
subscribe("apm:showcase")   # Showcase data reload broadcasts
```

### ShowcaseLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:agent_registered, _agent}, socket)
handle_info({:agent_updated, _agent}, socket)
handle_info({:config_reloaded, _config}, socket)
handle_info({:upm_session_registered, _}, socket)
handle_info({:showcase_data_reloaded, project, data}, socket)
handle_info(:heartbeat_push, socket)
```

### ShowcaseLive JS Hooks

```javascript
// Showcase hook - initialises GIMME-style diagram engine, handles heartbeat pulses
Hooks.Showcase
```

### Project Switching

Use the URL parameter to load a named project:

```
/showcase            # active project from apm_config.json
/showcase/ccem       # CCEM APM project
/showcase/my-app     # Any project with showcase data
```

Reload showcase data for a project without restarting the server:

```elixir
ApmV5.ShowcaseDataStore.reload("my-app")
```

## AgentPanel Component

**Module**: `ApmV5Web.Components.AgentPanel`
**Extracted from**: `DashboardLive` (v6.2.0)

Reusable component that renders a single agent card with tier, status, and type classification badges. Supports filter-aware rendering so callers can pass active filter state without coupling.

### AgentPanel Features

- **Tier badges**: Tier 1 / Tier 2 / Tier 3 color-coded chips
- **Status badges**: active (green), idle (yellow), error (red), completed (gray), discovered (blue)
- **Type badges**: individual, squadron, swarm, orchestrator — each with a distinct icon
- **Filter support**: `active_filters` attribute hides non-matching agents without re-mounting the component
- **Click-to-inspect**: `phx-click="inspect_agent"` with `phx-value-agent-id` for right-panel integration

### AgentPanel Attributes

```elixir
attr :agent, :map, required: true
attr :active_filters, :map, default: %{}
attr :selected_agent_id, :string, default: nil
```

### AgentPanel Usage

```heex
<.agent_panel
  agent={agent}
  active_filters={@filters}
  selected_agent_id={@inspector_agent_id}
/>
```

## PortPanel Component

**Module**: `ApmV5Web.Components.PortPanel`
**Extracted from**: `DashboardLive` (v6.2.0)

Reusable component that renders a single port entry card. Highlights clash conditions with inline remediation suggestions.

### PortPanel Features

- **Clash alert banner**: Shown when two or more projects claim the same port number
- **Remediation display**: Suggests next available port in the project's namespace range
- **Status dot**: Green (active/in-use), gray (assigned but not active)
- **Namespace badge**: web / api / service / tool with distinct colors

### PortPanel Attributes

```elixir
attr :port_entry, :map, required: true
attr :clashes, :list, default: []
```

### PortPanel Usage

```heex
<.port_panel
  port_entry={entry}
  clashes={@port_clashes}
/>
```

## CcemOverviewLive

**Route**: `/ccem`
**Module**: `ApmV5Web.CcemOverviewLive`
**Added**: v6.0.0 | **Updated**: v6.4.0

CCEM Management overview page — the entry point for the CCEM-specific section of the dual-section sidebar nav. Provides quick-access navigation tiles to all CCEM management tools, a Getting Started wizard, and an AG-UI callout chat assistant that accepts natural language commands to update tile styles on the fly.

### CcemOverviewLive Components

- **Tool Grid**: Four quick-access tiles (`id` prefixed `ccem-tile-*`) for Showcase, Ports, Actions, and Scanner. Each tile has a Hero icon, label, and hover transform animation.
- **Dynamic Header**: Branded "CCEM Management" header with a "Getting Started" button (question-mark icon) that re-triggers the wizard
- **Status Strip**: Inline footer showing current CCEM version, APM port, links to Notifications and Agents pages
- **Getting Started Wizard**: Rendered via `<.wizard page={@wizard_page} />` component; shown on first visit, re-triggerable via header button; emits `ccem:wizard_trigger` push event to client
- **AG-UI Callout Chat**: Fixed bottom-right FAB button (gradient purple-to-indigo) that expands a 400-pixel-tall chat panel. Backed by `ChatStore` at scope `"ccem:overview"`. Processes natural language style commands via `process_ccem_command/1` and pushes `ccem:style_update` events to the `CcemAssistant` JS hook

### CcemOverviewLive Features

- **Dual-section sidebar**: The sidebar splits into two sections at runtime — **CCEM Management** (Showcase, Ports, Actions, Scanner, `/ccem`) and **APM Monitoring** (Dashboard, Agents, Skills, Ralph, Timeline, etc.)
- **Active page highlighting**: `/ccem` is highlighted in the CCEM Management section of the sidebar
- **Navigation hub**: Each tile links to a first-class CCEM management page rather than duplicating content inline
- **AG-UI natural language UI commands**: The callout chat parses commands and pushes CSS style updates to the client without a page reload. Examples: "make the showcase card blue", "set the ports card border color to orange", "reset all"
- **Streaming AG-UI responses**: Subscribes to `ag_ui:events` topic; forwards `TEXT_MESSAGE_CONTENT` events for agent `"ccem-assistant"` to the client as `ccem:stream_token` events

### CcemOverviewLive Navigation Tiles

| Tile | DOM ID | Route | Description |
|------|--------|-------|-------------|
| Showcase | `ccem-tile-showcase` | `/showcase` | Project showcase with live agent/UPM data |
| Ports | `ccem-tile-ports` | `/ports` | Port registry and conflict detection |
| Actions | `ccem-tile-actions` | `/actions` | ActionEngine catalog and run history |
| Scanner | `ccem-tile-scanner` | `/scanner` | Project auto-discovery scanner |

### CcemOverviewLive Key Assigns

```elixir
:chat_open          # boolean — controls chat panel visibility
:chat_messages      # list of message maps from ChatStore (last 50)
:chat_input         # string — current input field value
:chat_assembling    # map — partial streaming token state
:wizard_page        # string — current wizard page key (e.g., "welcome")
:wizard_visible     # boolean — whether wizard modal is open
```

### CcemOverviewLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("ag_ui:events")    # AG-UI event stream for ccem-assistant streaming replies
```

### CcemOverviewLive Event Handlers

User interaction events:

```elixir
handle_event("toggle_wizard", _params, socket)
handle_event("chat:toggle", _params, socket)
handle_event("chat:close", _params, socket)
handle_event("chat:input", %{"content" => val}, socket)
handle_event("chat:send", %{"content" => content}, socket)
```

PubSub handlers:

```elixir
handle_info({:ag_ui_event, event}, socket)   # streams TEXT_MESSAGE_CONTENT tokens
```

### CcemOverviewLive JS Hooks

```javascript
// CcemAssistant hook — applies ccem:style_update events as inline CSS,
// handles ccem:stream_token for streaming text, ccem:wizard_trigger to show wizard
Hooks.CcemAssistant
```

## UsageLive

**Route**: `/usage`
**Module**: `ApmV5Web.UsageLive`
**Added**: v6.4.0 (US-042)

Claude model and token usage dashboard. Tracks input tokens, output tokens, cache tokens, and tool call counts across all projects and Claude models. Data is populated by the PostToolUse hook and persisted via `ApmV5.ClaudeUsageStore`. The page auto-refreshes every 10 seconds.

### UsageLive Components

- **Summary Stats Row**: Four stat cards — Input Tokens, Output Tokens, Top Model (monospace truncated), Total Tool Calls. Badge shows project count.
- **Token Distribution Progress Bars**: Three horizontal progress bars (input=info, output=success, cache=warning) rendered when any tokens are recorded. Max value is the sum of all three token types.
- **Model Breakdown Table**: Per-model aggregate table sorted descending by input tokens. Columns: Model, Input, Output, Cache, Tool Calls, Sessions, Last Seen. Shown when `summary.model_breakdown` is non-empty.
- **Per-Project Accordion**: Collapsible rows per project. Header shows project name, effort-level badge (intensive=error, high=warning, medium=info, low=ghost), aggregate token counts, and a "Reset" button. Clicking expands an inner per-model breakdown table for that project.
- **Empty State**: Shown when `usage_data` is an empty map; instructs the user to activate the PostToolUse hook.

### UsageLive Key Assigns

```elixir
:summary          # %{total_input_tokens, total_output_tokens, total_cache_tokens,
                  #   total_tool_calls, top_model, model_breakdown, projects}
:usage_data       # map of project_name => usage map from ClaudeUsageStore.get_all_usage/0
:selected_project # nil | string — controls which project accordion is expanded
```

### UsageLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:usage")    # Usage record events
```

A 10-second `:timer.send_interval/3` is also started on mount (connected sockets only) to poll `ClaudeUsageStore` regardless of PubSub events.

### UsageLive Event Handlers

User interaction events:

```elixir
handle_event("select_project", %{"project" => project}, socket)
  # Toggles the project accordion; sets :selected_project to nil if re-clicking the same project
handle_event("reset_project", %{"project" => project}, socket)
  # Calls ClaudeUsageStore.reset_project/1, refreshes summary and usage_data
```

PubSub and timer handlers:

```elixir
handle_info({:usage_updated, data}, socket)   # PubSub push — updates usage_data + summary
handle_info(:refresh, socket)                 # 10-second timer poll
```

### UsageLive JS Hooks

None — all rendering is server-side via LiveView assigns. No client-side JavaScript hooks required.

### Usage API Endpoints

The same data is accessible via REST for external consumers:

```
GET  /api/usage              # all usage data
GET  /api/usage/summary      # aggregated summary
GET  /api/usage/project/:name# single project data
POST /api/usage/record       # record a usage event
DELETE /api/usage/project/:name # reset project counters
```

## Sidebar Navigation

All pages include a consistent sidebar with navigation links to all LiveView pages. The sidebar is split into two sections since v6.0.0.

### CCEM Management Section

```text
CCEM             /ccem        (overview hub)
Showcase         /showcase
Ports            /ports
Actions          /actions
Scanner          /scanner
```

### APM Monitoring Section

```text
Dashboard        /
All Projects     /apm-all
Skills           /skills      (with badge count)
Ralph            /ralph
Timeline         /timeline
Formations       /formation
Usage            /usage
Docs             /docs
```

Active page is highlighted with `bg-primary/10 text-primary font-medium`. Each page defines its own sidebar via a `nav_item` component.

## Live Update Pattern

When data changes, update socket assigns which triggers a re-render. Only changed HTML is sent to the client (efficient).

Example of handling a real-time agent update:

```elixir
def handle_info({:agent_updated, agent}, socket) do
  # Get current agents from socket
  agents = socket.assigns.agents

  # Update the specific agent
  updated_agents = Enum.map(agents, fn a ->
    if a.id == agent.id, do: agent, else: a
  end)

  # Re-render with new data
  {:noreply, assign(socket, :agents, updated_agents)}
end
```

> **Pattern:** Only update the specific assign that changed. Phoenix LiveView diffs the rendered HTML and sends only the changed parts over the WebSocket.

## Performance Tips

1. **Lazy Load**: Load initial data in mount, additional data on-demand
2. **Pagination**: Paginate large lists (agents, notifications)
3. **Debounce**: Debounce frequent events (heartbeats)
4. **Selective Updates**: Update only changed assigns
5. **Client-side Filtering**: Use JS hooks for fast filtering

## Testing LiveView Pages

LiveView pages are tested with `Phoenix.LiveViewTest`.

Example unit test for rendering:

```elixir
test "dashboard renders stats" do
  {:ok, view, html} = live(conn, "/")

  assert html =~ "Agents"
  assert html =~ "Sessions"
end
```

Example test for real-time updates:

```elixir
test "agent list updates on registration" do
  {:ok, view, _html} = live(conn, "/")

  send(view.pid, {:agent_registered, %{...}})

  assert render(view) =~ "new-agent"
end
```

See `test/apm_v5_web/live/` for more examples.

### Integration Test Suite (v6.2.0+)

A formal ExUnit integration test suite covering the two most-used LiveViews ships with v6.2.0. Tests live in `test/apm_v5_web/live/`.

**DashboardLive tests (8):**

| Test | Asserts |
|------|---------|
| renders agent count stat card | `html =~ "Agents"` |
| renders session count stat card | `html =~ "Sessions"` |
| agent list updates on `{:agent_registered, agent}` | new agent name appears |
| agent card removed on `{:agent_disconnected, id}` | agent name absent |
| filter by status hides non-matching agents | filtered agent absent |
| inspector panel opens on `inspect_agent` click | inspector panel visible |
| notification badge increments on new notification | badge count +1 |
| project selector reflects config active project | project name highlighted |

**ShowcaseLive tests (6):**

| Test | Asserts |
|------|---------|
| renders default active project | active project name visible |
| switches project on `/showcase/:project` navigate | new project features rendered |
| feature grid groups features by wave | wave heading present |
| live agent count updates on `{:agent_registered, _}` | stats bar count updated |
| fullscreen toggle sets `fullscreen` assign | `phx-value-fullscreen` attribute present |
| showcase data reload via `{:showcase_data_reloaded, _, _}` | updated feature title visible |

Run the full test suite:

```bash
mix test test/apm_v5_web/live/
```

## Extending with New LiveView Pages

To add a new LiveView page:

1. Create module in `lib/apm_v5_web/live/`
2. Add route in `lib/apm_v5_web/router.ex`
3. Add nav link in the `nav_item` section of your render function
4. Subscribe to relevant PubSub topics

See [Extending CCEM](extending.md) for details.
