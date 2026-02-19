# Skills Tracking and Analytics

The CCEM APM skills system tracks which capabilities agents use, detects patterns, identifies emerging trends, and provides analytics via UEBA (User and Entity Behavior Analytics).

## Overview

Skills tracking provides:

- **Skill Catalog**: Comprehensive index of all skills used across agents
- **Co-Occurrence Matrix**: Understand which skills are used together
- **Methodology Detection**: Identify active methodologies (TDD, refactor-max, etc.)
- **UEBA Analytics**: Behavioral anomalies and patterns
- **Trending**: Popular and emerging skills

## Skills Dashboard

Navigate to `/skills` in the sidebar for the skills analytics page:

### Skill Catalog

Top section displays all skills:

```
Skill                 Count    Popularity    Last Used
code-review           124      ████████░░    5 mins ago
test-writing          98       ███████░░░    2 mins ago
refactoring           87       ██████░░░░    10 mins ago
analysis              76       █████░░░░░    3 mins ago
documentation         54       ███░░░░░░░    1 hour ago
bug-fixing            42       ██░░░░░░░░    2 hours ago
optimization          38       ██░░░░░░░░    5 hours ago
```

Click a skill to filter agents and see who has it.

### Co-Occurrence Matrix

Visual heatmap showing which skills are used together:

```
                code-review  test-writing  refactoring
code-review          1.0         0.85         0.72
test-writing         0.85        1.0          0.68
refactoring          0.72        0.68         1.0
analysis             0.65        0.71         0.79
```

Strong co-occurrence (> 0.7) indicates:
- Agents frequently work together
- Complementary skill sets
- Common workflow patterns

## Skill Tracking API

### POST /api/skills/track

Log a skill usage event:

```bash
curl -X POST http://localhost:3031/api/skills/track \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "agent-xyz789",
    "skill": "test-writing",
    "project": "ccem",
    "context": {
      "file": "src/test/unit.swift",
      "language": "swift",
      "test_framework": "XCTest",
      "tests_generated": 5
    }
  }'
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| **agent_id** | string | Agent performing the skill |
| **skill** | string | Skill identifier |
| **project** | string | Project namespace |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| **context** | object | Custom metadata about usage |
| **tokens_consumed** | integer | Tokens used for this skill |
| **success** | boolean | Skill usage successful (default: true) |

## Common Skills

Standard skill identifiers:

### Code Skills
- `code-review` - Peer code review
- `code-writing` - Writing new code
- `code-generation` - Generating code from specs
- `refactoring` - Code transformation
- `bug-fixing` - Error diagnosis and fixes
- `optimization` - Performance improvement

### Testing Skills
- `test-writing` - Creating test cases
- `test-execution` - Running tests
- `mock-generation` - Mock/stub creation
- `property-testing` - Property-based tests
- `performance-testing` - Load and stress testing

### Documentation Skills
- `documentation` - Writing docs
- `api-documentation` - OpenAPI/Swagger
- `readme-writing` - README creation
- `comment-generation` - Code comments

### Architectural Skills
- `architecture-design` - System design
- `database-design` - Schema design
- `api-design` - REST/GraphQL design

### Analysis Skills
- `analysis` - General code analysis
- `security-audit` - Security review
- `complexity-analysis` - Big-O analysis
- `dependency-analysis` - Library analysis

### DevOps Skills
- `deployment` - Release management
- `ci-cd-setup` - Pipeline configuration
- `docker-setup` - Containerization
- `monitoring-setup` - Observability config

Custom skills can be added by using descriptive identifiers like `custom-skill-name`.

## Methodology Detection

The system automatically detects active methodologies based on skill patterns:

### TDD (Test-Driven Development)
Detected when skills appear in sequence:
1. `test-writing`
2. `code-writing`
3. `refactoring`

Example detection:

```json
{
  "methodology": "tdd",
  "confidence": 0.92,
  "agents": ["test-gen", "code-writer", "refactorer"],
  "active_since": "2026-02-19T10:00:00Z",
  "events_count": 45
}
```

### Refactor-Max
Detected by high frequency of `refactoring` + `optimization`:

```json
{
  "methodology": "refactor-max",
  "confidence": 0.88,
  "agents": ["refactor-squad"],
  "active_since": "2026-02-19T11:30:00Z",
  "events_count": 23
}
```

### Fix Loop
Detected by `bug-fixing` → `test-writing` → `code-writing` pattern:

```json
{
  "methodology": "fix-loop",
  "confidence": 0.95,
  "agents": ["orchestrator", "fixer", "tester"],
  "active_since": "2026-02-19T12:00:00Z",
  "events_count": 67
}
```

Detected methodologies appear in the Methodology section of the skills page.

## UEBA Analytics

User and Entity Behavior Analytics detect anomalies and patterns:

### Anomalies

Unusual behaviors flagged:

```
High Token Spike
Agent: analyzer
Skill: analysis
Time: 2026-02-19T12:34:56Z
Normal: 2000 tokens/event
Observed: 45000 tokens
Status: Investigate
```

### Patterns

Recurring patterns identified:

```
Agent Collaboration Pattern
Agents: [test-gen, reviewer, merger]
Frequency: Every 2 hours
Skills: [test-writing, code-review, ci-cd-setup]
Pattern Type: Sequential workflow
Confidence: 89%
```

### Trending Skills

Skills increasing in usage:

```
test-writing     ↑ 34% week-over-week
refactoring      ↑ 22% week-over-week
documentation    ↓ -8% week-over-week
```

## Skill Statistics

### GET /api/skills

Get all skills and statistics:

```bash
curl http://localhost:3031/api/skills
```

Response:

```json
{
  "skills": [
    {
      "skill": "code-review",
      "count": 124,
      "agents": 8,
      "last_used": "2026-02-19T12:34:56Z",
      "avg_tokens_per_event": 1200,
      "success_rate": 0.98
    }
  ],
  "co_occurrence_matrix": { ... },
  "detected_methodologies": [ ... ],
  "anomalies": [ ... ]
}
```

## Best Practices

1. **Granular Skills**: Use specific skill names (not just "coding")
2. **Consistent Naming**: Use lowercase with hyphens (e.g., `test-writing`)
3. **Context Rich**: Include metadata to understand usage patterns
4. **Regular Tracking**: Log skills as they're used, not retrospectively
5. **Success Tracking**: Mark successful/failed skill usage
6. **Tokens Logged**: Include token consumption for cost analysis

## Troubleshooting

**Skills not appearing on dashboard?**
- Verify POST /api/skills/track succeeded
- Check agent_id exists and is active
- Refresh page (Cmd+R)

**Co-occurrence matrix not showing?**
- Ensure multiple skill events logged
- Wait 1-2 minutes for calculation
- Check browser console for JS errors

**Methodology not detected?**
- Verify correct skill sequence is logged
- Check skill names match standard identifiers
- Ensure sufficient event count (minimum 10 events)

**Anomalies not flagging?**
- Review threshold settings in config
- Check token usage is being logged
- Verify enough historical data exists

See [API Reference](../developer/api-reference.md) for complete skills endpoints.
