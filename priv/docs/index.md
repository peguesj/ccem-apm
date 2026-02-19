# CCEM APM v4 Documentation

Welcome to the CCEM APM (Agentic Performance Monitor) v4 documentation. This is a Phoenix/Elixir-based real-time monitoring system for Claude Code AI agent sessions.

## What is CCEM APM?

CCEM APM is a comprehensive monitoring and orchestration platform for AI agent workflows. It tracks:

- **AI Agents**: Individual agents, squadrons, swarms, and orchestrators
- **Sessions**: Claude Code session lifecycle and state
- **Projects**: Multi-project support with isolated namespacing
- **Skills**: Skill usage tracking with co-occurrence analysis
- **Workflows**: Ralph methodology autonomous execution
- **Tasks**: UPM (Unified Project Management) integration

## Key Features

- **Real-time Dashboard** with dependency graphs, agent fleet visualization, and live updates
- **Multi-project Support** with project switching and isolated namespaces
- **Ralph Methodology** integration for autonomous fix loops and PRD generation
- **Agent Fleet Management** with tier-based classification and discovery
- **Skills Tracking** with UEBA analytics and methodology detection
- **REST API** for agent registration, heartbeats, and data sync
- **SwiftUI Menubar Agent** (CCEMAgent) for macOS integration
- **Session Timeline** visualization and audit logging
- **Interactive Docs** with embedded slash command reference

## Quick Links

### For Users
- [Getting Started](user/getting-started.md) - Installation and first launch
- [Dashboard Guide](user/dashboard.md) - Using the web interface
- [Multi-Project Setup](user/projects.md) - Managing multiple projects
- [Agent Fleet](user/agents.md) - Understanding agent types and statuses
- [Ralph Methodology](user/ralph.md) - Autonomous workflow execution
- [UPM Integration](user/upm.md) - Project management tracking
- [Skills Analytics](user/skills.md) - Skill usage and co-occurrence
- [Notifications](user/notifications.md) - Alert system overview

### For Developers
- [Architecture](developer/architecture.md) - System design and GenServers
- [API Reference](developer/api-reference.md) - Complete endpoint documentation
- [LiveView Pages](developer/liveview-pages.md) - Frontend components
- [PubSub Events](developer/pubsub-events.md) - Real-time event system
- [Extending CCEM](developer/extending.md) - Adding new features

### For Administrators
- [Configuration](admin/configuration.md) - apm_config.json setup
- [Deployment](admin/deployment.md) - Production setup
- [Session Hooks](admin/hooks.md) - Initialization and registration
- [Troubleshooting](admin/troubleshooting.md) - Common issues and fixes

## System Architecture Overview

```
┌─────────────────────────────────────────────┐
│   Phoenix LiveView (HTML/JS/CSS)            │
│   - Dashboard, Projects, Skills, Ralph      │
│   - Real-time updates via WebSocket         │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│   REST API & WebSocket Routes               │
│   - Agent registration, heartbeats          │
│   - Notifications, tasks, commands          │
│   - Session data, metrics, audit logs       │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│   GenServer Stores (OTP Supervision)        │
│   - ConfigLoader, AgentRegistry, UpmStore   │
│   - SkillTracker, MetricsCollector          │
│   - AlertRulesEngine, EventStream           │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│   Data Layer (ETS + Files)                  │
│   - apm_config.json, session JSONs          │
│   - ETS tables for fast queries              │
└─────────────────────────────────────────────┘
```

## Default Port

CCEM APM runs on **port 3031** by default. Access the dashboard at:

```
http://localhost:3031
```

## Technology Stack

- **Backend**: Phoenix Framework (Elixir)
- **Frontend**: LiveView with HTML/JS, daisyUI, Tailwind CSS
- **Styling**: daisyUI components on Tailwind CSS
- **Visualization**: D3.js dependency graphs, Timeline.js
- **Menubar Agent**: Swift (AppKit, URLSession)
- **Realtime**: WebSocket via Phoenix PubSub
- **Data**: JSON configuration, ETS tables, file-based persistence

## Getting Started

For a quick start:

1. Clone the repository
2. Run `mix deps.get` to install dependencies
3. Run `mix phx.server` to start the server
4. Open `http://localhost:3031` in your browser

See [Getting Started](user/getting-started.md) for detailed instructions.

## Version

**CCEM APM v4.0.0** - Phoenix/Elixir rewrite with multi-project support, enhanced UI, and comprehensive monitoring.

## Support

For issues, questions, or feature requests, check [Troubleshooting](admin/troubleshooting.md) or review the relevant documentation section.
