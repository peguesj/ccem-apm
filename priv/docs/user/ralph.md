# Ralph Methodology

Ralph is CCEM APM's autonomous fix loop orchestration system. It manages complex workflows, story tracking, and adaptive resource allocation for multi-agent collaborative debugging and refactoring.

## Overview

Ralph enables:

- **Autonomous Fix Loops**: Agents automatically identify and resolve issues
- **Story-Based Workflows**: Organize work into discrete, trackable stories
- **Adaptive Resource Allocation**: Dynamically adjust agent teams based on problem complexity
- **Real-time Progress Tracking**: Monitor all active fixes in the dashboard
- **Flowchart Visualization**: Visual representation of fix workflow

## PRD Format

Ralph workflows are defined in `prd.json` (Product Requirements Document):

```json
{
  "project": "ccem",
  "version": "1.0.0",
  "objectives": [
    {
      "id": "obj-1",
      "title": "Implement multi-project support",
      "description": "Enable tracking across multiple codebases",
      "priority": "high"
    }
  ],
  "stories": [
    {
      "id": "story-1",
      "objective": "obj-1",
      "title": "Add project selector to dashboard",
      "description": "Allow users to switch between projects",
      "acceptance_criteria": [
        "Dropdown appears in top nav",
        "Project filtering works instantly",
        "Selection persists in local storage"
      ],
      "estimate_tokens": 5000,
      "assigned_tier": 2,
      "dependencies": [],
      "status": "not_started"
    }
  ],
  "ralph_config": {
    "autonomous_mode": true,
    "max_concurrent_agents": 5,
    "escalation_rules": [
      {
        "error_type": "compilation_error",
        "escalate_to_tier": 3
      }
    ]
  }
}
```

## Story Structure

Each story represents a unit of work:

| Field | Type | Description |
|-------|------|-------------|
| **id** | string | Unique identifier (story-N) |
| **objective** | string | Parent objective ID |
| **title** | string | Short name |
| **description** | string | Detailed requirements |
| **acceptance_criteria** | array | Definition of done |
| **estimate_tokens** | integer | Estimated token budget |
| **assigned_tier** | integer | Minimum agent tier required (1-3) |
| **dependencies** | array | Story IDs that must complete first |
| **status** | string | not_started, in_progress, blocked, completed |

## Autonomous Fix Loop

Ralph orchestrates the fix loop with minimal human intervention:

### Phase 1: Problem Analysis
1. Agent analyzes issue logs
2. Categorizes problem by type
3. Estimates scope and complexity
4. Determines minimum tier required

### Phase 2: Agent Assembly
1. Ralph queries available agents
2. Selects agents matching tier requirements
3. Organizes into squadron if needed
4. Briefs agents on objectives

### Phase 3: Execution
1. Agents work on assigned stories
2. Send heartbeats with progress
3. Ralph monitors for errors
4. Escalates to higher tiers if needed

### Phase 4: Verification
1. Test suite runs automatically
2. Acceptance criteria checked
3. Peer review by secondary agent
4. Story marked complete or blocked

### Phase 5: Iteration
1. Blocked stories moved to backlog
2. Dependencies resolved
3. Next wave of stories scheduled
4. Cycle repeats until all stories done

## Status Tracking

Stories progress through states:

```text
not_started → in_progress → (blocked) → completed
```

- **not_started**: Waiting for dependencies or resources
- **in_progress**: Agent actively working
- **blocked**: Waiting for external input or dependency resolution
- **completed**: All acceptance criteria met

View story status in dashboard Ralph tab or `/ralph` page.

## Ralph Dashboard Panel

In the right panel of the main dashboard:

### Current Objective
Shows active objective with progress bar.

### Story Breakdown
Lists all stories with:
- Story title
- Status badge (color-coded)
- Assigned agent tier
- Progress percentage
- Estimated/actual tokens

Example:

```text
Objective 1: Multi-project support (40% complete)
  ✓ story-1: Add project selector (complete, 5200 tokens)
  ⧖ story-2: Filter agent list (in progress, 3500/4000 tokens)
  ○ story-3: Update API routes (not started, estimated 6000)
  ⚠ story-4: Database migration (blocked, waiting for story-3)
```

### Active Agents
Lists agents assigned to current story with:
- Agent name and type
- Current subtask
- Time spent
- Tokens consumed

## Flowchart Visualization

Navigate to `/ralph` for a complete flowchart view:

- **Vertical swim lanes**: One per story
- **Horizontal timeline**: Execution progress
- **Color coding**:
  - Green = Complete
  - Blue = In progress
  - Gray = Not started
  - Orange = Blocked
  - Red = Error
- **Dependencies**: Arrows showing story dependencies
- **Agent assignments**: Icons showing assigned agents

Hover for details, click to navigate to story details.

## Escalation Rules

Ralph automatically escalates problems to higher tiers:

```json
"escalation_rules": [
  {
    "error_type": "compilation_error",
    "escalate_to_tier": 3
  },
  {
    "consecutive_failures": 3,
    "escalate_to_tier": 3
  },
  {
    "timeout_seconds": 300,
    "escalate_to_tier": 2
  }
]
```

When a rule is triggered:
1. Current agent pauses
2. Ralph selects higher-tier agent
3. Context and progress transferred
4. Escalated agent resumes work

## API Endpoints

### GET /api/ralph
Get current Ralph session data:

```bash
curl http://localhost:3031/api/ralph
```

Response:

```json
{
  "project": "ccem",
  "current_objective": "obj-1",
  "progress_percent": 40,
  "active_agents": 3,
  "stories": [
    {
      "id": "story-1",
      "status": "completed",
      "progress": 100
    }
  ]
}
```

### GET /api/ralph/flowchart
Get flowchart visualization data:

```bash
curl http://localhost:3031/api/ralph/flowchart
```

Returns D3-compatible JSON for drawing the flowchart.

## Best Practices

1. **Granular Stories**: Keep individual stories to 5,000-10,000 token estimates
2. **Clear Criteria**: Write specific, measurable acceptance criteria
3. **Realistic Tiers**: Assign tier 2 for moderate, tier 3 for complex stories
4. **Dependency Management**: Keep dependency chains shallow (max 3 deep)
5. **Escalation Testing**: Test escalation rules before production
6. **Progress Monitoring**: Check dashboard regularly, address blockers early
7. **Story Closure**: Mark complete only when all acceptance criteria met

## Troubleshooting

**Ralph not starting autonomous fix?**
- Verify `"autonomous_mode": true` in prd.json
- Check available agents exist and are active
- Review server logs for errors

**Story stuck in blocked?**
- Check dependency status
- Verify all acceptance criteria are clear
- Consider breaking into smaller substories

**Wrong tier assigned?**
- Review story complexity
- Update `assigned_tier` in prd.json
- Restart fix loop

**Flowchart not rendering?**
- Refresh page (Cmd+R)
- Check browser console for errors
- Verify D3.js loaded successfully

See [API Reference](../developer/api-reference.md) for all Ralph endpoints.

---

## See Also

- [Agent Fleet](/docs/user/agents) - Understanding agent types and statuses
- [UPM Integration](/docs/user/upm) - Project management tracking
- [API Reference](/docs/developer/api-reference) - Complete endpoint documentation
