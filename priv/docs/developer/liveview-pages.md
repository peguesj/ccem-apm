# LiveView Pages

CCEM APM v4 uses Phoenix LiveView for real-time, interactive web pages. Each page maintains a WebSocket connection with the server for live updates without page refresh.

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

Skill tracking, analytics, and methodology detection.

### SkillsLive Components

- **Skill Catalog**: All skills with usage counts
- **Co-Occurrence Matrix**: Heatmap of skill relationships
- **Detected Methodologies**: Active TDD, refactor-max, fix-loop, etc.
- **Trending Skills**: Week-over-week changes
- **UEBA Anomalies**: Flagged unusual behavior

### SkillsLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:skills")    # Skill tracking events
subscribe("apm:agents")    # Agent updates for context
```

### SkillsLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:skill_tracked, skill}, socket)
handle_info({:methodology_detected, methodology}, socket)
```

### SkillsLive JS Hooks

Client-side hooks for data visualization:

```javascript
// CoOccurrenceHeatmap hook - renders heatmap matrix
Hooks.CoOccurrenceHeatmap

// TrendingChart hook - renders trend lines
Hooks.TrendingChart
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

Port management dashboard for viewing and managing port assignments across all CCEM projects.

### PortsLive Components

- **Summary Bar**: Total projects, active count, clash count with scan button
- **Filter Bar**: Filter by status (all/active/clashes) and namespace (all/web/api/service/tool)
- **Port Cards Grid**: Each project shown as a card with port number, namespace badge, active status dot, and clash warnings with reassign button
- **Port Ranges Sidebar**: Visual display of configured port ranges per namespace with usage bars
- **Clash Resolution Panel**: Lists all port clashes with affected projects

### PortsLive Features

- Real-time updates via `apm:ports` PubSub topic
- Scan active ports on the system to detect which are in use
- Assign new ports to projects from available ranges
- Detect and resolve port clashes between projects
- Filter by status (active, clashes) and namespace (web, api, service, tool)

### PortsLive PubSub Subscriptions

Topics subscribed to on mount:

```elixir
subscribe("apm:ports")    # Port assignment events
```

### PortsLive Event Handlers

Handlers for incoming PubSub messages:

```elixir
handle_info({:port_assigned, _, _}, socket)
```

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

## Sidebar Navigation

All pages include a consistent sidebar with navigation links to all LiveView pages.

Navigation entries and their routes:

```text
Dashboard        /
All Projects     /apm-all
Skills           /skills      (with badge count)
Ralph            /ralph
Timeline         /timeline
Formations       /formation
Ports            /ports
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

## Extending with New LiveView Pages

To add a new LiveView page:

1. Create module in `lib/apm_v5_web/live/`
2. Add route in `lib/apm_v5_web/router.ex`
3. Add nav link in the `nav_item` section of your render function
4. Subscribe to relevant PubSub topics

See [Extending CCEM](extending.md) for details.
