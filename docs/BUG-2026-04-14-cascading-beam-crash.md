# BUG: Cascading BEAM Crash — erl_child_setup closed

**Date**: 2026-04-14
**Severity**: Critical
**Project**: CCEM APM (ccem-apm)
**Status**: All 4 root causes identified and fixed

## Summary

APM Phoenix server enters a death spiral where BEAM crashes with `erl_child_setup closed`, creating zombie processes that prevent subsequent restarts. Each restart attempt worsens system load until the machine becomes unresponsive.

## Root Causes Identified

### BUG-1: StatusCache Infinite Broadcast Loop (FIXED)
- **File**: `lib/apm_v5/status_cache.ex:128-136`
- **Issue**: `handle_cast({:warmup_done, ...})` broadcasts `{:status_cache_warmup_complete, key, now}` on every 500ms refresh cycle, not just initial warmup
- **Impact**: ~4 PubSub messages/second flooding BootReporter logs indefinitely, causing I/O saturation
- **Fix Applied**: Added `first_write` guard — broadcast only when ETS key doesn't exist yet
- **Status**: FIXED (edit applied to source, needs `mix compile` on clean system)

### BUG-2: session_init.sh Race Condition (FIXED)
- **File**: `~/Developer/ccem/apm/hooks/session_init.sh`
- **Issue**: No mutex/flock protection. Multiple concurrent Claude Code sessions fire SessionStart hook simultaneously, each killing the other's in-progress BEAM boot
- **Impact**: Cascading zombie accumulation (125+ zombies observed)
- **Fix Applied**: Added `flock` mutex (via `/opt/homebrew/opt/util-linux/bin/flock`) with `mkdir`-based fallback around start/restart logic
- **Status**: FIXED (2026-04-14)

### BUG-3: 50+ Sequential GenServer Supervision Tree (FIXED)
- **File**: `lib/apm_v5/application.ex:20-109`
- **Issue**: ~50 children started sequentially with `ApmV5Web.Endpoint` last. Multiple children do filesystem scanning during init (SkillsRegistryStore, LibraryStore, SessionManager, etc.). Under disk/memory pressure, boot never reaches the endpoint.
- **Fix Applied**: Moved `ApmV5Web.Endpoint` to start immediately after `ApmV5.DashboardData` (before all filesystem-scanning GenServers). Health checks now pass while scanners boot.
- **Status**: FIXED (2026-04-14, compilation verified clean)

### BUG-4: No epmd Recovery (FIXED)
- **Issue**: When `pkill -9 epmd` is run (by crash recovery scripts or hooks), subsequent BEAM starts hang in `UN` (uninterruptible I/O sleep) because there's no epmd to connect to
- **Fix Applied**: Added `epmd -daemon` before `mix phx.server` in `session_init.sh`
- **Status**: FIXED (2026-04-14)

## Environment at Time of Failure

- macOS Darwin 24.5.0, 12 cores
- 17 days uptime
- Disk: 97% full (788MB free) -> freed to 88% (3.2GB)
- Load average: peaked at 130.44
- Zombie processes: 125+
- Spotify consuming 888 CPU minutes

## Recovery Steps

1. Reboot (or logout/login to clear zombies)
2. Run: `bash ~/Developer/ccem/apm-v4/scripts/post-reboot-recovery.sh`
3. Verify: `curl http://localhost:3032/api/status`

## Files Modified

- `lib/apm_v5/status_cache.ex` — BUG-1 fix (warmup broadcast guard)
- `~/Developer/ccem/apm/hooks/session_init.sh` — BUG-2 fix (flock mutex) + BUG-4 fix (epmd daemon)
- `lib/apm_v5/application.ex` — BUG-3 fix (Endpoint moved before scanners)

## Tracking

### APM Notifications (2026-04-14)
- BUG-1: Notification #169 — StatusCache infinite broadcast loop (RESOLVED)
- BUG-2: Notification #170 — session_init.sh race condition (RESOLVED)
- BUG-3: Notification #171 — Supervision tree boot ordering (RESOLVED)
- BUG-4: Notification #172 — epmd recovery in startup hook (RESOLVED)

### Plane PM (CCEM project @ plane.lgtm.build)
- CCEM-390: [BUG-1] StatusCache Infinite Broadcast Loop (DONE)
- CCEM-391: [BUG-2] session_init.sh Race Condition (DONE)
- CCEM-392: [BUG-3] Supervision Tree Boot Ordering (DONE)
- CCEM-393: [BUG-4] No epmd Recovery (DONE)
