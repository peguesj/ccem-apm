# CCEM APM v6.1.0 Screenshots

Screenshots captured from CCEM APM running at `http://localhost:3032`.

---

## dashboard-project-dropdown.png

**Route**: `/` (Dashboard)

Shows the main dashboard header with the project namespace dropdown open. The dropdown is divided into two sections:

- **Active**: The currently active project namespace (one entry, highlighted with a green indicator)
- **Recently Active**: A list of recently accessed project namespaces, including the APM server itself and several other local development projects

The main dashboard content is visible behind the dropdown, including the Agent Fleet summary (7 agents, 4 active), Port Allocations panel showing ~55 registered projects, and the Dependency Graph with agentic hierarchy visualization (Session → Formation → Squadron → Swarm → Agent → Task levels).

Console note: Non-critical GenServer telemetry errors present in background; display unaffected.

---

## showcase-default.png

**Route**: `/showcase`

Full 3-column showcase layout for the active project:

- **Left column** — Feature Roadmap: 27/27 stories across 5 waves. Cards view with wave/status filters. Each card shows wave badge (W1–W5), story ID, status (DONE/Active/Planned), title, and summary.
- **Center column** — Architecture panel: SVG system diagram (System tab active) showing the C4-abstracted architecture across layers: Browser, Phoenix API Layer, OTP GenServers, Claude Code, CCEMAgent, and External Integrations. Status bar shows pipeline stage indicators (plan → build → verify → ship), agent count, and tsc:PASS gate.
- **Right column** — Resource Inspector: Shows live service health (CCEM APM: unreachable, AG-UI EventRouter: unknown, CCEMAgent: menubar app), agent list (7 agents with status), Git info (branch: main, version: 5.5.0, repo: my-org/my-project), stack details (Elixir/OTP 27, Phoenix 1.7, LiveView + daisyUI, AG-UI protocol), DRTW library versions, and key API endpoints.

Version displayed: v5.5.0. Console errors: periodic LiveView crash/remount cycle occurring (view crashes and recovers automatically); visual output captured correctly between cycles.

---

## showcase-feature-inspector.png

**Route**: `/showcase` — after clicking a feature card

Right column transitions from the Resource Inspector to the **Feature Inspector** after clicking the "AG-UI Protocol" card (W1, US-001, DONE):

- **Right column (Feature Inspector)**:
  - Feature title, wave/story badge, status
  - Description text
  - Related Agents section (empty — no agents currently assigned to this story)
  - Status History: Current: DONE
  - Actions: "View Formation" link and "Copy ID" button

- **Center column (Architecture)** switched to the **Formation Flow** tab automatically, displaying a vertical flowchart of the agentic hierarchy (Session → Formation → Wave 5 → Squadron → Swarm with "7 active" label → Agent → Task) corresponding to the active formation.

- **Left column**: First feature card (AG-UI Protocol) appears highlighted/selected.

---

## showcase-activity-tab.png

**Route**: `/showcase` — after clicking the "Activity" tab in the Architecture panel

The center Architecture panel switches to the **Activity** tab view:

- **Active agents area**: Shows "No active agents" placeholder (the APM connection is offline for this project's showcase data)
- **Action Log**: Collapsed accordion showing "Action Log (0 recent)" with an expand toggle
- The Feature Inspector remains open in the right column with the previously selected feature still shown
- The "Activity" tab button is highlighted/active in the architecture tab bar

This view is designed to show a live D3 force-graph of agent activity when agents are actively registered and sending heartbeats to the APM endpoint configured for the project. The empty state reflects that the showcase is currently in offline mode (APM: off indicator in the status bar).

---

## Notes

- All screenshots use the dark theme (daisyUI dark).
- Project names, file paths, and session IDs have been replaced with generic references: "my-org/my-project", "~/Developer/...", "xxxx-xxxx".
- The LiveView at `/showcase` exhibits a periodic crash/remount cycle during this capture session; all screenshots were taken during stable render windows.
- The `/dashboard` route does not exist; the root `/` route serves the dashboard and was used instead.
