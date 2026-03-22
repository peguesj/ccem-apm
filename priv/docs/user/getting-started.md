# Getting Started with CCEM APM v4

This guide walks you through installing and launching CCEM APM for the first time.

> **Tip:** If you already have a running APM instance, skip to [First Launch](#first-launch) to verify connectivity.

## System Prerequisites

- Elixir 1.14+ and Erlang/OTP 25+
- Git
- A terminal/shell environment
- macOS (for CCEMHelper menubar app, optional)

## Installation

### Clone the Repository

Clone the project into your development directory:

```bash
cd /Users/jeremiah/Developer
git clone <repository-url> ccem
cd ccem/apm-v5
```

### Install Elixir Dependencies

Fetch all Elixir packages defined in `mix.exs`:

```bash
mix deps.get
```

### Verify Configuration

The APM server needs a configuration file. Check `/Users/jeremiah/Developer/ccem/apm/apm_config.json`:

```json
{
  "project_name": "ccem",
  "project_root": "/Users/jeremiah/Developer/ccem",
  "active_project": "ccem",
  "port": 3031,
  "projects": [
    {
      "name": "ccem",
      "root": "/Users/jeremiah/Developer/ccem"
    }
  ],
  "sessions": {}
}
```

> **Note:** If the file does not exist, the ConfigLoader GenServer creates a default one automatically on first boot.

## Launching the Server

### Manual Start

Start the Phoenix server directly:

```bash
cd /Users/jeremiah/Developer/ccem/apm-v5
mix phx.server
```

You should see output similar to:

```text
[info] Running ApmV5Web.Endpoint with cowboy 2.x.x at http://localhost:3032
[info] Access the web interface at http://localhost:3032
```

### Automated Start via Session Hooks

The session initialization hook at `~/Developer/ccem/apm/hooks/session_init.sh` automatically starts the APM server if not running:

```bash
source ~/Developer/ccem/apm/hooks/session_init.sh
```

This script performs the following steps:

1. Checks if APM is already running on port 3031
2. Starts the server if needed
3. Registers the current Claude Code session
4. Updates `apm_config.json` with session metadata

## First Launch

### Access the Dashboard

Open your browser and navigate to:

```text
http://localhost:3032
```

You should see:

- **Stats Cards** at the top (Agents, Sessions, Projects, Skills)
- **Live Agent Fleet** list with agent statuses
- **D3 Dependency Graph** showing agent relationships
- **Filter Bar** for searching and filtering
- **Right Panel** with tabs: Inspector, Ralph, UPM, Commands, TODOs

### Verify Server Health

Check the health endpoint to confirm the server is running:

```bash
curl http://localhost:3032/health
```

Expected response:

```json
{
  "status": "ok",
  "timestamp": "2026-02-19T12:00:00Z",
  "version": "4.0.0"
}
```

### Register Your First Agent

Agents register via POST to `/api/register`. Send a test registration:

```bash
curl -X POST http://localhost:3032/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-agent",
    "type": "individual",
    "project": "ccem",
    "tier": 1,
    "capabilities": ["analysis", "code-review"]
  }'
```

The agent appears in the fleet list within seconds.

## Port Configuration

By default, CCEM APM uses **port 3031**. To change it:

1. Edit `apm_config.json` and set `"port": 3032` (or desired port)
2. Restart the server: `mix phx.server`
3. Update your browser bookmarks to `http://localhost:3032`

You can also set the port via the `APM_PORT` environment variable:

```bash
export APM_PORT=3032
mix phx.server
```

> **Warning:** If you change the port, update all session hooks and agent registrations to use the new port. Mismatched ports cause silent connection failures.

## Stopping the Server

### Keyboard Interrupt

In the terminal where the server is running, press `Ctrl+C`.

### Kill by Process ID

Find and kill the Erlang process:

```bash
lsof -ti:3031 | xargs kill -9
```

Or use the PID file:

```bash
cat /Users/jeremiah/Developer/ccem/apm-v5/.apm.pid
# Then: kill <pid>
```

## Environment Variables

Optional configuration via environment:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `APM_PORT` | `3031` | Server port |
| `APM_CONFIG_PATH` | `~/Developer/ccem/apm/apm_config.json` | Config file location |
| `MIX_ENV` | `dev` | Environment (dev, test, prod) |

Set them before starting the server:

```bash
export APM_PORT=3031
export APM_CONFIG_PATH="/path/to/config.json"
export MIX_ENV=prod
```

## Troubleshooting

### Port Already in Use

If you see "Address already in use", kill the existing process and restart:

```bash
lsof -ti:3031 | xargs kill -9
mix phx.server
```

### Dependencies Not Installing

Clean the build artifacts and re-fetch:

```bash
rm -rf _build deps mix.lock
mix deps.get
mix phx.server
```

### Agent Not Appearing in Fleet

Check the browser console for WebSocket errors. Verify agents exist via the API:

```bash
curl http://localhost:3032/api/agents | jq '.agents'
```

> **Tip:** If agents register but do not appear, confirm the `project` field in the registration payload matches the active project in `apm_config.json`.

## Architecture Overview

CCEM APM is built on Phoenix (Elixir) with:

- **LiveView** for real-time web UI
- **GenServers** for state management (agents, config, notifications)
- **PubSub** for event broadcasting
- **ETS** for in-memory caching
- **REST API** for agent integration

See [Architecture](/docs/developer/architecture) for details.

## Next Steps

- Read the [Dashboard Guide](/docs/user/dashboard) to explore the UI
- Set up [Multi-Project Support](/docs/user/projects)
- Learn about the [Agent Fleet](/docs/user/agents)
- Configure the [CCEMHelper SwiftUI Menubar App](/docs/developer/swift-agent)

---

## See Also

- [Dashboard Guide](/docs/user/dashboard) - Using the web interface
- [Multi-Project Setup](/docs/user/projects) - Managing multiple projects
- [Configuration](/docs/admin/configuration) - apm_config.json setup
