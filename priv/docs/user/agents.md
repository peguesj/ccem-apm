# Agent Fleet Management

The CCEM APM agent fleet system enables real-time monitoring, classification, and orchestration of Claude Code AI agents.

## Agent Types

Agents are classified into four distinct types:

### Individual
Single autonomous agent operating independently.
- Tier 1-3 capable
- Handles one primary task
- Example: `code-analyzer`, `test-generator`

### Squadron
Group of individual agents working toward a common goal.
- Tier 2-3
- Coordinated by an orchestrator
- Example: `tdd-squadron` (test + code + review agents)

### Swarm
Large coordinated group with peer-to-peer communication.
- Tier 3 only
- Self-organizing
- Example: `parallel-refactor-swarm`

### Orchestrator
Manages coordination of other agents (squadrons, swarms).
- Tier 3 only
- Routes tasks, aggregates results
- Example: `fix-loop-orchestrator`

## Agent Tiers

Tiers classify agent sophistication and responsibility:

| Tier | Level | Characteristics | Examples |
|------|-------|-----------------|----------|
| **1** | Entry | Single-task, basic analysis | syntax checker, formatter |
| **2** | Intermediate | Multi-step workflows, decision making | test generator, code analyzer |
| **3** | Expert | Complex orchestration, swarm management | orchestrator, advanced refactorer |

## Agent Statuses

An agent can be in one of five states:

| Status | Meaning | Action |
|--------|---------|--------|
| **active** | Running task, sending heartbeats | Normal operation |
| **idle** | Registered but no current task | Waiting for work |
| **error** | Encountered problem, stopped | Requires intervention |
| **discovered** | Auto-detected, not yet registered | Review before adoption |
| **completed** | Task finished, agent archived | Historical record |

## Agent Registration

### POST /api/register

Register a new agent:

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-generator",
    "type": "individual",
    "project": "ccem",
    "tier": 2,
    "capabilities": ["test-writing", "mock-generation"],
    "metadata": {
      "language": "swift",
      "framework": "XCTest"
    }
  }'
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| **name** | string | Unique agent identifier |
| **type** | string | individual, squadron, swarm, or orchestrator |
| **project** | string | Project namespace |
| **tier** | integer | 1, 2, or 3 |
| **capabilities** | array | Skills this agent provides |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| **metadata** | object | Custom JSON metadata |
| **namespace** | string | Session-specific namespace |

### Response

```json
{
  "id": "agent-uuid-1234",
  "name": "test-generator",
  "status": "active",
  "registered_at": "2026-02-19T12:00:00Z"
}
```

## Agent Heartbeats

Keep agents alive by sending periodic heartbeats:

### POST /api/heartbeat

```bash
curl -X POST http://localhost:3031/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-uuid-1234",
    "status": "active",
    "token_usage": 12500,
    "current_task": "Generating unit tests for AuthService",
    "progress": 75
  }'
```

**Recommended interval**: Every 10-30 seconds

If an agent doesn't heartbeat for 2 minutes, its status changes to `idle`. If no heartbeat for 10 minutes, it's marked `offline`.

## Agent Discovery

The system can automatically discover agents from process logs and environment variables.

### POST /api/agents/discover

```bash
curl -X POST http://localhost:3031/api/agents/discover \
  -H "Content-Type: application/json" \
  -d '{
    "project": "ccem"
  }'
```

Discovered agents appear with status `discovered`. Review and approve them for integration:

```bash
curl -X POST http://localhost:3031/api/agents/update \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "discovered-123",
    "status": "active"
  }'
```

## Namespaces

Agents within the same session can be further isolated using namespaces:

```bash
curl -X POST http://localhost:3031/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "analyzer",
    "type": "individual",
    "project": "ccem",
    "namespace": "session-abc123-wave-1",
    "tier": 2,
    "capabilities": ["analysis"]
  }'
```

Namespaces are useful for:
- Organizing agents by session
- Grouping agents by workflow wave
- Isolating feature-branch work

## Agent Fleet List

The dashboard displays all agents in a filterable table:

```
Name            Type        Status    Tier  Project   Updated
test-gen        individual  active    2     ccem      5 mins ago
refactor-squad  squadron    active    3     ccem      2 mins ago
analyzer        individual  idle      2     lcc       1 hour ago
fix-orch        orchestrator active   3     ccem      just now
```

### Filtering

- **Status Filter**: Show only agents with specific status
- **Type Filter**: Show only squadrons, individuals, etc.
- **Project Filter**: Show agents from specific project
- **Search**: Type agent name to narrow results

## Dependency Relationships

The D3 dependency graph shows agent relationships:

- **Arrows indicate** task dependencies or data flow
- **Thickness indicates** relationship strength
- **Distance indicates** collaboration frequency

Create dependencies via agent metadata:

```json
{
  "name": "reviewer",
  "type": "individual",
  "project": "ccem",
  "tier": 2,
  "capabilities": ["code-review"],
  "metadata": {
    "depends_on": ["test-generator", "formatter"]
  }
}
```

## Capabilities

Capabilities describe what an agent can do:

Common capabilities:
- `analysis` - Code analysis
- `code-review` - Peer review
- `refactoring` - Code transformation
- `test-writing` - Test generation
- `documentation` - Doc generation
- `debugging` - Error diagnosis
- `optimization` - Performance improvement
- `security-audit` - Security analysis

Register with multiple capabilities:

```json
{
  "capabilities": ["analysis", "refactoring", "optimization"]
}
```

Filter agents by capability in dashboard:

```bash
curl http://localhost:3031/api/agents?capability=refactoring
```

## Agent Metrics

Each agent tracks:

- **Token Usage**: Cumulative tokens consumed
- **Tasks Completed**: Number of successful tasks
- **Error Rate**: Percentage of failed tasks
- **Average Duration**: Mean time per task
- **Uptime**: Total active time since registration

View agent metrics:

```bash
curl http://localhost:3031/api/agents/agent-uuid-1234
```

Response includes:

```json
{
  "id": "agent-uuid-1234",
  "name": "test-generator",
  "status": "active",
  "tier": 2,
  "type": "individual",
  "metrics": {
    "token_usage": 45000,
    "tasks_completed": 23,
    "error_rate": 0.05,
    "avg_duration_ms": 2500,
    "uptime_seconds": 3600
  }
}
```

## Best Practices

1. **Unique Names**: Use descriptive, unique agent names
2. **Appropriate Tier**: Classify agents honestly by capability
3. **Regular Heartbeats**: Send heartbeats every 10-30 seconds
4. **Clear Capabilities**: List all relevant skills
5. **Metadata**: Include useful context in metadata
6. **Namespace Sessions**: Isolate session-specific agents
7. **Status Updates**: Update status when tasks change
8. **Monitor Health**: Check error rates and uptime regularly

## Troubleshooting

**Agent not appearing after registration?**
- Verify project name is in apm_config.json
- Check heartbeat is being sent
- Inspect browser console for WebSocket errors

**Agent stuck in error status?**
- Check the Error details in Inspector tab
- Send `/api/agents/{id}/reset` to clear error
- Review agent logs for root cause

**Dependency graph not showing relationships?**
- Verify metadata includes `depends_on` field
- Refresh dashboard (Cmd+R)
- Check agent heartbeats are being received

See [API Reference](../developer/api-reference.md) for complete endpoint documentation.
