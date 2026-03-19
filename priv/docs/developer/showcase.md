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

## Activity Tab (v6.1.0)

The Activity Tab is the second tab of the showcase panel. It provides live observability of agent activity without leaving the presentation view.

### Activity Tab Components

- **D3.js force-directed graph**: Each active agent rendered as a node; edges represent coordination/dependency links registered via the agent's `deps` field
- **anime.js pulse rings**: Agents with `status: "active"` emit a continuous concentric pulse ring animation at their node
- **30-event pull-down log**: Scrollable list of the 30 most recent events pulled from `GET /api/agents/activity-log?limit=30`; rendered below the force graph

### Activity Tab JS

The activity tab is driven by the `Showcase` hook in `assets/js/hooks/showcase.js`. On tab activation the hook:

1. Calls `GET /api/agents/activity-log?limit=30` to seed the event log
2. Subscribes to `apm:activity_log` via the LiveView channel to receive incremental events
3. Initialises the D3 force simulation with the current agent list
4. Starts anime.js pulse ring animations for each active agent node

Agent nodes auto-animate on `{:activity_log_event, event}` messages where `event.type == "lifecycle"`.

## Feature Inspector (v6.1.0)

The Feature Inspector is a collapsible right-column panel that provides per-feature detail without navigating away from the showcase.

### Feature Inspector Components

- **Acceptance criteria checklist**: Criteria sourced from `features.json` `acceptance_criteria` array; each item rendered as a checkbox (read-only, reflecting `done` status)
- **Related agents list**: Agents whose `story_id` field matches the selected feature's `id`; pulled live from the current agent roster on the socket
- **Status mini-timeline**: Four milestones (`planned → in-progress → review → done`) with the current status highlighted; timestamps shown where available from UPM events

### Feature Inspector Integration

To populate the acceptance criteria checklist, add an `acceptance_criteria` array to entries in `features.json`:

```json
{
  "id": "US-031",
  "wave": 6,
  "title": "AgentActivityLog GenServer",
  "status": "done",
  "acceptance_criteria": [
    {"text": "Ring buffer holds ≤200 events", "done": true},
    {"text": "PubSub broadcasts on apm:activity_log", "done": true},
    {"text": "REST endpoint returns chronological order", "done": true}
  ]
}
```

Opening the inspector is triggered by clicking a feature card. The panel opens via a CSS transition on a `data-inspector-open` attribute toggled by the `Showcase` hook.

## Template System (v6.1.0)

The Template System allows operators to switch the showcase canvas layout at runtime without reloading the page.

### TEMPLATES Registry

A `TEMPLATES` object defined in `showcase.js` maps template IDs to layout configurations:

```javascript
const TEMPLATES = {
  "engine":    { layout: "engine",    columns: 3, animate: true },
  "formation": { layout: "formation", columns: 2, animate: false }
}
```

Built-in templates:

| ID | Layout | Description |
|----|--------|-------------|
| `engine` | `engine` | 3-column feature grid, animated card entrances |
| `formation` | `formation` | 2-column wave-grouped list, compact mode |

### Applying a Template

Templates are applied programmatically by dispatching the `showcase:template-changed` custom event:

```javascript
window.dispatchEvent(new CustomEvent("showcase:template-changed", {
  detail: { templateId: "formation" }
}))
```

The `Showcase` hook listens for this event and calls `applyTemplate(id)`, which:

1. Looks up the template in `TEMPLATES`
2. Updates the root container's `data-layout` attribute
3. Re-triggers the entry animations if `animate: true`
4. Preserves the current selected feature in the Feature Inspector

### Template API

The active template can also be changed server-side by pushing a `template_changed` event from the LiveView:

```elixir
push_event(socket, "template_changed", %{template_id: "formation"})
```

## Project Dropdown UX (v6.1.0)

The project selector dropdown was reorganised in v6.1.0 into three labelled sections for faster navigation in multi-project APM deployments.

### Dropdown Sections

| Section | Contents |
|---------|----------|
| **Active** | The single project currently set in `apm_config.json` `active_project` |
| **Recently Active** | Projects with a session registered in the last 24 hours |
| **Other** | All remaining configured projects with showcase data |

### categorize_projects/2

Projects are sorted into sections by `ApmV5Web.ShowcaseLive.categorize_projects/2`:

```elixir
@spec categorize_projects([map()], String.t()) ::
  %{active: [map()], recently_active: [map()], other: [map()]}
def categorize_projects(projects, active_project_name)
```

The function is a pure helper (no GenServer calls) — pass the projects list from `ConfigLoader.get_config()` and the active project name string.

## Extending Showcase Data

To add a new project's showcase:

1. Create `your-project/showcase/data/` and add at minimum `features.json`
2. Add the project to `apm_config.json` with its `project_root`
3. Navigate to `/showcase/your-project` — the data loads automatically
4. Optionally call `ApmV5.ShowcaseDataStore.reload("your-project")` to force a cache refresh

See [Extending CCEM APM](extending.md) for the full extension guide.
