# Changelog

## v4.0.0 (2026-02-19)

Complete rewrite from Python APM v3 to Phoenix/Elixir.

### Added
- Phoenix LiveView dashboard with daisyUI styling
- Multi-project support with project switcher
- D3.js dependency graph with force-directed layout
- Agent fleet management (individual, squadron, swarm, orchestrator types)
- Ralph methodology flowchart page with D3 visualization
- UPM (Unified Project Management) execution tracking
- Skills tracking with UEBA analytics and co-occurrence matrix
- Session timeline with Gantt-style D3 visualization
- All Projects widget dashboard with resizable panels
- 50+ REST API endpoints (v3-compatible + v4 extensions)
- v2 API with OpenAPI 3.0 spec
- AG-UI SSE endpoint for real-time event streaming
- A2UI component endpoint
- Global filter bar (Splunk/ELK-style) for agent search
- Layout and filter preset save/restore
- Notification system with bell dropdown
- Dark/light theme toggle
- SwiftUI menubar agent (CCEMAgent) for macOS
- Session init hooks for automatic APM start
- Built-in documentation wiki at `/docs`
- Earmark-based markdown rendering with search
- DocsStore GenServer for doc caching and TOC generation

### Architecture
- 17 GenServers with ETS-backed state
- PubSub-driven real-time updates (8 topics)
- No database dependency -- config file persistence
- Bandit HTTP server on port 3031

### Migration from v3
- Full REST API backward compatibility
- Same session registration flow
- Same notification API
- Config file format preserved
