# SwiftUI Menubar Agent (CCEMAgent)

CCEMAgent is a native macOS application providing real-time monitoring and control of CCEM APM from the menu bar.

## Overview

CCEMAgent runs as a persistent menubar app (system tray on macOS) with:

- **Real-time Project Status**: Live display of all CCEM projects with agent counts and session activity
- **UPM Monitoring**: Wave progress, story status, and session tracking
- **Health Monitoring**: APM server connection state with auto-reconnect
- **Environment Filtering**: Toggle between All and Active project views
- **Drift Detection**: Per-project drift status monitoring
- **Login Item**: Auto-launch on system startup via ServiceManagement

## Architecture

```
+----------------------------------+
|  MenuBarView (SwiftUI)           |
|  - Header with connection state  |
|  - Filter picker (All/Active)    |
|  - Environment list              |
|  - UPM status bar                |
|  - Action buttons                |
+----------------+-----------------+
                 |
+----------------v-----------------+
|  EnvironmentMonitor (@Observable)|
|  - Polls APM server (10s)        |
|  - Tracks environments           |
|  - Manages connection state      |
|  - Fetches UPM status            |
+----------------+-----------------+
                 |
+----------------v-----------------+
|  APMClient (actor)               |
|  - async/await HTTP requests     |
|  - JSON decoding                 |
|  - Error handling                |
+----------------+-----------------+
                 |
           http://localhost:3031
```

## Key Components

### APMClient

An `actor` providing thread-safe async HTTP communication with the APM server.

```swift
actor APMClient {
    private let baseURL = URL(string: "http://localhost:3031")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    func checkHealth() async throws -> HealthStatus {
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APMClientError.badResponse
        }
        return try decoder.decode(HealthStatus.self, from: data)
    }

    func fetchProjects() async throws -> [APMProject] {
        let url = baseURL.appendingPathComponent("api/projects")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APMClientError.badResponse
        }
        if let wrapper = try? decoder.decode(ProjectListResponse.self, from: data) {
            return wrapper.projects
        }
        if let list = try? decoder.decode([APMProject].self, from: data) {
            return list
        }
        return []
    }

    func fetchEnvironments() async throws -> [APMProject] {
        let url = baseURL.appendingPathComponent("api/environments")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APMClientError.badResponse
        }
        if let wrapper = try? decoder.decode(EnvironmentListResponse.self, from: data) {
            return wrapper.environments
        }
        if let list = try? decoder.decode([APMProject].self, from: data) {
            return list
        }
        return []
    }

    func fetchUPMStatus() async throws -> UPMStatus {
        let url = baseURL.appendingPathComponent("api/upm/status")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APMClientError.badResponse
        }
        return try decoder.decode(UPMStatus.self, from: data)
    }

    func fetchData() async throws -> APMDataResponse {
        let url = baseURL.appendingPathComponent("api/data")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APMClientError.badResponse
        }
        return try decoder.decode(APMDataResponse.self, from: data)
    }
}
```

### APMClientError

```swift
enum APMClientError: Error, LocalizedError {
    case badResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Bad response from APM server"
        case .decodingFailed: return "Failed to decode APM response"
        }
    }
}
```

### EnvironmentMonitor

Uses Swift Observation framework (`@Observable`) with `@MainActor` isolation. Polls the APM server every 10 seconds using structured concurrency.

```swift
@MainActor
@Observable
final class EnvironmentMonitor {
    var connectionState: ConnectionState = .disconnected
    var environments: [APMEnvironment] = []
    var healthStatus: HealthStatus?
    var lastError: String?
    var lastRefresh: Date?
    var filter: EnvironmentFilter = .all
    var upmStatus: UPMStatus?

    var filteredEnvironments: [APMEnvironment] {
        switch filter {
        case .all: return environments
        case .active: return environments.filter { $0.sessionCount > 0 }
        }
    }

    var activeCount: Int {
        environments.filter { $0.sessionCount > 0 }.count
    }

    private let client = APMClient()
    private let driftDetector = DriftDetector()
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 10

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        connectionState = .connecting

        do {
            let health = try await client.checkHealth()
            healthStatus = health
            connectionState = health.isHealthy ? .connected : .disconnected
        } catch {
            connectionState = .disconnected
            lastError = error.localizedDescription
            environments = []
            return
        }

        // Build environments from health projects
        let healthProjects = healthStatus?.projects ?? []
        var updatedEnvironments: [APMEnvironment] = []

        for hp in healthProjects {
            let project = APMProject(
                id: hp.name, name: hp.name, projectRoot: nil,
                sessionCount: hp.sessionCount, lastActivity: nil, status: hp.status
            )
            let drift = await driftDetector.detectDrift(for: project)
            updatedEnvironments.append(APMEnvironment(
                id: hp.name, project: project,
                driftStatus: drift, agentCount: hp.agentCount
            ))
        }

        environments = updatedEnvironments.sorted {
            ($0.sessionCount, $0.name) > ($1.sessionCount, $1.name)
        }
        lastRefresh = Date()
        lastError = nil

        // Fetch UPM status (best-effort)
        do {
            upmStatus = try await client.fetchUPMStatus()
        } catch {
            upmStatus = nil
        }
    }

    func openDashboard() {
        guard let url = URL(string: "http://localhost:3031") else { return }
        NSWorkspace.shared.open(url)
    }
}
```

### ConnectionState

```swift
enum ConnectionState: Equatable {
    case connected
    case disconnected
    case connecting

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        }
    }
}
```

### EnvironmentFilter

```swift
enum EnvironmentFilter: String, CaseIterable {
    case all = "All"
    case active = "Active"
}
```

### MenuBarView

The main UI component using `@Bindable` for two-way binding with the `@Observable` monitor.

```swift
struct MenuBarView: View {
    @Bindable var monitor: EnvironmentMonitor
    @Bindable var launchManager: LaunchManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection       // Connection state, project/active counts, UPM bar
            Divider()
            contentSection      // Filter picker + environment list or disconnected view
            Divider()
            refreshLabel        // "Updated X ago"
            actionsSection      // Open Dashboard, Help, Refresh, Launch at Login, Quit
        }
        .frame(width: 340)
    }
}
```

**Header section** shows:
- "CCEM APM" title with `StatusIndicator` and connection label
- Project count and active count badges
- UPM wave progress bar and story completion when UPM is active

**Content section** shows:
- Segmented picker for All/Active filter (with active count in label)
- Scrollable list of `EnvironmentRow` components (max height 300)
- Disconnected view with error message when server unreachable

**Actions section** shows:
- Open Dashboard (opens browser to localhost:3031)
- Help & Docs (opens /docs)
- Refresh button (triggers async refresh)
- Launch at Login toggle (via LaunchManager)
- Quit button

### Model Types

#### HealthStatus

```swift
struct HealthStatus: Codable {
    let status: String?
    let uptime: Double?
    let serverVersion: String?       // "server_version"
    let totalProjects: Int?          // "total_projects"
    let activeProject: String?       // "active_project"
    let projects: [HealthProject]?

    var isHealthy: Bool {
        status?.lowercased() == "ok" || status?.lowercased() == "healthy"
    }
}
```

#### HealthProject

```swift
struct HealthProject: Codable, Identifiable {
    let name: String
    let status: String
    let sessionCount: Int            // "session_count"
    let agentCount: Int              // "agent_count"

    var id: String { name }
    var isActive: Bool { sessionCount > 0 }
}
```

#### UPMStatus

```swift
struct UPMStatus: Codable {
    let active: Bool
    let session: UPMSession?
    let events: [UPMEvent]?
}
```

#### UPMSession

```swift
struct UPMSession: Codable {
    let id: String
    let status: String
    let currentWave: Int             // "current_wave"
    let totalWaves: Int              // "total_waves"
    let stories: [UPMStory]?
}
```

#### UPMStory

```swift
struct UPMStory: Codable, Identifiable {
    let id: String
    let title: String?
    let status: String
    let agentId: String?             // "agent_id"
}
```

#### UPMEvent

```swift
struct UPMEvent: Codable, Identifiable {
    let id: Int
    let eventType: String            // "event_type"
    let timestamp: String?
}
```

#### APMProject

```swift
struct APMProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let projectRoot: String?         // "project_root"
    let sessionCount: Int?           // "session_count"
    let lastActivity: Date?          // "last_activity"
    let status: String?
}
```

#### APMEnvironment

```swift
struct APMEnvironment: Identifiable, Hashable {
    let id: String
    let project: APMProject
    var driftStatus: DriftStatus
    var agentCount: Int = 0

    var name: String { project.name }
    var sessionCount: Int { project.sessionCount ?? 0 }
    var lastActivity: Date? { project.lastActivity }
    var isActive: Bool { sessionCount > 0 }
}
```

#### DriftStatus

```swift
enum DriftStatus: Hashable {
    case clean
    case drifted(String)
    case unknown
}
```

## Polling Architecture

The menubar app uses a structured concurrency polling approach:

1. **Polling Interval**: 10 seconds (configurable via `pollInterval`)
2. **Health Check**: `GET /health` to verify connection and get project summaries
3. **Environment Building**: Constructs `APMEnvironment` list from health response projects
4. **Drift Detection**: Per-project drift detection via `DriftDetector`
5. **UPM Status**: Best-effort `GET /api/upm/status` fetch
6. **Error Handling**: Graceful degradation -- shows disconnected view with error message

## Features

### Status Indicator

Shows connection state with the `StatusIndicator` component:
- Green pulse: Connected and healthy
- Red: Disconnected or error
- Yellow pulse: Connecting

### Environment List

Displays all projects with:
- Project name and status
- Session count and agent count
- Drift detection status
- Sorted by session count (active first), then alphabetically

### Filter Picker

Segmented control to switch between:
- **All**: Show all environments
- **Active**: Show only environments with active sessions (count shown in label)

### UPM Status Bar

When UPM is active, shows:
- Wave progress (e.g., "UPM Wave 2/4")
- Session status with color coding (running=blue, verifying=orange, verified/shipped=green)
- Story progress bar and completion count

### Quick Actions

- **Open Dashboard**: Opens web dashboard at `http://localhost:3031`
- **Help & Docs**: Opens documentation at `http://localhost:3031/docs`
- **Refresh**: Manual async refresh
- **Launch at Login**: Toggle via `LaunchManager` using `ServiceManagement`
- **Quit**: Terminates the app

## Building and Deployment

### Build with Swift Package Manager

```bash
cd /Users/jeremiah/Developer/ccem/CCEMAgent
swift build -c release
```

### Build from Xcode

```bash
open CCEMAgent.xcodeproj
# Build and run with Cmd+R
```

### Install as App

```bash
cp -r .build/Release/CCEMAgent.app /Applications/
```

## Troubleshooting

### Menubar app not connecting
1. Verify APM server running on port 3031
2. Check network connectivity: `curl http://localhost:3031/health`
3. Review CCEMAgent logs in Console.app

### Environment list not updating
1. Check polling interval (default 10 seconds)
2. Verify projects are configured in `apm_config.json`
3. Try manual refresh button

### App crashes on launch
1. Check system console logs
2. Verify Swift runtime is installed
3. Try running from Xcode debugger

## Performance

- **Memory**: ~50MB baseline
- **CPU**: <5% at rest, <15% during refresh
- **Network**: 2-3 HTTP requests every 10 seconds
- **Battery**: Minimal impact due to infrequent updates

Adjust polling interval to reduce resource usage:

```swift
private let pollInterval: TimeInterval = 30  // Slower polling for battery life
```

## Security

- Communicates only with local APM server (localhost:3031)
- No credential storage in app
- API key authentication supported if APM requires it

## Integration with Claude Code

When Claude Code session starts, CCEMAgent automatically:

1. Detects session via health check polling (projects show updated session counts)
2. Displays active environments for current session
3. Shows UPM progress when a UPM session is active

The CCEM APM `SessionStart` hook at `~/Developer/ccem/apm/hooks/session_init.sh` updates the APM config, which the server picks up and reflects in the health endpoint that CCEMAgent polls.

See [Getting Started](../user/getting-started.md) for session integration.
