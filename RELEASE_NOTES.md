# CCEM APM v6.4.0 Release Notes

**Release date**: 2026-03-18
**Author**: Jeremiah Pegues <jeremiah@pegues.io>

## Highlights

### Skills UX Overhaul
Complete redesign of the Skills dashboard (`/skills`):
- **Three-tier health card grid**: critical (red), warning (amber), healthy (green) — color-coded by health score
- **Fix Wizard**: guided state machine (`diagnose → select → preview → done`) for remediating skill issues
- **Session Timeline**: visual history of skill invocations per session with outcome badges
- **AG-UI Health tab**: live event feed from the AG-UI event bus, filtered by skill-related events
- **Keyboard shortcut**: `/` focuses the skill search input (matches system convention)
- **WCAG 2.1 AA**: all interactive elements have 4.5:1+ contrast, focus rings, ARIA labels

### Claude Usage Tracking (`/usage`)
New LiveView and GenServer tracking Claude model usage per project:
- Input/output/cache token counters with per-session and per-project aggregation
- Effort level classification: `low` (<1K tokens) / `medium` (<10K) / `high` (<50K) / `intensive` (50K+)
- Real-time PubSub updates on every usage record
- REST API: `POST /api/usage/record`, `GET /api/usage/:project`, `DELETE /api/usage/project/:project`

### Port Management Intelligence
- `PortManager` GenServer with async `lsof` scan, session-file discovery, conflict detection
- `PortsLive` dashboard: utilization heatmap, conflict table, namespace allocation view
- ActionEngine actions: `register_all_ports`, `update_port_namespace`, `analyze_port_assignment`, `smart_reassign_ports`
- REST API: `GET /api/ports`, `POST /api/ports/register`, `GET /api/ports/conflicts`

### Documentation Fleet
Full documentation update via formation `fmt-ccem-docs-wiki-v640-20260318`:
- New: `priv/docs/user/usage.md` (Claude usage tracking)
- New: `priv/docs/developer/ports.md` (port management)
- Rewritten: `priv/docs/user/skills.md` (v6.4.0 redesign)
- Expanded: `priv/docs/developer/ccem-ui.md` (dual-section sidebar, CCEM hub)
- Updated: architecture, API reference, LiveView pages, hooks, changelog, index

### Notifications: Contextual Workflow Buttons
Notification cards now show context-aware action buttons:
- UPM notifications: Story link, Wave badge, PRD link
- Ralph notifications: Flowchart link, Story/Done badges
- Formation notifications: Formation deep-link (`/formation?id=`), Wave badge, Agents link

## Installation

```bash
# Clone and install
git clone https://github.com/peguesj/ccem.git
cd ccem/apm-v4
./install.sh

# Or upgrade existing installation
./install.sh --prefix ~/Developer/ccem
```

The installer (`install.sh`) supports:
- `--prefix <path>` — custom installation directory
- `--skip-service` — skip launchd/systemd service installation
- `--skip-hooks` — skip Claude Code settings.json patching
- `--skip-agent` — skip CCEMAgent build (macOS)
- `--dry-run` — preview what would be installed
- `--yes` — non-interactive mode
- Uses `gum` for TUI if available, falls back to plain ANSI output

## Requirements

- Elixir 1.15+ / OTP 26+
- macOS 14+ (for CCEMAgent) or Linux (server only)
- Homebrew (for `gum` TUI, optional)

## Checksums

| File | SHA-256 |
|------|---------|
| `install.sh` | ``1780c850df3f0385cb05b8e8785f6d0ea215eb29c205a4588868f6354cf79d4f`` |

## Changelog

See [CHANGELOG](priv/docs/changelog.md) for full history.
