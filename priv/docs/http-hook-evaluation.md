# http Hook Type Evaluation — CCEM APM

**Date**: 2026-03-27
**Claude Code version evaluated**: v2.1.85
**Hooks evaluated**: agentlock_context.sh, agentlock_pre_tool.sh, agentlock_post_tool.sh

---

## Summary

Evaluated the Claude Code v2.1.85 `http` hook type as a replacement for bash+curl subprocess hooks in the CCEM AgentLock pipeline. **No hooks were migrated.** All three agentlock hooks require `command` type.

---

## How the `http` Hook Type Works

The `http` type POSTs the **raw Claude hook payload** (the same JSON that `cat` reads from stdin in command hooks) directly to the configured URL. It:
- Eliminates the fork/exec subprocess overhead
- Is genuinely fire-and-forget for telemetry endpoints
- Cannot preprocess or transform the payload before sending
- Cannot read the HTTP response
- Cannot write files or return `updatedInput`

---

## Hooks NOT Migrated (require `command` type)

### agentlock_pre_tool.sh
**Disqualifiers:**
1. Reads the HTTP response from `/api/v2/auth/authorize` to extract `allowed`, `token_id`, `reason`, `detail`
2. Writes `$TOKEN_ID` to `$STATE_DIR/${TOOL_USE_ID}.atk` state file for PostToolUse consumption
3. Exits 2 on explicit deny to block tool execution (http type is always fire-and-forget, no blocking semantics)
4. Complex shell logic: agent name lookup, param extraction, project name resolution

**Verdict**: Keep `command` type. This hook is the AgentLock authorization gate — it must read the response and optionally block.

---

### agentlock_post_tool.sh
**Disqualifiers:**
1. Reads token from state file written by pre_tool hook (`$STATE_DIR/${TOOL_USE_ID}.atk`)
2. Cleans up the `.atk` file after consumption (`rm -f "$ATK_FILE"`)
3. Stateful file I/O is incompatible with `http` type

**Verdict**: Keep `command` type. Stateful token consumption across hook invocations requires shell.

---

### agentlock_context.sh
**This was the primary migration candidate** — it is documented as "fire-and-forget" and exits 0 unconditionally. However:

**Disqualifiers:**
1. **Payload transformation**: Maps `tool_name` to a `source` enum (`file_content`, `web_content`, `peer_agent`, `tool_output`) before sending. The `http` type sends the raw hook payload; the endpoint would receive `{tool_name, tool_input, session_id, ...}` instead of the required `{session_id, agent_id, source, content_hash}`.
2. **Content hash computation**: Derives `content_hash` from `tool_use_id` via `shasum -a 256`. This transformation cannot happen in an `http` hook.
3. **Schema mismatch**: `POST /api/v2/auth/context/write` expects `ContextWrite` schema with `source` (enum) and `content_hash` fields. The raw hook payload does not match this schema.

**Verdict**: Keep `command` type. The hook enriches and transforms the payload before posting. Migrating to `http` would require either (a) changing the APM endpoint to accept raw hook payloads and do the mapping server-side, or (b) adding a thin proxy layer.

---

## Hooks Migrated to `http` Type

**None in this evaluation cycle.**

---

## Policy Fragment Created

`~/.claude/managed-settings.d/ccem-agentlock.json` was created as the authoritative policy fragment for AgentLock hooks under the v2.1.85 `managed-settings.d` drop-in system. All three hooks are registered with `command` type and inline `_reason` annotations documenting why `http` migration was not applicable.

---

## Recommendation: When to Use `http` Type

Use `http` for future hooks that:
- Send the **raw Claude hook payload** to an endpoint that accepts it as-is (no field mapping needed)
- Require no response processing
- Require no file I/O
- Have no blocking/abort semantics

The best candidates in CCEM for future `http` migration would be:
- A simplified heartbeat hook that accepts the raw session/tool event payload directly
- A telemetry sink that indexes raw hook events without schema transformation

Reserve `command` for hooks that need: payload transformation, response parsing, file I/O, `updatedInput` return, or exit-code-based blocking.

---

## Path to Enabling `http` for agentlock_context.sh

If future work migrates this hook to `http` type, the APM endpoint would need to:
1. Accept raw PostToolUse hook payload at a new endpoint (e.g., `/api/v2/auth/context/ingest-raw`)
2. Perform tool→source mapping server-side
3. Derive content_hash from `tool_use_id` server-side

Until then, keep `command` type.
