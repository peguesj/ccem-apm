# Troubleshooting Guide

Common issues and solutions for CCEM APM v4.

## Server Won't Start

### Error: Port 3031 Already in Use

**Symptom**:
```
[error] listen error: eaddrinuse
```

**Solution 1: Kill existing process**

```bash
lsof -ti:3031 | xargs kill -9
mix phx.server
```

**Solution 2: Use different port**

```bash
export APM_PORT=3032
mix phx.server
```

**Solution 3: Find what's using the port**

```bash
lsof -i :3031
sudo lsof -i :3031  # If above doesn't show anything
```

### Error: Dependencies Not Found

**Symptom**:
```
Compiling...
error: could not find dependency
```

**Solution**:

```bash
rm -rf _build deps mix.lock
mix deps.get
mix phx.server
```

### Error: Mix Not Found

**Symptom**:
```
mix: command not found
```

**Solution**:

Verify Elixir is installed:

```bash
elixir --version
```

If not installed:

```bash
# macOS
brew install elixir

# Linux - follow https://elixir-lang.org/install.html
```

## Dashboard Not Loading

### Browser Shows Connection Refused

**Symptom**:
```
localhost:3031 refused to connect
```

**Verify server is running**:

```bash
curl http://localhost:3031/health
```

If no response, start server:

```bash
cd /Users/jeremiah/Developer/ccem/apm-v4
mix phx.server
```

### Dashboard Loads but Shows Blank Page

**Check browser console** (press F12):

Look for JavaScript errors in Console tab.

**Clear cache and reload**:

```
Cmd+Shift+R (macOS)
Ctrl+Shift+R (Linux/Windows)
```

**Check WebSocket connection**:

1. Open DevTools (F12)
2. Go to Network tab
3. Filter by "WS" (WebSockets)
4. Look for `/live` connection
5. Should show status "101 Switching Protocols"

If WebSocket fails:
- Verify server is accepting connections: `curl http://localhost:3031/`
- Check firewall isn't blocking port 3031
- Try accessing from different browser/incognito

## Agents Not Appearing

### Registered Agent Doesn't Show in Fleet

**Check agent registration succeeded**:

```bash
curl http://localhost:3031/api/agents
```

Look for your agent in the response.

**If not in list**:

```bash
# Re-register the agent
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-agent",
    "type": "individual",
    "project": "ccem",
    "tier": 2,
    "capabilities": ["test"]
  }'
```

**Check project name matches**:

```bash
# Get configured projects
curl http://localhost:3031/api/projects

# Verify "project": "ccem" in your registration
```

### Agent Disappears After Registration

**Check heartbeat is being sent**:

Agents must send heartbeat every 30 seconds or become `idle`:

```bash
# Send heartbeat
curl -X POST http://localhost:3031/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-abc123",
    "status": "active"
  }'
```

**If agent became idle**:

Send another heartbeat to activate it again.

## Session Not Registering

### Session Not Appearing in Config

**Check hook is being sourced**:

```bash
echo $CCEM_SESSION_ID
# Should output something like: session-abc123
```

If empty, source the hook:

```bash
source ~/Developer/ccem/apm/hooks/session_init.sh
```

**Check config file**:

```bash
cat ~/Developer/ccem/apm/apm_config.json | jq .sessions
```

Should show your session.

**Reload config if needed**:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

### APM Server Not Starting from Hook

**Check script permissions**:

```bash
ls -la ~/Developer/ccem/apm/hooks/session_init.sh
# Should have execute permission (-x)

chmod +x ~/Developer/ccem/apm/hooks/session_init.sh
```

**Check APM v4 path**:

```bash
ls -la ~/Developer/ccem/apm-v4/mix.exs
# Should exist
```

**Try starting manually**:

```bash
cd ~/Developer/ccem/apm-v4
mix deps.get
mix phx.server
```

## Configuration Issues

### Configuration File Not Updating

**Check file permissions**:

```bash
ls -la ~/Developer/ccem/apm/apm_config.json
# Should be writable by your user

chmod 644 ~/Developer/ccem/apm/apm_config.json
```

**Verify JSON is valid**:

```bash
jq empty ~/Developer/ccem/apm/apm_config.json
# If error, file is invalid JSON
```

**Check for syntax errors**:

```bash
# Pretty print to see issues
jq . ~/Developer/ccem/apm/apm_config.json
```

### Project Not Appearing in Dropdown

**Check project in config**:

```bash
jq .projects ~/Developer/ccem/apm/apm_config.json
```

If project missing, add it:

```bash
jq '.projects += [{
  "name": "new-project",
  "root": "/Users/jeremiah/Developer/new-project"
}]' ~/Developer/ccem/apm/apm_config.json > /tmp/config.tmp && \
mv /tmp/config.tmp ~/Developer/ccem/apm/apm_config.json
```

Then reload:

```bash
curl -X POST http://localhost:3031/api/config/reload
```

### Port Configuration Not Taking Effect

**Restart server**:

Config changes require server restart:

```bash
# Kill existing server
lsof -ti:3031 | xargs kill -9

# Start with new port
export APM_PORT=3032
mix phx.server
```

**Verify with environment variable**:

```bash
echo $APM_PORT
```

## Performance Issues

### Dashboard Very Slow with Many Agents

**Check agent count**:

```bash
curl http://localhost:3031/api/agents | jq '.agents | length'
```

**For 100+ agents**:

1. Use browser DevTools to check WebSocket latency
2. Consider filtering agents in dashboard
3. Check server logs for errors: `tail -f server.log`

**Reduce update frequency**:

In config, if option available:
```json
{
  "update_throttle_ms": 1000
}
```

### High Memory Usage

**Check if leak**:

Monitor memory over 5 minutes:

```bash
watch -n 5 'ps aux | grep apm_v4'
```

**If memory keeps growing**:

1. Check agent count: `curl http://localhost:3031/api/agents | jq '.total'`
2. Look for unbounded collections in logs
3. Restart server: `lsof -ti:3031 | xargs kill -9`

### High CPU Usage

**Identify cause**:

```bash
# Check active agents
curl http://localhost:3031/api/status

# Check recent errors
curl http://localhost:3031/api/notifications
```

**Reduce polling frequency**:

In CCEMAgent or config:
```json
{
  "polling_interval_seconds": 10
}
```

## API Errors

### 400 Bad Request

**Check JSON format**:

```bash
# Invalid JSON
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{invalid json}'

# Valid JSON
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{"name":"agent","type":"individual","project":"ccem","tier":1,"capabilities":[]}'
```

### 404 Not Found

**Check endpoint exists**:

```bash
# Does endpoint exist?
curl http://localhost:3031/api/agents

# Typo in URL?
curl http://localhost:3031/api/agens  # Wrong!
```

### 429 Rate Limited

**Check rate limits**:

Default limits:
- 10 agent registrations per minute
- 100 API calls per minute

**Wait or use different client IP**:

```bash
# Wait and retry
sleep 60
curl http://localhost:3031/api/agents
```

### 500 Internal Server Error

**Check server logs**:

```bash
# If running in foreground, see console output
# If as service:
sudo journalctl -u ccem-apm -n 50

# If launchd:
tail -100 /var/log/ccem-apm/stderr.log
```

**Try restarting**:

```bash
lsof -ti:3031 | xargs kill -9
sleep 2
mix phx.server
```

## Network Issues

### Cannot Access from Another Machine

**Check firewall**:

```bash
# Linux
sudo ufw allow 3031/tcp

# macOS
# System Preferences → Security & Privacy → Firewall Options
# Or: sudo pfctl -t blocklist -T add 3031
```

**Check binding address**:

```bash
# APM should be listening on all interfaces
netstat -an | grep 3031
```

If only listening on localhost, set:

```bash
export BIND_HOST=0.0.0.0
mix phx.server
```

### WebSocket Connection Drops

**Check server health**:

```bash
curl http://localhost:3031/health
```

**Increase timeout**:

If behind reverse proxy, increase timeout:

```nginx
proxy_read_timeout 300s;
proxy_send_timeout 300s;
```

**Check network stability**:

Monitor connection:

```bash
ping <server-ip>
traceroute <server-ip>
```

## CCEMAgent Issues

### Menubar App Won't Connect

**Check APM server**:

```bash
curl http://localhost:3031/health
```

**Check app logs** (macOS):

```bash
log show --predicate 'process == "CCEMAgent"' --last 1h
```

**Restart the app**:

1. Quit CCEMAgent (Cmd+Q)
2. Relaunch from Applications
3. Check menu bar for icon

### Agent List Not Updating in Menubar

**Check polling working**:

In Terminal, watch requests:

```bash
tail -f /var/log/ccem-apm/stdout.log | grep "GET /api/agents"
```

**Force refresh**: Click the refresh icon in menubar

**Check token budget**:

In config:
```json
{
  "token_budget": 100000
}
```

## Notification Issues

### Not Receiving Notifications

**Check bell icon**:

Top right of dashboard. Should show unread count.

**Refresh dashboard**:

```
Cmd+R (macOS)
Ctrl+R (Windows/Linux)
```

**Check notification permissions** (browser):

1. Open Settings
2. Look for notification settings
3. Allow notifications for localhost:3031

## Debug Mode

### Enable Debug Logging

```bash
export APM_LOG_LEVEL=debug
mix phx.server
```

This prints detailed logs to help diagnose issues.

### Get Full Status Report

```bash
# Health check
curl http://localhost:3031/health

# Server status
curl http://localhost:3031/api/status

# All agents
curl http://localhost:3031/api/agents

# Config
curl http://localhost:3031/api/projects

# Notifications
curl http://localhost:3031/api/notifications
```

## Getting Help

If issue persists:

1. **Collect debug info**:

```bash
# Server version
curl http://localhost:3031/health

# Current config (redacted)
cat ~/Developer/ccem/apm/apm_config.json | jq 'del(.projects[].root)'

# Recent logs
tail -100 server.log  # if saved to file

# System info
uname -a
elixir --version
```

2. **Check documentation**:
   - [Getting Started](../user/getting-started.md)
   - [Configuration](configuration.md)
   - [Deployment](deployment.md)

3. **Review logs closely** for error messages and timestamps

4. **Try minimal reproduction**: Simple curl test case

## Common Error Messages

### "Failed to connect to APM server"

- Server not running on configured port
- Firewall blocking connection
- Wrong hostname/IP address

### "Invalid project"

- Project name doesn't match apm_config.json
- Project path doesn't exist
- Typo in project name

### "Agent not found"

- Agent ID is wrong
- Agent timed out (no heartbeat for 10 minutes)
- Wrong project namespace

### "Configuration error: invalid JSON"

- apm_config.json has syntax error
- Use `jq empty apm_config.json` to verify
- Check for missing quotes, trailing commas

## Prevention

- **Regular backups**: `cp apm_config.json apm_config.json.backup`
- **Health checks**: Monitor `/health` endpoint regularly
- **Log review**: Check logs weekly for warnings
- **Update dependencies**: `mix deps.update` periodically
- **Test recovery**: Practice restoring from backups

See [Deployment](deployment.md) for production troubleshooting and [Configuration](configuration.md) for setup issues.
