# fastlane-mcp-server — Integration Reference

## Upstream

- **Repository**: https://github.com/lyderdev/fastlane-mcp-server
- **License**: MIT
- **Author**: lyderdev
- **Package name**: `fastlane-mcp-server` (per `package.json`)
- **Version**: 1.0.0
- **MCP SDK**: `@modelcontextprotocol/sdk@^0.5.0`
- **Language**: TypeScript → Node 18+, ESM, `dist/index.js`

## npm availability

**Not published to npm** as of 2026-04-05. Both `fastlane-mcp-server` and
`@lyderdev/fastlane-mcp-server` return 404 from the npm registry. Integration
requires git clone + `npm install && npm run build`.

## Local install path

Cloned + built to:

```
~/Developer/MCP/fastlane-mcp-server/
  ├── dist/index.js      # entry point (ESM)
  ├── package.json
  └── src/
```

Smoke test (boots stdio MCP server, waits for requests):

```bash
node ~/Developer/MCP/fastlane-mcp-server/dist/index.js
# [Fastlane MCP] ✓ Fastlane MCP Server started successfully
# [Fastlane MCP] Waiting for requests...
```

## Exposed tools (8)

| # | Tool | Purpose | Key params |
|---|------|---------|-----------|
| 1 | `build` | Build iOS/Android app | `platform`, `projectPath`, `lane?`, `environment?`, `clean?` |
| 2 | `deploy_appcenter` | Ship to AppCenter | `platform`, `projectPath`, `appName?`, `group?`, `notes?` |
| 3 | `firebase` | Firebase App Distribution / Crashlytics | `action` (deploy/distribute/crashlytics), `platform`, `projectPath`, `appId?`, `groups?`, `releaseNotes?` |
| 4 | `test` | Run automated tests | `platform`, `projectPath`, `device?`, `testPlan?` |
| 5 | `manage_certificates` | Code signing (iOS-focused) | `platform`, `action` (sync/create/renew/revoke), `projectPath`, `type?` |
| 6 | `list_lanes` | Discover Fastfile lanes | `projectPath`, `platform?` |
| 7 | `version_management` | Bump/set/get app version | `platform`, `projectPath`, `action` (bump/set/get), `versionType?`, `version?` |
| 8 | `metadata` | App Store / Play Store metadata + screenshots | `platform`, `projectPath`, `action` (deliver/supply/snapshot), `skipScreenshots?`, `skipMetadata?` |

> Tool names above are the human-friendly labels from the README; actual MCP
> tool names appear as `mcp__fastlane__<tool>` in Claude Code once registered.

## Environment variables

| Var | Purpose | Required for |
|-----|---------|--------------|
| `FASTLANE_USER` | Apple ID email | TestFlight / App Store Connect via Apple ID |
| `FASTLANE_PASSWORD` | Apple ID app-specific password | TestFlight / App Store Connect via Apple ID |
| `APPCENTER_API_TOKEN` | Microsoft AppCenter token | AppCenter distribution |
| `FIREBASE_TOKEN` | Firebase CLI token | Firebase App Distribution |
| `MATCH_PASSWORD` | Match passphrase | iOS cert sync via match |
| `FASTLANE_SKIP_UPDATE_CHECK` | Skip fastlane update check | CI stability |
| `FASTLANE_HIDE_TIMESTAMP` | Cleaner log output | Log hygiene |

> CCEM convention: prefer **App Store Connect API key** (stored path in
> `APP_STORE_CONNECT_API_KEY_PATH`) over `FASTLANE_USER`/`FASTLANE_PASSWORD`
> for CI — no 2FA friction, no Apple ID rate limits.

## Expected project structure

```
your-project/
├── ios/fastlane/{Fastfile,Appfile}
├── android/fastlane/{Fastfile,Appfile}
└── firebase.json (optional)
```

The `projectPath` parameter on every tool points to the root that contains
the `ios/` and/or `android/` directories.

## Claude Code registration (stdio)

```json
{
  "mcpServers": {
    "fastlane": {
      "command": "node",
      "args": ["/Users/jeremiah/Developer/MCP/fastlane-mcp-server/dist/index.js"],
      "env": {
        "FASTLANE_SKIP_UPDATE_CHECK": "true",
        "FASTLANE_HIDE_TIMESTAMP": "true"
      }
    }
  }
}
```

Secrets (`FASTLANE_PASSWORD`, `MATCH_PASSWORD`, `APPCENTER_API_TOKEN`,
`FIREBASE_TOKEN`) are **NOT** baked into the MCP registration. Instead:

1. Export them in the user shell rc (`~/.zshrc`) as environment vars
2. Or retrieve on-demand via `/azure` Key Vault skill
3. Or use `/safesecret` to present via macOS dialog with auto-clear

## Prerequisites on host

- Node.js 18+
- `gem install fastlane` (or `brew install fastlane`)
- Xcode + valid Apple Developer account for iOS
- Android SDK + Java for Android
- `firebase` CLI for Firebase features
- `appcenter` CLI for AppCenter distribution

## Known caveats

- The MCP server shells out to `fastlane` — it does **not** reimplement
  fastlane actions. If `fastlane` isn't on PATH in Claude Code's spawn
  environment, every tool call fails.
- Designed around the `ios/` + `android/` layout typical of React
  Native / Flutter / Capacitor projects. Pure-Apple projects (Swift
  Package, single-target Xcode project) may need to pass `projectPath`
  pointing at a parent wrapper or use the `/fastlane` skill directly.
- No built-in `gym`/`scan`/`match`/`pilot`/`deliver` granularity — those
  are invoked through `build`/`test`/`manage_certificates`/`metadata`
  with the underlying lane name supplied via the `lane?` param.
