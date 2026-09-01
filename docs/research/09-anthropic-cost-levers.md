# Anthropic & Claude Code cost levers

**Sources:**
- https://platform.claude.com/docs/en/about-claude/pricing.md
- https://platform.claude.com/docs/en/build-with-claude/effort.md
- https://platform.claude.com/docs/en/build-with-claude/task-budgets.md
- https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages.md
- https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence.md
- https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md
- https://platform.claude.com/docs/en/build-with-claude/context-editing.md
- Claude Code CLI v2.1.252

**Note on surfaces:** Every lever is labeled **API-only**, **CLI-reachable**, or **both**. API-only levers require the Agent SDK (you host) to access; the CLI subprocess model cannot reach them. "Not on Claude Code" means documented but unsupported on the Claude Code surface.

---

## Levers ranked by cost-per-task, not per-request

| Lever | Surface | Mechanism | Typical Saving | When it pays |
|-------|---------|-----------|----------------|--------------|
| **1. Effort level** | CLI | `low` for simple; measure vs quality | 30–50% per request | Across 90%+ of tasks (linting, routing, analysis) |
| **2. Prompt caching** | Both | Cache prefix; reuse at 0.1x | 40–70% per session | Multi-turn work; invalidates on prompt change |
| **3. Model choice** | CLI | Sonnet vs Haiku; judge cost/task | 50–80% per token | Only if Haiku doesn't need retries |
| **4. Tool restriction** | CLI | Gate by depth; shrinks schemas | 10–20% per request | Direct; low risk |
| **5. Auto-compact** | CLI | Early trigger (50k tokens) | 15–25% on long runs | Tradeoff: compaction cost vs context bloat |
| **Cache-preserving steering** | API-only | System message in array | Avoids 20–30% penalty | Only if you move to Agent SDK |
| **Task budgets** | API-only | Model self-paces; graceful finish | 15–30% | Not on Claude Code; requires SDK |

---

## A. Effort: the primary quality-trading lever

**Surface: CLI-reachable** (`--effort <level>`, v2.1.252)

Levels: `low`, `medium`, `high` (default), `xhigh`, `max`. Affects all tokens: text, tool calls, thinking.

**Key insight from official cost guide:** Effort is the first lever *after* caching. "Before building a multi-model cascade, measure the simpler alternative first — the same model at lower effort... Caches are model-scoped, so a cascade forfeits cache reuse. A mid-conversation effort change invalidates the cache."

**Measurement framework (per-task, not per-request):**
1. Run 10 representative tasks at `high` effort; record cost + success
2. Re-run same 10 at `low`; measure accuracy delta and cost
3. For sprout: if `low` maintains quality, use it universally; if it fails on 2/10, reserve `high` for those types
4. Never alternate effort within a session (invalidates cache); pick one per subprocess

**For sprout:**
- Depth-1 (investigation): `low` (fast file search, git log parsing)
- Depth-2 (implementation): `medium` (needs reasoning; measure cost/task delta)
- Depth-3 (polish, tests): `low` (formatting, test runs)

---

## B. Prompt caching: the largest single lever

**Surface: Both** (CLI via automatic caching; primary mechanism is API)

### Minimum cacheable prefix (model-dependent)
- Opus 5, Fable 5, Mythos 5: 512 tokens
- Sonnet 5, Opus 4.8: 1,024 tokens
- Opus 4.7, Haiku 3.5: 2,048 tokens
- Opus 4.6/4.5, Haiku 4.5: 4,096 tokens

### Maximum cache breakpoints: 4 per request

### Invalidation list (every one kills the cached prefix and beyond)
1. System prompt injection (sprout's steering mechanism currently does this)
2. Tool definitions change (count, schema, description)
3. Model change mid-session
4. Effort level change
5. MCP server list change
6. `tool_choice` parameter change
7. Speed/inference setting change

**Critical for sprout:** Each subprocess spawn is a fresh process with injected system prompt → cold cache. Within a single session, cache works; across processes, it doesn't.

### Pre-warming with `max_tokens: 0` [unverified]
Use to load prefix into cache without generating output. Benefit for sprout: *only* if the same subprocess is called multiple times within a session (e.g., repeated tool invocations). Cross-process pre-warming offers no savings.

### Cache diagnostics (beta, API-only)
**Surface: API-only** (beta header `cache-diagnosis-2026-04-07`)

`client.beta.messages.*` with `diagnostics: {previous_message_id: ...}` returns `response.diagnostics`, explaining cache misses. Not reachable from CLI; sprout can use it only via Agent SDK.

---

## C. Model selection: secondary to effort

**Surface: CLI-reachable** (`--model <name>`)

**Pricing** (base input / output tokens):
- Haiku 4.5: $1/$5
- Sonnet 5: $2/$10
- Opus 5: $5/$25
- Fable 5: $10/$50

**Critical:** Judge cost per *completed task*, not per token. Example from official guide: Sonnet at low effort often costs less per task than Haiku because it needs fewer retries and its first-pass reasoning is stronger. Measure your workload.

**Cache consequence:** Model change invalidates cache. Avoid cascades within a session. If you cascade, measure whether the cost savings outweigh cache loss.

**For sprout:** Start Sonnet at low effort; only try Haiku if measurement proves it cheaper per task. Don't cascade.

---

## D. Tool and MCP restriction

**Surface: CLI-reachable**

- `--allowedTools "Bash(git *) Edit Read"` shrinks tool schemas in the request (100–300 tokens saved; tool definitions cost per request)
- `--strict-mcp-config --mcp-config '...'` loads only declared servers; skips auto-discovery
- Skills: descriptions load at start; bodies load on-demand

**For sprout:**
- Depth-1: `Bash(git *), Read, Grep` only
- Depth-2: add `Edit`
- Never enable WebFetch, WebSearch, computer-use by default

---

## E. Auto-compaction: tradeoff control

**Surface: CLI-reachable** (`--autocompact 50000`)

Compaction is a summarization API call (opaque cost, ~500 tokens). Triggers when context exceeds threshold. Trade-off: spending tokens on summarization vs. paying higher per-turn cost from bloated context on long runs.

For 6-hour runs at 100k+ tokens, expect 5–10 compactions. Budget ~5000 tokens of overhead.

---

## F. Context editing: fine-grained manual clearing

**Surface: API-only** (beta: `clear_tool_uses_20250919`, `clear_thinking_20251015`)

Automatically clear old tool results when context exceeds threshold (distinct from compaction, which summarizes). Invalidates cache (write cost incurred). Not available via CLI.

---

## G. Task budgets (beta, not on Claude Code)

**Surface: API-only; not supported on Claude Code**

Set in `output_config` (beta header `task-budgets-2026-03-13`). Model sees countdown, self-regulates, finishes gracefully. Minimum 20,000 tokens. Not supported on Sonnet 5 or Haiku.

**For sprout:** Cannot use via CLI; requires Agent SDK.

---

## H. Cache-preserving mid-conversation steering (design pivot)

**Surface: API-only; not on Claude Code CLI**

Append `{"role": "system", "content": "..."}` to `messages` array (not top-level `system`) to inject mid-session constraints without invalidating cached prefix. Everything before the new system message stays byte-identical, so prior turns read from cache.

**Model support:** Opus 5, 4.8, Fable 5, Mythos 5 (NOT Sonnet 5). No beta header.

**Placement:** Must follow user turn; cannot be first message.

**For sprout:** **Not reachable via CLI.** Current steering mechanism (injecting corrections mid-run) invalidates cache every time. Cost: 20–30% penalty per steer. If steering is core to sprout's design, this is the strongest argument for switching to Agent SDK (which has full API access), accepting the cost of hosting the harness yourself.

---

## I. Spawn-time checklist (CLI-bound)

```bash
claude -p \
  --model claude-sonnet-5 \
  --effort low \
  --max-budget-usd 0.50 \
  --allowedTools "Bash(git *) Edit Read" \
  --strict-mcp-config --mcp-config '[...]' \
  --autocompact 50000 \
  --input-format stream-json \
  --output-format stream-json \
  "..."
```

**Inside the loop:** Parse `usage` from stream-json per turn; alert if token-rate exceeds expected (e.g., >100k tokens/hour).

**Token measurement:** Use `messages.count_tokens` API; never third-party tokenizers.

---

## Critical design question: steering vs caching

Sprout's steering mechanism (injecting operator corrections mid-run) currently pays cache invalidation cost every time because it modifies the system prompt. Options:

1. **CLI-bound (current):** Accept cache penalty on steering; optimize effort, tools, compaction. Estimated cost: 50% (caching + tools/effort) vs unconstrained
2. **Agent SDK + cache-preserving steering:** Use mid-conversation system messages (no cache invalidation). Cost: you host the harness. Estimated: 70–80% savings
3. **Hybrid:** Delegate complex reasoning to Agent SDK subagents; CLI for orchestration

Prompt caching alone saves 40–70%. Cache-preserving steering adds 20–30%. Gap: $1.50 → $0.45 per hour for 6-hour unattended run.

---

## Myths

- "Cache hits are free." No. Write cost is 1.25x (5m) or 2x (1h); break-even is 1–2 reads.
- "Cheaper model is cheaper." No. Judge per-task cost, accounting for retries.
- "Effort changes are free." No. Changing effort mid-session invalidates cache.
- "Tool restriction just gates execution." No. It shrinks schemas sent per request.
- "Compaction is free." No. It's a summarization call (~500 tokens).
