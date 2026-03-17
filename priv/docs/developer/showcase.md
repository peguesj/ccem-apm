# Showcase — GIMME-Style Dashboard

The Showcase is an IP-safe, project-switchable presentation layer integrated directly into the CCEM APM chrome. It renders architecture diagrams, feature roadmaps, and live agent/UPM data for any project that provides a showcase data directory.

## Route

```
/showcase             # Active project from apm_config.json
/showcase/:project    # Explicit project by name
```

**Module**: `ApmV5Web.ShowcaseLive`

## Architecture

```
ShowcaseLive
  └── ShowcaseDataStore (GenServer + ETS)
        ├── load features.json
        ├── load narrative-content.json
        ├── load diagram-design-system.json
        ├── load redaction-rules.json
        └── load speaker-notes.json
```

The `ShowcaseDataStore` is an ETS-backed GenServer that caches showcase data per project. It resolves the data path in this priority order:

1. `project.showcase_data_path` — explicit override in `apm_config.json`
2. `project.project_root/showcase/data/` — conventional relative path
3. `~/Developer/{project_name}/showcase/data/` — convention-based discovery

CCEM projects (`"ccem"`, `"CCEM APM"`, `"apm-v4"`) always use `~/Developer/ccem/showcase/data/`. All other projects resolve independently — if no data directory is found, an empty showcase state is returned with zero features.

## Project Switching

Navigate to a named project using the URL parameter:

```
/showcase/ccem        # CCEM APM project
/showcase/my-app      # Any project with showcase data
```

Project switching uses `push_patch/2` — the URL updates without a full page reload, and the socket assigns are updated in `handle_params/3`.

To programmatically list projects with showcase data:

```elixir
config = ApmV5.ConfigLoader.get_config()
all_projects = Map.get(config, "projects", [])
showcase_projects = ApmV5.ShowcaseDataStore.filter_showcase_projects(all_projects)
```

`filter_showcase_projects/1` checks each project map for a usable showcase path.

## ShowcaseDataStore API

```elixir
# Get all showcase data for a project
ApmV5.ShowcaseDataStore.get_showcase_data("ccem")
#=> %{"features" => [...], "narratives" => %{}, ...}

# Get just the feature list
ApmV5.ShowcaseDataStore.get_features("ccem")
#=> [%{"id" => "US-001", "wave" => 1, "title" => "AG-UI Protocol", ...}, ...]

# Reload from disk (hot-reload without server restart)
ApmV5.ShowcaseDataStore.reload("my-app")
#=> :ok

# Check if a project has showcase data
ApmV5.ShowcaseDataStore.has_showcase?(%{"project_root" => "/path/to/project"})
#=> true | false
```

After `reload/1`, the store broadcasts `{:showcase_data_reloaded, project_name, data}` on the `apm:showcase` PubSub topic so `ShowcaseLive` updates automatically.

## Showcase Data Directory Structure

```
showcase/data/
├── features.json           # Feature list: id, wave, title, description
├── narrative-content.json  # Section narratives: problem, solution, outcome
├── diagram-design-system.json  # Colors, fonts, spacing constants
├── redaction-rules.json    # IP redaction: terms to replace, abstraction level
└── speaker-notes.json      # Per-slide speaker notes
```

### features.json Schema

```json
[
  {
    "id": "US-001",
    "wave": 1,
    "title": "Feature Title",
    "description": "What this feature does — one or two sentences.",
    "status": "done"
  }
]
```

Features are grouped by `wave` in the UI and rendered as animated cards.

## IP-Safe Presentation

The showcase uses C4 abstraction levels to avoid exposing proprietary implementation details:

- **Level 1 (Context)**: System name, external actors, high-level data flows
- **Level 2 (Container)**: Major services and their responsibilities
- **Level 3 (Component)**: Internal modules — only if publicly known or generic

Proprietary terms in `redaction-rules.json` are substituted before rendering. This allows presenting architecture to external audiences without disclosing internal naming conventions, algorithms, or business logic.

## Fullscreen Mode

Click the fullscreen icon in the header to expand the showcase to cover the entire APM chrome. Press **Esc** to exit fullscreen mode.

## PubSub Events

`ShowcaseLive` subscribes to the following topics on mount (connected sockets only):

| Topic | Purpose |
|-------|---------|
| `apm:agents` | Update live agent count in stats bar |
| `apm:config` | React to active project changes |
| `apm:upm` | Update UPM session status indicator |
| `ag_ui:events` | Receive AG-UI events for real-time diagram updates |
| `apm:showcase` | React to `ShowcaseDataStore.reload/1` calls |

## Extending Showcase Data

To add a new project's showcase:

1. Create `your-project/showcase/data/` and add at minimum `features.json`
2. Add the project to `apm_config.json` with its `project_root`
3. Navigate to `/showcase/your-project` — the data loads automatically
4. Optionally call `ApmV5.ShowcaseDataStore.reload("your-project")` to force a cache refresh

See [Extending CCEM APM](extending.md) for the full extension guide.
