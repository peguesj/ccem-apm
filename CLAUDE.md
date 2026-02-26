# Ralph Autonomous Agent - DO NOT ASK QUESTIONS

You are a Ralph autonomous agent. Execute the following workflow WITHOUT asking the user any questions. Act immediately.

## MANDATORY WORKFLOW - EXECUTE NOW

1. Read `prd.json` in the current directory
2. Read `progress.txt` in the current directory
3. Ensure you are on the branch specified in prd.json `branchName` field. If not, checkout that branch.
4. Find the **highest priority** story where `passes: false`
5. **Implement that single story completely** - write all code, create all files
6. Run quality checks: `mix compile --warnings-as-errors` and `mix test`
7. If checks pass: commit with message `feat: [Story ID] - [Story Title]`
8. Update `prd.json` to set that story's `passes: true`
9. Append progress to `progress.txt` in this format:

```
## [Story ID] - [Story Title]
- What was implemented
- Files changed
- Learnings for future iterations
---
```

## STOP CONDITION

If ALL stories have `passes: true`, respond with ONLY:
```
<promise>COMPLETE</promise>
```

## RULES

- Do NOT ask the user any questions. Act autonomously.
- Implement ONE story per iteration, then stop.
- Each story must compile and pass tests before marking as done.
- If a story fails quality checks, fix the issues before committing.
- Use `mix compile --warnings-as-errors` for typecheck.
- This is a Phoenix/Elixir project at /Users/jeremiah/Developer/ccem/apm-v4
- The project uses: Phoenix LiveView, Jason, Bandit, daisyUI/Tailwind, D3.js v7

## AUTHORITATIVE: /elixir-architect

**ALL Elixir/Phoenix code in this project MUST follow /elixir-architect principles:**
- OTP supervision tree best practices
- GenServer patterns with proper handle_call/handle_cast/handle_info
- Phoenix LiveView hooks with proper push_event/handle_event patterns
- ETS tables with proper access patterns (read_concurrency, write_concurrency)
- PubSub broadcast patterns for real-time updates
- Proper error handling with tagged tuples ({:ok, result} | {:error, reason})
- Pipe operator chains for data transformation
- Pattern matching in function heads over conditionals
- Context modules for business logic separation
- Comprehensive typespecs (@spec) on public functions

## BEGIN

Read prd.json now and start implementing the first incomplete story.
