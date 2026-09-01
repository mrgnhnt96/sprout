# Claude Code control plane — research notes

> ## ⚠️ SUPERSEDED — do not build against this file
>
> This document was written from **documentation, not observation**, and Phase 0 found **six of its
> claims wrong**, one of them inverted in a way that would have made every sprout gate fail open
> (it says a Stop hook blocks on exit 0 and allows on exit 2; the truth is the reverse).
>
> **Use `17-observed-schemas.md`**, which was captured from a live CLI v2.1.252 with the raw frames
> committed under `fixtures/phase0/`. Where the two disagree, `17` is right by construction.
>
> Known-wrong here: `UserPromptSubmit.prompt_text` (really `prompt`); `PostToolUse.tool_result`
> (really `tool_response`); `SubagentStart.subagent_id` + `parent_tool_use_id` (really `agent_id`,
> and no parent field at all); `Stop.reason` (does not exist); `SessionStart.model`/`.tools` (do not
> exist); the Stop-hook exit codes. Also missing entirely: the whole `system/task_*` frame family,
> which is the best observation surface the control plane has.
>
> This file is kept because §A (spawn flags) and §D (limits) are broadly sound, and because the
> handoff's warning to "treat this document with more suspicion than the others" was correct and is
> worth preserving as a record.

**Sources:** https://code.claude.com/docs/en/cli-reference.md, https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode.md, https://code.claude.com/docs/en/headless.md, https://code.claude.com/docs/en/permission-modes.md

**Confidence:** Official documentation v2.1.246+, v2.1.252+ CLI, Agent SDK Python v0.2.140+, TypeScript v0.3.234+

**Version checked:** Claude Code v2.1.252

## Verdict up front

| Requirement | Status | Notes |
|---|---|---|
| Spawn sessions | YES | `claude -p`, Agent SDK (TS/Python), `claude --bg`. No Dart binding; drive CLI via subprocess. |
| Observe activity | YES | Hooks fire at every point; JSON streams with `--output-format stream-json`. |
| Live web UI | PARTIAL | Hooks + stream-json event feed provide observability; UI rendering is sprout's responsibility. |
| **Steer mid-flight** | **YES** | **Streaming input via `--input-format stream-json` (CLI) or async generators (SDK).** |
| Keep on-target | YES | Stop hook, max_turns, max_budget_usd, compaction, interrupts. |
| Leverage installed skills/MCP | YES | Spawned sessions inherit via --mcp-config, --settings, CLAUDE.md. |

## A. Spawning and driving sessions

### 1. Programmatic spawning options

**CLI mode (`claude -p`):**
- Single-shot: `claude -p "prompt"` exits after result
- Streaming JSON: `--output-format stream-json --include-partial-messages`
- JSON result: `--output-format json` returns `{result, session_id, usage, cost}`
- Continue: `claude -p --continue` or `--resume <session-id>`
- Session ID: `--session-id <uuid>` to continue specific session or `--fork-session` to branch
- Structured output: `--json-schema <schema>` validates output

**Agent SDK (Python and TypeScript only):**
- Python: `from claude_agent_sdk import query`, async generators with `prompt=...` or `prompt=async_generator()`
- TypeScript: `import { query } from "@anthropic-ai/claude-agent-sdk"`, async generator input
- Full streaming input support via async generators
- Session IDs in init `SystemMessage` and `ResultMessage`

**Background mode:**
- `claude --bg "task"` spawns detached, returns `{session_id}`
- Poll with `claude agents` or `claude logs <id>`

**For Dart:** Drive CLI via subprocess. Use `--input-format stream-json --output-format stream-json` for interactive steering.

### 2. Streaming input (mid-flight steering) — FULLY SUPPORTED

**Status: Real-time message injection works.** Sessions accept NEW messages while running, without restart.

**CLI protocol:**
```bash
claude -p --input-format stream-json --output-format stream-json << 'EOF'
{"type": "user", "message": {"role": "user", "content": "First prompt"}}
{"type": "user", "message": {"role": "user", "content": "New message while running"}}
EOF
```

**NDJSON message envelope format** (one per line):
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "text" or [content blocks]
  },
  "parent_tool_use_id": null
}
```

**Content blocks:**
```json
{"type": "text", "text": "message"}
{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}
```

**Timing: When messages process:**
- Each message waits for the CURRENT TURN to complete
- Agent does NOT interrupt mid-turn; new message starts next turn
- Multiple messages queue; agent processes them sequentially
- `--replay-user-messages` echoes received messages back for acknowledgment

**Agent SDK (Python/TypeScript):**
```python
async def message_generator():
    yield {"type": "user", "message": {"role": "user", "content": "First"}}
    await asyncio.sleep(1)
    yield {"type": "user", "message": {"role": "user", "content": "Correction"}}

async for message in query(prompt=message_generator()):
    pass  # Process
```

**Interruption:**
- Python SDK: `await client.interrupt()` cancels queued messages
- CLI: SIGINT (Ctrl+C) gracefully ends, SIGTERM forces
- Interrupted messages are dropped; current turn continues

**Verdict:** Sprout can send corrections/goals to running agents via stdin or SDK generator. This is the intended steering mechanism.

### 3. System prompt / role definition

**Flags:**
- `--system-prompt "text"` replaces default
- `--append-system-prompt "text"` adds to default
- `--system-prompt-file path` / `--append-system-prompt-file path`

**Agent definitions:** `.claude/agents/<name>.md` with YAML frontmatter
- Fields: `name`, `description`, `tools`, `model`, `permissionMode`, `skills`, `maxTurns`, `effort`
- Pass via `--agents` flag or load from `.claude/agents/`
- Subagents inherit automatically

**In headless mode:** Pass `--system-prompt`, `--agents <json>`, `--settings <json>`.

### 4. Permissions for unattended runs

**Available modes (v2.1.252):**
- `acceptEdits`: auto-approves file edits and common fs commands (mkdir, touch, mv, cp). Safest for unattended.
- `auto`: classifier model reviews actions. Requires network.
- `plan`: read-only exploration, edits prompt for approval.
- `dontAsk`: denies anything not in allow rules or read-only set. Hard deny for locked-down CI.
- `default`/`manual`: prompts for each action. NOT suitable for unattended.
- `bypassPermissions`: skip all checks (container/CI only; not available as root).

**Recommended for sprout:**
```bash
claude -p "task" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
  --max-budget-usd 10.00 \
  --max-turns 50
```

**Risks:**
- Destructive Bash still runs. Add `if: "Bash(rm *)"` rule to block.
- Network requests need explicit allow.
- AskUserQuestion prompts even in acceptEdits; deny if unattended.

### 5. Session identity

**Get session ID:**
- SDK: `message.session_id` (TypeScript direct; Python in `.data`)
- CLI JSON: `claude -p ... --output-format json | jq '.session_id'`
- Flag: `--session-id <uuid>` to continue; `--fork-session` to branch
- Stream events: every event includes `"session_id"`
- Hooks: every hook payload includes `"session_id"`

**Disk:** `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

---

## B. Hook reference

| Hook | Fires | Key fields | Return | Can block | Inject |
|---|---|---|---|---|---|
| SessionStart | Begin | session_id, cwd, model, tools | systemMessage | No | YES |
| UserPromptSubmit | Prompt sent | session_id, prompt_text | additionalContext | No | YES |
| PreToolUse | Before tool | session_id, tool_name, tool_input | updatedInput, permissionDecision | YES | YES |
| PostToolUse | After tool | session_id, tool_name, tool_result | None | No | No |
| SubagentStart | Subagent spawns | session_id, subagent_id, parent_tool_use_id | None | No | No |
| SubagentStop | Subagent ends | session_id, subagent_id, result | None | No | No |
| Stop | Agent finishes | session_id, reason | decision: "block" | YES | No |
| PreCompact | Before compaction | session_id, trigger | None | No | No |
| SessionEnd | Exit | session_id, transcript_path | None | No | No |

**Exit codes:** 0 = success, 2 = block, other = pass through

**JSON output:**
```json
{
  "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny"},
  "updatedInput": {"command": "modified"},
  "additionalContext": "Extra info"
}
```

**Subagent tree:** Use `parent_tool_use_id` from SubagentStart to link to spawning tool call.

---

## C. Nesting and recursion

**Spawn mechanisms:**
1. Agent tool: `Claude calls Agent(name, task)` → SubagentStart/Stop hook fires
2. Agent definition: `.claude/agents/name.md` + `@"name (agent)"` mention
3. Subprocess: `claude -p --session-id xyz` from Bash (no hook)

**Depth limit:** Default 3 (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=5` to override)
**Concurrency:** Default 20 (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=50` to override)

**Agent definition frontmatter:**
```yaml
name: reviewer
description: "Code review"
model: opus
tools: Read, Glob, Grep
permissionMode: acceptEdits
maxTurns: 10
effort: high
```

**Can sprout generate agents?** YES. Write YAML files to `~/.claude/agents/` or `.claude/agents/`; Claude Code loads them.

**Skills/MCP inheritance:**
- Skills: loaded from `~/.claude/skills/` and `.claude/skills/` automatically
- MCP: pass `--mcp-config ~/.claude/mcp.json` to spawned sessions
- Subagents inherit parent's skills/MCP by default

---

## D. Keeping it on target

### 14. Stop hook and loop control

**Stop hook blocks session end:**
```json
{
  "hookEventName": "Stop",
  "reason": "task_complete",
  "hookSpecificOutput": {"decision": "block"}
}
```

Exit code 0 = block, 2 = allow (counterintuitive).

**Limits:**
- `max_turns`: stop after Nth tool-use turn → `error_max_turns`
- `max_budget_usd`: stop after cost ceiling → `error_max_budget_usd`
- Context window: auto-compaction when full → `PreCompact` hook fires
- Interrupt: `interrupt()` (SDK) or SIGINT (CLI) cancels queued messages

### 15. Observability surfaces

**Streaming JSON (`--output-format stream-json`):**
- `--include-hook-events`: hook lifecycle events in stream
- `--forward-subagent-text`: subagent text with `parent_tool_use_id` for tree reconstruction
- `--include-partial-messages`: text_delta events for streaming text
- Every event carries `session_id`

**Stream event types:**
- `system/init`: model, tools, MCP servers loaded
- `system/api_retry`: API retries with attempt count
- `assistant`: agent response
- `user`: user message or tool result
- `stream_event`: raw API events (text_delta, tool_use, etc.)
- `result`: final output, `total_cost_usd`, `num_turns`

**Hooks (alternative/supplement):**
- Install via `~/.claude/settings.json` hooks
- Capture all sessions on machine
- Write to shared log file for audit trail

---

## The steer mechanism — RECOMMENDATION

**Use streaming input.** Send messages on stdin via `--input-format stream-json` or SDK async generators. Messages queue and process between turns. This is the intended mechanism, zero startup overhead.

**No alternatives needed.** File-based mailbox approach would be slower and unnecessary.

---

## The observability mechanism — RECOMMENDATION

**Strategy: Stream-JSON parsing** (primary)
```bash
claude -p "task" \
  --output-format stream-json \
  --forward-subagent-text \
  --include-hook-events
```

**Pros:**
- Single unified event stream from invocation
- Complete subagent tree via `parent_tool_use_id`
- Final cost in `result` event
- No setup needed; works anywhere

**Cons:**
- Sprout must own the process
- Requires NDJSON parsing
- Real-time only while process runs
- Hook output not included (hooks run outside agent context)

**Optional supplement: Hooks** (for audit trail or external sessions)
- Pre-install hooks to write JSON log
- Captures ALL sessions, even spawned elsewhere
- Post-run analysis

**Verdict:** Use stream-json for live UI. Add hooks only if auditing external sessions or collecting per-repo trails.

---

## Gaps and blockers

1. [VERIFIED] Streaming input IS supported. Earlier claim was wrong.
2. No Dart SDK. Sprout spawns CLI subprocess.
3. Hook payloads lack full agent context (reasoning, intermediate steps).
4. No cost-per-turn breakdown.
5. Session files (`.jsonl`) not stable API.
6. Max recursion depth not queryable from within session.

---

## Takeaways for sprout

1. **Spawn CLI subprocesses.** Use `--input-format stream-json --output-format stream-json` for interactive steering.

2. **USE STREAMING INPUT.** Send corrections/goals on stdin or SDK async generators. This is the steering mechanism.

3. **Observability: stream-json parsing.** Flags: `--output-format stream-json --forward-subagent-text --include-hook-events`. Reconstruct tree via `parent_tool_use_id`.

4. **Limits: max_turns (50–100), max_budget_usd (10–50).**

5. **Agent definitions in .claude/agents/*.md.** Sprout generates them; sprout loads via `--agents`.

6. **Permissions: acceptEdits + granular --allowedTools + max_budget_usd.**

7. **Session tracking: store session_id, resume with --session-id.**

8. **Stream-json gives metadata; final transcripts via `/export` after completion.**

