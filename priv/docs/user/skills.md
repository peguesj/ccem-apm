# Skills — User Guide

**Version**: v6.4.0
**Author**: Jeremiah Pegues

The Skills page is the central hub for understanding, auditing, and repairing the skill definitions that power CCEM APM's agentic workflow. The v6.4.0 redesign replaces the previous flat-list analytics view with a three-tier health card grid, an interactive Fix Wizard, a live session timeline, and full AG-UI integration awareness — all built to WCAG 2.1 AA compliance.

---

## Overview

Prior to v6.4.0, the Skills page was a read-only analytics surface. The v6.4.0 redesign introduced:

- **Three-tier health classification** — Healthy / Needs Attention / Critical, each with a collapsible card grid and SVG health ring per skill
- **Skill Detail Drawer** — a slide-in panel with structured metadata, health breakdown progress bars, and raw frontmatter display
- **Fix Wizard** — a guided 4-step repair state machine (diagnose → select → preview → done) that dispatches ActionEngine repairs on demand
- **AG-UI Health Panel** — a dedicated tab mapping each skill's health score to its AG-UI event emission status (Connected / Degraded / Broken)
- **WCAG 2.1 AA compliance** — skip link, ARIA landmarks, tablist/tab/tabpanel roles, `aria-live` announcements, and full keyboard navigation

---

## Navigating to Skills

Open the Skills page by clicking **Skills** in the main sidebar navigation, or navigate directly to `/skills`.

The active skill count for the current session is shown as a badge on the sidebar link, so you always know how many skills have fired without opening the page.

### Keyboard Shortcut: Focus Search

Press `/` from anywhere on the Skills page to immediately focus the search input. The shortcut is suppressed when focus is already inside an input, select, or textarea element, so it will not interfere with typing.

---

## Page Layout

The Skills page is divided into three main areas:

1. **Top bar** — page title, tab switcher (Registry / Session / AG-UI), active filter count badge, and the Audit All button
2. **Filter bar** — visible only on the Registry tab; contains the search input and dropdown filters
3. **Content panel** — scrollable body that renders the active tab

---

## Registry Tab

The Registry tab is the default view. It shows all skills scanned from `~/.claude/skills/` organized into health tiers.

### Summary Stats

A stats strip at the top of the content panel shows:

| Stat | Description |
| :--- | :--- |
| **Total Skills** | Count of all skills in the registry |
| **Healthy** | Skills with `health_score >= 80` |
| **Needs Attention** | Skills with `health_score` in 50–79 |
| **Critical** | Skills with `health_score < 50` |

The stats strip uses `aria-label` attributes and labelled stat elements so screen readers can announce each value correctly.

### Three-Tier Health System

Skills are split into three tiers based on health score:

| Tier | Score Range | Visual |
| :--- | :--- | :--- |
| **Critical** | < 50 | Red label, error badge |
| **Needs Attention** | 50–79 | Yellow/amber label, warning badge |
| **Healthy** | ≥ 80 | Green label, success badge |

Each tier is a collapsible section with a toggle button that shows the tier name, a skill count badge, and a collapse/expand indicator. The toggle button uses `aria-expanded` and `aria-controls` to expose the state to assistive technology.

By default the Healthy tier is collapsed (to reduce visual noise) and both Critical and Needs Attention tiers are expanded. You can toggle any tier independently.

### Card Grid

Within each tier, skills are displayed in a responsive card grid:

- 1 column on small screens
- 2 columns on medium screens (`md:`)
- 3 columns on large screens (`lg:`)

Each card contains:

| Element | Description |
| :--- | :--- |
| **Health ring** | 40×40 SVG donut that fills proportionally to the health score. Green at ≥ 80, amber at 50–79, red below 50. The score numeral is centred inside the ring. |
| **Skill name** | Truncated if too long; full name shown in the drawer |
| **Description** | Two-line clamp of the skill's description text |
| **Description quality badge** | `good`, `poor`, or `missing` |
| **Last modified** | Human-readable relative timestamp |

Cards are keyboard navigable: `Tab` moves between cards, `Enter` or `Space` opens the Skill Detail Drawer for the focused card. Each card has an `aria-label` that reads the skill name, tier, and score — for example: `"ccem-apm: Healthy, score 92"`.

Clicking (or activating with keyboard) a card that is already selected closes the drawer.

### Audit All

Clicking **Audit All** in the top bar triggers a full re-scan of `~/.claude/skills/` via `SkillsRegistryStore.refresh_all/0`. While the scan is in progress, the button text changes to "Scanning…", the button shows a loading spinner, and the `aria-busy` attribute is set to `"true"`. The button is disabled during scanning to prevent duplicate runs.

When the scan completes, a PubSub message (`apm:skills`) updates all live assigns and re-renders the tier grids automatically — no page reload required.

If no skills are found, the grid area displays a prompt with a **Scan Now** button that triggers the same audit.

---

## Filter Bar

The filter bar is visible only when the Registry tab is active. It provides three independent filters that can be combined in any combination.

### Search Input

- **ID**: `skill-search`
- **Keyboard shortcut**: Press `/` to focus and select all text
- **Debounce**: 200 ms — filtering runs 200 ms after you stop typing, not on every keystroke
- Matches against skill name and description (case-insensitive)
- The `<label>` element is visually hidden (`sr-only`) but present for screen readers

### Tier Dropdown

Limits results to a specific health tier. Options:

- All tiers (default)
- Healthy
- Needs Attention
- Critical

### Methodology Dropdown

Limits results to skills associated with a specific methodology. Options:

- All methodologies (default)
- Ralph
- TDD
- Elixir Architect

### Active Filter Count Badge

When any filter is active, an `aria-live="polite"` badge in the top bar announces the number of active filters — for example, "2 filters active". This badge updates immediately when you add or remove filters.

Below the filter bar, when filters are active, a result count line reads: "Showing N of M skills". This is also wrapped in an `aria-live="polite"` region so screen readers announce changes after each filter adjustment.

### Clear Filters

A **Clear filters** button appears below the filter row when any filter is active. Clicking it resets all three filters to their defaults in a single operation.

---

## Skill Detail Drawer

Clicking a skill card opens the Skill Detail Drawer — a slide-in panel fixed to the right edge of the viewport.

### ARIA Role and Focus Management

The drawer is rendered as:

```html
<aside role="dialog" aria-modal="true" aria-labelledby="drawer-title" id="skill-drawer">
```

When the drawer opens, the `SkillsHook` JavaScript hook saves the element that had focus (typically the card that was clicked), then moves focus to the close button (`aria-label="Close skill details"`). When the drawer closes — whether via the close button, Escape key, or backdrop click — focus returns to the previously focused element.

A semi-transparent backdrop covers the rest of the page. Clicking the backdrop closes the drawer (equivalent to clicking the close button).

### Closing the Drawer

Three ways to close the drawer:

1. Click the **✕** close button in the drawer header
2. Press **Escape** — if the Fix Wizard is active and mid-step, Escape steps backwards through the wizard; once the wizard is at `nil` or `done`, Escape closes the drawer
3. Click the backdrop

### Drawer Header

The header shows:

- The health ring SVG for the selected skill
- The skill name (used as `id="drawer-title"` for the `aria-labelledby` reference)
- A health badge: tier label and numeric score, e.g. "Needs Attention — 62/100"

### Drawer Body Sections

**Description** — the skill's description text from its frontmatter, or "No description available." if absent.

**Health Breakdown** — five progress bars, each representing one scoring component:

| Component | Max Points | Awarded When |
| :--- | :--- | :--- |
| Frontmatter | 30 | Skill has valid YAML frontmatter |
| Description | 25 | Description quality is `good` (25), `poor` (10), or `missing` (0) |
| Triggers | 20 | Up to 20 points; 7 points per trigger defined, capped at 20 |
| Examples | 15 | Skill has at least one example block |
| Template | 10 | Skill has a template section |

Each bar uses `role="progressbar"` with `aria-valuenow`, `aria-valuemin`, and `aria-valuemax` for screen reader compatibility. The bar fill colour is green when full, amber when partial, and empty (base background) when zero.

**Frontmatter** — rendered as a monospace key/value list when the skill has raw frontmatter data. Hidden if frontmatter is absent.

**Metadata** — a `<dl>` list showing:

- File count
- Description quality (badge)
- Last modified date
- Has examples (Yes/No)
- Has template (Yes/No)

### Fix Wizard

When a skill's `health_score` is below 80, a **Fix Skill** button appears in the drawer footer. Skills at 80 or above show "Skill is healthy — no fixes needed" instead.

The Fix Wizard is a 4-step state machine:

#### Step 1 — Diagnose

Displays all detected issues for the selected skill with point penalties:

| Issue | Penalty |
| :--- | :--- |
| Missing frontmatter | −30 pts |
| Poor or missing description | −15 pts (poor) or −25 pts (missing) |
| No triggers defined | −20 pts |
| No examples | −15 pts |
| No template | −10 pts |

The step indicator reads "Step 1 of 3". Click **Select Repairs →** to advance, or **Cancel** to exit.

#### Step 2 — Select

Presents three checkboxes for the available repair actions:

| Repair | ActionEngine Action |
| :--- | :--- |
| Fix frontmatter | `fix_skill_frontmatter` |
| Improve description | `complete_skill_description` |
| Add triggers | `add_skill_triggers` |

Repairs that are not needed (the issue is already resolved) are pre-disabled and shown with strikethrough text. You must select at least one repair before the **Preview →** button becomes active. The Preview button uses `aria-disabled` to communicate its unavailable state when no repairs are selected.

Use **← Back** to return to the Diagnose step, or **Cancel** to exit.

#### Step 3 — Preview

Lists the selected repairs with a brief description of each action. This is the confirmation step before any writes occur. Click **Run Fixes** to dispatch the repairs, **← Back** to return to Select, or **Cancel** to exit.

Running fixes dispatches each selected `ActionEngine.run_action/3` call asynchronously. The wizard advances to the Done step immediately — the repairs run as background tasks.

#### Step 4 — Done

Confirms that repairs have been queued. Displays: "Repairs queued for `<skill-name>`. Run Audit All to rescan health."

Click **Close** (or press Escape) to dismiss the wizard. After the ActionEngine tasks complete, click **Audit All** to re-scan and see the updated health score.

---

## Session Tab

The Session tab shows skills that were invoked during the current active session, alongside cross-session analytics.

### Invocation Timeline

A vertical dot-timeline lists every skill invoked in the current session, sorted by `last_seen` descending (most recently invoked first).

Each timeline entry displays:

- A dot on the vertical line — filled with the primary colour if the skill is associated with a detected methodology, or a muted grey otherwise
- The skill name
- A methodology badge (e.g. `ralph`, `tdd`) if applicable
- An invocation count badge — for example `7×`
- A relative timestamp — for example "3 mins ago"

Each entry is rendered as an `<article role="listitem">` with an `aria-label` that includes the skill name, count, and relative time for screen reader users.

If no skills have been invoked in the current session, the timeline shows "No skills invoked in current session." in a polite live region.

### Skill Catalog

A sortable table showing cross-session skill usage statistics:

| Column | Description |
| :--- | :--- |
| **Skill** | Skill identifier |
| **Total Invocations** | Cumulative count across all sessions |
| **Sessions** | Number of sessions that used this skill |
| **Source** | Source badge (e.g. `user`, `agent`, `hook`) |

Skills are sorted by total invocations descending. The table uses `<caption class="sr-only">` for screen readers and `scope="col"` on all header cells.

### Skill Co-occurrence

When co-occurrence data is available, a table shows pairs of skills that frequently appear in the same sessions:

| Column | Description |
| :--- | :--- |
| **Skill A** | First skill identifier |
| **Skill B** | Second skill identifier |
| **Sessions Together** | Count of sessions where both skills fired |

Pairs are sorted by session count descending. This section is hidden when no co-occurrence data exists.

---

## AG-UI Tab

The AG-UI tab maps each skill's health score to its AG-UI event emission status. It is the operational view for understanding which skills are actively contributing to the AG-UI event stream.

### AG-UI Health Panel

A stats strip at the top shows three counters:

| Status | Score Range | Description |
| :--- | :--- | :--- |
| **Connected** | ≥ 80 | Healthy hooks emitting events normally |
| **Degraded** | 50–79 | Partial connectivity; hooks may be emitting with errors |
| **Broken** | < 50 | Hooks need repair; event emission is failing or absent |

These counts are derived directly from `health_score` — the same values shown in the Registry tab summary.

### Skills as AG-UI Event Emitters

A responsive card grid shows each skill with:

- Skill name (truncated if needed)
- A pulsing status dot: green (Connected), amber (Degraded), red (Broken)
- The status label text
- A `CUSTOM` event type badge
- A `valid` badge (success outline) if the skill has valid frontmatter
- A **Repair** button (error outline) for skills with `health_score < 50`

Each card has an `aria-label` that reads: `"Skill <name>: <status>"`.

### Hook Repair

The Hook Repair section shows the overall health of the AG-UI Event Bridge:

- A status dot (green if no broken hooks, red if any exist)
- A human-readable summary: "All hooks operational" or "N hook(s) need repair"

The **Repair All Hooks** button dispatches `ActionEngine.run_action("update_hooks", …)` which restarts and redeploys the event bridge for all skills. This is the bulk repair action; use the per-skill **Repair** button in the Fix Wizard for targeted repairs.

---

## Real-Time Updates

The Skills page subscribes to the `apm:skills` PubSub topic on mount. When any agent tracks a skill (via `POST /api/skills/track`) or when an audit completes, the PubSub message triggers a live refresh of all assigns — session skills, catalog, co-occurrence, registry, and active skill count — without any page reload.

All counters, badges, and tier grids update in place. The `aria-live="polite"` regions on the filter result count and the filter active badge will announce changes to screen reader users after each update.

---

## Accessibility

The Skills page is built to WCAG 2.1 AA across all tabs.

### Skip Link

A visually hidden skip link is the first focusable element in the DOM:

```
Skip to main content
```

It becomes visible on focus and links to `#main-content`. This satisfies WCAG 2.4.1 (Bypass Blocks).

### ARIA Landmarks

| Role | Element | Purpose |
| :--- | :--- | :--- |
| `navigation` (`aria-label="Main navigation"`) | `<nav>` wrapping sidebar | Main navigation landmark |
| `main` (`aria-label="Skills dashboard"`) | `<main id="main-content">` | Main content landmark |
| `search` (`aria-label="Filter skills"`) | Filter bar wrapper | Search landmark |
| `dialog` / `aria-modal="true"` | Skill detail drawer | Modal dialog landmark |

### Tab Switcher

The Registry / Session / AG-UI switcher uses full ARIA tablist semantics:

- Container: `role="tablist" aria-label="Skills views"`
- Each button: `role="tab"`, `aria-selected`, `aria-controls="tabpanel-<name>"`
- Each content panel: `role="tabpanel"`, `aria-labelledby="tab-<name>"`, `tabindex="0"`

### Focus Management

- **Drawer open**: focus moves to the close button immediately via `requestAnimationFrame`
- **Drawer close**: focus returns to the element that was focused before the drawer opened
- **Escape key**:
  - During Fix Wizard steps 2–3: steps back one wizard step
  - With drawer open, no wizard active: closes drawer
  - With drawer closed: no-op

### Live Regions

| Region | Location | Purpose |
| :--- | :--- | :--- |
| `aria-live="polite"` | Active filter count badge | Announces filter count changes |
| `aria-live="polite"` | Filter result count line | Announces "Showing N of M skills" |
| `aria-live="polite"` | Session timeline empty state | Announces when no skills are active |

### Keyboard Navigation in Card Grid

Each skill card has `tabindex="0"` and responds to `Enter` or `Space` to open the detail drawer. This mirrors standard interactive widget behaviour and does not require mouse access.

---

## API Reference

The Skills API is served from the `SkillsController` and `SkillTracker` context modules.

### GET /api/skills/registry

Returns all skills in the registry with health scores and metadata.

```bash
curl http://localhost:3032/api/skills/registry
```

Response:

```json
{
  "skills": [
    {
      "name": "ccem-apm",
      "health_score": 92,
      "has_frontmatter": true,
      "description": "Agentic Performance Monitor skill for CCEM APM.",
      "description_quality": "good",
      "file_count": 3,
      "has_examples": true,
      "has_template": true,
      "trigger_count": 4,
      "last_modified": "2026-03-15T10:22:00Z"
    }
  ]
}
```

### GET /api/skills/:name

Returns the full record for a single skill by name.

```bash
curl http://localhost:3032/api/skills/ccem-apm
```

Response:

```json
{
  "skill": {
    "name": "ccem-apm",
    "health_score": 92,
    "has_frontmatter": true,
    "description": "Agentic Performance Monitor skill for CCEM APM.",
    "description_quality": "good",
    "raw_frontmatter": {
      "name": "ccem-apm",
      "version": "1.0.0",
      "triggers": ["apm", "ccem apm", "monitor agents"]
    },
    "file_count": 3,
    "has_examples": true,
    "has_template": true,
    "trigger_count": 3,
    "last_modified": "2026-03-15T10:22:00Z"
  }
}
```

Returns `404` if the skill is not found in the registry.

### GET /api/skills/:name/health

Returns only the health score and tier for a single skill. Useful for lightweight polling.

```bash
curl http://localhost:3032/api/skills/ccem-apm/health
```

Response:

```json
{
  "name": "ccem-apm",
  "health_score": 92,
  "tier": "healthy"
}
```

### POST /api/skills/audit

Triggers a full re-scan of `~/.claude/skills/`. Equivalent to clicking **Audit All** in the UI. The scan runs asynchronously; the response confirms the scan was initiated.

```bash
curl -X POST http://localhost:3032/api/skills/audit \
  -H "Content-Type: application/json" \
  -d '{}'
```

Response:

```json
{
  "status": "ok",
  "message": "Skill audit initiated"
}
```

Once the audit completes, the PubSub broadcast updates all connected LiveView clients automatically.

---

## Troubleshooting

### No skills appear on the Registry tab

- Ensure `~/.claude/skills/` exists and contains at least one skill directory with a `SKILL.md` file
- Click **Audit All** (or `POST /api/skills/audit`) to trigger the initial scan
- Check the APM server log at `~/Developer/ccem/apm/hooks/apm_server.log` for scan errors

### Health scores are lower than expected

Review the Health Breakdown bars in the Skill Detail Drawer. Common causes:

| Symptom | Fix |
| :--- | :--- |
| Frontmatter bar is 0/30 | Add YAML frontmatter block (`---`) to `SKILL.md` |
| Description bar is low | Expand the description to at least 20 words for `good` quality |
| Triggers bar is 0/20 | Add `triggers:` list to frontmatter |
| Examples bar is 0/15 | Add an `## Examples` section to `SKILL.md` |
| Template bar is 0/10 | Add a `## Template` section to `SKILL.md` |

Alternatively, use the Fix Wizard (click **Fix Skill** in the drawer footer) for automated guided repair.

### Fix Wizard repairs not taking effect

- Repairs are dispatched to `ActionEngine` as background tasks — they do not complete instantly
- Wait a few seconds, then click **Audit All** to re-scan
- Check `/tasks` in the sidebar to see the status of repair tasks

### AG-UI tab shows all skills as Broken

- The AG-UI event bridge may need repair — click **Repair All Hooks** on the AG-UI tab
- If issues persist, check that the APM server is running: `GET http://localhost:3032/api/status`

### Search returns unexpected results

- Search matches on skill name and description text (case-insensitive, partial match)
- Combining search with tier or methodology filters applies all constraints simultaneously
- Click **Clear filters** to reset all filters and confirm the unfiltered result set

---

## See Also

- [Agent Fleet](/docs/user/agents) — Understanding agent types and statuses
- [Actions](/docs/user/actions) — Running and monitoring ActionEngine actions
- [Background Tasks](/docs/user/tasks) — Monitoring repair and audit tasks
- [API Reference](/docs/developer/api-reference) — Complete endpoint documentation
