# CCEM Plane PM Backlog Analysis — Full Audit

**Generated**: 2026-03-17
**Current version**: v6.1.0 (commit `903725d`)
**Audit method**: Plane API + git log correlation + CLAUDE.md checkpoint cross-reference
**Total issues reported by Plane API**: 193 (with CCEM-194 and CCEM-195 each holding duplicate UUIDs — actual unique count is ~195)
**Open issues (Backlog + Todo + InProgress)**: 48

---

## 1. Full Issue List by State

### 1a. In Progress (12 entries)

| Issue | Priority | Name |
|-------|----------|------|
| CCEM-044 | urgent | [Epic] APM Multi-Project Support |
| CCEM-056 | medium | [Epic] Documentation & Wiki |
| CCEM-057 | medium | Git history documentation |
| CCEM-186 | medium | [US-013] Update /docs LiveView for v6.0.0 sections |
| CCEM-187 | medium | [US-014] Add @moduledoc/@doc/@spec to v6.0.0 modules |
| CCEM-188 | medium | [US-015] Update OpenAPI 3.0.3 spec for v6.0.0 |
| CCEM-194 (a) | high | [UX-001] CCEMAgent: menubar text label + APMAutoRestartManager |
| CCEM-194 (b) | medium | [UX-002] CCEMAgent: NotificationSettingsStore + NotificationSettingsView |
| CCEM-195 (a) | high | [UX-003] APM: Notification panel — decision gates + formation tree + UPM context |
| CCEM-195 (b) | high | [UX-004] APM: Formation page redesign — TD/LR toggle + verbose node cards + anime.js |
| CCEM-196 | medium | [UX-006] APM: Showcase CSS full parity — embedded vs standalone |
| CCEM-197 | medium | [UX-005] APM: Getting started wizard expansion — all 26 LiveViews |

### 1b. Todo (16 entries)

| Issue | Priority | Name |
|-------|----------|------|
| CCEM-045 | high | US-001: v4 config loader with multi-project support |
| CCEM-046 | high | US-002: Per-project data isolation in registries |
| CCEM-047 | high | US-003: Project-scoped API routes |
| CCEM-048 | medium | US-004: Project selector landing page |
| CCEM-049 | medium | US-005: Project-scoped dashboard |
| CCEM-050 | medium | US-006: Multi-project /health endpoint |
| CCEM-058 | medium | README updates |
| CCEM-060 | high | [US-001] Connection tracking store with project-scoped agent bindings |
| CCEM-061 | high | [US-002] Configuration drift detection engine with auto-repair |
| CCEM-062 | urgent | [US-003] Formation execution real-time tree view in FormationLive |
| CCEM-063 | urgent | [US-004] Build control plane API: kill, retry, tsc gate results |
| CCEM-064 | medium | [US-005] Connection health widget in AllProjectsLive dashboard |
| CCEM-065 | high | [US-006] Multi-project /health endpoint with per-project breakdown |
| CCEM-066 | high | [US-007] Live agent output streaming in formation tree |
| CCEM-067 | low | [US-008] README v4.2.0 update with build execution architecture docs |
| CCEM-085 | medium | [US-001] APMServerManager Swift service |

### 1c. Backlog (20 entries)

| Issue | Priority | Name |
|-------|----------|------|
| CCEM-051 | medium | [Epic] SwiftUI CCEM Agent |
| CCEM-052 | medium | macOS menubar app for monitoring CC environments |
| CCEM-053 | medium | APM connection tracking |
| CCEM-054 | medium | Configuration drift detection |
| CCEM-055 | low | Login item / launch-on-CC-run capability |
| CCEM-059 | low | Wiki generation |
| CCEM-124 | medium | [CCEM-ENH] Hook state file cleanup — implement rotation/TTL for .hook_state/ |
| CCEM-125 | medium | [CCEM-ENH] Session file rotation — implement archival for stale sessions |
| CCEM-126 | medium | [CCEM-ENH] OpenAPI spec reconciliation — document 44+ missing routes |
| CCEM-127 | medium | [CCEM-ENH] Version sync automation — single source of truth for version number |
| CCEM-128 | medium | [CCEM-ENH] Document 6 undocumented feature subsystems as skills |
| CCEM-129 | medium | [CCEM-ENH] Showcase asset serving — add /showcase route to APM LiveView |
| CCEM-136 | high | US-001: DiagramRenderer GenServer — multi-format rendering engine |
| CCEM-137 | high | US-002: UPM diagram definitions — 6 diagram types |
| CCEM-138 | high | US-003: DiagramLive LiveView at /diagrams |
| CCEM-139 | medium | US-004: Anime.js animation integration for SVG diagrams |
| CCEM-140 | low | US-005: Lottie integration for decorative transitions |
| CCEM-141 | high | US-006: PlantUML server-side renderer |
| CCEM-142 | medium | US-007: UPM dashboard integration — embed diagrams in /upm LiveView |
| CCEM-143 | low | US-008: v5.2.0 prep — OpenAPI spec + CHANGELOG for diagram endpoints |

---

## 2. Drift Table: Issue vs CLAUDE.md Checkpoints vs Git

### 2a. Should Be Closed — Shipped but not closed in Plane

These issues are confirmed complete by CLAUDE.md `[x]` checkpoints and corresponding git commits, yet remain open in Plane.

| Issue | CLAUDE.md Evidence | Git Commit | Drift |
|-------|-------------------|------------|-------|
| CCEM-085 | CP-18 [x], CP-24 [x] — APMServerManager | `6d12d5b`, `20adca1` | Duplicate of CCEM-086 (Done). Open in Todo. |
| CCEM-052 | CCEMAgent v3.0.0 shipped | `903725d`, `20adca1` | CCEMAgent fully shipped. In Backlog. |
| CCEM-051 | CCEMAgent [Epic] — all CPs done | Multiple commits | [Epic] fully delivered. In Backlog. |
| CCEM-055 | CP-18 [x] APMServerManager | `6d12d5b` | Login-item capability covered by shipped APMServerManager. In Backlog. |
| CCEM-054 | CCEM-061 children shipped | `9da7c7e` | Absorbed and delivered. In Backlog. |
| CCEM-053 | CCEM-060 children shipped | `9da7c7e` | Absorbed and delivered. In Backlog. |
| CCEM-129 | v6.0.0 showcase integration | `9da7c7e` — `/showcase` route shipped | Showcase route live. In Backlog. |
| CCEM-067 | v4.2.0 shipped (CP-56 [x]) | `0fac8d6` | README for v4.2.0 is 4 versions stale. In Todo. |
| CCEM-045 | CCEM-025 (ConfigLoader) Done | `6987f06`, `6d12d5b` | ConfigLoader shipped as CCEM-025. In Todo. |
| CCEM-046 | CCEM-026 (ProjectStore) Done | `6987f06` | Per-project data isolation shipped. In Todo. |
| CCEM-047 | CCEM-030–034 Done | `6987f06` | Project-scoped API routes shipped. In Todo. |
| CCEM-048 | CCEM-036 (AllProjectsLive) Done | `6987f06` | Project selector page shipped. In Todo. |
| CCEM-049 | CCEM-036 Done | `6987f06` | Project-scoped dashboard shipped. In Todo. |
| CCEM-050 | Duplicate of CCEM-065 | n/a | Same feature, two tickets. In Todo. |
| CCEM-143 | v5.2.0 shipped without diagram endpoints | n/a | Changelog/OpenAPI for diagram endpoints — superseded by v6.0.0. In Backlog. |

### 2b. Stale In Progress — No Recent Commits

These issues are InProgress in Plane but have no recent git activity and no matching open checkpoints in CLAUDE.md.

| Issue | Last Activity | Analysis |
|-------|--------------|----------|
| CCEM-044 | ~25 days ago | [Epic] APM Multi-Project Support — all children (CCEM-045–050) are Todo with no commits. The feature was partially shipped across v4.x via different tickets. Epic shell is stale. |
| CCEM-056 | ~25 days ago | [Epic] Documentation & Wiki — no active child tasks, no commits. Reset to Backlog. |
| CCEM-057 | ~25 days ago | Git history documentation — no commits touching docs for git history. No definition of done. |

### 2c. Genuinely InProgress — Open Checkpoints Confirmed

These are InProgress in Plane AND have corresponding `[ ]` (unchecked) entries in CLAUDE.md Wave 3.

| Issue | CLAUDE.md Checkpoint | Status |
|-------|---------------------|--------|
| CCEM-186 | CP-110 `[ ]` — Update /docs LiveView | Correctly InProgress |
| CCEM-187 | CP-111 `[ ]` — Add @moduledoc/@doc/@spec | Correctly InProgress |
| CCEM-188 | CP-112 `[ ]` — Update OpenAPI 3.0.3 spec | Correctly InProgress |

### 2d. Active UX Sprint — Correctly InProgress

These correspond to a v6.1.0 UX sprint with no prior CLAUDE.md checkpoint entries (new work not yet tracked in CLAUDE.md).

| Issue | Status |
|-------|--------|
| CCEM-194 (a+b) | UX-001/002 CCEMAgent improvements — active sprint |
| CCEM-195 (a+b) | UX-003/004 APM Notification panel + Formation redesign — active sprint |
| CCEM-196 | UX-006 Showcase CSS parity — active sprint |
| CCEM-197 | UX-005 Getting started wizard expansion — active sprint |

### 2e. Duplicate Sequence IDs (Data Integrity Issue)

Two sequence IDs have two distinct Plane UUIDs each. This appears to be a batch-creation artifact.

| Sequence ID | Issue A | Issue B |
|------------|---------|---------|
| CCEM-194 | [UX-001] CCEMAgent: menubar text label + APMAutoRestartManager | [UX-002] CCEMAgent: NotificationSettingsStore + NotificationSettingsView |
| CCEM-195 | [UX-003] APM: Notification panel | [UX-004] APM: Formation page redesign |

### 2f. Unimplemented Backlog — No Code, No Checkpoint

The Diagram Engine suite (CCEM-136–142) has no implementation in git, no CLAUDE.md checkpoint, and no corresponding module in the codebase. This is a coherent but deferred feature group.

| Issue | Priority | Implementation Status |
|-------|----------|-----------------------|
| CCEM-136 | high | DiagramRenderer GenServer — no code found |
| CCEM-137 | high | UPM diagram definitions — no code found |
| CCEM-138 | high | DiagramLive at /diagrams — no LiveView found |
| CCEM-139 | medium | Anime.js for SVG — partially exists in showcase only |
| CCEM-140 | low | Lottie integration — no code found |
| CCEM-141 | high | PlantUML renderer — no code found |
| CCEM-142 | medium | UPM diagram embed — no code found |

---

## 3. Recommended Actions Per Issue

### Close / Cancel (Cancelled state: `80645a72-1150-4fc1-af9c-b1e85c30cd86`)

| Issue | Reason |
|-------|--------|
| CCEM-085 | Duplicate of CCEM-086 (Done). APMServerManager shipped. |
| CCEM-052 | CCEMAgent fully shipped as v3.0.0. No remaining work. |
| CCEM-051 | [Epic] SwiftUI CCEM Agent — all child features delivered. |
| CCEM-055 | Login-item covered by CCEM-086 APMServerManager (Done). |
| CCEM-054 | Configuration drift detection — absorbed into CCEM-061; child of CCEM-044. |
| CCEM-053 | APM connection tracking — absorbed into CCEM-060; child of CCEM-044. |
| CCEM-129 | Showcase route shipped in v6.0.0 (`9da7c7e`). |
| CCEM-067 | README for v4.2.0 is 4 versions old. Obsolete. |
| CCEM-045 | ConfigLoader shipped as CCEM-025 (Done). |
| CCEM-046 | Per-project data isolation shipped in CCEM-026 (Done). |
| CCEM-047 | Project-scoped API routes shipped in CCEM-030–034 (Done). |
| CCEM-048 | Project selector shipped as AllProjectsLive in CCEM-036 (Done). |
| CCEM-049 | Project-scoped dashboard shipped in CCEM-036 (Done). |
| CCEM-050 | Duplicate of CCEM-065 (Todo). |
| CCEM-143 | v5.2.0 diagram OpenAPI prep — superseded by v6.0.0 without diagram endpoints. |
| CCEM-044 | [Epic] APM Multi-Project Support — all concrete features shipped via v4.x tickets; stale shell epic. |
| CCEM-058 | README updates — no version context; replace with targeted v6.1.0 ticket if needed. |

**Total recommended closures: 17**

### Reset to Backlog (from InProgress)

| Issue | Reason |
|-------|--------|
| CCEM-056 | [Epic] Documentation & Wiki — no active sprint. Reset to Backlog until documentation sprint is planned. |
| CCEM-057 | Git history documentation — stale, no definition of done, no commits. Reset to Backlog. |

### Keep InProgress (genuinely active)

| Issue | Reason |
|-------|--------|
| CCEM-186 | CP-110 `[ ]` — incomplete v6.0.0 Wave 3 task |
| CCEM-187 | CP-111 `[ ]` — incomplete v6.0.0 Wave 3 task |
| CCEM-188 | CP-112 `[ ]` — incomplete v6.0.0 Wave 3 task |
| CCEM-194 (a+b) | Active UX sprint |
| CCEM-195 (a+b) | Active UX sprint |
| CCEM-196 | Active UX sprint |
| CCEM-197 | Active UX sprint |

### Keep in Todo (valid near-term)

| Issue | Priority | Reason |
|-------|----------|--------|
| CCEM-062 | urgent | Formation real-time tree view — core observability gap, no implementation |
| CCEM-063 | urgent | Build control plane API — enables autonomous fix loop kill/retry |
| CCEM-060 | high | Connection tracking store — foundational for multi-project coordination |
| CCEM-061 | high | Configuration drift detection with auto-repair — valid, not yet shipped |
| CCEM-066 | high | Live agent output streaming in formation tree — genuine capability gap |
| CCEM-064 | medium | Connection health widget — valid UI enhancement |
| CCEM-065 | high | Multi-project /health with per-project breakdown — keep (close CCEM-050 as duplicate) |

### Keep in Backlog (infrastructure quality — small but important)

| Issue | Reason |
|-------|--------|
| CCEM-124 | Hook state file cleanup — valid operational hygiene |
| CCEM-125 | Session file rotation — valid operational hygiene |
| CCEM-127 | Version sync automation — valid engineering improvement |
| CCEM-126 | OpenAPI spec reconciliation — update scope to reflect v6.0.0+ state |
| CCEM-128 | Document undocumented subsystems — partially done; verify remaining count |

### Keep in Backlog (deferred Diagram Engine suite)

Group under a new `[Epic] APM Diagram Engine` issue. Keep CCEM-136–142. Cancel CCEM-140 (Lottie) and CCEM-143 (stale v5.2.0 changelog).

| Issue | Keep/Cancel |
|-------|------------|
| CCEM-136 | Keep — DiagramRenderer GenServer |
| CCEM-137 | Keep — UPM diagram definitions |
| CCEM-138 | Keep — DiagramLive LiveView |
| CCEM-139 | Keep — Anime.js SVG animation |
| CCEM-140 | Cancel — Lottie integration, low value |
| CCEM-141 | Keep — PlantUML renderer (evaluate vs Mermaid server) |
| CCEM-142 | Keep — UPM dashboard diagram embed |
| CCEM-143 | Cancel — superseded by v6.0.0 |

---

## 4. Priority Matrix for refactor-max Initiative

### P0 — Complete v6.0.0 Wave 3 First

These three open checkpoints must close before starting a refactor-max pass:

| Issue | Task |
|-------|------|
| CCEM-186 | Update /docs LiveView for v6.0.0 sections (CP-110) |
| CCEM-187 | Add @moduledoc/@doc/@spec to v6.0.0 modules (CP-111) |
| CCEM-188 | Update OpenAPI 3.0.3 spec for v6.0.0 new endpoints (CP-112) |

### P1 — Formation Control Plane (highest functional impact)

| Issue | Priority | Impact |
|-------|----------|--------|
| CCEM-063 | urgent | Build control plane (kill/retry/tsc gates) — enables autonomous recovery in ralph loops |
| CCEM-062 | urgent | Formation real-time tree view — core formation observability |
| CCEM-066 | high | Live agent output streaming — essential for long-running formation visibility |
| CCEM-061 | high | Configuration drift detection + auto-repair — foundation for refactor-max self-healing |

### P2 — Connection & Health Infrastructure

| Issue | Priority | Impact |
|-------|----------|--------|
| CCEM-060 | high | Connection tracking store — enables reliable project-scoped agent binding |
| CCEM-065 | high | Multi-project /health with per-project breakdown — enables dashboard health rollup |
| CCEM-064 | medium | Connection health widget in AllProjectsLive — observable health at a glance |

### P3 — Operational Hygiene (refactor-max quality gates)

| Issue | Priority | Impact |
|-------|----------|--------|
| CCEM-127 | medium | Version sync automation — eliminates manual drift between mix.exs/CHANGELOG/skill files |
| CCEM-125 | medium | Session file rotation — prevents stale session accumulation in ~/.apm/sessions/ |
| CCEM-124 | medium | Hook state file cleanup — TTL-based rotation for .hook_state/ |
| CCEM-126 | medium | OpenAPI spec reconciliation — update scope to v6.0.0+ endpoint reality |

---

## 5. Suggested New Issues for refactor-max Initiative

14 story titles recommended for creation as a new Plane epic (`[Epic] refactor-max v6.2.0`):

| # | Title | Priority | Area |
|---|-------|----------|------|
| RM-001 | GenServer audit — enforce child_spec/init/handle_call/handle_info typespecs across all 18 GenServers | high | Code Quality |
| RM-002 | LiveView audit — extract shared mount/assign patterns into shared ComponentHelpers module | high | Code Quality |
| RM-003 | Eliminate bare Task.start/1 calls — migrate to Task.Supervisor.start_child for fault tolerance | urgent | Reliability |
| RM-004 | ETS table ownership audit — verify all ETS tables are owned by their GenServer supervisor | high | Reliability |
| RM-005 | Telemetry instrumentation — add :telemetry.execute/3 spans to all GenServer message handlers | medium | Observability |
| RM-006 | Router consolidation — merge duplicate scope blocks and standardize /api/v1 vs /api/v2 routing | medium | Architecture |
| RM-007 | JavaScript hook lifecycle audit — verify all phx-hook modules handle mounted/destroyed cleanup | high | Reliability |
| RM-008 | CSS purge pass — remove unused daisyUI component classes from app.css (target: 40% reduction) | medium | Performance |
| RM-009 | AG-UI inbound event validation — add EventType.valid?/1 guards to all inbound event handler entry points | high | Correctness |
| RM-010 | ExUnit coverage expansion — grow from ~13 tests to 80+ covering GenServer edge cases and error paths | urgent | Testing |
| RM-011 | OpenAPI spec auto-generation — evaluate PhoenixSwagger / ex_doc_api to derive spec from routes at compile time | medium | Architecture |
| RM-012 | APM config hot-reload — replace per-request File.read! with FileSystem watcher + GenServer cache | medium | Performance |
| RM-013 | FormationStore TTL archival — implement configurable TTL-based archival for completed formations in ETS | medium | Reliability |
| RM-014 | CCEMAgent memory audit — profile Swift @Observable stores for retain cycles; evaluate @Model migration | high | CCEMAgent |

---

## 6. Missing Plane Coverage for Shipped Features

The following features appear in the git log but have no corresponding Plane issue:

| Feature | Git Commit | Suggested Issue Title |
|---------|------------|----------------------|
| Activity diagram rendering | `903725d` v6.1.0 | APM: Activity diagram LiveView + renderer |
| Showcase inspector panel | `903725d` v6.1.0 | APM: Showcase inspector — interactive SVG inspection panel |
| Project dropdown UX | `903725d` v6.1.0 | APM: Project dropdown selector UX improvement |
| UAT integration testing panel | `570a8a5` | APM: UAT integration testing panel — live AG-UI exerciser |
| DRTW LiveView | `3ed41b0` | APM: DRTW LiveView — Don't Reinvent The Wheel dashboard |
| Intake/watcher architecture | `3ed41b0` | APM: Intake > watcher architecture pattern |
| v6.1.0 release | `903725d` | v6.1.0 release — CHANGELOG, version bump, CCEMAgent rebuild |

---

## 7. Board Clean-Up Summary

| Action | Count | Issues |
|--------|-------|--------|
| Close / Cancel | 17 | CCEM-044, 045, 046, 047, 048, 049, 050, 051, 052, 053, 054, 055, 058, 067, 085, 129, 143 |
| Reset to Backlog | 2 | CCEM-056, 057 |
| Keep InProgress (active) | 7 | CCEM-186, 187, 188, 194(a+b), 195(a+b), 196, 197 |
| Keep Todo (valid) | 7 | CCEM-060, 061, 062, 063, 064, 065, 066 |
| Keep Backlog (hygiene) | 5 | CCEM-124, 125, 126, 127, 128 |
| Keep Backlog (diagrams) | 6 | CCEM-136, 137, 138, 139, 141, 142 |
| Cancel Backlog (diagrams) | 2 | CCEM-140, 143 |
| Create new (missing coverage) | 7 | See Section 6 |
| Create new (refactor-max) | 14 | RM-001 through RM-014 |
| Fix duplicate sequence IDs | 2 | CCEM-194, CCEM-195 — resolve UUID collision in Plane admin |

**Net result**: Closing 19 issues + adding 21 targeted issues = cleaner board with 50 focused open tickets instead of 48 noisy ones.
