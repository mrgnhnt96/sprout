# ReDel — research notes

**Sources:**

Paper (read in full, text-extracted from PDF):
- https://aclanthology.org/2024.emnlp-demo.17/ — Zhu, Dugan, Callison-Burch. "ReDel: A Toolkit for LLM-Powered Recursive Multi-Agent Systems." EMNLP 2024 System Demonstrations, pp. 162–171. PDF: https://aclanthology.org/2024.emnlp-demo.17.pdf

Docs (read):
- https://redel.readthedocs.io/en/latest/ (index), `/redel.html`, `/delegation.html`, `/events.html`, `/viz.html`

Source, read verbatim via raw.githubusercontent.com (`zhudotexe/redel@main`):
- `README.md`
- `redel/app.py`, `redel/base_kani.py`, `redel/kanis.py`, `redel/events.py`, `redel/state.py`, `redel/config.py`, `redel/eventlogger.py`, `redel/utils.py`, `redel/namer.py`, `redel/tool_config.py`, `redel/tools/_base.py`
- `redel/delegation/_base.py`, `redel/delegation/delegate_one.py`, `redel/delegation/delegate_and_wait.py`
- `redel/server/server.py`, `redel/server/models.py`, `redel/server/session_manager.py`, `redel/server/indexer.py`
- `viz/src/redel/state.ts`, `viz/src/redel/interactive.ts`, `viz/src/redel/api.ts`, `viz/src/redel/models.ts`, `viz/src/redel/notifications.ts`
- `viz/src/components/Tree.vue`, `viz/src/components/Chat.vue`, `viz/src/components/SessionMetaRow.vue`, `viz/src/views/Home.vue`, `viz/src/views/Interactive.vue`, `viz/src/views/SaveViewer.vue`, `viz/package.json`
- Full repo file tree via GitHub API.

**Confidence:** Everything below marked with a class name, field name, default, or file path was read in the source listed above. Doc-only claims are marked **[docs]**. Paper-only claims are marked **[paper]**. Anything I did not read is marked **[inferred]** and should be treated as a guess. I did **not** run ReDel, and I did not read `redel/tools/browsing/*`, `redel/embeddings.py`, or `viz/src/components/ChatMessages.vue` / `Drawer.vue` / `LoadSaveModal.vue`.

## What it is

ReDel is a Python research toolkit (MIT, ~2.5k LOC core) for *recursive* multi-agent systems: one root LLM agent gets a `delegate()` tool, and any agent it spawns may recursively get the same tool. Nobody hand-draws the agent graph — the models decide at runtime how deep and how wide to go. It is built on `kani` (same authors' LLM library); every agent is a `ReDelKani` subclass of `kani.Kani`. Its distinguishing features versus LangGraph/AutoGen/MetaGPT/AutoGPT/XAgent are: dynamic (runtime-constructed) graphs, parallel agents, an event bus with append-only logging, replayable runs, and a bundled web UI — the paper's Table 1 claims it is the only fully-open-source toolkit with all five [paper]. It is a *research demo*, not a production harness: no budget caps, no timeouts, no persistence beyond flat files, single-process asyncio.

## Mechanisms that matter

### Delegation schemes

**What it does.** A "delegation scheme" is a swappable class that defines *how* a parent hands work to a child and *how* it waits. It is a special kind of tool (`DelegationBase(ToolBase)`), so its `@ai_function`-decorated methods become the parent's function-calling surface.

**How it works.** Two bundled schemes, both in `redel/delegation/`:

- **`DelegateOne`** — exposes one function, `delegate(instructions: str)`. It calls `create_delegate_kani(instructions)`, wraps the child's whole run in `with self.kani.run_state(RunState.WAITING)`, drains `helper.full_round_stream(instructions, max_function_rounds=5)`, collects every ASSISTANT message with content, calls `await helper.cleanup()`, and returns `"\n".join(result)` as the tool result. The parent's Python coroutine is blocked for the child's entire run. Parallelism comes *only* from the LLM emitting multiple `delegate` tool calls in one turn (parallel function calling), which kani then runs concurrently. Note `max_function_rounds=5` is hardcoded with a `# TODO temp` comment — a silently-capped child.
- **`DelegateWait`** — exposes two functions, `delegate(instructions: str, who: str = None)` and `wait(until: str)`. `delegate` fires `asyncio.create_task(_task())` and returns immediately with the string `f"{helper.name!r} is helping you with this request."`. The parent keeps generating. `wait(until)` accepts a helper name, `"next"` (`asyncio.wait(..., FIRST_COMPLETED)`), or `"all"` (`ALL_COMPLETED`), and only then enters `RunState.WAITING`. `_task()` wraps the child in try/except and, on exception, returns the string `f"encountered an exception: {e}"` as the result — errors are surfaced to the parent as prose, not raised. `who=` lets a parent re-address a *previous* helper for a follow-up turn (multi-turn delegation), replying `"{who} is currently busy"` if that helper still has an outstanding future.

Both schemes contain the same anti-lazy guard: `rapidfuzz.fuzz.ratio(instructions, self.kani.last_user_message.content) > 80` → refuse and return a scolding string telling the model to break the task up. This is a prompt-level defense against pure pass-through delegation.

**Scope of the choice: global per session.** `delegation_scheme` is a single `type` on the `ReDel` constructor (`delegation_scheme: type | None = DelegateWait`), read by `ReDelKani.register_child_kani` for every child. There is no per-agent or per-role override. Setting it to `None` disables delegation entirely.

**Which suits an unattended overnight run.** `DelegateWait`. Reasons, all from source: (a) it does not pin a parent coroutine per in-flight child, so a wide tree does not consume one blocked frame per branch; (b) `wait("all")` gives a natural join point for fan-out; (c) `who=` supports follow-up rounds without respawning context; (d) failures come back as text the parent can react to rather than propagating an exception. Its known cost — stated by the authors — is **zombie agents**: if the parent never calls `wait()` on a child, that child's task runs (and bills) with nobody consuming its result. "From our testing, this is a fairly rare occurrence" [paper]. `DelegateOne` is the safer default only because a synchronous call graph cannot leak; the paper's own benchmark runs used `DelegateOne` [paper §4.1].

**Verdict: ADAPT.** sprout wants `DelegateWait` semantics (non-blocking spawn + explicit join) but must fix the zombie hole with a supervisor that tracks unclaimed children — and it should make the scheme selectable per node, not per session.

### The delegation interface (what a child actually receives)

**What it does.** Defines the entire parent→child contract.

**How it works.** `DelegationBase.create_delegate_kani(instructions)` delegates to `ReDelKani.create_delegate_kani` (`redel/kanis.py`), which:
1. picks a name from `Namer` — a plain `itertools.cycle` over the 24 lowercase Greek letters (`alpha`…`omega`), *per-parent*, so names repeat across the tree;
2. constructs `ReDelKani(app.delegate_engine, app=..., parent=self, name=name, dispatch_creation=False, system_prompt=app.delegate_system_prompt, **app.delegate_kani_kwargs)` — `depth = parent.depth + 1`, `id = uuid4()`;
3. calls `register_child_kani`, which attaches the delegation scheme (unless at the depth cap) and every tool whose config has `always_include: True`, then `app.on_kani_creation(kani_inst)` → dispatches `KaniSpawn`;
4. dispatches `KaniDelegated(parent_id, child_id, parent_message_idx, child_message_idx, instructions)`.

**The child receives exactly two things: a system prompt template and the instruction string.** `DEFAULT_DELEGATE_PROMPT` is a fixed paragraph with `{name}` and `{time}` substituted at every `get_prompt()` call (so the clock is always current). Crucially the child gets **no parent chat history, no task tree, no shared scratchpad**, and `DelegateOne`'s function docstring says so to the model: *"NOTE: Helpers cannot see previous parts of your conversation."* Everything the child needs must be re-serialized into `instructions` by the parent.

**The result comes back as the child's concatenated ASSISTANT text**, joined by `"\n"`, returned as the `delegate()`/`wait()` tool result. There is no structured return, no schema, no success/failure flag. The paper explicitly flags this as a customization point: *"having each child call a `set_result()` function to explicitly record its answer to a subtask instead of implicitly sending its chat output to the parent"* [paper §3.2] — i.e. the authors know free-text return is weak and did not fix it.

**Verdict: ADAPT.** Take the "child is context-isolated, parent must write a complete brief" discipline — it forces terseness. Reject free-text return: sprout needs a structured result (status, artifact refs, decisions recorded) since nobody is reading a chat transcript at 3am.

### The event system

**What it does.** One `asyncio.Queue` per session, drained by a single background task (`ReDel._dispatch_task`), fanning out to N listeners via `asyncio.gather(..., return_exceptions=True)`. Every subsystem (logger, websocket broadcaster, title generator) is just a listener.

**How it works.** `redel/events.py`. All events are Pydantic models extending `BaseEvent`, which has exactly two universal fields: `type: str` (a `Literal` discriminator) and `timestamp: float` (`default_factory=time.time`), plus a class flag `__log_event__ = True`. The complete built-in set (the docs page lists only 6 of these 11 — the source is the authority):

| `type` | Class | Fields beyond `type`/`timestamp` | logged? |
|---|---|---|---|
| `kani_spawn` | `KaniSpawn(KaniState, BaseEvent)` | `id, depth, parent, children, always_included_messages, chat_history, state, name, engine_type, engine_repr, functions` | yes |
| `kani_delegated` | `KaniDelegated` | `parent_id, child_id, parent_message_idx, child_message_idx, instructions` | yes |
| `kani_state_change` | `KaniStateChange` | `id, state` | yes |
| `tokens_used` | `TokensUsed` | `id, prompt_tokens, completion_tokens` | yes |
| `kani_message` | `KaniMessage` | `id, msg: ChatMessage` | yes |
| `root_message` | `RootMessage` | `msg: ChatMessage` (no `id`) | yes |
| `stream_delta` | `StreamDelta` | `id, delta, role` | **no** (`__log_event__ = False`) |
| `round_complete` | `RoundComplete` | `session_id` | yes |
| `session_meta_update` | `SessionMetaUpdate` | `title` | yes |
| `session_close` | `SessionClose` | `session_id` | **no** |
| `error` | `Error` | `msg` | yes |
| `send_message` | `SendMessage` (client→server) | `content` | yes |

Notable design points: `KaniSpawn` multiply-inherits `KaniState`, so a spawn event carries the agent's **entire state snapshot**, and its docstring says *"The ID can be the same as an existing ID, in which case this event should overwrite the previous state"* — spawn doubles as a state-restore event. `functions: list[AIFunctionState]` records each tool's `name, desc, auto_retry, auto_truncate, after, json_schema` — the log knows what the agent *could* have done, not just what it did. `RootMessage` fires *in addition to* `KaniMessage` for the root, a deliberate duplication so UI code can subscribe to just the human-facing channel. `StreamDelta` is dispatched per token from `BaseKani.chat_round_stream`/`full_round_stream` and is explicitly excluded from the log — high-frequency UI-only events are separated from the durable trace by a class flag.

Custom events: subclass `BaseEvent`, give it a `Literal` `type`, call `self.app.dispatch(MyEvent(...))` from anywhere (typically a tool). Nothing registers them; the discriminator is the whole contract [paper Fig. 4].

State enum (`redel/state.py`): `RunState = {STOPPED, RUNNING, WAITING, ERRORED}`. `BaseKani.set_run_state` no-ops if unchanged (dedupe at the source), and `run_state()` is a context manager pushing/popping a `_old_state_stack`, so nesting restores correctly.

**Verdict: PORT.** This is the single most transferable piece. A discriminated-union event model, a `__log_event__`-style loggable flag separating durable trace from UI chatter, a state snapshot embedded in the spawn event, and one queue → many listeners is exactly what sprout's Revali daemon + Jaspr UI need.

### Logging & replay

**What it does.** Every loggable event is appended to a JSONL "append-only file" (the code literally calls it `aof_path`), plus a periodic full-state snapshot.

**How it works.** `redel/eventlogger.py`. Per session, `$REDEL_HOME/instances/{session_id}/` (default `~/.redel/instances/`, overridable via `$REDEL_HOME`) contains exactly two files:
- `events.jsonl` — one `event.model_dump_json()` per line, opened with `buffering=1` (line-buffered, so a crash loses at most the current line). Opened lazily via `@cached_property` so an idle session creates no directory. On reopen it re-reads the file to rebuild `event_count: Counter`.
- `state.json` — `{id, title, last_modified, n_events, state: [KaniState...]}`, rewritten by `write_state()` on **every `RoundComplete`** (autosave) and on close. `n_events` is described in the docstring as *"a basic checksum against the AOF to check validity"*.

`session_id` is `f"{int(time.time())}-{uuid.uuid4()}"` — time-sortable.

**Replay granularity is one event.** The frontend does full bidirectional replay in `viz/src/redel/state.ts`: `handleEvent(e)` (forward) and `undoEvent(e)` (backward), plus an index into the event array. `undoKaniSpawn` removes the child from the parent's `children` and deletes it from `kaniMap`; `undoKaniMessage` pops the last message with a `console.warn` sanity check comparing content. **`undoKaniStateChange` is lossy** — the comment says *"this is a best-effort guess since we don't actually know the previous state"* and it heuristically maps `running→waiting`, `waiting|stopped→running`, else `stopped`. So node colors are approximate when scrubbing backward. That is a direct consequence of `KaniStateChange` carrying only the new state.

Replay is client-side over the whole event array: `GET /api/saves/{id}/events` returns the entire JSONL as a JSON array in one shot. Fine for a demo, will not survive a 12-hour run.

A save can also be **resumed**: `POST /api/saves/{id}/load` with `{"fork": bool}` rebuilds live `ReDelKani` objects by DFS over `state.json`'s `children` lists, inside `redel.logger.suppress_logs()` so reconstruction emits nothing. `fork: true` copies the AOF to a new session dir; `fork: false` reattaches to the original.

**Verdict: PORT (the shape), ADAPT (the mechanics).** Append-only event log + periodic snapshot + snapshot-carries-event-count-as-checksum is the right persistence model for Zonai. But sprout must add: prev-state in the state-change event (so undo is exact), and paged/ranged event fetch.

### Recursion control

**What it does / how it works.** Exactly one control exists: `max_delegation_depth: int = 8` on the `ReDel` constructor. Enforcement is one line in `ReDelKani.register_child_kani`:

```python
if self.app.delegation_scheme is None or self.depth == self.app.max_delegation_depth:
    delegation_scheme_inst = None
```

The child simply is not given the `delegate` tool. Note `self` is the **parent**, so a parent at depth 8 produces a tool-less child at depth 9 — **the deepest node is `max_delegation_depth + 1`, and the deepest *delegating* agent is at depth 8.** This contradicts the constructor docstring ("Kanis created at this depth will not inherit from the delegation_scheme class"), which is off by one. Also note `==` not `>=`; it is correct only because no path can skip a level.

**There is nothing else.** I grepped the whole Python package: no token budget, no dollar budget, no wall-clock timeout, no fan-out/breadth cap, no max-agents cap, no root supervisor, no cancellation API. The only adjacent limits are `retry_attempts=10` (kani default override in `ReDelKani.__init__`) and `DelegateOne`'s hardcoded `max_function_rounds=5`. The paper confirms runaway recursion is a real failure mode: undercommitting agents *"entered an infinite loop of delegation until they reached a configured depth limit or timed out"* [paper §5] — the "timed out" refers to their experiment harness, not to ReDel.

Measured undercommitment rates (chains of ≥3 agents with ≤1 child each) [paper Table 3]: GPT-4o — FanOutQA 11.3%, TravelPlanner 0.5%, WebArena **44.8%**. Overcommitment (graph of ≤2 agents): GPT-4o — 22.7% / 41.1% / 31.3%; GPT-3.5-turbo TravelPlanner **96.7%**.

**Verdict: ADAPT (depth cap), SKIP (everything else — there is nothing else to port).** Depth 8 is a reasonable order of magnitude for a cap, but sprout must add a token/cost budget that decrements down the tree, a per-node wall clock, a breadth cap, and cancellation. A 44.8% undercommitment rate on the hardest benchmark means an unattended run will burn money on delegation chains that do no work.

### Root/state management

**What it does.** Tracks the live tree.

**How it works.** Three overlapping structures:
- `ReDel.kanis: WeakValueDictionary[str, BaseKani]` — id → agent, weak so finished agents can be collected. They survive only because `on_kani_creation` also does `ai.parent.children[ai.id] = ai` (a *strong* dict on the parent), so the tree is held by parent links from the root down.
- Each `BaseKani` holds `parent`, `children: dict[str, BaseKani]`, `depth`, `id`, `name`, `state`.
- The serialized view is `KaniState.from_kani(ai)`, a flat list — the tree is reconstructed from `parent`/`children` id references, not nesting. This is what goes in `state.json` and in `KaniSpawn`.

There is no central scheduler and no supervisor loop. Concurrency is implicit in asyncio: a parent awaiting a child *is* the join. The whole session is one process, one event loop.

**Verdict: ADAPT.** The flat-list-plus-id-references shape is right for a wire format and for Zonai. The weak-map-plus-strong-parent-links trick is a Python GC artifact sprout does not need and should not imitate.

## The web UI, in detail

Stack: Vue 3 + TypeScript SFCs, Bulma CSS, **d3 v7** for the graph, `markdown-it` + `markdown-it-highlightjs` for message rendering, `axios` for REST, FontAwesome icons, `autosize` for the textarea. Served by FastAPI/uvicorn at `127.0.0.1:8000`, with the built SPA mounted at `/` via `StaticFiles(..., html=True)`. Four views (`viz/src/views/`).

**Transport — hybrid REST + WebSocket, no polling.** Initial hydration is `GET /api/states/{session_id}` → `SessionState` (full tree snapshot). Then `InteractiveClient.connect()` opens `ws://…/api/ws/{session_id}` and every subsequent update is a pushed event. The client is *event-sourced after first load*: `onRawMessage` JSON-parses, calls `state.handleEvent(msg)` to mutate the local model, then re-dispatches it on a DOM `EventTarget` under its own `type` name so components can subscribe selectively (`client.events.addEventListener("kani_message", ...)`). The socket is bidirectional: the client sends `{"type":"send_message","content":"…"}` upstream. Reconnect is exponential-ish backoff, `attempt * 1000 + random()*1000` ms, `maxAttempts = 5`, skipped on a clean close (except code 1012). REST endpoints: `GET/POST /api/states`, `GET /api/states/{id}`, `GET /api/saves`, `GET/DELETE /api/saves/{id}`, `GET /api/saves/{id}/events`, `POST /api/saves/{id}/load`. Interactive FastAPI docs at `/docs` [docs].

**1. Home** (`Home.vue`). A centered welcome box, three clickable cards (Load a saved session → modal; Read the paper; View code on GitHub), and a single auto-sizing textarea at the bottom: "Or type here to start a new session…". Enter → `POST /api/states {start_content}` → router push to `/interactive/{id}`. A sidebar (`Drawer.vue`, not read) lists interactive sessions already started [paper Fig. 5a].

**2. Interactive** (`Interactive.vue`) — two equal columns, full viewport height.
- **Left column, top:** a thin toolbar showing only `state.meta?.title || "Untitled Session"`. The title is **LLM-generated**: `ReDel.create_title_listener` fires once `event_count["root_message"] >= 4`, spawns a throwaway `Kani` and asks for a "~5 words, descriptive" title, then dispatches `SessionMetaUpdate` and removes itself as a listener.
- **Left column, body:** the **root node's chat history only** (`ChatMessages` bound to `state.rootKani`). Message components are per-role: `UserMessage`, `AssistantMessage`, `AssistantFunctionCall`, `AssistantThinking`, `AssistantStream`, `FunctionMessage`, `SystemMessage` — function calls and thinking get their own visual treatment rather than being dumped as text.
- **Left column, bottom:** a textarea, `:disabled="state.rootKani?.state !== RunState.stopped"`. **You cannot type while the system is running.**
- **Right column, top: the delegation graph** (`Tree.vue`, deliberately plain JS "because d3 is wack"). A `d3.forceSimulation` in a 1000×500 viewBox with `forceManyBody().strength(-200)`, `forceLink().distance(55).strength(3)`, and x/y centering forces. Nodes are r=14 circles with stroke-width 3, **draggable** (`d3.drag` with `fx`/`fy` pinning, released on drag end). Node fill encodes run state — selected `#a9e5ff` (blue) beats everything, else running `#9af362` (green), waiting `#fffe48` (yellow), errored `#FF9B9B` (red), stopped `#ddd` (grey) or `#fff` for the root. Node **label is a glyph, not text**: `☆` for the root (depth 0), `∑` if the name ends in "summarizer", otherwise the actual Greek letter for the agent's Greek-letter name (α, β, γ…). SVG `<title>` gives `"{name} ({id})"` on hover. `update()` recycles old node objects by id to preserve position and velocity across re-layouts, so the graph doesn't jump when a node is added.
- **Right column, middle:** one line — `Selected: {name}-{depth}`.
- **Right column, bottom:** the selected node's **full message history**, scrollable, or "Click on a node on the tree above to view its state."
- Redraw discipline is explicit and cheap: `kani_message` → `tree.update()` (relayout), `kani_state_change` → `tree.updateColors()` (recolor only). Streaming tokens repaint the message panes but never touch the graph.

**3. Save Browser** (`LoadSaveModal.vue`, described in paper Fig. 5c and `indexer.py`). `find_saves()` recursively walks each configured save root looking for directories containing `state.json`. Each row shows title (or `<No title - ID …>`), the directory path it was found in, last-modified as a locale datetime, and **event count**. Sortable by name, edit time, or event count; searchable by title. The paper says sorting by event count exists specifically so *"users can quickly find outliers at a glance"* — a runaway or a stall is a count anomaly.

**4. Replay** (`SaveViewer.vue`). Layout identical to Interactive; the message bar is swapped for a replay bar. Loads `GET /api/saves/{id}` (state) + `GET /api/saves/{id}/events` (full array), then sets `replayIdx = n_events` (start at the end). Seven controls in one row: `<` back one event, `<<` previous message in *selected* node, `<<<` previous *root* message, a range slider, `>>>` next root message, `>>` next message in selected node, `>` forward one event, and a live `{replayIdx} / {events.length}` counter. `setReplayTarget(idx)` slices the event array forward (`handleEvent`) or reversed-backward (`undoEvent`), and only calls `tree.update()` if the slice contained a `kani_message` or `kani_spawn` — an explicit "does this event change topology?" test. The toolbar adds **Load** and **Fork** buttons that turn the replay back into a live session.

**What a naive implementation would not have thought to show:**
1. **A stall or a loop is legible from graph *shape* alone.** The paper's whole error analysis rests on this: overcommitment = a 2-node graph; undercommitment = a long thin chain (Fig. 6). Colour + topology, no text.
2. **Event count as a first-class, sortable session attribute.** It is the cheapest possible anomaly detector across hundreds of runs.
3. **The selected-node message pane is a peer of the root chat, not a modal.** Two histories on screen at once — what the user asked for, and what one agent is actually doing.
4. **Per-node position/velocity is preserved across relayouts.** Without this, the tree reshuffles on every spawn and the human loses their place — fatal for a long-running view.
5. **Replay has "next message in *this* node" as a distinct control from "next message anywhere."** Following one agent through a run is a different task from following the run.
6. **Function calls and "thinking" get dedicated message components**, so tool traffic is skimmable rather than buried in prose.
7. **The auto-generated 5-word session title.** Nobody names their sessions; the system does it after 4 root messages.
8. **`__log_event__ = False` on stream deltas.** The UI gets token-level liveness; the durable log doesn't get 100k junk lines.

**What it does not have:** no per-node timers ("running since", "next check-in"), no token/cost display anywhere in the UI despite `TokensUsed` being logged, no way to message a non-root node, no cancel/pause, no notification when a long run finishes (there is a `Notifications` class but it only surfaces HTTP/WS errors), no tree collapsing or virtualization, and no rendering of `KaniDelegated` — `state.ts`'s `handleEvent` switch handles only `kani_spawn`, `kani_state_change`, `kani_message`, `root_message`, `stream_delta`, `session_meta_update`; `kani_delegated`, `tokens_used`, `round_complete` and `error` fall to `console.debug("Unknown event:")`. **The instruction text on each delegation edge is logged but never shown.** Also, `API_BASE`/`WS_BASE` are hardcoded to `http://127.0.0.1:8000` in `api.ts`.

## Anti-patterns and limitations

1. **Free-text results.** A child returns joined ASSISTANT prose. No status, no structure, no failure signal. The authors name the fix (`set_result()`) and don't ship it [paper §3.2].
2. **Zombie agents.** `DelegateWait` can orphan a running child forever if the parent never calls `wait()`. Author-acknowledged; unmitigated in code.
3. **Depth cap is the only guardrail.** No budget, no timeout, no breadth cap, no cancel. Confirmed by grep over the whole package.
4. **Off-by-one depth cap** and a docstring that contradicts the code.
5. **Lossy state undo in replay** because `KaniStateChange` omits the previous state.
6. **Root-only human input**, and it's disabled while the system runs. There is no "steer a subordinate" concept anywhere in ReDel — nothing analogous exists in the codebase. The only client→server message type is `SendMessage` to the root queue, and `server.py` has the comment `# todo additional message types`.
7. **Whole-log-in-one-response replay** (`list(read_jsonl(...))` server-side, full array client-side).
8. **Single process, single event loop, in-memory session registry** (`self.interactive_sessions: dict`). Server restart drops every live session; only saves survive.
9. **`asyncio.gather(..., return_exceptions=True)` in the dispatcher swallows listener errors** — a broken listener fails silently.
10. **Greek names repeat.** `Namer` is per-parent and cycles after 24, so `beta` is ambiguous across the tree; the UI compensates by rendering `{name}-{depth}`.
11. **No formal Limitations or Ethics section in the paper** (it's a 4-page demo), so nothing is documented about failure modes beyond §5's over/undercommitment analysis.
12. **Measured failure rates are high.** Overcommitment 22.7–41.1% and undercommitment up to 44.8% with GPT-4o [paper Table 3]. Recursive delegation is not reliable unsupervised on 2024 models — sprout's premise depends on this having improved, or on structural mitigation.

## Takeaways for sprout

1. **Port the discriminated-union event model wholesale.** Every event = `{type: <literal>, timestamp, ...}`, sealed Dart classes with a `type` discriminator, one queue → many listeners. This is ReDel's best idea and it is language-agnostic. Zonai persists them; Jaspr replays them.
2. **Copy the `__log_event__` split.** Mark high-frequency UI-only events (token streams, cursor pings) as non-durable so a 12-hour run's log stays analyzable. sprout should be stricter still: log decisions and transitions, stream everything else.
3. **Embed a full node-state snapshot in the spawn event and make spawn idempotent** (same id ⇒ overwrite). ReDel's `KaniSpawn extends KaniState` means a client can hydrate from the log alone with no separate bootstrap path. Do the same.
4. **Put `prevState` in the state-change event.** ReDel's omission forces a lossy `undoKaniStateChange` heuristic. One extra field buys exact bidirectional replay — and sprout's replay matters more, because the developer was asleep.
5. **Adopt `DelegateWait` semantics but make the scheme per-node, not per-session.** ReDel's `delegation_scheme` is one global class. sprout's supervisor nodes want non-blocking fan-out; leaf-adjacent nodes want blocking simplicity. Same interface, chosen at spawn time.
6. **Close the zombie hole with a reaper.** Track every spawned child against the parent's outstanding-join set; if a parent goes STOPPED with unjoined children, that is an error state the UI must show and the supervisor must resolve — not a silent leak. This is the concrete bug ReDel ships with.
7. **Structured results, not chat text.** A sprout child returns `{status, summary (≤N chars), artifacts, decisions[]}`. The "decisions" list is exactly where sprout's RECORDED-not-escalated choices (question / options / choice / reason) live, and it must be part of the return contract, not a log side-effect. ReDel has no equivalent and its authors flag the gap.
8. **Keep the child context-isolated and force the parent to write a complete brief.** ReDel's `"Helpers cannot see previous parts of your conversation"` in the delegate docstring is a feature: it makes vague delegation fail fast and keeps briefs terse. Adopt it verbatim in sprout's delegate tool description.
9. **Ship the anti-passthrough guard.** ReDel's `fuzz.ratio(instructions, last_user_message) > 80 → refuse` is 4 lines and directly attacks the 44.8%-undercommitment failure mode. sprout should generalize it: refuse a delegation whose brief is near-identical to the node's own task.
10. **Budget must decrement down the tree; depth alone is insufficient.** Give every node a token/dollar/wall-clock allowance drawn from its parent's remainder, refuse spawns that would overdraw, and surface remaining budget per node in the UI. ReDel has none of this and is unsafe to leave running.
11. **Fix the depth-cap off-by-one and use `>=`.** Cap the *child's* depth, not the parent's. Default ~8 is a defensible starting number.
12. **UI: encode run state as node fill and let shape carry diagnosis.** Green/yellow/grey/red on a force-directed tree let the ReDel authors classify failures at a glance. sprout must add what ReDel lacks and the brief demands: **running-since**, **next-check-in**, and current task string on every node. Rendering these as small labels/rings on the node, not a side table, keeps the "whole tree top-to-bottom" property.
13. **Render the delegation edge label.** `KaniDelegated.instructions` is exactly "what did the parent ask for", it is already logged, and ReDel throws it away in the UI. In sprout that string is the node's *current task* — the single most important thing on screen.
14. **Preserve node positions across relayouts and stream over WebSocket, never poll.** ReDel's node recycling by id and its REST-hydrate-then-WS-push pattern are both directly reusable in Jaspr/Revali.
15. **Session-level anomaly signal in the list view.** ReDel sorts saves by event count to spot outliers. sprout's session list should surface event count, spend, and time-since-last-event — a stalled overnight run is a *missing* event, and only the list view can show that.
16. **Add the steer path ReDel doesn't have.** ReDel's only client→server message is `SendMessage` to the root, disabled while running. sprout needs `Steer{nodeId, text}` accepted mid-run, injected into the target's next turn, and propagated to subordinates — model it as a first-class event so it lands in the log and the replay too.
17. **Two-pane discipline: root narrative + selected-node detail, always both.** ReDel's layout is the right answer for "what is the system doing" vs. "what is this agent doing", and it costs no extra screen.

## Open questions

1. **Does `DelegateWait` actually work well in practice?** The paper's benchmark runs all used `DelegateOne` [paper §4.1] — the scheme the authors recommend for parallelism is the one they did **not** evaluate. Their zombie-rate claim ("fairly rare") is unsourced. *Answered by:* running both schemes on the released logs (`https://datasets.mechanus.zhu.codes/redel-dist.zip`, ~their full experiment logs) or instrumenting a `DelegateWait` run and counting unjoined `KaniDelegated` children.
2. **How large do real delegation trees get?** No node-count or depth distribution is published, so I cannot say whether ReDel's UI (unvirtualized d3 force layout) survives 50+ nodes, or what depth is typically reached against the cap of 8. *Answered by:* aggregating `kani_spawn` events per session over the released `redel-dist.zip` logs.
3. **What does the UI do on a multi-hour run?** Every event since page load accumulates in memory (`kaniMap`, per-node `chat_history` arrays); nothing is paged or evicted. Whether the interactive view degrades is untested here. *Answered by:* a long soak run, or reading the memory behaviour of `ChatMessages.vue` (which I did not read).
4. **Is there any cancellation path at all?** `SessionManager.close()` calls `self.task.cancel()` on the whole session, but I found nothing that cancels a single subtree. *Answered by:* reading `redel/tools/browsing/impl.py` and `terminal.py`/`server.py` at repo root, which I did not read.
5. **Has ReDel moved since the EMNLP release?** I read `@main` and the paper is from Nov 2024; I did not check the commit log or releases for post-paper changes (e.g. whether `max_function_rounds=5`'s `TODO temp` was resolved). *Answered by:* `git log`/releases on the repo.
6. **What is in `docs/experiments.md`?** Not read. It likely documents the exact configs (depth, engines, tool sets) used for FanOutQA/TravelPlanner/WebArena, which would give real-world defaults rather than constructor defaults. *Answered by:* reading that page.
