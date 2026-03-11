# Dashboard Guide

> **Prerequisite:** Complete [Getting Started](/docs/user/getting-started) first.

The CCEM APM dashboard is your central hub for monitoring agent workflows, tracking projects, and managing Claude Code sessions.

## Dashboard Layout

### Top Navigation Bar

- **CCEM APM Logo** (left) - Links to home dashboard
- **Project Selector** (dropdown) - Switch between configured projects
- **Search Bar** (center) - Filter agents and tasks by name
- **Settings Icon** (right) - Access configuration and help

### Stats Cards

Four key metrics displayed at the top of the page:

| Card | Metric | Details |
| :--- | :--- | :--- |
| **Agents** | Total active agents | Count of all registered agents across all statuses |
| **Sessions** | Active Claude Code sessions | Number of currently tracked sessions |
| **Projects** | Configured projects | Number of projects in apm_config.json |
| **Skills** | Total skills tracked | Cumulative skill events recorded |

Stats update in real-time as agents register and send heartbeats.

> **Tip:** Use the filter picker below the stats cards to switch between All and Active views.

## Agent Fleet List

### Central Panel

The main panel displays a live-updating table of agents:

| Column | Description |
| :--- | :--- |
| **Name** | Agent identifier, clickable for details |
| **Type** | individual, squadron, swarm, or orchestrator |
| **Status** | active, idle, error, discovered, or completed |
| **Tier** | 1-3 classification (1=entry, 2=intermediate, 3=expert) |
| **Project** | Namespace/project the agent belongs to |
| **Updated** | Relative timestamp (e.g., "5 mins ago") |

Click an agent row to populate the **Right Panel** with details.

### Filtering Agents

Use the **Filter Bar** below the stats cards:

- **Status Filter**: Show only agents with specific status (All, Active, Idle, Error, Discovered, Completed)
- **Type Filter**: Filter by agent type (All, Individual, Squadron, Swarm, Orchestrator)
- **Search**: Type agent name to filter in real-time
- **Clear All**: Reset filters to show all agents

## D3 Dependency Graph

### Graph Elements

A D3.js-rendered dependency graph shows:

- **Nodes** (circles) = Individual agents
- **Links** (lines) = Agent relationships and dependencies
- **Node Color** = Agent status (green=active, yellow=idle, red=error, gray=discovered)
- **Node Size** = Agent tier and workload

### Graph Interactions

- **Drag Nodes**: Reposition for clarity
- **Hover**: Shows agent name and type in tooltip
- **Click Node**: Selects agent and updates right panel
- **Double-Click**: Centers graph on that agent
- **Zoom**: Mouse wheel to zoom in/out
- **Pan**: Click and drag background to pan

### Graph Legend

Located below the graph:

| Color | Status |
| :--- | :--- |
| Green circle | Active |
| Yellow circle | Idle |
| Red circle | Error |
| Gray circle | Discovered |

Line thickness indicates dependency strength.

## Right Panel Tabs

When you select an agent, the right panel shows five tabs:

### Inspector Tab

Detailed agent information:

```text
Name: test-agent
Type: individual
Status: active
Tier: 2
Project: ccem
Namespace: session-abc123
Capabilities: [analysis, code-review, refactoring]
Last Update: 2026-02-19 12:34:56 UTC
Token Budget: 45000 / 100000
Current Task: Analyzing authentication module
Progress: 65%
```

Copy buttons are available for agent ID and JSON payload.

### Ralph Tab

Ralph methodology execution details:

- **Current PRD**: Link to prd.json
- **Autonomous Fix Loop Status**: Active/idle
- **Current Story**: Name and progress
- **Flowchart Link**: `/ralph` page for visualization
- **Metrics**: Tokens used, tasks completed, estimated remaining time

### UPM Tab

Unified Project Management execution tracking:

- **Waves**: Grouped work items
- **Stories**: Individual tasks
- **Events**: Execution timeline
- **Status**: Wave/story completion percentage

Example output:

```text
Wave 1: Foundation (80% complete)
  - Story 1: Setup (completed)
  - Story 2: Config (completed)
  - Story 3: API (in progress)
Wave 2: Expansion (20% complete)
  - Story 4: Testing (pending)
```

### Commands Tab

Available slash commands and recent command history:

- **/spawn**: Create new agent
- **/fix**: Autonomous fix workflow
- **/tdd**: Test-driven development
- **/analyze**: Code analysis

Shows command syntax, parameters, and recent invocations with timestamps.

### TODOs Tab

Task list for the selected agent:

- **Pending Tasks**: Not yet started
- **In Progress**: Currently being worked on
- **Completed**: Finished tasks

Each task shows description, priority, estimated tokens, and assignee.

## Sidebar Navigation

Left sidebar provides quick access:

- **Dashboard** (home icon) - Current view
- **All Projects** - Multi-project overview
- **Skills** - Skill tracking and analytics
- **Ralph** - Methodology flowchart
- **Timeline** - Session timeline
- **Docs** - This documentation

The active page is highlighted.

## Real-time Updates

The dashboard uses WebSocket to receive live updates:

- New agents appear within 1 second of registration
- Agent status changes update instantly
- Notifications broadcast to all connected clients
- Dependency graph redraws on significant changes

> **Note:** If WebSocket disconnects, a reconnection banner appears at the top of the page. The dashboard automatically attempts to reconnect.

## Keyboard Shortcuts

| Shortcut | Action |
| :---: | :--- |
| `?` | Open help/command reference |
| `/` | Focus search bar |
| `e` | Toggle agent details (when focused) |
| `g` | Jump to dependency graph |
| `t` | Jump to task list |

## Responsive Design

The dashboard adapts to screen size:

| Breakpoint | Layout |
| :--- | :--- |
| Desktop (1440px+) | Full three-column layout (stats, agents/graph, details) |
| Tablet (768px-1439px) | Two columns, details below |
| Mobile (< 768px) | Stack view, access panels via tabs |

## Performance Notes

- Dashboard optimized for 100-500 agents
- D3 graph groups agents into clusters at 1000+ agents
- Updates throttled to 1/sec for smooth UX
- Browser local storage caches filter preferences

## Troubleshooting

### Dependency Graph Not Rendering

- Check browser console (F12) for JS errors
- Refresh page (Cmd+R on Mac, Ctrl+R on Windows)
- Clear browser cache

### Real-time Updates Not Working

- Check WebSocket connection in DevTools Network tab
- Verify server is running: `curl http://localhost:3032/health`
- Restart server: `mix phx.server`

### Agents Not Appearing

- Ensure agent POST `/api/register` succeeded
- Check notification bell for errors
- Verify project name matches apm_config.json

> **Tip:** Open browser DevTools (F12) and filter the Network tab by "websocket" to diagnose real-time update issues.

See [Troubleshooting](/docs/admin/troubleshooting) for more help.

---

## See Also

- [Agent Fleet](/docs/user/agents) - Understanding agent types and statuses
- [Ralph Methodology](/docs/user/ralph) - Autonomous workflow execution
- [UPM Integration](/docs/user/upm) - Project management tracking
- [Skills Analytics](/docs/user/skills) - Skill usage and co-occurrence
