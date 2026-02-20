# CCEM APM v4

**Agentic Performance Monitor** -- real-time monitoring dashboard for Claude Code agent sessions.

Built with Phoenix LiveView, daisyUI, D3.js, and a companion SwiftUI menubar agent.

## Quick Start

```bash
cd apm-v4
mix deps.get
mix phx.server
```

Open [http://localhost:3031](http://localhost:3031).

## Features

- **Multi-project dashboard** with D3.js dependency graph
- **Agent fleet management** -- register, track, and inspect AI agents
- **Ralph methodology** integration with flowchart visualization
- **UPM execution tracking** -- waves, stories, verification gates
- **Skills tracking** with UEBA analytics and co-occurrence matrix
- **Session timeline** with Gantt-style D3 visualization
- **50+ REST API endpoints** with v2 OpenAPI spec
- **AG-UI SSE** for real-time event streaming
- **SwiftUI menubar agent** (CCEMAgent) for macOS
- **Built-in documentation wiki** at `/docs`

## Architecture

Phoenix/OTP application with 17 GenServers managing state via ETS tables. PubSub-driven real-time updates across 6 LiveView pages. No database -- all state is in-memory with config file persistence.

Key modules:
- `AgentRegistry` -- agent lifecycle and fleet management
- `ProjectStore` -- multi-project tasks and commands
- `ConfigLoader` -- watches and reloads `apm_config.json`
- `SkillTracker` -- skill catalog and usage analytics
- `UpmStore` -- UPM execution session tracking
- `DocsStore` -- markdown documentation wiki

## Documentation

Full documentation available at [http://localhost:3031/docs](http://localhost:3031/docs) when the server is running.

## License

Private -- CCEM project.
