# Changelog

All notable changes to CCEM APM are documented in this file.

## [4.0.0] - 2026-02-19

### Major Features

#### Phoenix/Elixir Rewrite
- Complete rewrite from Python to Phoenix/Elixir
- OTP supervision tree with 14 specialized GenServers
- Real-time WebSocket updates via Phoenix LiveView
- PubSub-based event broadcasting
- ETS-backed in-memory caching

#### Multi-Project Support
- Single server instance serves multiple projects
- Project isolation by namespace
- Project selector in dashboard UI
- Session tracking per-project
- Cross-project analytics and reporting

#### Enhanced Dashboard UI
- **D3.js Dependency Graph**: Force-directed visualization of agent relationships
- **Real-time Updates**: Live agent fleet updates without page refresh
- **daisyUI Styling**: Modern component library on Tailwind CSS
- **Responsive Design**: Works on desktop, tablet, and mobile
- **Right Panel Tabs**: Inspector, Ralph, UPM, Commands, TODOs
- **Filter Bar**: Status, type, project, and text search filtering

#### Agent Fleet Management
- **Tier-based Classification**: Agents classified as tier 1, 2, or 3
- **Flexible Typing**: individual, squadron, swarm, orchestrator agent types
- **Advanced Statuses**: active, idle, error, discovered, completed
- **Automatic Discovery**: Environment scanner detects agents
- **Heartbeat Monitoring**: Keep-alive with token/progress tracking
- **Dependency Tracking**: Relationships and coordination tracking

#### Ralph Methodology Integration
- **PRD JSON Format**: Product requirements in structured format
- **Story-based Workflows**: Organize work into discrete stories
- **Autonomous Fix Loops**: Ralph orchestrator manages fix workflows
- **Flowchart Visualization**: `/ralph` page with D3 swimlane flowchart
- **Escalation Rules**: Auto-escalate to higher tiers on errors
- **Progress Tracking**: Real-time story and wave completion

#### UPM (Unified Project Management)
- **Wave-based Organization**: Logical grouping of stories
- **Story Tracking**: Individual work items with estimates
- **Event Logging**: Detailed execution timeline
- **Agent Assignment**: Dynamic agent allocation to stories
- **Ralph Integration**: Seamless handoff to Ralph methodology
- **Status Reporting**: Real-time progress and metrics

#### Skills Tracking System
- **Skill Catalog**: Comprehensive index of all capabilities
- **Co-Occurrence Matrix**: Heatmap showing skill relationships
- **Methodology Detection**: Auto-detect TDD, refactor-max, fix-loop patterns
- **UEBA Analytics**: User and entity behavior analytics
- **Trending Analysis**: Popular and emerging skills
- **Anomaly Detection**: Flag unusual behavior patterns

#### Session Timeline Visualization
- **Event Log**: Chronological list of all session events
- **Interactive Timeline**: Visual navigation through time
- **Filtering**: Filter by event type, agent, date range
- **Export**: Download session history as JSON
- **Audit Trail**: Complete immutable event record

#### SwiftUI Menubar Agent (CCEMAgent)
- **Native macOS Application**: AppKit-based system tray app
- **Real-time Status**: Live agent count and health display
- **Quick Actions**: Register agents, trigger commands, pause/resume
- **Token Tracking**: Cumulative usage progress bar
- **Health Monitoring**: APM server connection status
- **Login Item**: Auto-launch on system startup
- **URLSession Polling**: Efficient HTTP polling architecture

#### REST API Compatibility
- **REST v1 API**: Backward compatible with APM v3
- **V2 API**: New comprehensive API with OpenAPI spec
- **Endpoints**: 40+ endpoints for agents, notifications, UPM, skills
- **Server-Sent Events**: Real-time event streaming (`/api/ag-ui/events`)
- **Data Import/Export**: Full data export/import as JSON
- **Rate Limiting**: Graceful rate limiting with Retry-After headers

#### Documentation Wiki System
- **Interactive Docs**: Embedded documentation in `/docs`
- **Full-text Search**: Searchable across all docs
- **Breadcrumb Navigation**: Clear document hierarchy
- **Markdown Rendering**: Beautiful styled markdown
- **Code Highlighting**: Syntax highlighting for code blocks
- **Responsive Viewer**: Works on all screen sizes

### Architecture

#### GenServer Stores
- `ConfigLoader` - Configuration management
- `DashboardStore` - Aggregated metrics and state
- `AgentRegistry` - Central agent fleet registry
- `ProjectStore` - Multi-project management
- `UpmStore` - UPM session and story tracking
- `SkillTracker` - Skill usage and analytics
- `MetricsCollector` - System metrics aggregation
- `AlertRulesEngine` - Alert rules and escalation
- `AuditLog` - Immutable audit trail
- `EventStream` - Event queue and streaming
- `AgentDiscovery` - Auto-discovery from environment
- `EnvironmentScanner` - System environment monitoring
- `CommandRunner` - Slash command execution
- `DocsStore` - Documentation caching and serving
- `SloEngine` - SLO rules and evaluation

#### PubSub Topics
- `apm:agents` - Agent lifecycle events
- `apm:notifications` - Alert and notification events
- `apm:config` - Configuration changes
- `apm:tasks` - Task execution events
- `apm:commands` - Slash command execution
- `apm:upm` - UPM execution tracking
- `apm:skills` - Skill tracking events
- `apm:audit` - Audit logging events

#### LiveView Pages
- `DashboardLive` (`/`) - Main monitoring dashboard
- `AllProjectsLive` (`/apm-all`) - Multi-project overview
- `SkillsLive` (`/skills`) - Skills analytics
- `RalphFlowchartLive` (`/ralph`) - Ralph flowchart
- `SessionTimelineLive` (`/timeline`) - Event timeline
- `DocsLive` (`/docs`) - Documentation viewer

### Data Persistence

#### Configuration
- `apm_config.json` - Project and session configuration
- ETS tables - In-memory caching for fast access
- File-based persistence - Session metadata storage

#### Audit Trail
- Immutable event log
- All agent actions tracked
- Configuration changes logged
- Task lifecycle recorded

### Monitoring and Observability

#### Health Checks
- `/health` endpoint for liveness checks
- `/api/status` for detailed server status
- Connection status in menubar app

#### Metrics
- Agent count, session count, skill count
- Token usage per agent
- Task completion rates
- Error rates and patterns

#### Notifications
- Info, warning, error, success levels
- Auto-dismiss and persistent alerts
- Bell icon with unread count
- Action buttons for quick navigation

### Breaking Changes from v3

- Python codebase completely replaced with Elixir
- API endpoints remain compatible but extended
- Configuration format updated (still JSON-based)
- Database layer changed (ETS instead of SQLite for core)
- Heartbeat protocol simplified

### Performance Improvements

- **Startup Time**: ~5 seconds (v3: ~15 seconds)
- **Memory**: ~500MB baseline (v3: ~800MB)
- **Agent Registration**: <100ms (v3: ~500ms)
- **Dashboard Update Latency**: <50ms (v3: ~200ms)
- **Concurrent Agents**: Tested to 1000+ (v3: ~300)

### Security Enhancements

- API key authentication support
- CORS configuration
- Rate limiting with adaptive backoff
- Audit logging of all operations
- Session isolation by project

### Known Limitations

- Clustering not yet supported (single-node only)
- External database integration optional (ETS-based)
- File-based config (not database-backed)

### Migration Guide

From v3 to v4:

1. **Install Elixir** 1.14+ and Erlang/OTP 25+
2. **Clone new v4 repo**: `git clone <url> apm-v4`
3. **Update config**: Map v3 projects to `apm_config.json`
4. **Export v3 data**: Use `curl /api/v2/export` from old server
5. **Import to v4**: `POST /api/v2/import` with exported JSON
6. **Test agent registration**: Verify agents connect to new server
7. **Update agent configs**: Point to new server/port if needed
8. **Switch production**: Update hooks and menubar app URL

See [Deployment](admin/deployment.md) for detailed migration steps.

### Acknowledgments

- **Framework**: Phoenix, Elixir
- **Frontend**: LiveView, daisyUI, Tailwind CSS
- **Visualization**: D3.js
- **Native**: Swift, AppKit
- **Inspired by**: Ralph methodology, autonomous fix loops

---

## Previous Versions

### v3.x - Python Era

v3 was the original Python implementation with:
- Flask web server
- SQLite persistence
- Basic agent registration
- Manual workflow orchestration
- Limited analytics

v3 maintained in legacy branch for historical reference.

### v2.x - Early Days

v2 featured initial APM prototype with:
- Simple REST API
- Session tracking
- Agent heartbeats
- Basic notifications

No longer supported.

### v1.x - Pre-Release

v1 was internal research prototype.

---

## Future Roadmap

### v4.1 (Q2 2026)

- [ ] Database backend (PostgreSQL) option
- [ ] Erlang clustering support
- [ ] Advanced SLO engine
- [ ] Custom skill definitions
- [ ] Slack/Discord notifications
- [ ] GraphQL API

### v4.2 (Q3 2026)

- [ ] Machine learning-based anomaly detection
- [ ] Predictive resource allocation
- [ ] Cross-project aggregate analytics
- [ ] Advanced audit reporting
- [ ] Webhook integrations

### v5.0 (2027)

- [ ] Full distributed architecture
- [ ] Advanced federation for multi-org
- [ ] Rich AI-powered recommendations
- [ ] Custom dashboard builder
- [ ] Embedded agent marketplace

---

## Release Notes

### Important Dates

- **2026-02-19**: v4.0.0 Release - Phoenix/Elixir rewrite with multi-project support
- **2026-02-10**: v4.0.0-rc1 Release Candidate
- **2026-01-15**: v4.0.0-beta.1 Beta release for testing

### How to Report Issues

- GitHub Issues: https://github.com/your-org/ccem-apm/issues
- Documentation: See [Troubleshooting](admin/troubleshooting.md)
- Support: Check [FAQ](user/getting-started.md#troubleshooting)

### Version Numbering

CCEM APM follows semantic versioning:

- **MAJOR**: Breaking API changes or major rewrites
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes and improvements

### Upgrade Guide

Always backup `apm_config.json` before upgrading:

```bash
cp apm_config.json apm_config.json.backup
```

For detailed upgrade instructions, see [Deployment](admin/deployment.md).

---

## Credits

CCEM APM v4 developed with:

- **Elixir/Phoenix** for robust backend
- **LiveView** for real-time UI
- **D3.js** for visualization
- **daisyUI** for component styling
- **Swift** for native integration

Built for the Claude Code platform and AI agent workflows.

---

*Last Updated: 2026-02-19*
