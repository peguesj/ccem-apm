# Troubleshooting Guide

Common issues and solutions for CCEM APM v4.

> **Important:** Always back up `apm_config.json` before attempting fixes that modify configuration.

---

## Server Issues

### Issue: Port 3031 Already in Use

**Symptoms:** Error message `[error] listen error: eaddrinuse` when running `mix phx.server`

**Cause:** Another process is already bound to port 3031.

**Fix:**

```bash
# Option 1: Kill the existing process
lsof -ti:3031 | xargs kill -9
mix phx.server

# Option 2: Use a different port
PORT=3032 mix phx.server

# Option 3: Identify what is using the port
lsof -i :3031
sudo lsof -i :3031  # If above shows nothing
```

### Issue: Dependencies Not Found

**Symptoms:** Error `could not find dependency` during compilation.

**Cause:** Stale build artifacts or missing dependencies after a branch switch or update.

**Fix:**

```bash
rm -rf _build deps mix.lock
mix deps.get
mix phx.server
```

### Issue: Mix Not Found

**Symptoms:** Error `mix: command not found` in terminal.

**Cause:** Elixir is not installed or not on `PATH`.

**Fix:**

```bash
# Verify Elixir installation
elixir --version

# Install if missing (macOS)
brew install elixir

# Install if missing (Linux)
# Follow https://elixir-lang.org/install.html
```

---

## Dashboard Issues

### Issue: Browser Shows Connection Refused

**Symptoms:** Navigating to `localhost:3031` shows "connection refused" in browser.

**Cause:** The APM server is not running.

**Fix:**

```bash
# Verify server status
curl http://localhost:3031/health

# If no response, start the server
cd /Users/jeremiah/Developer/ccem/apm-v4
mix phx.server
```

### Issue: Dashboard Loads but Shows Blank Page

**Symptoms:** Page loads (HTTP 200) but no content renders.

**Cause:** JavaScript error or broken WebSocket connection preventing LiveView mount.

**Fix:**

1. Open browser DevTools (F12) and check the Console tab for JavaScript errors
2. Hard-reload the page: `Cmd+Shift+R` (macOS) or `Ctrl+Shift+R` (Linux)
3. Check the Network tab, filter by "WS", and verify a `/live` WebSocket shows status `101 Switching Protocols`
4. If WebSocket fails, verify `curl http://localhost:3031/` returns HTML and that no firewall is blocking the port

---

## Agent Issues

### Issue: Registered Agent Not in Fleet

**Symptoms:** Agent registered via API but does not appear in the dashboard fleet view.

**Cause:** Registration failed, project name mismatch, or dashboard not refreshed.

**Fix:**

```bash
# Check if agent exists in registry
curl http://localhost:3031/api/agents

# Re-register if missing
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-agent",
    "type": "individual",
    "project": "ccem",
    "tier": 2,
    "capabilities": ["test"]
  }'

# Verify project name matches a configured project
curl http://localhost:3031/api/projects
```

### Issue: Agent Disappears After Registration

**Symptoms:** Agent appears briefly then vanishes or shows as `idle`.

**Cause:** No heartbeat received within the 30-second timeout window.

**Fix:**

```bash
# Send a heartbeat to reactivate
curl -X POST http://localhost:3031/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active"
  }'
```

> **Important:** Agents must send heartbeats at least every 30 seconds to remain `active`.

---

## Session Issues

### Issue: Session Not Appearing in Config

**Symptoms:** A new Claude Code session does not show in the dashboard or `apm_config.json`.

**Cause:** Session init hook did not run, or config reload was not triggered.

**Fix:**

```bash
# Check per-session file was created
ls ~/Developer/ccem/apm/sessions/

# Check config for the session
jq '.projects[] | select(.name == "my-project") | .sessions' ~/Developer/ccem/apm/apm_config.json

# Force a config reload
curl -X POST http://localhost:3031/api/config/reload
```

### Issue: APM Server Not Starting from Hook

**Symptoms:** Session starts but APM dashboard is unreachable.

**Cause:** Hook script missing execute permission or APM v4 directory not found.

**Fix:**

```bash
# Check script permissions
ls -la ~/Developer/ccem/apm/hooks/session_init.sh
chmod +x ~/Developer/ccem/apm/hooks/session_init.sh

# Check APM v4 path exists
ls -la ~/Developer/ccem/apm-v4/mix.exs

# Try starting manually
cd ~/Developer/ccem/apm-v4
mix deps.get
mix phx.server
```

---

## Configuration Issues

### Issue: Configuration File Not Updating

**Symptoms:** Edits to `apm_config.json` via jq or text editor are not persisted.

**Cause:** File permissions prevent writing, or JSON syntax is invalid.

**Fix:**

```bash
# Check file permissions
ls -la ~/Developer/ccem/apm/apm_config.json
chmod 644 ~/Developer/ccem/apm/apm_config.json

# Verify JSON is valid
jq empty ~/Developer/ccem/apm/apm_config.json

# Pretty print to see syntax issues
jq . ~/Developer/ccem/apm/apm_config.json
```

### Issue: Project Not Appearing in Dropdown

**Symptoms:** Project exists in `apm_config.json` but the dashboard dropdown does not list it.

**Cause:** Config not reloaded after manual edit, or project entry is malformed.

**Fix:**

```bash
# Verify project is in config
jq '.projects[].name' ~/Developer/ccem/apm/apm_config.json

# Add project if missing
jq '.projects += [{
  "name": "new-project",
  "root": "/Users/jeremiah/Developer/new-project",
  "tasks_dir": "", "prd_json": "", "todo_md": "",
  "status": "active",
  "registered_at": (now | todate),
  "sessions": []
}]' ~/Developer/ccem/apm/apm_config.json > /tmp/config.tmp && \
mv /tmp/config.tmp ~/Developer/ccem/apm/apm_config.json

# Reload
curl -X POST http://localhost:3031/api/config/reload
```

### Issue: Port Configuration Not Taking Effect

**Symptoms:** Server still listens on old port after changing `port` in config.

**Cause:** Port is set via environment variable at server start time, not read from config at runtime.

**Fix:**

```bash
# Kill existing server
lsof -ti:3031 | xargs kill -9

# Start with new port
PORT=3032 mix phx.server
```

---

## Performance Issues

### Issue: Dashboard Very Slow with Many Agents

**Symptoms:** UI becomes unresponsive or laggy when displaying a large agent fleet.

**Cause:** High volume of WebSocket updates overwhelming the browser.

**Fix:**

1. Check agent count: `curl http://localhost:3031/api/agents | jq '.agents | length'`
2. Use dashboard filters to reduce visible agents
3. Check browser DevTools for WebSocket latency
4. Consider increasing the update throttle if configurable

### Issue: High Memory Usage

**Symptoms:** APM process consuming excessive RAM over time.

**Cause:** Unbounded growth in ETS tables, event queues, or agent heartbeat data.

**Fix:**

```bash
# Monitor memory over time
watch -n 5 'ps aux | grep apm_v4'

# Check agent count
curl http://localhost:3031/api/agents | jq '.total'

# Restart if needed
lsof -ti:3031 | xargs kill -9
mix phx.server
```

### Issue: High CPU Usage

**Symptoms:** APM process consuming excessive CPU.

**Cause:** Large number of active agents, frequent heartbeats, or expensive discovery operations.

**Fix:**

```bash
# Check active agents
curl http://localhost:3031/api/status

# Check recent errors
curl http://localhost:3031/api/notifications
```

---

## API Errors

### Issue: 400 Bad Request

**Symptoms:** API returns HTTP 400 on POST requests.

**Cause:** Request body is not valid JSON or missing required fields.

**Fix:**

```bash
# Ensure valid JSON with correct Content-Type header
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{"name":"agent","type":"individual","project":"ccem","tier":1,"capabilities":[]}'
```

### Issue: 404 Not Found

**Symptoms:** API returns HTTP 404.

**Cause:** Endpoint path is misspelled or does not exist.

**Fix:**

```bash
# Verify the endpoint exists
curl http://localhost:3031/api/agents
```

### Issue: 429 Rate Limited

**Symptoms:** API returns HTTP 429 with `Retry-After` header.

**Cause:** Too many requests in a short window. Default limits are 10 registrations/min and 100 API calls/min.

**Fix:**

```bash
# Wait for the rate limit window to reset
sleep 60
curl http://localhost:3031/api/agents
```

### Issue: 500 Internal Server Error

**Symptoms:** API returns HTTP 500.

**Cause:** Unhandled exception in server code.

**Fix:**

```bash
# Check server logs for the stack trace
sudo journalctl -u ccem-apm -n 50     # systemd
tail -100 /var/log/ccem-apm/stderr.log  # launchd

# Restart the server
lsof -ti:3031 | xargs kill -9
sleep 2
mix phx.server
```

---

## Network Issues

### Issue: Cannot Access from Another Machine

**Symptoms:** Dashboard loads on localhost but not from other machines on the network.

**Cause:** Server is bound to `127.0.0.1` only, or firewall is blocking the port.

**Fix:**

```bash
# Bind to all interfaces
export BIND_HOST=0.0.0.0
mix phx.server

# Open firewall (Linux)
sudo ufw allow 3031/tcp

# macOS: System Preferences > Security & Privacy > Firewall Options
```

### Issue: WebSocket Connection Drops

**Symptoms:** Dashboard goes stale or shows "disconnected" periodically.

**Cause:** Network instability, proxy timeout, or server overload.

**Fix:**

```bash
# Check server health
curl http://localhost:3031/health

# If behind reverse proxy, increase timeouts
# nginx example:
#   proxy_read_timeout 300s;
#   proxy_send_timeout 300s;
```

---

## CCEMAgent (Menubar App) Issues

### Issue: Menubar App Won't Connect

**Symptoms:** CCEMAgent icon shows disconnected status.

**Cause:** APM server is not running or not reachable on the configured port.

**Fix:**

```bash
# Verify server is running
curl http://localhost:3031/health

# Check app logs (macOS)
log show --predicate 'process == "CCEMAgent"' --last 1h
```

If server is running but app still disconnected, quit and relaunch CCEMAgent.

### Issue: Agent List Not Updating in Menubar

**Symptoms:** Menubar shows stale agent data.

**Cause:** Polling requests failing or returning cached data.

**Fix:**

1. Click the refresh icon in the menubar
2. Verify polling is working: `tail -f /var/log/ccem-apm/stdout.log | grep "GET /api/agents"`
3. Quit and relaunch CCEMAgent

---

## Debug Mode

### Enable Debug Logging

```bash
APM_LOG_LEVEL=debug mix phx.server
```

### Get Full Status Report

```bash
curl http://localhost:3031/health            # Health check
curl http://localhost:3031/api/status         # Server status
curl http://localhost:3031/api/agents         # All agents
curl http://localhost:3031/api/projects       # Config
curl http://localhost:3031/api/notifications  # Notifications
```

---

## Common Error Messages

### "Failed to connect to APM server"

- Server not running on the configured port
- Firewall blocking the connection
- Wrong hostname or IP address

### "Invalid project"

- Project name does not match any entry in `apm_config.json`
- Project path does not exist on disk

### "Agent not found"

- Agent ID is incorrect
- Agent timed out (no heartbeat for 10+ minutes)
- Agent registered under a different project namespace

### "Configuration error: invalid JSON"

- `apm_config.json` has a syntax error (missing quotes, trailing commas, etc.)
- Validate with: `jq empty ~/Developer/ccem/apm/apm_config.json`

---

## Prevention

- **Regular backups**: `cp apm_config.json apm_config.json.backup`
- **Health checks**: Monitor the `/health` endpoint regularly
- **Log review**: Check logs weekly for warnings
- **Update dependencies**: Run `mix deps.update --all` periodically
- **Test recovery**: Practice restoring from backups

See [Deployment](deployment.md) for production troubleshooting and [Configuration](configuration.md) for setup issues.
