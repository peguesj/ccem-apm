# CCEM UI — Dual-Section Sidebar and Management Hub

Since v6.0.0, CCEM APM uses a dual-section sidebar that distinguishes **CCEM Management** tools from **APM Monitoring** pages. This section documents the navigation architecture and the `/ccem` overview hub.

## Dual-Section Sidebar

The sidebar is split into two visually distinct sections at runtime:

### CCEM Management Section

Routes for managing the CCEM environment itself:

| Label | Route | Description |
|-------|-------|-------------|
| CCEM | `/ccem` | Management hub overview |
| Showcase | `/showcase` | Project showcase dashboard |
| Ports | `/ports` | Port registry and conflict detection |
| Actions | `/actions` | ActionEngine catalog |
| Scanner | `/scanner` | Project auto-discovery |

### APM Monitoring Section

Routes for monitoring Claude Code agent activity:

| Label | Route | Description |
|-------|-------|-------------|
| Dashboard | `/` | Agent fleet and real-time metrics |
| All Projects | `/apm-all` | Multi-project overview |
| Skills | `/skills` | Skill tracking and analytics |
| Ralph | `/ralph` | Ralph methodology flowchart |
| Timeline | `/timeline` | Session execution timeline |
| Formations | `/formation` | Formation hierarchy |
| Docs | `/docs` | Documentation |

### Active Page Highlighting

The active route is highlighted with `bg-primary/10 text-primary font-medium` in the sidebar. Each LiveView page passes `current_path` to the `<.sidebar_nav>` component so the correct entry is highlighted:

```heex
<.sidebar_nav current_path="/ccem" />
```

## CcemOverviewLive

**Route**: `/ccem`
**Module**: `ApmV5Web.CcemOverviewLive`

The CCEM Management hub is a stateless overview page that provides quick-access tiles to all management tools. It has no PubSub subscriptions.

### Navigation Tiles

```
┌─────────────────┬─────────────────┐
│   Showcase      │     Ports       │
│  /showcase      │    /ports       │
├─────────────────┼─────────────────┤
│   Actions       │    Scanner      │
│  /actions       │   /scanner      │
└─────────────────┴─────────────────┘
```

Each tile uses an icon, label, and hover highlight. Clicking navigates to the respective management page.

### Dynamic Header Branding

The header on CCEM Management pages displays **"CCEM Management"** instead of **"APM"** to visually distinguish the two areas. This is controlled by the LiveView module rather than a shared layout, keeping the branding accurate per section.

## Port Management — /ports

**Route**: `/ports`
**Module**: `ApmV5Web.PortsLive`

The port management dashboard gives a real-time view of all port assignments registered with `ApmV5.PortManager`.

### Features

- **Port registry**: Lists all projects with their assigned ports, namespaces, and active status
- **Conflict detection**: Automatically detects and highlights port clashes between projects
- **Namespace filtering**: Filter by namespace (web, api, service, tool)
- **Status filtering**: Show all ports, only active, or only clashing
- **Port ranges sidebar**: Visual utilization bars per namespace range
- **Clash resolution**: One-click reassign for conflicting ports
- **Active scanning**: Scan live ports on the system to update active status

### PortManager API

```elixir
# Get all registered ports
ApmV5.PortManager.get_port_map()
#=> %{3032 => %{project: "ccem", namespace: :api, active: true}, ...}

# Detect clashes
ApmV5.PortManager.detect_clashes()
#=> [%{port: 3000, projects: ["app-a", "app-b"]}, ...]

# Assign next available port in a namespace
ApmV5.PortManager.assign_port("my-project")
#=> {:ok, 3100}

# Scan active ports on the system
ApmV5.PortManager.scan_active_ports()
#=> :ok
```

### PubSub

`PortsLive` subscribes to `apm:ports` and refreshes on `{:port_assigned, _, _}` messages.

### Port Namespace Ranges

| Namespace | Range | Use |
|-----------|-------|-----|
| `web` | 3000–3069 | Front-end dev servers, Next.js, Vite |
| `api` | 3070–3099 | API servers, Phoenix backends |
| `service` | 3100–3149 | Microservices, workers |
| `tool` | 3150–3199 | Dev tools, test servers, utilities |

## ActionEngine — /actions

ActionEngine provides a catalog of automated actions that can be run against CCEM projects. See the [API Reference](api-reference.md) for the `/api/actions` endpoints.

## ProjectScanner — /scanner

The project scanner auto-discovers projects in configured developer directories. See the [Architecture](architecture.md) page for `ProjectScanner` GenServer details.
