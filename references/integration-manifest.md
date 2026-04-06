# Fastlane MCP — Integration Manifest

All artifacts created/modified for the `fastlane-mcp-server` integration.

## User-scope files (outside this repo)

| Path | Action | Purpose |
|------|--------|---------|
| `~/.mcp.json` | Modified | Registered `fastlane` MCP server entry |
| `~/Developer/MCP/fastlane-mcp-server/` | Cloned + built | Local install of lyderdev/fastlane-mcp-server (v1.0.0) |
| `~/.claude/skills/fastlane/SKILL.md` | Modified | Appended "MCP Integration" section (tool→lane mapping, env setup, when-to-use) |
| `~/.claude/skills/fastlane/patterns.md` | Created | 6 reusable patterns (TestFlight, notarization, multi-platform, match nuke, version sync, Firebase symbols) |
| `~/.claude/skills/fastlane/learnings.md` | Created | 9 hard-won lessons (ASC API key, SKIP_BUNDLE_INSTALL, Xcode 26 stapling, SSH preflight, etc.) |
| `~/.claude/agents/fastlane/fastlane-build-agent.md` | Created | Archive/build specialist |
| `~/.claude/agents/fastlane/fastlane-release-agent.md` | Created | Distribution upload specialist |
| `~/.claude/agents/fastlane/fastlane-signing-agent.md` | Created | Certificate lifecycle specialist |

## Project-scope files (this repo)

| Path | Action | Purpose |
|------|--------|---------|
| `references/fastlane-mcp.md` | Created | Upstream research: repo metadata, 8 tools, env vars, registration snippet |
| `references/integration-manifest.md` | Created | This file — full artifact inventory |

## MCP server registration snippet

Added to `~/.mcp.json` under `mcpServers`:

```json
"fastlane": {
  "command": "node",
  "args": ["/Users/jeremiah/Developer/MCP/fastlane-mcp-server/dist/index.js"],
  "env": {
    "FASTLANE_SKIP_UPDATE_CHECK": "true",
    "FASTLANE_HIDE_TIMESTAMP": "true"
  }
}
```

## Smoke test result

```
$ node ~/Developer/MCP/fastlane-mcp-server/dist/index.js
[Fastlane MCP] No configuration file found, using defaults
[Fastlane MCP] ✓ Fastlane MCP Server started successfully
[Fastlane MCP] Waiting for requests...
```

Server boots cleanly in stdio mode, ready for Claude Code discovery on
next restart.

## 8 exposed MCP tools

1. `mcp__fastlane__build` — iOS/Android archive
2. `mcp__fastlane__test` — scan/gradle test
3. `mcp__fastlane__list_lanes` — Fastfile introspection
4. `mcp__fastlane__manage_certificates` — match sync/create/renew/revoke
5. `mcp__fastlane__version_management` — bump/set/get version + build
6. `mcp__fastlane__deploy_appcenter` — AppCenter distribution
7. `mcp__fastlane__firebase` — App Distribution + Crashlytics
8. `mcp__fastlane__metadata` — deliver/supply/snapshot

## npm status

**Not published to npm.** Installation requires git clone + build.
Upstream package.json declares `name: "fastlane-mcp-server"` v1.0.0 but
no published versions exist on the npm registry (verified 2026-04-05).

## LibraryStore (apm-v4 project scope)

Skipped in this iteration — no existing `LibraryStore` with 7-category
catalog was located in `apm-v4/lib/apm_v5/`. Integration is fully
functional via user-scope skills + agents + MCP registration alone.
