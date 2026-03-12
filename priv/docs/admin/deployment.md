# Production Deployment

Guide for deploying CCEM APM v4 to production environments.

> **Warning:** Never run multiple APM instances on the same port. Check for existing processes before starting a new server.

## System Requirements

- **Elixir**: 1.14+
- **Erlang/OTP**: 25+
- **Memory**: 500MB minimum (scales with agent count)
- **Disk**: 100MB for code and logs
- **Network**: Port 3031 (or configured port) accessible

## Pre-Deployment Checklist

Complete all items before deploying:

- [ ] Elixir 1.14+ and Erlang/OTP 25+ installed (`elixir --version`)
- [ ] Dependencies fetched (`mix deps.get`)
- [ ] Project compiles cleanly (`mix compile --warnings-as-errors`)
- [ ] Configuration file prepared (`apm_config.json` with `"version": "4.0.0"`)
- [ ] Environment variables set (`MIX_ENV`, `SECRET_KEY_BASE`, `PORT`)
- [ ] Port 3031 is free (`lsof -ti:3031` returns nothing)
- [ ] SSL certificates ready (if using HTTPS)
- [ ] Firewall rules allow traffic on the configured port
- [ ] Monitoring and alerting configured
- [ ] Backup strategy in place for `apm_config.json`
- [ ] Previous APM instance stopped (if upgrading)

## Build Process

### Release Build

Create a production release:

```bash
cd /Users/jeremiah/Developer/ccem/apm-v5
MIX_ENV=prod mix release
```

This generates a standalone release in `_build/prod/rel/apm_v5/`.

### Environment Configuration

Set production environment variables:

```bash
export MIX_ENV=prod
export PORT=3031
export SECRET_KEY_BASE=$(openssl rand -base64 32)
```

> **Important:** `SECRET_KEY_BASE` is required for session encryption. Generate a unique value per deployment.

## Starting the Server

### Development (Testing/Staging)

```bash
cd /Users/jeremiah/Developer/ccem/apm-v5
mix phx.server
```

### Production (Release)

Start the compiled release:

```bash
/Users/jeremiah/Developer/ccem/apm-v5/_build/prod/rel/apm_v5/bin/apm_v5 start
```

Or run in foreground for debugging:

```bash
/Users/jeremiah/Developer/ccem/apm-v5/_build/prod/rel/apm_v5/bin/apm_v5 foreground
```

### Background Service (systemd)

Create `/etc/systemd/system/ccem-apm.service`:

```ini
[Unit]
Description=CCEM APM v4
After=network.target

[Service]
Type=simple
User=apm
WorkingDirectory=/Users/jeremiah/Developer/ccem/apm-v5
Environment="MIX_ENV=prod"
Environment="PORT=3031"
ExecStart=/Users/jeremiah/Developer/ccem/apm-v5/_build/prod/rel/apm_v5/bin/apm_v5 start
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl enable ccem-apm
sudo systemctl start ccem-apm
sudo systemctl status ccem-apm
```

### Background Service (launchd - macOS)

Create `/Library/LaunchDaemons/com.ccem.apm.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ccem.apm</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/jeremiah/Developer/ccem/apm-v5/_build/prod/rel/apm_v5/bin/apm_v5</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/jeremiah/Developer/ccem/apm-v5</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MIX_ENV</key>
        <string>prod</string>
        <key>PORT</key>
        <string>3031</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/ccem-apm/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/ccem-apm/stderr.log</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Load and manage:

```bash
sudo launchctl load /Library/LaunchDaemons/com.ccem.apm.plist
sudo launchctl unload /Library/LaunchDaemons/com.ccem.apm.plist
```

## PID File Management

The server writes its PID to `.apm.pid`:

```bash
cat /Users/jeremiah/Developer/ccem/apm-v5/.apm.pid
# Output: 12345
```

Use for process management:

```bash
# Check if running
if [ -f .apm.pid ]; then
  PID=$(cat .apm.pid)
  kill -0 $PID 2>/dev/null && echo "Running" || echo "Dead"
fi

# Graceful shutdown
kill $(cat .apm.pid)

# Force kill
kill -9 $(cat .apm.pid)
```

## Environment Variables

### Required

```bash
export MIX_ENV=prod
export SECRET_KEY_BASE=$(openssl rand -base64 32)
```

### Optional

```bash
export PORT=3031                              # HTTP listen port (default: 3031)
export APM_CONFIG_PATH=/etc/ccem/apm_config.json  # Custom config location
export BIND_HOST=0.0.0.0                      # Bind to all interfaces
export APM_LOG_LEVEL=debug                    # Enable verbose logging
```

## Port Binding

### Local Development

```text
http://localhost:3032
```

### Network Accessible

Bind to all interfaces:

```bash
export BIND_HOST=0.0.0.0
```

Access from other machines:

```text
http://<server-ip>:3031
```

### Behind Reverse Proxy (nginx)

Configure nginx to forward to local APM:

```nginx
upstream apm_v5 {
  server localhost:3032;
}

server {
  listen 80;
  server_name apm.example.com;

  location / {
    proxy_pass http://apm_v5;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  }
}
```

> **Important:** The `upgrade` headers are required for LiveView WebSocket connections. Without them, the dashboard will not receive real-time updates.

## SSL/TLS Configuration

### Self-Signed Certificate (Testing)

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 -keyout apm.key -out apm.crt
```

### Production Certificate

Use a proper certificate from a CA (Let's Encrypt, etc.).

### Configure HTTPS

In `config/prod.exs`:

```elixir
config :apm_v5, ApmV5Web.Endpoint,
  url: [host: "apm.example.com", port: 443, scheme: "https"],
  https: [
    port: 443,
    cipher_suite: :strong,
    keyfile: "/path/to/apm.key",
    certfile: "/path/to/apm.crt"
  ]
```

## Monitoring and Health

### Health Check Endpoint

```bash
curl http://localhost:3032/health
```

Response:

```json
{
  "status": "ok",
  "timestamp": "2026-02-19T12:00:00Z",
  "version": "4.0.0"
}
```

### Logging

```bash
# Foreground: logs print to stdout

# systemd service
sudo journalctl -u ccem-apm -f

# launchd service
tail -f /var/log/ccem-apm/stdout.log
```

### Process Monitor Script

Script to monitor and auto-restart:

```bash
#!/bin/bash
PID_FILE="/Users/jeremiah/Developer/ccem/apm-v5/.apm.pid"
CHECK_INTERVAL=30

while true; do
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ! kill -0 $PID 2>/dev/null; then
      echo "APM died, restarting..."
      /Users/jeremiah/Developer/ccem/apm-v5/_build/prod/rel/apm_v5/bin/apm_v5 start
    fi
  fi
  sleep $CHECK_INTERVAL
done
```

## Scaling Considerations

### For 100+ Agents

- Increase ETS table sizes
- Enable agent indexing optimization
- Consider increasing memory allocation
- Monitor CPU usage during peak periods

```bash
# Increase Erlang scheduler threads
export ELIXIR_ERL_OPTIONS="+S 4:4"
```

### For 1000+ Agents

- Use multiple APM instances behind load balancer
- Implement agent sharding by project
- Consider external data store (PostgreSQL)
- Enable message queuing for high throughput

### Clustering (Advanced)

For multi-node setup:

```bash
# Node 1
export NODE_NAME=apm1@localhost
export COOKIE=secret_cookie

# Node 2
export NODE_NAME=apm2@localhost
export COOKIE=secret_cookie
```

Then cluster nodes in Elixir code.

## Backup and Recovery

> **Important:** Always back up `apm_config.json` before upgrades or manual edits.

### Configuration Backup

```bash
cp /Users/jeremiah/Developer/ccem/apm/apm_config.json \
   /backup/apm_config.json.$(date +%Y%m%d)
```

### Data Export

```bash
curl http://localhost:3032/api/v2/export > /backup/apm_export_$(date +%Y%m%d).json
```

### Restore

```bash
curl -X POST http://localhost:3032/api/v2/import \
  -H "Content-Type: application/json" \
  -d @/backup/apm_export_DATE.json
```

## Performance Tuning

### Erlang VM Tuning

```bash
export ELIXIR_ERL_OPTIONS="+K true +A 256 +S 4:4"
```

- `+K true` -- Enable kernel polling
- `+A 256` -- Async threads
- `+S 4:4` -- Scheduler threads

### Phoenix Tuning

In `config/prod.exs`:

```elixir
config :apm_v5, ApmV5Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true,
  code_reloader: false,
  watchers: []

config :phoenix, serve_endpoints: true
```

## Troubleshooting

### Port Already in Use

```bash
lsof -ti:3031 | xargs kill -9
```

### Memory Leaks

Monitor memory over time:

```bash
watch -n 5 'ps aux | grep apm_v5'
```

If memory grows unbounded, check for:
- Agent heartbeat memory accumulation
- Event queue buildup
- ETS table growth

### High CPU Usage

- Check agent count with `curl http://localhost:3032/api/status`
- Monitor heartbeat frequency
- Disable expensive operations (discovery)
- Increase polling interval in config

### Connection Issues

```bash
# Linux
sudo ufw allow 3031/tcp

# macOS: System Preferences > Security & Privacy > Firewall Options
```

## Logs and Debugging

### Enable Debug Logging

```bash
export APM_LOG_LEVEL=debug
```

### Log Rotation

If using syslog:

```bash
# /etc/logrotate.d/ccem-apm
/var/log/ccem-apm/*.log {
  daily
  rotate 7
  compress
  delaycompress
  notifempty
}
```

### Remote Debugging

Use Erlang debugger for production issues:

```bash
erl -name debug@localhost -setcookie secret -remsh apm1@localhost
```

## Disaster Recovery

1. Stop server: `kill $(cat .apm.pid)`
2. Check config validity: `jq empty apm_config.json`
3. Restore from backup if needed
4. Restart: `/path/to/apm_v5 start`
5. Verify with health check: `curl http://localhost:3032/health`

### Session Recovery

Sessions are stored in `apm_config.json`. Restore from backup:

```bash
cp apm_config.json.backup apm_config.json
curl -X POST http://localhost:3032/api/config/reload
```

## Support and Maintenance

- Review logs weekly for errors
- Test backups monthly
- Monitor agent registration trends
- Clean up old sessions periodically
- Update dependencies regularly
- Plan capacity for growing agent count

See [Configuration](configuration.md) for setup reference and [Troubleshooting](troubleshooting.md) for common issues.
