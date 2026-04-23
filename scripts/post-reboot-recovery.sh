#!/bin/bash
# Post-Reboot APM Recovery Script
# Run after reboot/re-login to restore APM service
# Created: 2026-04-14 — addresses cascading BEAM crash issue

set -euo pipefail

echo "=== APM Post-Reboot Recovery ==="

# 1. Verify clean state
echo "[1/5] Verifying clean state..."
ZOMBIES=$(ps aux | awk '$8 ~ /E/' | wc -l | tr -d ' ')
echo "  Zombie processes: $ZOMBIES"
if [ "$ZOMBIES" -gt 10 ]; then
  echo "  WARNING: Still $ZOMBIES zombies — consider full reboot"
fi

LOAD=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
echo "  Load average: $LOAD"

# 2. Start epmd
echo "[2/5] Starting epmd..."
epmd -daemon 2>/dev/null
sleep 1
epmd -names 2>&1

# 3. Verify port is free
echo "[3/5] Checking port 3032..."
if lsof -ti:3032 >/dev/null 2>&1; then
  echo "  Port 3032 held — killing..."
  lsof -ti:3032 | xargs kill -9 2>/dev/null
  sleep 2
fi
echo "  Port 3032: FREE"

# 4. Start APM server
echo "[4/5] Starting APM server..."
cd ~/Developer/ccem/apm-v4
MIX_ENV=dev PORT=3032 mix phx.server > /tmp/apm-recovery.log 2>&1 &
echo $! > .apm.pid
echo "  PID: $(cat .apm.pid)"

# 5. Wait for server
echo "[5/5] Waiting for server..."
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3032/ 2>/dev/null)
  if [ "$code" != "000" ]; then
    echo "  APM UP: HTTP $code after ${i}s"
    echo "  Dashboard: http://localhost:3032"
    # Launch CCEMHelper
    open -a CCEMHelper 2>/dev/null || true
    echo "=== Recovery complete ==="
    exit 0
  fi
  sleep 1
done

echo "  FAILED: Server did not start in 30s"
echo "  Check log: cat /tmp/apm-recovery.log"
exit 1
