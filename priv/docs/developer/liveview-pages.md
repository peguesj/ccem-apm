# LiveView Pages

CCEM APM v4 uses Phoenix LiveView for real-time, interactive web pages. Each page maintains WebSocket connection with server for live updates without page refresh.

## Architecture

Each LiveView page follows this pattern:

```elixir
defmodule ApmV4Web.DashboardLive do
  use ApmV4Web, :live_view

  def render(assigns), do: ~H"""..."""

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to PubSub topics
      ApmV4.PubSub.subscribe("apm:agents")
      ApmV4.PubSub.subscribe("apm:notifications")
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

## DashboardLive

**Route**: `/`
**Template**: `lib/apm_v4_web/live/dashboard_live.html.heex`
**Module**: `ApmV4Web.DashboardLive`

The main dashboard showing all agents, metrics, and real-time data.

### Components

- **Stats Cards**: Agent count, session count, project count, skill count
- **Agent Fleet List**: Filterable table of all agents
- **D3 Dependency Graph**: Visual agent relationships
- **Filter Bar**: Status, type, search filters
- **Right Panel Tabs**: Inspector, Ralph, UPM, Commands, TODOs

### PubSub Subscriptions

```elixir
subscribe("apm:agents")      # Agent registration, updates
subscribe("apm:notifications")  # New alerts
subscribe("apm:config")      # Config changes
subscribe("apm:skills")      # Skill events
```

### Event Handlers

```elixir
handle_info({:agent_registered, agent}, socket)
handle_info({:agent_updated, agent}, socket)
handle_info({:agent_discovered, id, project}, socket)
handle_info({:notification_added, notif}, socket)
handle_info({:config_reloaded, config}, socket)
```

### JS Hooks

```javascript
// Clock hook - updates relative timestamps
Hooks.Clock

// DependencyGraph hook - renders D3 graph
Hooks.DependencyGraph
```

## AllProjectsLive

**Route**: `/apm-all`
**Template**: `lib/apm_v4_web/live/all_projects_live.html.heex`
**Module**: `ApmV4Web.AllProjectsLive`

Multi-project overview and management page.

### Features

- **Project List**: All configured projects with stats
- **Project Selector**: Switch active project
- **Cross-Project Metrics**: Aggregate stats across projects
- **Project Configuration**: Add/remove projects
- **Session Summary**: Sessions per project

### PubSub Subscriptions

```elixir
subscribe("apm:config")      # Config reload, project changes
subscribe("apm:agents")      # Agent registration
```

### Event Handlers

```elixir
handle_info({:config_reloaded, config}, socket)
handle_info({:agent_registered, agent}, socket)
```

## SkillsLive

**Route**: `/skills`
**Template**: `lib/apm_v4_web/live/skills_live.html.heex`
**Module**: `ApmV4Web.SkillsLive`

Skill tracking, analytics, and methodology detection.

### Components

- **Skill Catalog**: All skills with usage counts
- **Co-Occurrence Matrix**: Heatmap of skill relationships
- **Detected Methodologies**: Active TDD, refactor-max, fix-loop, etc.
- **Trending Skills**: Week-over-week changes
- **UEBA Anomalies**: Flagged unusual behavior

### PubSub Subscriptions

```elixir
subscribe("apm:skills")      # Skill tracking events
subscribe("apm:agents")      # Agent updates for context
```

### Event Handlers

```elixir
handle_info({:skill_tracked, skill}, socket)
handle_info({:methodology_detected, methodology}, socket)
```

### JS Hooks

```javascript
// CoOccurrenceHeatmap hook - renders heatmap matrix
Hooks.CoOccurrenceHeatmap

// TrendingChart hook - renders trend lines
Hooks.TrendingChart
```

## RalphFlowchartLive

**Route**: `/ralph`
**Template**: `lib/apm_v4_web/live/ralph_flowchart_live.html.heex`
**Module**: `ApmV4Web.RalphFlowchartLive`

Ralph methodology flowchart and story tracking visualization.

### Components

- **Flowchart**: Vertical swim lanes per story with timeline
- **Color Coding**: Status indicators (complete, in-progress, blocked)
- **Dependencies**: Arrows showing story dependencies
- **Agent Assignments**: Icons showing assigned agents per story
- **Legend**: Status color reference

### PubSub Subscriptions

```elixir
subscribe("apm:agents")      # Agent status changes
subscribe("apm:upm")         # Story and wave progress
subscribe("apm:tasks")       # Task completions
```

### Event Handlers

```elixir
handle_info({:upm_event, event}, socket)
handle_info({:agent_updated, agent}, socket)
handle_info({:tasks_synced, project, tasks}, socket)
```

### JS Hooks

```javascript
// RalphFlowchart hook - renders SVG flowchart
Hooks.RalphFlowchart

// DependencyArrows hook - draws dependency relationships
Hooks.DependencyArrows
```

## SessionTimelineLive

**Route**: `/timeline`
**Template**: `lib/apm_v4_web/live/session_timeline_live.html.heex`
**Module**: `ApmV4Web.SessionTimelineLive`

Session execution timeline with event log.

### Components

- **Timeline Visualization**: Horizontal or vertical timeline
- **Event Entries**: Each event with timestamp, agent, action
- **Filtering**: By event type, agent, date range
- **Zoom/Pan**: Navigate time periods
- **Export**: Download session log

### PubSub Subscriptions

```elixir
subscribe("apm:agents")      # All agent events
subscribe("apm:upm")         # UPM execution events
subscribe("apm:audit")       # Audit log entries
subscribe("apm:tasks")       # Task events
```

### Event Handlers

```elixir
handle_info({:audit_entry, entry}, socket)
handle_info({:upm_event, event}, socket)
handle_info({:agent_updated, agent}, socket)
```

### JS Hooks

```javascript
// Timeline hook - renders timeline visualization
Hooks.Timeline

// EventFilter hook - client-side event filtering
Hooks.EventFilter
```

## DocsLive

**Route**: `/docs`
**Template**: `lib/apm_v4_web/live/docs_live.html.heex`
**Module**: `ApmV4Web.DocsLive`

Interactive documentation viewer with search and navigation.

### Components

- **Doc List**: Sidebar navigation of all docs
- **Doc Viewer**: Rendered markdown content
- **Search**: Full-text search across docs
- **Breadcrumbs**: Current doc path
- **Table of Contents**: Headings from current doc

### Features

- **Markdown Rendering**: Converts .md to HTML
- **Syntax Highlighting**: Code blocks with language detection
- **Search Indexing**: Full-text search over all docs
- **Static Serving**: Docs in `priv/docs/`

### PubSub Subscriptions

None - docs are static.

## Sidebar Navigation

All pages include sidebar with navigation:

```heex
<aside class="sidebar">
  <nav>
    <a href="/" class={active?(page, :dashboard)}>
      Dashboard
    </a>
    <a href="/apm-all" class={active?(page, :projects)}>
      All Projects
    </a>
    <a href="/skills" class={active?(page, :skills)}>
      Skills
    </a>
    <a href="/ralph" class={active?(page, :ralph)}>
      Ralph
    </a>
    <a href="/timeline" class={active?(page, :timeline)}>
      Timeline
    </a>
    <a href="/docs" class={active?(page, :docs)}>
      Docs
    </a>
  </nav>
</aside>
```

Active page is highlighted using conditional class.

## JS Hooks

JavaScript hooks enable client-side interactivity:

### Clock Hook
Updates relative timestamps every second.

```javascript
Hooks.Clock = {
  mounted() {
    setInterval(() => {
      this.updateTimestamps()
    }, 1000)
  }
}
```

### DependencyGraph Hook
Renders D3.js force-directed graph.

```javascript
Hooks.DependencyGraph = {
  mounted() {
    const data = JSON.parse(this.el.dataset.graph)
    d3.forceSimulation(data.nodes)
      .force("link", d3.forceLink(data.links))
      .on("tick", () => this.updateGraph())
  }
}
```

### RalphFlowchart Hook
Renders SVG flowchart with swimlanes.

```javascript
Hooks.RalphFlowchart = {
  mounted() {
    const svg = d3.select(this.el)
    this.drawFlowchart(svg)
  }
}
```

### Timeline Hook
Renders timeline visualization.

```javascript
Hooks.Timeline = {
  mounted() {
    const timeline = new Timeline(this.el, this.el.dataset.events)
    timeline.render()
  }
}
```

## Live Update Pattern

When data changes, update socket assigns which triggers re-render:

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

Only changed HTML is sent to client (efficient).

## Performance Tips

1. **Lazy Load**: Load initial data in mount, additional data on-demand
2. **Pagination**: Paginate large lists (agents, notifications)
3. **Debounce**: Debounce frequent events (heartbeats)
4. **Selective Updates**: Update only changed assigns
5. **Client-side Filtering**: Use JS hooks for fast filtering

## Testing

LiveView pages tested with `Phoenix.LiveViewTest`:

```elixir
test "dashboard renders stats" do
  {:ok, view, html} = live(conn, "/")

  assert html =~ "Agents"
  assert html =~ "Sessions"
end

test "agent list updates on registration" do
  {:ok, view, _html} = live(conn, "/")

  send(view.pid, {:agent_registered, %{...}})

  assert render(view) =~ "new-agent"
end
```

See `test/apm_v4_web/live/` for examples.

## Extending

To add a new LiveView page:

1. Create module in `lib/apm_v4_web/live/`
2. Create template in `lib/apm_v4_web/live/` with `.html.heex`
3. Add route in `lib/apm_v4_web/router.ex`
4. Add nav link in sidebar component
5. Subscribe to relevant PubSub topics

See [Extending CCEM](extending.md) for details.
