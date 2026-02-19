# Getting Started with CCEM APM v4

This guide walks you through installing and launching CCEM APM for the first time.

## Prerequisites

- Elixir 1.14+ and Erlang/OTP 25+
- Git
- A terminal/shell environment
- macOS (for CCEMAgent menubar app, optional)

## Installation

### 1. Clone the Repository

```bash
cd /Users/jeremiah/Developer
git clone <repository-url> ccem
cd ccem/apm-v4
```

### 2. Install Dependencies

```bash
mix deps.get
```

This installs all Elixir dependencies defined in `mix.exs`.

### 3. Verify Configuration

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

If the file doesn't exist, the ConfigLoader GenServer will create a default one.

## Launching the Server

### Manual Start

```bash
cd /Users/jeremiah/Developer/ccem/apm-v4
mix phx.server
```

You should see:

```
[info] Running ApmV4Web.Endpoint with cowboy 2.x.x at http://localhost:3031
[info] Access the web interface at http://localhost:3031
```

### Automated Start (via Session Hooks)

The session initialization hook at `~/Developer/ccem/apm/hooks/session_init.sh` automatically starts the APM server if not running:

```bash
source ~/Developer/ccem/apm/hooks/session_init.sh
```

This script:
1. Checks if APM is already running on port 3031
2. Starts the server if needed
3. Registers the current Claude Code session
4. Updates `apm_config.json` with session metadata

## First Launch

### 1. Access the Dashboard

Open your browser and navigate to:

```
http://localhost:3031
```

You should see:
- **Stats Cards** at the top (Agents, Sessions, Projects, Skills)
- **Live Agent Fleet** list with agent statuses
- **D3 Dependency Graph** showing agent relationships
- **Filter Bar** for searching and filtering
- **Right Panel** with tabs: Inspector, Ralph, UPM, Commands, TODOs

### 2. Verify Server Status

Check the health endpoint:

```bash
curl http://localhost:3031/health
```

Expected response:

```json
{
  "status": "ok",
  "timestamp": "2026-02-19T12:00:00Z",
  "version": "4.0.0"
}
```

### 3. Register Your First Agent

Agents register via POST to `/api/register`:

```bash
curl -X POST http://localhost:3031/api/register \
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

**Note**: The port is also read from the `APM_PORT` environment variable if set:

```bash
export APM_PORT=3032
mix phx.server
```

## Stopping the Server

### Method 1: Keyboard Interrupt

In the terminal where the server is running, press `Ctrl+C`.

### Method 2: Kill Process

Find and kill the Erlang process:

```bash
lsof -ti:3031 | xargs kill -9
```

Or check for the PID file:

```bash
cat /Users/jeremiah/Developer/ccem/apm-v4/.apm.pid
# Then: kill <pid>
```

## Environment Variables

Optional configuration via environment:

```bash
export APM_PORT=3031              # Server port
export APM_CONFIG_PATH="/path/to/config.json"  # Config file location
export MIX_ENV=prod               # Environment (dev, test, prod)
```

## Troubleshooting

### Port Already in Use

If you see "Address already in use":

```bash
lsof -ti:3031 | xargs kill -9
mix phx.server
```

### Dependencies Not Installing

```bash
rm -rf _build deps mix.lock
mix deps.get
mix phx.server
```

### Agent Not Appearing

Check the browser console for WebSocket errors. Verify the agent POST request succeeded:

```bash
curl http://localhost:3031/api/agents | jq '.agents'
```

## Next Steps

- Read the [Dashboard Guide](../user/dashboard.md) to explore the UI
- Set up [Multi-Project Support](../user/projects.md)
- Learn about the [Agent Fleet](../user/agents.md)
- Configure the [CCEMAgent SwiftUI Menubar App](../developer/swift-agent.md)

## Architecture

CCEM APM is built on Phoenix (Elixir) with:
- **LiveView** for real-time web UI
- **GenServers** for state management (agents, config, notifications)
- **PubSub** for event broadcasting
- **ETS** for in-memory caching
- **REST API** for agent integration

See [Architecture](../developer/architecture.md) for details.
