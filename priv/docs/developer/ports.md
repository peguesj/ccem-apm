# Port Registry and Port Intelligence

Port Registry and Port Intelligence is an CCEM APM v6.4.0 feature that tracks port assignments across all developer projects, detects conflicts, and provides smart reassignment via the `PortManager` GenServer and the `/ports` LiveView dashboard.

## Route

```
/ports    # Port management dashboard
```

**Module**: `ApmV5Web.PortsLive`

## Overview

Every developer project in a multi-project workspace competes for a finite set of TCP ports. Port Registry centralises this knowledge so CCEM APM can surface conflicts early and automate resolution.

```
PortManager (GenServer)
  ├── build_project_configs/0   # parse session files → project → port map
  ├── scan_active_ports/0       # lsof -iTCP:LISTEN → active port map
  ├── detect_clashes/0          # group port_map by port → >1 project = clash
  └── PubSub broadcast          # "apm:ports" on scan completion
```

`PortManager` starts under the application supervision tree. On init it performs an immediate config parse (`handle_continue(:initial_scan, state)`) and then kicks off a non-blocking `lsof` scan in a `Task`. The LiveView (`PortsLive`) subscribes to the `"apm:ports"` PubSub topic on mount and refreshes whenever the scan completes.

## Port Registry Architecture

### GenServer State

`PortManager` holds three collections in process state:

| Key | Type | Description |
|-----|------|-------------|
| `port_map` | `%{port => %{project, root, namespace, active}}` | All configured ports keyed by port number |
| `active_ports` | `%{port => %{pid, command, cwd, full_command, server_type, namespace}}` | Ports currently bound on the host per `lsof` |
| `project_configs` | `%{project_name => config}` | Full per-project config including all detected ports and stack info |

### Session-File Discovery

Project configs are built from APM session files at `~/Developer/ccem/apm/sessions/`. Each `*.json` session file contains a `project_root` (or `working_directory`) which is used to locate config files. The scan reads:

| Source | File | Detection Pattern |
|--------|------|-------------------|
| `:env` | `.env` | `PORT=\d+` |
| `:package_json` | `package.json` | `--port N` or `-p N` in scripts |
| `:next_config` | `next.config.{js,mjs,ts}` | `port: N` |
| `:dev_exs` | `config/dev.exs` | `port: N` |

### Port Entry Schema

Each entry in `port_map` has the shape:

```elixir
%{
  project:   "my-app",        # project name from session file
  root:      "/path/to/root", # project_root from session file
  namespace: :web,            # atom — :web | :api | :service | :tool | :other
  active:    false            # updated after lsof scan
}
```

After an `lsof` scan, `active_ports` entries are enriched with:

```elixir
%{
  pid:          12345,
  command:      "beam.smp",
  cwd:          "/path/to/project",
  full_command: "elixir --erl ... mix phx.server",
  server_type:  :phoenix,      # :phoenix | :nextjs | :vite | :node | :python_web | ...
  namespace:    :web
}
```

### Namespace Ranges

Ports are categorised into four namespaces based on their number:

| Namespace | Range | Typical use |
|-----------|-------|-------------|
| `:web` | 3000–3999 | Web servers, dev servers (Next.js, Vite, Phoenix) |
| `:api` | 4000–4999 | API servers, backend services |
| `:service` | 5000–6999 | Internal services, message brokers |
| `:tool` | 7000–9999 | Tooling, databases, dashboards |

Categorisation is performed by `categorize/1` pattern-matching on port number ranges.

## Conflict Detection

A conflict (clash) occurs when two or more projects are configured to use the same port number. `detect_clashes/0` groups `port_map` entries by port and returns only those groups with more than one project:

```elixir
port_map
|> Enum.group_by(fn {port, _} -> port end, fn {_, info} -> info.project end)
|> Enum.filter(fn {_, projects} -> length(projects) > 1 end)
|> Enum.map(fn {port, projects} ->
  owner = find_exclusive_owner(port)
  %{port: port, projects: projects, owner: owner, should_move: [...]}
end)
```

### Exclusive Ownership

A project may declare exclusive ownership of a port in `apm_config.json`:

```json
{
  "name": "my-app",
  "primary_port": 3000,
  "port_ownership": "exclusive"
}
```

When `find_exclusive_owner/1` identifies such a project, the clash struct includes `owner: "my-app"` and `should_move: [<other projects>]`. The smart reassignment logic and recommendation text use this to determine which projects must move.

Ownership values: `"exclusive"` | `"shared"` | `"reserved"`.

### Remediation Suggestions

`suggest_remediation/1` returns a suggestion map for a given port:

```elixir
ApmV5.PortManager.suggest_remediation(3000)
#=> %{
#     port: 3000,
#     claimants: [%{project: "app-a", source: :env, file: ".env", namespace: :web}, ...],
#     alternatives: [3001, 3002, 3003],  # up to 3 free ports in same namespace
#     recommendation: "Move app-b to port 3001 (update .env)"
#   }
```

Alternatives are drawn from the same namespace range, excluding both configured and currently-active ports.

## API Reference

All port endpoints are under `/api/` (or `/api/v2/` — the router aliases both).

### `GET /api/ports`

Returns the full port map, namespace ranges, and any current clashes.

**Response:**
```json
{
  "ok": true,
  "ports": {
    "3000": {"project": "my-app", "root": "/path", "namespace": "web", "active": true},
    "3032": {"project": "ccem-apm", "root": "/path", "namespace": "api", "active": true}
  },
  "ranges": {
    "web":     {"first": 3000, "last": 3999},
    "api":     {"first": 4000, "last": 4999},
    "service": {"first": 5000, "last": 6999},
    "tool":    {"first": 7000, "last": 9999}
  },
  "clashes": []
}
```

### `POST /api/ports/scan`

Triggers a live `lsof` scan of TCP listening ports on the host. Returns the currently-active port map. The scan runs synchronously from the caller's perspective but the underlying `lsof` call is handled by the GenServer; the response is the cached result from the most recent scan.

**Response:**
```json
{
  "ok": true,
  "active_ports": {
    "3000": {"pid": 12345, "command": "node", "namespace": "web", "server_type": "nextjs"}
  }
}
```

### `POST /api/ports/assign`

Assign the next available port in a namespace or for a specific project.

**By namespace:**
```json
{"namespace": "web"}
```

**By project name:**
```json
{"project": "my-app"}
```

**Response:**
```json
{"ok": true, "port": 3001}
```

Returns HTTP 422 if no port is available in the namespace, or HTTP 400 if the namespace name is invalid.

### `GET /api/ports/clashes`

Returns only the current clash list without the full port map. Useful for polling from hooks or agents that only need conflict state.

**Response:**
```json
{
  "ok": true,
  "clashes": [
    {
      "port": 3000,
      "projects": ["app-a", "app-b"],
      "owner": null,
      "should_move": []
    }
  ]
}
```

### `POST /api/ports/set-primary`

Set a project's primary port and ownership mode in `apm_config.json`.

**Request:**
```json
{
  "project":   "my-app",
  "port":      3000,
  "ownership": "exclusive"
}
```

`ownership` must be one of `"exclusive"`, `"shared"`, or `"reserved"`. Defaults to `"shared"` if omitted.

**Response:**
```json
{
  "ok": true,
  "project": "my-app",
  "primary_port": 3000,
  "port_ownership": "exclusive"
}
```

Returns HTTP 400 for missing parameters or an invalid ownership value. Returns HTTP 422 if the config update fails.

## ActionEngine Integration

Four port-related actions are registered in `ApmV5.ActionEngine`'s catalog under the `"ports"` category. Actions are invoked via `POST /api/actions/run` with `{"action_id": "<id>"}`.

### `register_all_ports`

Scans all configured projects and assigns a port for any project that has no port assignments detected. Calls `PortManager.assign_port/1` for each gap (defaults to the `:web` namespace).

```json
{"action_id": "register_all_ports"}
```

**Result shape:**
```json
{
  "newly_assigned": 2,
  "skipped": 5,
  "assignments": [
    {"project": "new-service", "port": 3003}
  ]
}
```

### `update_port_namespace`

Moves a project's port assignment to a different namespace. Finds the next available port in the target namespace, calls `PortManager.reassign_port/2`, and returns the new port.

```json
{
  "action_id": "update_port_namespace",
  "params": {
    "project":   "my-app",
    "namespace": "api"
  }
}
```

**Result shape:**
```json
{
  "project":    "my-app",
  "namespace":  "api",
  "new_port":   4001,
  "message":    "Port reassigned to api namespace (port 4001)"
}
```

Returns an error if no port is available in the target namespace.

### `analyze_port_assignment`

Returns a summary of port utilization across the entire registered project fleet: namespace distribution, active vs inactive counts, clash summary, and a utilization percentage.

```json
{"action_id": "analyze_port_assignment"}
```

**Result shape:**
```json
{
  "total_ports":         7,
  "active_ports":        3,
  "clash_count":         1,
  "namespace_distribution": {"web": 4, "api": 2, "service": 1, "tool": 0, "other": 0},
  "namespace_capacity":  {"web": 1000, "api": 1000, "service": 2000, "tool": 3000},
  "utilization_pct":     0.07,
  "clashes": [
    {"port": 3000, "projects": ["app-a", "app-b"], "owner": null}
  ]
}
```

### `smart_reassign_ports`

Analyzes active clashes and produces a resolution plan. If no clashes exist it returns immediately. Otherwise it builds a suggestion list (using `suggest_remediation/1`) and returns it for review. The caller must apply each suggestion individually using `update_port_namespace`.

```json
{"action_id": "smart_reassign_ports"}
```

**No clashes:**
```json
{"message": "No port clashes detected", "changes": []}
```

**With clashes:**
```json
{
  "message": "Review suggestions and use update_port_namespace to apply",
  "suggestions": [
    {
      "port":       3000,
      "projects":   ["app-a", "app-b"],
      "suggestion": "Keep app-a on port 3000, reassign others"
    }
  ]
}
```

This action is designed to feed into an AG-UI chat flow: the suggestions are presented as structured text in `InspectorChatLive`, the operator confirms, and the apply step is a follow-up `update_port_namespace` call for each affected project.

## PortsLive Dashboard

Navigate to `/ports` in the CCEM APM chrome to open the Port Manager dashboard.

### Header Bar

The top bar shows three counters updated on every PubSub event:

- **projects** — total number of entries in `port_map`
- **active** — count of entries whose port is currently bound per `lsof`
- **clashes** (shown only when > 0) — count of clash groups

The **Scan Ports** button sends a `"scan_ports"` LiveView event, which calls `PortManager.scan_active_ports/0` and rebinds the socket assigns.

### Filter Bar

Two independent filter axes:

| Axis | Options |
|------|---------|
| **Status** | All / Active / Clashes |
| **Namespace** | All / Web / Api / Service / Tool |

Filters are applied client-side in `refilter/1` without a server round-trip. Status `"active"` shows only entries where `active == true`. Status `"clashes"` shows only entries whose project name appears in any clash group.

### Project Cards

Each configured project is rendered as a card showing:

- Project name and namespace badge (colour-coded: blue=web, purple=api, amber=service, emerald=tool)
- Port number in large monospace font
- Active indicator dot (green = bound, grey = not bound)
- When clashing: a red "Port clash" banner with a **Reassign** button that triggers `"assign_port"` for that project (finds next available port in the same namespace)

### Port Ranges Panel

A sidebar panel on the right shows all four namespaces with their configured range (first–last) and a proportional utilization bar. Bar width is computed as `Range.size(range) / 70` capped at 100%, providing a visual heatmap of namespace density.

### Clash Resolution Panel

When `clash_count > 0`, a dedicated section renders below the card grid. Each clash entry shows the conflicting port number and all projects claiming it. Use the Reassign button on individual cards or the `smart_reassign_ports` action for batch resolution.

## Smart Reassignment — AG-UI Chat Flow

Smart port reassignment is surfaced through the `InspectorChatLive` panel available on the `/ports` route. The flow:

1. Agent sends `smart_reassign_ports` action via `POST /api/actions/run`
2. ActionEngine returns a suggestions list
3. `InspectorChatLive` renders each suggestion as a structured message card (AG-UI `TEXT_MESSAGE_CONTENT` events)
4. Operator reviews and approves suggestions in chat
5. Each confirmed suggestion triggers `update_port_namespace` with the target project and namespace
6. `PortManager` reassigns and broadcasts `{:port_assigned, project, new_port}` on `"apm:ports"` PubSub
7. `PortsLive` receives the broadcast and rebinds `port_map` and `clashes`

For automated conflict resolution without operator confirmation, call `update_port_namespace` directly for each clash entry in the `smart_reassign_ports` response.

## PubSub Events

`PortManager` and `PortsLive` use the `"apm:ports"` PubSub topic.

| Topic | Message | When | Subscribers |
|-------|---------|------|-------------|
| `"apm:ports"` | `{:ports_updated, active_ports}` | After every `lsof` scan completes (async `Task`) | `PortsLive` |
| `"apm:ports"` | `{:port_assigned, project, port}` | After a successful `assign_port` or `reassign_port` call | `PortsLive` |

`PortsLive` handles both messages in `handle_info/2` by calling `PortManager.get_port_map/0` and `PortManager.detect_clashes/0` to refresh state:

```elixir
def handle_info({:port_assigned, _, _}, socket) do
  port_map = ApmV5.PortManager.get_port_map()
  clashes  = ApmV5.PortManager.detect_clashes()
  {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
end
```

The `{:ports_updated, _}` broadcast is cast from the `handle_cast({:scan_result, active}, state)` callback after each background scan.

No other LiveViews subscribe to `"apm:ports"` by default. Agents or hooks that need real-time port state should poll `GET /api/ports` or `GET /api/ports/clashes` rather than subscribing to PubSub directly.

## Elixir API Quick Reference

```elixir
# Full port map (configured ports, enriched with active status)
ApmV5.PortManager.get_port_map()

# All per-project configs with ports, stack, config files, and apm_config enrichment
ApmV5.PortManager.get_project_configs()

# Trigger a live lsof scan (async; updates state via cast)
ApmV5.PortManager.scan_active_ports()

# All clash groups
ApmV5.PortManager.detect_clashes()

# Namespace ranges map (%{web: 3000..3999, api: 4000..4999, ...})
ApmV5.PortManager.get_port_ranges()

# Assign next available port in a namespace
ApmV5.PortManager.assign_port(:web)          #=> {:ok, 3001} | {:error, :no_available_port}
ApmV5.PortManager.assign_port("my-app")      #=> {:ok, 3001} (defaults to :web)

# Reassign a project to a specific port (in-memory; config file update is manual)
ApmV5.PortManager.reassign_port("my-app", 3005)  #=> {:ok, 3005} | {:error, :project_not_found}

# Set primary port + ownership in apm_config.json
ApmV5.PortManager.set_primary_port("my-app", 3000, "exclusive")  #=> :ok | {:error, reason}

# Remediation suggestion for a specific port
ApmV5.PortManager.suggest_remediation(3000)
#=> %{port: 3000, claimants: [...], alternatives: [3001, 3002, 3003], recommendation: "..."}
```

## Extending Port Detection

To add a new config file format to port detection, add a private `detect_*_detailed/1` function in `ApmV5.PortManager` that returns a list of port-info maps:

```elixir
defp detect_myformat_detailed(root) do
  with {:ok, content} <- File.read(Path.join(root, "my.config")),
       [_, port_str]  <- Regexep.run(~r/listen_port\s*=\s*(\d+)/, content),
       {port, _}      <- Integer.parse(port_str) do
    [%{port: port, source: :myformat, file: "my.config", namespace: categorize(port)}]
  else
    _ -> []
  end
end
```

Then call it from `detect_ports_detailed/1`:

```elixir
defp detect_ports_detailed(root) do
  detect_env_detailed(root) ++
  detect_pkg_json_detailed(root) ++
  detect_next_config_detailed(root) ++
  detect_dev_exs_detailed(root) ++
  detect_myformat_detailed(root)   # add here
end
```

No other changes are required — the port entry will appear in `port_map`, the dashboard, and clash detection automatically.

---

See [Architecture Overview](architecture.md) for the full supervision tree. See [Extending CCEM APM](extending.md) for adding new GenServers and LiveViews.

**Version**: v6.4.0
**Author**: Jeremiah Pegues
