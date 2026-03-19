# Claude Usage Tracking

CCEM APM v6.4.0 introduces built-in Claude Usage tracking — a real-time token and effort monitoring system that gives you per-project, per-model visibility into how Claude is being used across all your active workstreams.

> **Tip:** New to CCEM APM? Start with [Getting Started](/docs/user/getting-started) to set up the server, then return here to understand usage tracking.

## Overview

Every interaction with Claude — tool invocations, session turns, generated tokens — has a cost. Without visibility into this consumption, it is difficult to understand which projects are consuming the most resources, which models are being used, or how intensive agent workloads have become.

The Claude Usage tracking system solves this by:

- **Accumulating token counters** (input, output, cache) per project and per model
- **Tracking tool call and session counts** to derive effort classifications
- **Providing a real-time dashboard** at `/usage` that updates without polling
- **Exposing a REST API** so hooks, agents, and external tools can record and query usage programmatically

Data is held in ETS (in-memory) for the lifetime of the APM server process. It is intentionally ephemeral — usage reflects the current server session, not historical totals. This keeps the system fast and stateless, suitable for local development monitoring.

---

## Usage Dashboard

Navigate to [http://localhost:3032/usage](http://localhost:3032/usage) to open the Usage dashboard.

The dashboard is a LiveView page that subscribes to real-time updates and also auto-refreshes every 10 seconds as a fallback.

### Summary Bar

The top of the page shows four summary stats:

| Stat | Description |
| :--- | :--- |
| **Input Tokens** | Total input tokens consumed across all projects and models |
| **Output Tokens** | Total output tokens generated across all projects and models |
| **Top Model** | The model with the highest cumulative input token consumption |
| **Total Tool Calls** | Sum of all tool invocations recorded across all projects |

### Token Distribution

Below the summary bar, a visual token distribution section displays three progress bars:

- **Input** — proportion of total token volume that is input
- **Output** — proportion of total token volume that is output
- **Cache** — proportion of total token volume served from cache

The bars are relative to the combined total `(input + output + cache)`. This section only renders when at least one token has been recorded.

### Model Breakdown Table

A sortable table lists every model that has been recorded, ranked by input token consumption (descending):

```text
Model                     Input     Output    Cache     Tool Calls  Sessions  Last Seen
claude-sonnet-4-6         1.2M      340.5k    88.2k     482         21        3m ago
claude-opus-4-5           220.1k    62.3k     14.0k     84          5         1h ago
claude-haiku-3-5          45.0k     11.2k     0         19          3         2h ago
```

Each row shows the cumulative counters across all projects for that model.

### Per-Project Accordion

Below the model table, each project is listed as a collapsible row. The header row shows:

- Project name (monospace)
- Effort level badge (see [Effort Levels](#effort-levels))
- Summary counters: input tokens, output tokens, tool calls
- A **Reset** button to clear that project's data

Click a project row to expand it and view the per-model breakdown for that project specifically. This is useful for understanding which models are being used within a given codebase.

### Empty State

If no usage has been recorded yet, the dashboard shows:

```text
No usage data recorded yet.
The PostToolUse hook will populate this once active.
```

This is normal on a fresh APM server start before any agents or hooks have called `POST /api/usage/record`.

---

## Effort Levels

CCEM APM infers an **effort level** for each project based on the ratio of tool calls to sessions recorded. This is not a configurable threshold — it is derived at read time from the stored counters.

### Threshold Table

| Level | Tool Calls / Session | Badge Color | Meaning |
| :--- | :--- | :--- | :--- |
| **low** | < 10 | Ghost (neutral) | Light interaction; simple queries or small tasks |
| **medium** | 10 – 50 | Blue | Moderate work; multi-step tasks with several tool uses |
| **high** | 50 – 100 | Yellow/Warning | Heavy agent activity; complex feature work or fix loops |
| **intensive** | > 100 | Red/Error | Very high automation load; large formations or ralph loops |

### How the Ratio is Calculated

For a given project, the ratio is:

```
ratio = total_tool_calls / total_sessions
```

If `total_sessions` is zero (i.e., record calls were made but the session counter never incremented from zero), the ratio falls back to `total_tool_calls` directly.

Each call to `POST /api/usage/record` increments the session counter by 1 for the given `{project, model}` key. Tool calls are accumulated from the `tool_calls` field in the request body.

### Example

```text
Project: ccem
  Sessions: 8
  Tool Calls: 520
  Ratio: 65.0

  → Effort Level: high
```

The effort level is displayed as a badge in the project accordion and is also included in the API responses for per-project queries.

---

## Token Counters

Token counters are tracked per `{project, model}` key. Each record event upserts into ETS, accumulating into running totals.

### Counter Fields

| Field | Type | Description |
| :--- | :--- | :--- |
| `input_tokens` | integer | Tokens in the prompt / context window |
| `output_tokens` | integer | Tokens generated by the model in its response |
| `cache_tokens` | integer | Tokens served from prompt cache (cache read hits) |
| `tool_calls` | integer | Number of tool invocations in the recorded interaction |
| `sessions` | integer | Number of record events (auto-incremented per call) |
| `last_seen` | ISO-8601 string | Timestamp of the most recent record event |

### Display Formatting

Token values are formatted for readability in the dashboard:

| Raw Value | Displayed As |
| :--- | :--- |
| 1,250 | `1.2k` |
| 1,250,000 | `1.2M` |
| 850 | `850` |

### Aggregation Across Models

When you view a project's summary, token counters are summed across all models recorded for that project. The per-model breakdown table shows the individual model contributions.

When you view the global summary, counters are further summed across all projects per model.

---

## Real-Time Updates

The Usage dashboard uses Phoenix PubSub for zero-polling live updates.

### PubSub Topic

```
"apm:usage"
```

Every call to `POST /api/usage/record` and every project reset triggers a broadcast on this topic:

```elixir
Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:usage", {:usage_updated, get_all_usage()})
```

### LiveView Subscription

`UsageLive` subscribes to `"apm:usage"` when the WebSocket connection is established:

```elixir
Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:usage")
```

When the `{:usage_updated, data}` message arrives, the LiveView re-fetches the summary and re-renders the page immediately — no browser refresh required.

### Fallback Refresh

In addition to PubSub, the LiveView schedules a periodic refresh every 10 seconds:

```elixir
:timer.send_interval(10_000, self(), :refresh)
```

This ensures the dashboard stays accurate even if a WebSocket reconnect is in progress.

### Latency Expectations

Updates appear in the dashboard within approximately 100–500 ms of a `record` call, depending on server load and WebSocket connection quality. The 10-second fallback ensures eventual consistency in all cases.

---

## Recording Usage

Usage events are recorded by sending a `POST` request to `/api/usage/record`. This is typically done from:

- **PostToolUse hooks** in `~/.claude/hooks/` — automatically fired after each tool invocation
- **Formation agents** — at the end of each task or wave
- **Custom scripts** — any process that has visibility into token usage

### POST /api/usage/record

```bash
curl -X POST http://localhost:3032/api/usage/record \
  -H "Content-Type: application/json" \
  -d '{
    "project":        "ccem",
    "model":          "claude-sonnet-4-6",
    "input_tokens":   1500,
    "output_tokens":  320,
    "cache_tokens":   200,
    "tool_calls":     3
  }'
```

### Request Body

| Field | Type | Required | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `project` | string | No | `"unknown"` | Project name/identifier |
| `model` | string | No | `"claude-sonnet-4-6"` | Claude model identifier |
| `input_tokens` | integer | No | `0` | Input tokens consumed |
| `output_tokens` | integer | No | `0` | Output tokens generated |
| `cache_tokens` | integer | No | `0` | Cache read tokens |
| `tool_calls` | integer | No | `0` | Number of tool calls made |

All integer fields accept string values — the server parses them automatically.

### Response

```json
{
  "ok": true,
  "project": "ccem",
  "model": "claude-sonnet-4-6",
  "effort_level": "medium",
  "usage": {
    "claude-sonnet-4-6": {
      "input_tokens": 14500,
      "output_tokens": 3200,
      "cache_tokens": 1800,
      "tool_calls": 62,
      "sessions": 12,
      "last_seen": "2026-03-18T14:22:10.000000Z"
    }
  }
}
```

The response returns HTTP 201 and includes the updated usage state for the project, along with the inferred effort level.

### PostToolUse Hook Example

A minimal PostToolUse hook that records Claude usage after every tool call:

```bash
#!/usr/bin/env bash
# ~/.claude/hooks/post_tool_use.sh

PROJECT="${CLAUDE_PROJECT:-unknown}"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
INPUT_TOKENS="${CLAUDE_INPUT_TOKENS:-0}"
OUTPUT_TOKENS="${CLAUDE_OUTPUT_TOKENS:-0}"
CACHE_TOKENS="${CLAUDE_CACHE_TOKENS:-0}"

curl -s -X POST http://localhost:3032/api/usage/record \
  -H "Content-Type: application/json" \
  -d "{
    \"project\":       \"${PROJECT}\",
    \"model\":         \"${MODEL}\",
    \"input_tokens\":  ${INPUT_TOKENS},
    \"output_tokens\": ${OUTPUT_TOKENS},
    \"cache_tokens\":  ${CACHE_TOKENS},
    \"tool_calls\":    1
  }" >/dev/null 2>&1 &
```

This is fire-and-forget — it does not block Claude Code execution.

### Formation Agent Pattern

Formation agents can record usage at wave completion using the same endpoint:

```bash
curl -s -X POST http://localhost:3032/api/usage/record \
  -H "Content-Type: application/json" \
  -d '{
    "project":        "ccem",
    "model":          "claude-sonnet-4-6",
    "input_tokens":   48200,
    "output_tokens":  12100,
    "cache_tokens":   8400,
    "tool_calls":     187
  }' >/dev/null 2>&1 &
```

---

## Resetting Data

You can reset usage counters for a specific project through the dashboard or the API. Resetting removes all model-keyed records for that project from the ETS table and broadcasts the updated state to all connected LiveView clients.

### Reset via Dashboard

In the per-project accordion, each project row has a **Reset** button on the right side. Clicking it immediately clears all usage data for that project and collapses the expanded view.

> **Warning:** This action is immediate and irreversible. There is no confirmation prompt.

### DELETE /api/usage/project/:name

```bash
curl -X DELETE http://localhost:3032/api/usage/project/ccem
```

Response:

```json
{
  "ok": true,
  "project": "ccem",
  "message": "Usage data reset"
}
```

After a reset, the project will no longer appear in `GET /api/usage` or `GET /api/usage/summary` until new usage events are recorded.

---

## API Reference

All usage endpoints are served under `/api/usage`. No authentication is required for local APM access.

### GET /api/usage

Return all usage data, keyed by project then model.

```bash
curl http://localhost:3032/api/usage
```

Response:

```json
{
  "ok": true,
  "usage": {
    "ccem": {
      "claude-sonnet-4-6": {
        "input_tokens": 14500,
        "output_tokens": 3200,
        "cache_tokens": 1800,
        "tool_calls": 62,
        "sessions": 12,
        "last_seen": "2026-03-18T14:22:10.000000Z"
      }
    },
    "lcc": {
      "claude-opus-4-5": {
        "input_tokens": 5400,
        "output_tokens": 1100,
        "cache_tokens": 0,
        "tool_calls": 18,
        "sessions": 4,
        "last_seen": "2026-03-18T13:55:00.000000Z"
      }
    }
  }
}
```

### GET /api/usage/summary

Return aggregated totals across all projects, a per-model breakdown, and per-project summaries with effort levels.

```bash
curl http://localhost:3032/api/usage/summary
```

Response shape:

```json
{
  "ok": true,
  "summary": {
    "total_input_tokens":  19900,
    "total_output_tokens": 4300,
    "total_cache_tokens":  1800,
    "total_tool_calls":    80,
    "total_sessions":      16,
    "top_model":           "claude-sonnet-4-6",
    "model_breakdown": {
      "claude-sonnet-4-6": {
        "input_tokens": 14500,
        "output_tokens": 3200,
        "cache_tokens": 1800,
        "tool_calls": 62,
        "sessions": 12,
        "last_seen": "2026-03-18T14:22:10.000000Z"
      }
    },
    "projects": {
      "ccem": {
        "input_tokens": 14500,
        "output_tokens": 3200,
        "cache_tokens": 1800,
        "tool_calls": 62,
        "sessions": 12,
        "effort_level": "medium",
        "model_breakdown": {
          "claude-sonnet-4-6": { "...": "..." }
        }
      }
    }
  }
}
```

`top_model` is the model with the highest cumulative `input_tokens` across all projects.

### GET /api/usage/project/:name

Return usage data and effort level for a single project.

```bash
curl http://localhost:3032/api/usage/project/ccem
```

Response:

```json
{
  "ok": true,
  "project": "ccem",
  "effort_level": "medium",
  "usage": {
    "claude-sonnet-4-6": {
      "input_tokens": 14500,
      "output_tokens": 3200,
      "cache_tokens": 1800,
      "tool_calls": 62,
      "sessions": 12,
      "last_seen": "2026-03-18T14:22:10.000000Z"
    }
  }
}
```

If the project has no recorded usage, `usage` is an empty object and `effort_level` is `"low"`.

### POST /api/usage/record

Record a usage event for a project and model. Returns HTTP 201 with the updated project usage state.

See [Recording Usage](#recording-usage) for full field reference and examples.

### DELETE /api/usage/project/:name

Reset all usage counters for a project. Returns HTTP 200.

See [Resetting Data](#resetting-data) for full details.

### Endpoint Summary

| Method | Path | Description |
| :--- | :--- | :--- |
| `GET` | `/api/usage` | All usage data, all projects |
| `GET` | `/api/usage/summary` | Aggregated summary with effort levels |
| `GET` | `/api/usage/project/:name` | Single project usage + effort level |
| `POST` | `/api/usage/record` | Record a usage event |
| `DELETE` | `/api/usage/project/:name` | Reset counters for a project |

---

## Best Practices

1. **Use fire-and-forget** — always send usage records as background curl calls (`>/dev/null 2>&1 &`) to avoid blocking agent execution
2. **Record at task boundaries** — one record per tool call or one record per formation wave works well
3. **Include the project field** — the `"unknown"` default makes it harder to filter and compare across projects
4. **Use canonical model identifiers** — match the model string exactly as returned by the Anthropic API (e.g., `claude-sonnet-4-6`, not `sonnet`)
5. **Reset sparingly** — usage data resets are irreversible; prefer reading the summary to understand load rather than wiping data
6. **Monitor effort level trends** — if a project climbs to `intensive`, it may indicate runaway agent loops or misconfigured formation sizes

---

## Troubleshooting

### Dashboard Shows No Data

- Verify at least one `POST /api/usage/record` call has been made: `curl -s http://localhost:3032/api/usage | python3 -m json.tool`
- If using a PostToolUse hook, confirm the hook is active and the APM server is running on port 3032
- Check the APM log for any errors: `tail -f ~/Developer/ccem/apm/hooks/apm_server.log`

### Data Not Updating in Real Time

- Check that the browser WebSocket connection is active (no red indicator in browser DevTools Network tab)
- The 10-second fallback refresh ensures the dashboard will update even if PubSub is delayed
- If running APM behind a reverse proxy, ensure WebSocket upgrade headers are forwarded

### Effort Level Stuck at "low"

- Confirm `tool_calls` is being set to a non-zero value in record requests
- Check the ratio: if sessions are very high relative to tool calls, the ratio may legitimately be low
- Use `GET /api/usage/project/:name` to inspect the raw counters

### Record Call Returns 500

- Ensure the APM server is running: `curl http://localhost:3032/api/status`
- Verify the JSON body is valid and `Content-Type: application/json` is set
- Check that integer fields are not `null` — omit fields you do not have values for rather than sending `null`

---

## See Also

- [Agent Fleet Management](/docs/user/agents) - Register and monitor agents
- [Background Tasks](/docs/user/tasks) - Track background processes
- [Ralph Methodology](/docs/user/ralph) - Autonomous fix loop execution
- [API Reference](/docs/developer/api-reference) - Complete endpoint documentation

---

*CCEM APM v6.4.0 — Author: Jeremiah Pegues*
