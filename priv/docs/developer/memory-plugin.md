# Memory Plugin — Claude-Mem APM Integration

CCEM APM v9.2.0 introduces the Memory plugin, which bridges the external `claude-mem` worker service into the APM dashboard. It surfaces conversation observations, provides search and timeline views, and correlates memory entries to agent sessions.

## Plugin Scope

```elixir
:memory
```

Registered as a first-class `plugin_scope` atom in `ApmV5.Plugins.PluginBehaviour`. The Memory plugin is implemented by `ApmV5.Plugins.Memory.MemoryPlugin`.

## Architecture

The Memory plugin is composed of three supervised GenServer processes started as children of the root `ApmV5.Supervisor`:

| Module | Role |
|:-------|:-----|
| `ApmV5.Plugins.Memory.MemoryClientBridge` | HTTP client to the `claude-mem` worker; SQLite fallback when worker is unreachable |
| `ApmV5.Plugins.Memory.ObservationCache` | ETS-backed store with TTL expiry and LRU eviction; broadcasts updates on `"apm:memory"` |
| `ApmV5.Plugins.Memory.ConversationMemoryCorrelator` | Links observation IDs to APM session IDs for cross-referencing |

### MemoryClientBridge

`MemoryClientBridge` is a `GenServer` that polls the `claude-mem` HTTP worker at a configurable interval. On each poll it:

1. Fetches the latest observations from `http://localhost:<claude_mem_port>/observations`
2. Normalises the response into `ApmV5.Plugins.Memory.Observation` structs
3. Inserts updated entries into `ObservationCache`
4. Falls back to local SQLite if the worker returns a non-200 status or is unreachable

```elixir
# Fetch all observations (delegates to cache)
ApmV5.Plugins.Memory.MemoryClientBridge.list_observations()

# Search by keyword (delegated to cache full-text scan)
ApmV5.Plugins.Memory.MemoryClientBridge.search_observations("agent registration")

# Get a single observation by ID
ApmV5.Plugins.Memory.MemoryClientBridge.get_observation("obs_abc123")
```

### ObservationCache

ETS-backed GenServer with:

- **TTL**: configurable per-entry expiry (default 24 hours)
- **LRU eviction**: evicts least-recently-used entries when the table exceeds the size limit
- **PubSub**: broadcasts `{:memory_updated, observations}` on `"apm:memory"` after each write

ETS table name: `:memory_observations`

```elixir
# Read directly from ETS (O(1))
:ets.lookup(:memory_observations, "obs_abc123")
```

### ConversationMemoryCorrelator

Links `claude-mem` observation IDs to CCEM APM session IDs. Used by `ConversationMonitorLive` to display a Memory tab and by `MemoryLive` to display a Sessions section for each observation.

```elixir
ApmV5.Plugins.Memory.ConversationMemoryCorrelator.correlate("obs_abc123", "session_xyz")
ApmV5.Plugins.Memory.ConversationMemoryCorrelator.sessions_for("obs_abc123")
ApmV5.Plugins.Memory.ConversationMemoryCorrelator.observations_for("session_xyz")
```

## Plugin Actions

`MemoryPlugin` implements `PluginBehaviour` and exposes five actions callable via the Engine Plugins panel at `/plugins`:

| Action | Description |
|:-------|:------------|
| `list_observations` | Return all cached observations, sorted by timestamp descending |
| `search_observations` | Full-text search across observation content and metadata |
| `get_observation` | Fetch a single observation by ID with full detail |
| `timeline` | Return observations bucketed by hour for the past 24 hours |
| `health_check` | Check claude-mem worker reachability and cache freshness |

## LiveView: /memory

`ApmV5Web.MemoryLive` serves the `/memory` route. It subscribes to `"apm:memory"` and renders three tabs:

| Tab | Content |
|:----|:--------|
| Browse | Paginated list of all observations with type badges and timestamps |
| Search | Keyword search box with instant results; links to detail panel |
| Timeline | Hour-by-hour bar chart of observation volume for the past 24 hours |

The observation detail panel slides in from the right and shows:

- Full observation content
- Linked APM sessions (from `ConversationMemoryCorrelator`)
- Source (claude-mem worker or SQLite fallback)
- TTL remaining in `ObservationCache`

## Dashboard Widget

Widget ID: `memory_observations`

Registered in `ApmV5.Plugins.WidgetRegistry` with:

```elixir
%{
  id: "memory_observations",
  title: "Memory Observations",
  plugin_scope: :memory,
  pinnable: true,
  editable: false,
  supported_scopes: [:global, :project],
  default_config: %{max_rows: 5, show_timeline: true},
  display_order: 60
}
```

The widget renders a compact summary card showing:

- Total cached observations
- claude-mem worker health indicator (green/amber/red)
- Last-updated timestamp
- Sparkline of observation volume over the past hour

## REST API Endpoints

All endpoints are registered under the `/api/v2/memory` prefix.

| Method | Path | Description |
|:-------|:-----|:------------|
| GET | `/api/v2/memory/observations` | List all observations (paginated, `?page=1&per_page=50`) |
| GET | `/api/v2/memory/observations/:id` | Fetch a single observation by ID |
| GET | `/api/v2/memory/search` | Full-text search (`?q=<keyword>`) |
| GET | `/api/v2/memory/timeline` | Hourly observation counts for the past 24 hours |
| GET | `/api/v2/memory/health` | claude-mem worker status and cache statistics |

### GET /api/v2/memory/observations

```bash
curl http://localhost:3032/api/v2/memory/observations?page=1&per_page=20
```

Example response:

```json
{
  "observations": [
    {
      "id": "obs_abc123",
      "content": "Agent registered with session session_xyz",
      "type": "agent_event",
      "timestamp": "2026-04-22T10:30:00Z",
      "session_id": "session_xyz",
      "ttl_remaining_s": 86100
    }
  ],
  "total": 142,
  "page": 1,
  "per_page": 20
}
```

### GET /api/v2/memory/search

```bash
curl "http://localhost:3032/api/v2/memory/search?q=agent+registration"
```

Example response:

```json
{
  "query": "agent registration",
  "results": [
    {
      "id": "obs_abc123",
      "content": "Agent registered with session session_xyz",
      "score": 0.94
    }
  ]
}
```

### GET /api/v2/memory/health

```bash
curl http://localhost:3032/api/v2/memory/health
```

Example response:

```json
{
  "worker_reachable": true,
  "worker_url": "http://localhost:4040",
  "cache_size": 142,
  "cache_ttl_s": 86400,
  "last_poll_at": "2026-04-22T10:29:55Z",
  "fallback_active": false
}
```

## PubSub Topic

| Topic | Event | Payload |
|:------|:------|:--------|
| `"apm:memory"` | `{:memory_updated, observations}` | Full list of current cached observations |
| `"apm:memory"` | `{:memory_health_changed, status}` | Worker health change (`%{reachable: bool, fallback: bool}`) |

Subscribe in a LiveView:

```elixir
Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:memory")

@impl true
def handle_info({:memory_updated, observations}, socket) do
  {:noreply, assign(socket, :observations, observations)}
end
```

## Navigation

The Memory plugin adds a sidebar nav entry under the CCEM Management section:

```elixir
%{path: "/memory", label: "Memory", icon: "hero-circle-stack"}
```

The entry is only visible when `MemoryClientBridge` reports at least one observation or the claude-mem worker is reachable.

## Error Handling

- If the claude-mem worker is unreachable, `MemoryClientBridge` switches to SQLite fallback and broadcasts `{:memory_health_changed, %{reachable: false, fallback: true}}`.
- If SQLite is also unavailable, the cache is left with its last-known state and a warning notification is sent to `"apm:notifications"`.
- `ObservationCache` continues serving stale data until TTL expiry rather than returning errors to callers.

## Configuration

No additional `apm_config.json` fields are required. The claude-mem worker URL defaults to `http://localhost:4040` and can be overridden in `config/runtime.exs`:

```elixir
config :apm_v5, :memory_plugin,
  claude_mem_url: System.get_env("CLAUDE_MEM_URL", "http://localhost:4040"),
  poll_interval_ms: 30_000,
  cache_ttl_s: 86_400,
  cache_max_size: 10_000
```
