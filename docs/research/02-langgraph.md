# LangGraph — research notes

**Sources:** (all read 2026-08-31)
- https://docs.langchain.com/oss/python/langgraph/persistence
- https://docs.langchain.com/oss/python/langgraph/checkpointers
- https://docs.langchain.com/oss/python/langgraph/interrupts
- https://docs.langchain.com/oss/python/langgraph/streaming
- https://docs.langchain.com/oss/python/langgraph/graph-api
- https://docs.langchain.com/oss/python/langgraph/use-subgraphs
- https://docs.langchain.com/oss/python/langgraph/use-time-travel
- https://docs.langchain.com/oss/python/langchain/multi-agent
- https://reference.langchain.com/python/langgraph/types/Durability
- https://reference.langchain.com/python/langgraph/checkpoints
- https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/checkpoint/langgraph/checkpoint/base/__init__.py (Checkpoint TypedDict, source of truth)
- https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/langgraph/langgraph/pregel/main.py (durability default)
- https://raw.githubusercontent.com/langchain-ai/langgraph/main/libs/checkpoint-postgres/langgraph/checkpoint/postgres/base.py (DDL)
- https://raw.githubusercontent.com/kyoron2/LangChain-projectsdocs/main/src/oss/langgraph/durable-execution.mdx (mirror of upstream durable-execution.mdx; primary URL kept redirecting)
- https://www.langchain.com/blog/command-a-new-tool-for-multi-agent-architectures-in-langgraph
- https://github.com/langchain-ai/langgraph/issues/6446 (concurrent-update error in parallel subgraphs)

**Confidence:**
- **Verified in docs/source:** checkpoint schema, Postgres DDL, durability modes + default, `interrupt()` semantics and gotchas, stream modes, `checkpoint_ns` format, reducers, time travel.
- **Inferred (marked inline):** anything about non-blocking steering, depth limits, and sprout mappings.

---

## What it is (and why we care despite not using it)

LangGraph is a Python/JS runtime for graphs of "nodes" over a shared typed state, executed in BSP-style
**super-steps** (a "tick" where all scheduled nodes run, possibly in parallel). Its actual value to sprout is
not the graph API — it is the **persistence layer**: a well-shaped, battle-tested answer to "an agent process
died mid-run, how does it resume without redoing work." It also has the only mainstream, documented model for
**hierarchically namespaced checkpoints** (subgraph-within-subgraph), which is exactly sprout's recursive
delegation tree. Its human-in-the-loop story (`interrupt()`) is the *opposite* of what sprout wants — it is
strictly blocking — and that negative result is itself useful. Streaming with `subgraphs=True` is a direct
blueprint for sprout's live tree UI.

---

## Mechanisms that matter

### Checkpoint + thread model
**What it does.** Persists the entire graph state at super-step boundaries, keyed by thread, so any run can be
resumed, inspected, replayed, or forked.
**How it works.** Three identifiers, all passed under `config["configurable"]`:
- `thread_id` — the run/conversation. Primary key. Required for any checkpointed invocation. (Postgres impl
  caps it at 255 chars.)
- `checkpoint_id` — one snapshot within a thread. Monotonically increasing (uuid6). Omit → latest.
- `checkpoint_ns` — **which graph owns this checkpoint.** `""` = root. A subgraph gets `"node_name:<task_uuid>"`.
  Nesting joins with `|`: `"outer_node:uuid|inner_node:uuid"`. Source constants: `NS_END` = the `:` between task
  name and task id, `NS_SEP` = the `|` between levels. Readable inside a node via
  `config["configurable"]["checkpoint_ns"]`.

**Why it matters for sprout.** `thread_id` = one sprout run. `checkpoint_ns` = the **path of the agent in the
delegation tree**. This gives you a single flat table that stores an arbitrarily deep tree, with the tree
structure encoded in a sortable/prefix-matchable string. Prefix query `checkpoint_ns LIKE 'root:x|%'` = "all
descendants of this agent."
**Verdict: PORT** — the `(thread_id, checkpoint_ns, checkpoint_id)` triple is the right primary key for sprout.

### Durability modes
**What it does.** Trades write cost against crash-recovery granularity.
**How it works.** `durability: Literal["sync","async","exit"]`, passed per-call to `stream`/`invoke`.
- `"sync"` — persisted **before the next step starts**. Highest durability, most overhead.
- `"async"` — persisted **while the next step executes**. Small window where a crash loses the checkpoint.
- `"exit"` — persisted **only when the graph exits** (success, error, or interrupt). Fastest; no mid-run recovery.
- **Default is `"async"`** — verified in `pregel/main.py`: `durability = config.get(CONF, {}).get(CONFIG_KEY_DURABILITY, "async")`.

**Why it matters for sprout.** sprout's whole premise is surviving crashes/usage-limits mid-run, so `"exit"` is
useless and `"async"` is a real (if narrow) data-loss window. sprout's checkpoint writes are cheap compared to an
LLM call, so the tradeoff LangGraph agonizes over mostly does not apply.
**Verdict: ADAPT** — keep the *concept* of a durability knob, but default to sync. **[inferred]** The write cost
is noise next to a multi-second model call.

### Pending writes (the underrated one)
**What it does.** Makes recovery finer-grained than "re-run the whole super-step."
**How it works.** Two-level persistence. As each node in a super-step finishes, its output is written
immediately to the `checkpoint_writes` table as a task-scoped row (`task_id`, `idx`, `channel`, `blob`). Only
after *all* nodes in the step finish is the full checkpoint committed. If node B crashes while A and C
succeeded, A's and C's writes are already durable — on resume they are **not re-run**, only B is.
Special writes use negative `idx` via `WRITES_IDX_MAP`: `ERROR=-1`, `SCHEDULED=-2`, `INTERRUPT=-3`, `RESUME=-4`.
**Why it matters for sprout.** A supervisor that fanned out to 5 subordinates and died must not re-spawn the 3
that already finished. This is precisely that mechanism.
**Verdict: PORT** — sprout needs a per-child completed-work table separate from the parent's committed state.

### `interrupt()` / `Command(resume=...)`
**What it does.** Pauses the graph mid-node for human input.
**How it works.** `interrupt(payload)` **throws a special exception** (`GraphInterrupt`) that unwinds to the
runtime, which checkpoints and stops. The value surfaces on `result["__interrupt__"]` (or `stream.interrupts` /
`stream.interrupted` with `stream_events(version="v3")`). You resume by invoking with the **same `thread_id`** and
`Command(resume=value)`; that value becomes the return value of the original `interrupt()` call. Static variants
`interrupt_before` / `interrupt_after` set node-boundary breakpoints (docs call these debugging tools).
**It is fully blocking.** Docs: the system "waits indefinitely until you resume execution."
**Why it matters for sprout.** This is the anti-requirement. sprout wants steer-without-blocking. LangGraph has
**no documented non-blocking human-input mechanism** — the closest thing is `get_stream_writer()` custom events,
which are notify-only (agent → human), never human → agent mid-flight.
**Verdict: SKIP the mechanism, PORT the resume-token idea.** sprout's steer should be a *state channel a running
agent polls*, not an exception that halts it.

### Streaming / `subgraphs=True`
**What it does.** External observation of a running graph at chosen granularity.
**How it works.** `stream_mode` ∈ `values` (full state after each step) | `updates` (changed keys only, per node)
| `messages` (`(token, metadata)` LLM tokens) | `custom` (whatever a node writes via `get_stream_writer()`) |
`checkpoints` (persisted snapshots; needs checkpointer) | `tasks` (node start/finish + errors; needs checkpointer)
| `debug` (checkpoints + tasks + extras). A list of modes can be passed at once.
With `version="v2"` every chunk is a uniform `StreamPart`: `{"type": <mode>, "ns": <tuple>, "data": ...}`.
`subgraphs=True` populates `ns` with the path tuple: `()` at root, `("parent_node:<task_id>", "child_node:<task_id>")`
at depth 2 — the same namespace path as `checkpoint_ns`.
**Why it matters for sprout.** This is literally sprout's UI feed: one subscription at the root yields events
from every node at every depth, each tagged with its tree path. `custom` is how a node reports "current task"
and "next check-in" without polluting state.
**Verdict: PORT** — the `{type, ns, data}` envelope plus a `custom` writer channel is the whole UI protocol.

### State: channels + reducers
**What it does.** Defines how concurrent node outputs merge.
**How it works.** State is a `TypedDict`/dataclass/Pydantic model; each key is an independent **channel**. Per-key
reducer via `Annotated[list, add_messages]` or `Annotated[list[str], operator.add]`. Applied as
`new = reducer(current[key], update[key])`. **No reducer = last-write-wins overwrite**, and if two nodes write the
same reducer-less key in the same super-step you get `InvalidUpdateError` (`INVALID_CONCURRENT_GRAPH_UPDATE`,
"can receive only one value per step"). Separate `input_schema` / `output_schema` / private channels are
supported; caveat — **private channels are not redacted when streaming with `stream_mode="values"`**; use
`output_keys` to restrict. `Send("node", payload)` from a conditional edge does dynamic map-reduce fan-out.
`CachePolicy(ttl=...)` gives per-node result caching keyed on inputs (`{'__metadata__': {'cached': True}}`).
**Why it matters for sprout.** Sprout's "decision record" list (question/options/choice/reason) is an append-only
channel with an `operator.add`-style reducer — N subordinates append concurrently and nothing is lost. The
overwrite-by-default rule is a footgun worth inverting.
**Verdict: ADAPT** — append-reducer for records/logs; explicit single-writer for scalar status fields.

### Subgraph state flow
**What it does.** Parent → child → parent state handoff.
**How it works.** Two patterns.
1. **Shared keys** — pass the compiled subgraph straight to `add_node()`. State flows directly; no wrapper.
2. **Different schemas** — call the subgraph *inside* a node function that maps parent state → subgraph input and
   subgraph output → parent update. Docs say this is the common multi-agent shape (agents keep independent
   message histories).
`.compile(checkpointer=...)`: `None` (default) — fresh per invocation but **inherits the parent's checkpointer**
so interrupts work; `True` — state accumulates across calls on the same thread; `False` — stateless, no durable
execution, and subgraph state becomes invisible to `get_state`. Docs/issues recommend **only the parent graph
carries a checkpointer**. Inspecting a paused child: `graph.get_state(config, subgraphs=True).tasks[0].state`.
Viewing subgraph state requires the subgraph be **statically discoverable** (added as a node, or called inside one).
**Why it matters for sprout.** Pattern 2 is sprout's delegation contract: the parent hands a subordinate a
*brief*, not its whole context, and gets a *result* back. Context isolation is the point.
**Verdict: PORT pattern 2, SKIP pattern 1** — shared mutable state across agent boundaries is how you get the
concurrent-update error (issue #6446: parallel subgraphs writing shared keys).

### Time travel (replay / fork)
**What it does.** Re-run from, or branch off, a past checkpoint.
**How it works.** `get_state_history(config)` → `StateSnapshot`s, newest first. **Replay:** invoke with that
checkpoint's config and `None` as input. Nodes *before* the checkpoint are skipped (results already saved);
nodes *after* re-execute **for real** — docs are blunt: "Replay re-executes nodes—it doesn't just read from cache.
LLM calls, API requests, and interrupts fire again and may return different results." Replaying the final
checkpoint is a no-op. **Fork:** `update_state(config, values, as_node=...)` on a past checkpoint. It "does not
roll back a thread. It creates a new checkpoint that branches from the specified point" — original history intact.
Updates go through reducers, so reducer-backed channels *accumulate* rather than overwrite. Metadata records
`source: "fork"`.
**Why it matters for sprout.** "You took a wrong turn at step 12" = fork at checkpoint 12, inject a corrective
state value, re-run forward. Immutable-append history means you never lose the bad branch (useful for the
decision record).
**Verdict: PORT** — fork-not-rollback is the right default for an unattended system.

### Multi-agent architectures / handoffs
**What it does.** Patterns for agents delegating to agents.
**How it works.** Current LangChain docs enumerate five patterns: **Subagents** (main agent calls subagents as
tools; all routing through the main agent; **stateless by design, for context isolation**), **Handoffs** (tool
calls flip a routing state var; stateful), **Skills** (one agent loads specialized knowledge; keeps control),
**Router** (classify then dispatch), **Custom Workflow**. Handoffs are implemented with `Command`: a node returns
`Command(update={...}, goto="agent_b")`, and `Command(goto=..., graph=Command.PARENT)` jumps to a node in the
**parent** graph — the mechanism that makes hierarchical (supervisor-of-supervisors) architectures expressible.
`langgraph-supervisor` packages the supervisor pattern.
**The warning the docs actually give:** "Not every complex task requires this approach—a single agent with the
right (sometimes dynamic) tools and prompt can often achieve similar results." No depth limit is documented, and
they explicitly bless mixing: "a subagents architecture can invoke tools that invoke custom workflows or router
agents."
**Why it matters for sprout.** LangGraph's official position is that recursion is *allowed and unbounded* but
that you should justify each layer. sprout's recursion is the product, so the guidance to internalize is the
cost warning, not a prohibition.
**Verdict: ADAPT** — take `Command.PARENT`-style explicit return-to-parent handoff; skip the tool-call framing.

---

## The checkpoint model, in detail

### `Checkpoint` (verbatim from `libs/checkpoint/.../base/__init__.py`, main branch)

```python
class Checkpoint(TypedDict):
    """State snapshot at a given point in time."""
    v: int                                    # format version
    id: str                                   # unique, monotonically increasing (uuid6)
    ts: str                                   # ISO 8601 timestamp
    channel_values: dict[str, Any]            # deserialized channel snapshots
    channel_versions: ChannelVersions         # monotonic version per channel
    versions_seen: dict[str, ChannelVersions] # node -> {channel: version last consumed}
    updated_channels: list[str] | None        # channels modified in this checkpoint
```

Notes:
- `LATEST_VERSION = 2`. The `v` docstring in source still reads "currently 1" — treat as stale. **[inferred]**
- **`pending_sends` is gone** from current `main`. It existed in v1 (holding `Send` payloads for the next step);
  v2 appears to fold that into channels + `updated_channels`. **[inferred]** — do not design around it.
- `versions_seen` is the load-bearing field: it is what lets the runtime decide, on resume, which nodes have
  *already consumed* which channel versions, i.e. what does **not** need re-running.

### `CheckpointMetadata`

```python
class CheckpointMetadata(TypedDict, total=False):
    source: Literal["input", "loop", "update", "fork"]
    step: int                        # -1 for input, 0+ for loop
    parents: dict[str, str]          # checkpoint_ns -> checkpoint_id  (the ancestor chain!)
    run_id: str
    counters_since_delta_snapshot: dict[str, tuple[int, int]]
```

`parents` is the explicit nesting link: for a subgraph checkpoint it maps each ancestor namespace to that
ancestor's checkpoint id. That is a materialized path up the agent tree.

### `CheckpointTuple` (what a saver returns)

```python
class CheckpointTuple(NamedTuple):
    config: RunnableConfig
    checkpoint: Checkpoint
    metadata: CheckpointMetadata
    parent_config: RunnableConfig | None = None
    pending_writes: list[PendingWrite] | None = None
```

### `StateSnapshot` (what the user-facing `get_state` returns)

| Field | Meaning |
|---|---|
| `values` | channel values at this checkpoint |
| `next` | `tuple[str, ...]` of nodes to execute next; `()` = done |
| `config` | `{thread_id, checkpoint_ns, checkpoint_id}` |
| `metadata` | `source`, `writes` (node outputs), `step` |
| `created_at` | ISO 8601 |
| `parent_config` | previous checkpoint's config; `None` for the first |
| `tasks` | `tuple[PregelTask, ...]` — `id`, `name`, `error`, `interrupts`, and optional **`state`** (the child's own snapshot) |

`tasks[].state` is how you drill into a paused subgraph. `next` is what makes "where was it?" a single field.

### Storage interface

```
get_tuple(config) -> CheckpointTuple | None
list(config, *, filter, before, limit) -> Iterator[CheckpointTuple]
put(config, checkpoint, metadata, new_versions) -> RunnableConfig
put_writes(config, writes, task_id, task_path="") -> None
delete_thread(thread_id) / copy_thread(src, dst) / prune(thread_ids, strategy="keep_latest")
```
Plus `a*` async twins. Serde defaults to `JsonPlusSerializer`; `EncryptedSerializer` (AES, pycryptodome) wraps it
for at-rest encryption. `MemorySaver` is explicitly test-only; `PostgresSaver` is the production one.

### Actual Postgres DDL (three tables)

```sql
CREATE TABLE checkpoints (
  thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', checkpoint_id TEXT NOT NULL,
  parent_checkpoint_id TEXT, type TEXT, checkpoint JSONB NOT NULL, metadata JSONB NOT NULL DEFAULT '{}',
  PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id));

CREATE TABLE checkpoint_blobs (           -- channel values stored out-of-line, versioned
  thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', channel TEXT NOT NULL,
  version TEXT NOT NULL, type TEXT NOT NULL, blob BYTEA,
  PRIMARY KEY (thread_id, checkpoint_ns, channel, version));

CREATE TABLE checkpoint_writes (          -- per-task pending/completed writes
  thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', checkpoint_id TEXT NOT NULL,
  task_id TEXT NOT NULL, idx INTEGER NOT NULL, channel TEXT NOT NULL, type TEXT, blob BYTEA NOT NULL,
  task_path TEXT NOT NULL DEFAULT '',     -- added by a later migration
  PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id, task_id, idx));
```

The blob split is the key design move: the checkpoint row holds only *pointers* (`channel_versions`), and channel
payloads are content-addressed by `(channel, version)`. Unchanged channels are not rewritten each step.

### Minimum viable checkpoint for sprout **[inferred, but derived directly from the above]**

A killed sprout agent can resume without redoing work given:
1. `(thread_id, checkpoint_ns, checkpoint_id)` — who am I, where in the tree, which snapshot.
2. `channel_values` (or version pointers into a blob table) — the agent's working state.
3. `next` / equivalent — what it was about to do.
4. `versions_seen` — what it has already consumed, so completed steps are not repeated.
5. `pending_writes` for the in-flight step — the results of siblings that finished before the crash.
6. `parents` / `parent_checkpoint_id` — the ancestor chain, to rebuild the tree and to report upward.
Items 4 and 5 are the ones people skip and then re-do work. Everything else in LangGraph's schema is optional.

---

## Anti-patterns and gotchas

1. **Code before `interrupt()` re-runs on resume.** Docs: "The node restarts from the beginning of the node where
   the interrupt was called when resumed, so any code before the interrupt runs again." Side effects before an
   interrupt must be idempotent (upsert, not create).
2. **Interrupt matching is strictly index-based.** Multiple `interrupt()` calls in one node are matched by call
   order. Conditionally skipping one, or a non-deterministic loop, silently mismatches resume values.
3. **Do not `try/except` around `interrupt()`** (it swallows the control-flow exception) and **do not `while True`**
   with an interrupt inside a node — use conditional edges.
4. **Replay is not a cache.** "LLM calls, API requests, and interrupts fire again and may return different results."
   Time travel is re-execution, not memoization.
5. **A failed task re-runs on resume.** Docs: if a task starts but fails, resumption re-runs it — non-idempotent
   operations risk "unintended duplication." Idempotency keys are on you.
6. **Non-determinism must be wrapped.** "you must wrap any non-deterministic operations (e.g., random number
   generation) and any operations with side effects inside tasks or nodes" — otherwise replay diverges.
   Granularity rule: "wrap each operation in a separate task," or the whole coarse task re-runs.
7. **Two nodes writing one reducer-less key in the same step = `InvalidUpdateError`.** Bites hardest with
   parallel subgraphs sharing state keys (issue #6446).
8. **Mixing `add_edge` with dynamic routing from the same node** runs *both* paths. Pick one per node.
9. **Private state channels leak into `stream_mode="values"`** — they are not redacted; restrict with `output_keys`.
10. **`checkpointer=False` on a subgraph silently makes its state invisible** to `get_state(subgraphs=True)`.
    Related: `checkpointer=True` on a subgraph causes duplicate storage; convention is parent-only.
11. **Default durability is `"async"`**, i.e. the out-of-the-box configuration has a real crash window. Nobody
    tells you this in the quickstart.
12. **Subgraph state is only inspectable if statically discoverable** (added as a node or invoked inside one).
    Dynamically constructed subgraphs are opaque to the observability APIs.

---

## Takeaways for sprout

1. **Adopt the `(thread_id, checkpoint_ns, checkpoint_id)` key in Zonai.** `checkpoint_ns` as a `|`-joined path of
   `agentName:taskId` segments makes the recursion tree a prefix query, not a join. This single decision buys
   tree reconstruction, scoped resume, and scoped streaming.
2. **Split the checkpoint row from the payload blobs.** Row holds `channel_versions` pointers; a
   `(namespace, channel, version)`-keyed blob table holds values. Unchanged state is not rewritten per step —
   essential when checkpointing every super-step over a multi-hour run.
3. **Implement pending-writes before anything else clever.** A per-task write log committed *as each child
   finishes*, separate from the parent's committed checkpoint. Without it, a supervisor crash re-spawns finished
   subordinates — the single most expensive failure mode for sprout.
4. **Persist `versions_seen` (or an equivalent consumed-marker).** It is what distinguishes "resume" from
   "restart from the last snapshot."
5. **Default to `durability: sync`, expose the knob.** LangGraph's `"async"` default optimizes a cost sprout does
   not have. Keep `"exit"` only for a fast local/dry-run mode.
6. **Do NOT copy `interrupt()`.** It is a blocking exception, and its documented gotchas (pre-interrupt code
   re-running, index-based resume matching) are inherent to "pause = unwind the stack." Instead: model **steer as
   an append-only channel** written by the UI and read by the agent at its own next-check-in boundary. The agent
   never unwinds; propagation to subordinates is namespace-prefix delivery (write to `ns` and all `ns|*`).
7. **Record-don't-escalate maps to a reducer channel, not an interrupt.** `decisions: Annotated[List<Decision>, append]`
   — every agent at every depth appends `{question, options, choice, reason}` concurrently, no conflict, and the
   UI reads the merged list. This is the pattern LangGraph uses for messages; reuse it verbatim.
8. **Steal the streaming envelope wholesale.** `{type, ns, data}` with `type ∈ {values, updates, custom, tasks,
   checkpoints}` and `ns` = the tree path. One root subscription feeds the entire Jaspr tree UI. Put
   "current task / since / next-check-in" on the `custom` channel so heartbeat traffic never touches persisted state.
9. **Emit `tasks`-style start/finish/error events per node.** That, plus `next`, is what makes the UI able to
   render "currently doing X since T" without inferring it from state diffs.
10. **Delegation = "call subgraph inside a node," never "share state keys."** Parent hands down a brief, child
    returns a result. Context isolation avoids issue-#6446-class concurrent-update failures and keeps subordinate
    token usage bounded.
11. **Fork, never roll back.** A steer that says "wrong turn" should create a new checkpoint branching from the
    named one, leaving the bad branch in history. Immutable history is also the audit log the decision-record
    requirement wants.
12. **Make each agent's unit of work explicitly idempotent and separately checkpointed.** LangGraph's "wrap each
    operation in its own task" rule exists because coarse tasks re-run wholesale. sprout's equivalent: checkpoint
    at every tool call boundary, and require tool calls to carry an idempotency key.
13. **Encode the ancestor chain in metadata** (`parents: {ns -> checkpoint_id}`). Cheap, and it makes "reconstruct
    the exact tree state at time T" a single-row read rather than a recursive walk.

---

## Open questions

1. **Steer delivery semantics.** LangGraph gives no precedent for non-blocking human→agent input mid-run. Does
   sprout deliver a steer at the next tool-call boundary (bounded latency, simple) or interrupt the in-flight
   model call (fast, but re-opens the "code before the pause re-runs" problem)? Unresolved by this research.
2. **Does sprout need `versions_seen` per-channel, or is a simpler per-node "last completed step" marker enough?**
   LangGraph's per-channel granularity exists for arbitrary DAGs; sprout's tree may be simpler. Needs a spike.
3. **Checkpoint cadence under long tool calls.** LangGraph checkpoints at super-step boundaries; a sprout agent
   may sit in one model call for minutes. What is the boundary — per tool call, per model turn, per N seconds?
4. **How does a resumed agent re-establish its LLM context?** LangGraph replays state, not conversation. sprout
   must decide whether a resumed agent re-reads its full transcript, a compacted summary, or only its checkpoint.
5. **Retention/pruning.** LangGraph offers `prune(strategy="keep_latest")` and `delete_thread`. A multi-hour
   deep-recursion run will produce a lot of checkpoints; sprout needs a retention policy that preserves fork
   points and decision records while discarding intermediate state.
6. **`v: 1` vs `LATEST_VERSION = 2` and the disappearance of `pending_sends`** — I could not find migration notes
   explaining the v1→v2 schema change. If sprout wants to mirror the schema closely, that delta is worth chasing.
7. **Depth limits.** No documented maximum nesting for LangGraph subgraphs, and no guidance on cost at depth.
   sprout needs its own budget/depth-cap policy; there is no prior art here to copy.
