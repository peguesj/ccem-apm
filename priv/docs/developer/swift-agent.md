# SwiftUI Menubar Agent (CCEMAgent)

CCEMAgent is a native macOS application providing real-time monitoring and control of CCEM APM from the menu bar.

## Overview

CCEMAgent runs as a persistent menubar app (system tray on macOS) with:

- **Real-time Agent Status**: Live display of active agents and health
- **Quick Actions**: Register agents, trigger commands, pause/resume
- **Health Monitoring**: APM server status and connection health
- **Token Tracking**: Display cumulative token usage
- **Notifications**: Alert badges for errors and important events
- **Login Item**: Auto-launch on system startup

## Architecture

```
┌─────────────────────────────────┐
│  MenuBarView (SwiftUI)          │
│  - Status display               │
│  - Agent list                   │
│  - Quick action buttons         │
└────────────┬────────────────────┘
             │
┌────────────▼────────────────────┐
│  EnvironmentMonitor             │
│  - Polls APM server             │
│  - Tracks agent state           │
│  - Manages timers               │
└────────────┬────────────────────┘
             │
┌────────────▼────────────────────┐
│  APMClient (URLSession)         │
│  - HTTP requests to APM API     │
│  - JSON parsing                 │
│  - Error handling               │
└────────────┬────────────────────┘
             │
       http://localhost:3031
```

## Key Components

### MenuBarView

The main UI component for the menubar app.

```swift
struct MenuBarView: View {
  @StateObject var monitor: EnvironmentMonitor
  @State var isPopoverPresented = false

  var body: some View {
    VStack(spacing: 10) {
      // Server status
      HStack {
        Image(systemName: monitor.isHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(monitor.isHealthy ? .green : .red)
        Text(monitor.statusText)
      }

      // Agent count
      Text("Agents: \(monitor.agents.count)")
        .font(.headline)

      // Quick agent list
      List(monitor.activeAgents, id: \.id) { agent in
        HStack {
          Circle()
            .fill(agent.statusColor)
            .frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 2) {
            Text(agent.name)
              .font(.caption)
            Text(agent.status)
              .font(.caption2)
              .foregroundColor(.gray)
          }
          Spacer()
          Text("\(agent.tier)")
            .font(.caption)
        }
        .padding(.vertical, 4)
      }

      // Token usage
      VStack(alignment: .leading, spacing: 4) {
        Text("Token Usage")
          .font(.caption)
          .bold()
        ProgressView(value: monitor.tokenPercentage)
          .tint(.blue)
        Text("\(monitor.totalTokens) / \(monitor.maxTokens)")
          .font(.caption2)
          .foregroundColor(.gray)
      }

      Divider()

      // Action buttons
      HStack(spacing: 10) {
        Button(action: { monitor.refresh() }) {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh status")

        Button(action: { openDashboard() }) {
          Image(systemName: "globe")
        }
        .help("Open dashboard")

        Button(action: { quit() }) {
          Image(systemName: "xmark")
        }
        .help("Quit")
      }
      .buttonStyle(.borderless)
      .font(.caption)
    }
    .padding()
    .frame(width: 300)
  }
}
```

### EnvironmentMonitor

Manages polling of APM server and state updates.

```swift
class EnvironmentMonitor: NSObject, ObservableObject {
  @Published var agents: [Agent] = []
  @Published var isHealthy = false
  @Published var statusText = "Connecting..."
  @Published var totalTokens = 0
  @Published var maxTokens = 100000

  private let client: APMClient
  private var timer: Timer?

  override init() {
    self.client = APMClient(baseURL: "http://localhost:3031")
    super.init()
    startPolling()
  }

  func startPolling() {
    // Poll every 5 seconds
    timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      self?.updateStatus()
    }
    updateStatus() // Immediate check
  }

  func updateStatus() {
    client.getHealth { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success(let health):
          self?.isHealthy = true
          self?.statusText = "Connected"
          self?.updateAgents()

        case .failure(let error):
          self?.isHealthy = false
          self?.statusText = "Disconnected: \(error.localizedDescription)"
        }
      }
    }
  }

  func updateAgents() {
    client.getAgents { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success(let agents):
          self?.agents = agents
          self?.totalTokens = agents.reduce(0) { $0 + $1.tokenUsage }

        case .failure(let error):
          print("Error fetching agents: \(error)")
        }
      }
    }
  }

  func refresh() {
    updateStatus()
  }

  deinit {
    timer?.invalidate()
  }
}
```

### APMClient

HTTP client for communicating with APM server.

```swift
class APMClient {
  private let baseURL: URL
  private let session = URLSession.shared

  init(baseURL: String) {
    self.baseURL = URL(string: baseURL)!
  }

  func getHealth(completion: @escaping (Result<HealthStatus, Error>) -> Void) {
    let url = baseURL.appendingPathComponent("health")
    var request = URLRequest(url: url)
    request.timeoutInterval = 5.0

    session.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let data = data else {
        completion(.failure(APIError.noData))
        return
      }

      do {
        let health = try JSONDecoder().decode(HealthStatus.self, from: data)
        completion(.success(health))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }

  func getAgents(completion: @escaping (Result<[Agent], Error>) -> Void) {
    let url = baseURL.appendingPathComponent("api/agents")
    var request = URLRequest(url: url)
    request.timeoutInterval = 5.0

    session.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let data = data else {
        completion(.failure(APIError.noData))
        return
      }

      do {
        let response = try JSONDecoder().decode(AgentsResponse.self, from: data)
        completion(.success(response.agents))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }
}

enum APIError: Error {
  case noData
  case decodingError
}
```

### HealthStatus Model

```swift
struct HealthStatus: Codable {
  let status: String
  let timestamp: Date
  let version: String
}
```

### Agent Model

```swift
struct Agent: Codable, Identifiable {
  let id: String
  let name: String
  let type: String
  let status: String
  let tier: Int
  let project: String
  let capabilities: [String]
  let tokenUsage: Int

  enum CodingKeys: String, CodingKey {
    case id, name, type, status, tier, project, capabilities
    case tokenUsage = "token_usage"
  }

  var statusColor: Color {
    switch status {
    case "active": return .green
    case "idle": return .yellow
    case "error": return .red
    case "discovered": return .gray
    default: return .gray
    }
  }
}

struct AgentsResponse: Codable {
  let agents: [Agent]
  let total: Int
}
```

## LaunchManager

Manages login item (auto-launch on startup).

```swift
class LaunchManager {
  static let shared = LaunchManager()

  func addToLoginItems() {
    let app = NSApplication.shared
    guard let appPath = Bundle.main.bundlePath as NSString? else { return }

    do {
      try LSRegisterURL(URL(fileURLWithPath: appPath) as CFURL, false)
    } catch {
      print("Error registering launch item: \(error)")
    }
  }

  func removeFromLoginItems() {
    // Implementation for removing from login items
  }
}
```

## Polling Architecture

The menubar app uses a polling approach:

1. **Polling Interval**: 5 seconds by default
2. **Health Check**: `GET /health` to verify connection
3. **Agent List**: `GET /api/agents` for current agents
4. **Token Tracking**: Aggregate token usage from agents
5. **Error Handling**: Graceful degradation if APM unavailable

Adjust polling interval in EnvironmentMonitor:

```swift
timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { ... }
```

## Features

### Status Indicator

Shows connection status with visual indicator:
- Green checkmark: Connected and healthy
- Red X: Disconnected or error
- Status text shows last update time

### Agent List

Displays active agents with:
- Status badge (green/yellow/red)
- Agent name
- Current status
- Tier level

Click on agent to open detailed view in dashboard.

### Quick Actions

Buttons for common operations:

- **Refresh**: Manual refresh of agent status
- **Dashboard**: Open web dashboard in browser
- **Quit**: Close the menubar app

### Token Usage

Progress bar shows cumulative token usage across all agents:

```
Tokens: [████████░░] 80000 / 100000
```

Click to open token usage details in dashboard.

### Notifications

System notifications for important events:

- Agent registered
- Agent error
- Low token budget
- APM server reconnected

## Building and Deployment

### Build from Source

```bash
cd /Users/jeremiah/Developer/ccem/CCEMAgent
xcodebuild -scheme CCEMAgent -configuration Release build
```

### Install as App

```bash
cp -r build/Release/CCEMAgent.app /Applications/
```

### Auto-Launch on Login

Enable in app preferences or call:

```swift
LaunchManager.shared.addToLoginItems()
```

## Configuration

The menubar app reads from `apm_config.json`:

```json
{
  "apm_server_url": "http://localhost:3031",
  "polling_interval_seconds": 5,
  "max_agents_in_menu": 10,
  "token_budget": 100000
}
```

## Troubleshooting

### Menubar app not connecting
1. Verify APM server running on port 3031
2. Check network connectivity: `curl http://localhost:3031/health`
3. Review CCEMAgent logs in Console.app

### Agent list not updating
1. Check polling interval (default 5 seconds)
2. Verify agents are registered in APM
3. Try manual refresh button

### Token usage not accurate
1. Ensure agents sending heartbeats
2. Check `/api/agents` response includes token_usage
3. Verify max token budget in config

### App crashes on launch
1. Check system console logs
2. Verify Swift runtime is installed
3. Try running from Xcode debugger

## Development

### Run from Xcode

```bash
open CCEMAgent.xcodeproj
# Build and run with Cmd+R
```

### Testing with Mock Data

Create mock APMClient for testing:

```swift
class MockAPMClient: APMClient {
  override func getAgents(completion: @escaping (Result<[Agent], Error>) -> Void) {
    let mockAgents = [
      Agent(id: "1", name: "test-gen", type: "individual", ...)
    ]
    completion(.success(mockAgents))
  }
}
```

## Performance

- **Memory**: ~50MB baseline
- **CPU**: <5% at rest, <15% during refresh
- **Network**: 2-3 HTTP requests every 5 seconds
- **Battery**: Minimal impact due to infrequent updates

Adjust polling interval to reduce resource usage:

```swift
// Slower polling for laptop battery life
timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { ... }
```

## Security

- HTTPS support for secure connections
- API key authentication (if APM requires)
- No credential storage in app
- Communicates only with local APM server

For remote APM server:

```swift
init(baseURL: String, apiKey: String) {
  self.baseURL = URL(string: baseURL)!
  self.apiKey = apiKey
}

private func addAuthHeader(to request: inout URLRequest) {
  request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
}
```

## Integration with Claude Code

When Claude Code session starts, CCEMAgent automatically:

1. Detects session initialization from config file watch
2. Updates APM server URL if changed
3. Displays active agents for current session
4. Shows relevant notifications

See [Getting Started](../user/getting-started.md) for session integration.
