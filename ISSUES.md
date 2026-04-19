# APM v5 Known Issues

## APM-001: Server fails to bind HTTP port on startup (P0)

**Status**: Open
**Filed**: 2026-04-14
**Severity**: Critical — all downstream sessions lose APM telemetry
**Component**: `ApmV5Web.Endpoint`, Tailwind watcher, StatusCache

### Symptoms

- `mix phx.server` starts, GenServers initialize (PortManager, UPM stores, SkillsRegistryStore, BootReporter), but Bandit never binds port 3032
- Log shows infinite `[BootReporter] cache_warmup_complete` messages from StatusCache broadcasting on `apm:boot` PubSub topic
- `nc -z 127.0.0.1 3032` returns exit 1 (port not listening)
- `curl http://localhost:3032/health` returns exit 7 (connection refused)
- The `Running ApmV5Web.Endpoint with Bandit x.x.x at 127.0.0.1:3032 (http)` log line never appears

### Root Cause Analysis

1. **Tailwind watcher crash**: `config/dev.exs` line 19 configures `tailwind: {Tailwind, :install_and_run, [:apm_v5, ~w(--watch)]}`. This invokes a Bun-based binary that fails with:
   ```
   error: dlopen(/$bunfs/root/lightningcss.darwin-arm64-fh6fk5tv.node, 0x0001):
     tried: '/$bunfs/root/lightningcss.darwin-arm64-fh6fk5tv.node' (no such file)
   code: "ERR_DLOPEN_FAILED"
   Bun v1.2.20 (macOS arm64)
   ```
   The lightningcss native binary is missing from Bun's virtual filesystem.

2. **Endpoint stall**: The watcher crash may prevent `ApmV5Web.Endpoint` from completing its `init/1` phase. Phoenix dev endpoints with `code_reloader: true` start watchers during endpoint boot — a watcher crash in this window can block the HTTP listener from binding.

3. **StatusCache spin**: `StatusCache` broadcasts `:status_cache_warmup_complete` events repeatedly because the endpoint it's trying to warm never starts. The BootReporter passively logs these (not causal).

4. **Launchd crash loop**: With `KeepAlive.SuccessfulExit = false` in the launchd plist, the service restarts after each non-zero exit, creating zombie BEAM processes and disk pressure.

### Observed Impact

- Every Claude Code session depending on APM (`CLAUDE.md` integration across all projects) silently loses monitoring
- Fire-and-forget `curl` POSTs to `/api/notify` fail silently
- `agentlock_pre_tool.sh` hook hangs or times out when APM is unreachable, slowing all Bash commands
- Disk pressure from repeated BEAM compile cycles and zombie processes

### Files Involved

| File | Role |
|------|------|
| `config/dev.exs:17-20` | Tailwind + esbuild watcher config |
| `lib/apm_v5/telemetry/boot_reporter.ex` | Passive — logs PubSub events (not causal) |
| `lib/apm_v5/status_cache.ex` | Emits repeated warmup events when endpoint stalls |
| `lib/apm_v5/plugin_scanner.ex:52,72` | Compiler warning: ungrouped `handle_info/2` clauses |
| `~/Library/LaunchAgents/io.pegues.agent-j.labs.ccem.apm-server.plist` | Launchd plist (created 2026-04-14) |

### Proposed Fixes

**Option A (quick fix)**: Disable watchers for headless/API-only mode
```elixir
# config/dev.exs — add a conditional or separate config
config :apm_v5, ApmV5Web.Endpoint,
  watchers: if(System.get_env("APM_NO_WATCHERS"), do: [], else: [
    esbuild: {Esbuild, :install_and_run, [:apm_v5, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:apm_v5, ~w(--watch)]}
  ])
```
Then start with `APM_NO_WATCHERS=1 mix phx.server` for headless operation.

**Option B (fix lightningcss)**: Reinstall Tailwind standalone binary:
```bash
cd ~/Developer/ccem/apm-v4 && mix tailwind.install
```

**Option C (launchd guard)**: Update plist to set `APM_NO_WATCHERS=1` in EnvironmentVariables so launchd-managed starts always skip watchers.

**Option D (resilient watchers)**: Wrap watcher init in a supervisor that tolerates crashes without blocking endpoint startup.

### Update (2026-04-14 16:30)

Disabling watchers via `APM_NO_WATCHERS=1` did NOT fix the issue. With only ~800MB free disk space, the BEAM process enters `UN` (uninterruptible sleep) state — stuck on disk I/O. The endpoint stall is caused by **disk pressure**, not just the watcher crash. The watcher crash consumes additional disk (recompile cycles) which makes it worse, but the core problem is that APM cannot start with <1GB free disk.

**Minimum disk requirement**: APM needs at least 2-3GB free to compile, start the BEAM VM, and bind the HTTP endpoint reliably.

### Workaround

Start APM manually and confirm Bandit binds before relying on health checks:
```bash
cd ~/Developer/ccem/apm-v4
APM_NO_WATCHERS=1 MIX_ENV=dev mix phx.server
# Or if APM_NO_WATCHERS not yet implemented:
# Temporarily comment out watchers in config/dev.exs
```

### Collateral: PluginScanner warning

```
warning: clauses with the same name and arity (number of arguments) should be grouped together,
  "def handle_info/2" was previously defined (lib/apm_v5/plugin_scanner.ex:52)
```
`lib/apm_v5/plugin_scanner.ex` line 72 has a `handle_info(:refresh, state)` clause separated from the one at line 52. Group them together.
