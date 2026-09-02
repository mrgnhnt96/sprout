# sprout — Implementation Plan

**Status: SIGNED OFF 2026-08-31.** All six decisions accepted as recommended, including dropping
Zonai for in-process `package:sqlite3` (§13). Open follow-on: token-cost research (§14), requested
at sign-off — reduce cost, raise quality, keep the developer able to see what is happening.

**Supersedes** `00-vision.md` wherever they disagree. Every claim here traces to a doc in
`docs/research/`. Where research contradicted the vision, the research wins and the change is
called out explicitly under [§2](#2-where-the-research-overruled-the-vision).

---

## 1. What sprout is, restated after research

A single compiled Dart binary + a machine-wide daemon that runs real Claude Code sessions as a
**bounded, centrally-orchestrated tree**, observes them from **outside** the sessions, and shows
the whole tree live in a web UI — so a task can be given in one sentence and left alone for hours.

The one-line justification, which research sharpened into something stronger than the original
pitch:

> Every gate in game_loop and showrunner fires **from inside the session that stopped working**.
> A real run sat inert for six hours with the Stop gate, watchdog, and limit gate all reporting
> healthy. A stuck session cannot notice it is stuck.
> — `07-local-harnesses.md`

sprout's daemon is the watcher outside the session. That is the structural win, and it is the
thing neither existing harness can retrofit.

---

## 2. Where the research overruled the vision

Five changes. Each one narrows the original ambition, and each is evidence-backed.

### 2.1 "Arbitrarily deep" → **hard depth cap of 3, enforced in code**

The vision said recursion is "recursive by design, with hard limits." The literature says the
limits are the *whole* story and the depth budget is much smaller than assumed:

- RAH's entire recursion control is a static depth cap, **default 3** — and the authors state
  they never ablate it (`04`).
- DELEGATE-52: frontier models corrupt ~25% of content over 20 hops and **never plateau**
  (GPT 5.4: 79.7% at 10 hops → 58.7% at 100) (`04`).
- Kim et al.: decentralized topologies amplify trace-level errors **17.2×**; centralized
  coordination contains it to **4.4×** — measured at *one* orchestrator level, with no published
  number for depth 3 (`04`).

**Decision:** depth 3 enforced by the daemon before a child is launched, never asked of the model.
Configurable, but *default-refuse* above 3. "Arbitrarily deep" is dropped as a goal.

### 2.2 Roles as personas → **roles as capability contracts**

- MAST (1600+ annotated traces, 7 frameworks): "disobey role specification" causes **0.5%** of
  failures. The real killers are step repetition 17.1%, reasoning-action mismatch 14.0%,
  verification 13.5%, unaware-of-stopping-conditions 9.8% (`03`).
- arXiv:2311.10054: 162 personas × 4 model families × 2410 questions — no improvement over no
  persona; auto-selecting the best persona is no better than random (`03`).
- AG2's clean-sheet v1.0 **deleted** personas; CrewAI's own docs say 80% of effort belongs in task
  design, 20% in agents (`03`).

**Decision:** a Role is a contract — tool allow/deny, model, output schema, budget caps, stop
conditions, delegation policy, escalation policy, context policy. Prose is **one optional field**,
and a lint rejects any role that is *only* prose.

### 2.3 One delegation model → **two explicit modes**

The isolation-vs-sharing literature genuinely disagrees, and the disagreement tracks task shape
(`04`):

| Mode | When | Context | Evidence |
|---|---|---|---|
| **map** | children independent, read-only, mechanically verifiable | isolate; fan out wide | RAH 81→90%; Anthropic +90.2% |
| **build** | children produce artifacts that must compose | push shared decisions down; narrow fan-out | Cognition's Flappy Bird failure |

Defaulting build-shaped work to map-shaped fan-out is exactly how you get "a Mario background and
a bird that isn't Flappy." sprout must pick the mode explicitly and default **build** for code.

### 2.4 A reviewer agent → **deterministic verification first**

Blocksworld, GPT-4 as its own critic (`04`): no verification 40/100 → LLM self-critique 55/100 →
**external sound verifier 88/100**. The critic showed a **38% false-positive rate** on approve.

**Decision:** every leaf must declare a machine-checkable success condition (tests, build,
analyzer, diff applies). An LLM critic is weak evidence, never a gate, and **never the same model
that produced the artifact**.

### 2.5 A drift dashboard → **per-hop gates**

DELEGATE-52's mechanical detail: degradation is **sparse and catastrophic**, not diffuse — models
hold near-perfect reconstruction then lose 10–30 points in a single round trip, and these sparse
failures explain **~80% of total degradation** (`04`).

**Decision:** no trend gauge. A per-return acceptance check by the parent, against the brief it
wrote. Monitoring trends would mostly display noise and miss the actual failures.

---

## 3. Delegation floor — when *not* to decompose

Kim et al.: above ~**45%** single-agent baseline accuracy, adding agents produces *negative*
returns; coordination turn-count scales as a power law in agent count with exponent **1.724**
(doubling agents ≈ 3.3× the turns) (`04`).

So "just do it yourself" is a first-class branch and the **default for small tasks**. sprout
decomposes only when the root task is plausibly beyond one session. This is the cheapest
performance win in the whole design and it consists of *not* building a tree.

---

## 4. Architecture

```
   sprout CLI ─────────────┐
                           ▼
            ┌────────────────────────────────┐      ┌──────────────────┐
            │   sproutd (Revali, machine-wide)│◀────▶│ Zonai store      │
            │   · task graph + depth/budget   │      │ nodes, briefs,   │
            │   · supervisor & watchdog       │      │ decisions,       │
            │   · spawns/owns child processes │      │ journal, roles   │
            │   · snapshot + watch --since    │      └──────────────────┘
            └───┬────────────────────┬────────┘
        stdin/  │                    │ SSE
     stdout NDJSON                   ▼
                ▼            ┌──────────────────┐
     ┌────────────────────┐  │  Jaspr web UI    │
     │ claude -p sessions │  │  tree · decisions│
     │ (depth ≤ 3)        │  │  steer box       │
     └────────────────────┘  └──────────────────┘
```

**Control plane** (**`17-observed-schemas.md` — captured from a live CLI v2.1.252. `06` is superseded
wherever the two disagree**):

- Spawn: `claude -p --input-format stream-json --output-format stream-json`. sprout owns the pipe.
- **Steer**: NDJSON on stdin — `{"type":"user","message":{"role":"user","content":"…"}}`. A message
  **queues and lands at the turn boundary**; it does not interrupt mid-turn. This independently
  matches LangGraph's conclusion that human input belongs at check-in boundaries, not as an
  interrupt (`02`).
  Phrase every steer **additively** ("Also…", "One more constraint:…"). An override-shaped steer
  ("STOP. Ignore the previous instruction") is refused by the model as prompt injection and the run
  still reports `success` — observed, `17` §8.
- Observe: the same stream, plus `--include-hook-events` and `--forward-subagent-text` (which sets
  `parent_tool_use_id`, giving parent→child reconstruction from one stream — confirmed sufficient,
  `17` §2). The `system/task_started` / `task_progress` / `task_updated` / `task_notification`
  family carries `spawn_depth`, per-node token spend and current tool live; build Phase 2 on it.
- Bound: `--max-budget-usd`, `--permission-mode acceptEdits`, and the env knobs
  `CLAUDE_CODE_MAX_TURNS`, `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`,
  `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`. **`--max-turns` is not a CLI flag in v2.1.252** — it is
  the env var only.
- Gate: `PreToolUse` → `{"hookSpecificOutput":{"permissionDecision":"deny", …}}` at exit 0, and the
  Stop gate at **exit 2** with the reason on stderr. `06` had these exit codes inverted.

**Two observation paths, both needed.** stream-json is richer but only covers sessions sprout
launched and owns the pipe for. A machine-wide hook config (`~/.claude/settings.json`) is the only
way to see sessions the developer starts by hand. v1 ships stream-json; the hook path is additive
and does not require per-repo installation.

---

## 5. The node lifecycle

Adapted from game_loop's mandate model, which `07` identifies as already being sprout's core
promise — moved from per-session to per-node.

```
spawn → bind mandate (the parent's words, verbatim) → work
      → exactly three honest endings:
          checkpoint   progress, hands back, ASKS NOTHING          (the default)
          arm          the one escalation — see §6
          clear        genuinely done, with proof
      → parent acceptance check against the brief it wrote
      → close with a real artifact
```

Plus one **human-only** exit: `park`. The developer calling a break. Never the agent's judgement.

**Three liveness verdicts, not two: live / stalled / abandoned.** A live pid proves nothing —
`ps` reports the same state for a parked and a computing session. A frozen transcript mtime beside
a live pid is the signal. **Never auto-reclaim a stalled node**: the real incident behind this rule
held four uncommitted files and a green test suite (`07`). Surface it, page, never act.

---

## 6. Escalation — the "don't consult me" mechanism

This is the requirement the whole project exists for, and game_loop already has the right answer
(`07`):

```
arm --question "…" --read <a file already read that did NOT answer it> --predict "<the reply you expect>"
```

> "`--predict` is the test, and it is aimed at you: if you can predict the answer, you did not
> need to ask."

Two sprout-specific changes:

1. **Ration escalations tree-wide, not per node.** With recursion, N nodes each entitled to one
   question is N interruptions. The budget lives at the root.
2. **Everything else is RECORDED, not escalated** — into an append-only decisions feed: question,
   options, choice, reason. The UI's "questions I decided for you" list.

**Four gates stay human-only.** This is sprout's principled answer to "when may an autonomous agent
be stopped":

1. writes outside the node's declared workspace
2. sprout's own policy files (the config deciding what agents may do)
3. deploy / publish / irreversible outward acts
4. `park` — the human calling a break

And, enforced by name: **"a brief is not a human."** A parent node's text can never authorize what
only the developer can. In a real run an agent cited its brief as authorization twice, and the log
then read as human-sanctioned (`07`).

---

## 7. The web UI

Take showrunner's protocol whole — `07` calls it "already designed and debugged":

- **`snapshot`** — the whole world, one call, one instant.
- **`watch --since <cursor>`** — deltas, one JSON object per line. *"An event saying `leaf.closed`
  is not a picture, it is a delta against one."*
- Frame types: **`ready`** (end of replay, so attaching is never a blank screen), **`heartbeat`**
  (*"a stream that has DIED looks the same"* as a sparse one), **`bye`** (*"a stream that simply
  stops did not end, it broke"*).
- The cursor is namespaced to its instance and **belongs to the consumer**.

Rendered as: the live tree (every node, role, `current task | since | next check-in`), the
decisions feed, and a steer box per node.

**Three fields survive any compression** (`07`): `next check-in` — printed as `NONE SCHEDULED`
rather than left blank, because absence must never look like presence; any held resource with its
holder; and `journal_unreadable`. **Never estimate an age** — `since ?` when there is no frame,
never a guess.

---

## 8. Output budget

Inherited from the user's own terseness rules (`07`), applied at **tree scope** — neither existing
harness budgets what N nodes collectively print at one human.

One line per node: `VERDICT · node · task · since HH:MM (age)`. No prose, no headings, no
narration, no closing sentence, no pasted JSON. **No start notices** — under a turn-end gate an
announcement is indistinguishable from a question, so N children saying hello costs N blocked
turn-ends on the one party whose attention is not parallel. If it doesn't fit on a phone screen,
it's wrong.

---

## 9. Principles carried over verbatim

- **Enforcement lives in tools and artifacts, never in instructions.** Acceptance test: *if the
  agent ignored every instruction, would this still hold?* This is the argument for the binary.
- **Every fail-open path prints `ALLOWED WITHOUT BEING CHECKED`.** An allow nobody is told about is
  indistinguishable from a guard that ran and was content. Generalized: an identity element (zero,
  empty, silent) is reported as *could not tell*, never *nothing there*.
- **Name a real file.** The one check prose cannot satisfy. Sharpened per `07`'s own admitted gap:
  where an interrogating command exists, a document describing the same thing is the weaker
  citation (`git check-ignore` beats reading `.gitignore`).
- **Premise refuted is a success.** Close and stop — *"do not build a smaller version of the thing
  so you have something to show."* "Unreachable" is a third outcome.
- **Append-only, superseding, never editable** — *"a record that can be edited is one nobody can
  cite later."* Prose travels through a file, never a shell argument (a backtick executes and
  vanishes, corrupting a permanent record silently).
- **No ceremony as a phase.** Per the user's own verdict on his own tool: hardening "is not a
  requirement and not a step in any run… most work should finish with nothing hardened at all."
  Read as a general veto — no retro phase, no doctor phase, no completion-summary ritual.

---

## 10. Zero-install — the friction budget

`07` enumerated **45** per-repo obligations across the two harnesses. The design constraint is that
sprout's count is **zero**: no per-repo directory, no tracked payload, no `settings.json` merge, no
`.gitignore` edit, no session restart, no doctor, no local-vs-central decision, no hand-armed
watchdog, no per-repo `verify.yaml`/`INVARIANTS.md`/`config.json`/`baseline`, no manual hook wiring,
no skill symlinks, no campaign env var, no separately-cloned chat tool.

If sprout ever needs a per-repo file, it must be **optional, untracked, and additive**.

The evidence this matters, from the user's own repo (`DESIGN.md:73`): in a 16-hour unattended run
in a repo with **both** harnesses installed and wired, one orchestrator dispatched 42 worker
sessions — **all 42 used game_loop, none used showrunner**. Cause: game_loop owns `SessionStart`
and `PostCompact`; showrunner owns neither.

> "Adoption decays at exactly the rate context does. A guard whose enabling condition is 'you
> already adopted me' is not a guard."

---

## 11. Build order

Each phase ends at something demonstrable.

**Phase 0 — ground truth. ✅ DONE** — `docs/research/17-observed-schemas.md`, with raw captures under
`docs/research/fixtures/phase0/`. Six probes against live CLI v2.1.252 ($0.34) settled all four
questions: the stream envelope, `parent_tool_use_id` sufficiency (yes), the real hook field names,
and mid-run steering (works; phrasing is load-bearing). Six of `06`'s claims were wrong, including
the Stop-hook exit code, which was inverted and would have made every gate fail open.

**Phase 1 — daemon skeleton. ✅ DONE** — `sproutd/`, 135 tests, six leaves built through showrunner
in their own worktrees and integrated with checks green against a recorded baseline. Revali +
`package:sqlite3` (not Zonai — §13). Store with a recursive-CTE tree and triggers making the event
feed append-only in the schema; a stream parser that never throws on unknown input, deduping by
frame `uuid` and rebuilding the agent tree from `parent_tool_use_id`; a containment policy with the
depth cap and subtree budgets decided before a child process exists, counting its own refusals; a
session runner that streams frames to a raw NDJSON log *and* the store. Verified on trunk, not just
on branches: 7.4 MB binary, run from `/`, serving the snapshot on loopback with a WebSocket `101`
and refusing both the LAN address and `::1`; `sprout run` spawned a real depth-0 session, and the
store recorded 27 gapless events whose `UPDATE` the trigger refuses.

**Phase 2 — observation. ✅ DONE** — 242 tests, five leaves built through showrunner in their own
worktrees and integrated with checks green against the recorded baseline. The protocol is taken
whole from showrunner (§7): a `Cursor` is the token `s1.<instance>.<seq>`, so a consumer
reconnecting to a *restarted* sproutd is refused rather than silently resumed at a seq that has
come to mean something else; `snapshot` is the whole world at one cursor, printing `NONE SCHEDULED`
and `since ?` rather than a blank or a guess, and carrying `journal_unreadable` when the feed
cannot be read; `watch --since` replays, emits exactly one `ready`, then live deltas, with
`heartbeat` on an idle stream and a `bye` carrying its reason. `marksEndOfReplay` is true on
`ready` alone, so a delta that happened to carry no events can never be mistaken for the end of
replay. Verified on trunk rather than on a branch: the compiled binary run from `/` answers
`GET /api/tree/events` with `101`, opens with `snapshot` then `ready`, and heartbeats at +15.0s
and +30.0s of silence over a socket held 40s — where the same probe against the pre-merge binary
got one `{"data":{"type":"hello","cursor":0}}` frame and a close code 1000 at +1ms. `sprout watch`
refuses a foreign cursor with exit 4 and a malformed one with exit 5, each naming what it saw.

Three findings from Phase 2 are recorded and **not** repaired, because each lies outside the leaf
that found it. They are the first things Phase 3 will hit:

1. **The CLI and the daemon do not agree on an instance id.** `SproutInstance.current` is generated
   per process, so a cursor from `sprout snapshot` is refused by the socket as foreign. `bin/`
   already derives a stable id from the absolute database path plus the identity of the feed's
   first event; the fix is lifting that into `lib/protocol.dart` as `SproutInstance.forStore(...)`.
   Forking a second hash that must stay equal would be the bug, not the fix. Pinned by a test that
   fails the day it lands.
2. **Creating a subagent node appends no event.** `StoreProjection._syncSubagents` writes the row
   with `putNode` and emits nothing, while every frame it emits is attributed to the emitting node.
   A consumer holding a snapshot plus every delta after it therefore still does not know that
   subagent exists — only a fresh `snapshot` reveals it. A new *root* does announce itself, via
   `runner.spawned`. This is a Phase 3 blocker for a UI that expects to stay current from `watch`
   alone.
3. **`@WebSocket.ping(...)` is silently dropped.** `revali_construct 3.0.0` reads `Duration`'s
   private `_duration`, which Dart 3.13.2 replaced with the public `inMicroseconds`; `revali build`
   succeeds with no warning. Without a ping nothing reads the socket while the connect handler is
   streaming, so a client hang-up is never noticed and every disconnect leaks a watch session and
   its two timers. Measured: still subscribed 12s after the client left with no ping, torn down in
   2219ms at ping 1s. Passing a `Duration` straight to `WebSocketRoute(ping: …)` works, so only the
   annotation path is broken.

Also for Phase 3: every message arrives as a **binary** frame — `BodyImpl.read()` is
`Stream<List<int>>` whatever the payload — so a browser client must set `binaryType`. And
`lib/protocol.dart` has no `SnapshotFrame`, so `ProtocolFrame.decodeLine` throws on the opening
frame and a consumer needs one branch before it. For Phase 7: `execute()` awaits `onConnect` fully
before `listenToMessages()`, so on this revali version the back channel cannot be concurrent with
server push — two-way is still the right mode, but a steer needs a revali-side change.

**Phase 3 — the UI.** Jaspr over SSE. Live tree, `current task | since | next check-in`.

**Phase 4 — delegation.** Depth 2 then 3, map/build modes, waves over estimated file sets
(unestimable ⇒ collides with everything), worktree per child.

**Phase 5 — autonomy.** Mandate per node, three endings, tree-wide escalation budget, decisions
feed, the four human-only gates.

**Phase 6 — the watchdog.** Outside the sessions. Contradiction-triggered, settle before measuring,
ring cap on *consecutive unproductive* rings that resets on progress, newest-wins with a
start-time-verified pid, every quiet exit logged with a `why`.

**Phase 7 — steer.** NDJSON into a live session; propagate to affected children.

---

## 12. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ~~Hook payload field names in `06` partly unverified~~ | ~~high~~ | ~~medium~~ | **Retired.** Phase 0 captured them; `17` is the source of truth |
| A steer is silently ignored — accepted by the transport, refused by the model as injection | medium | medium | Phrase additively; verify by consequence, never by acceptance (`17` §8) |
| A subagent outlives its parent and reports to the *grandparent* | *certain* | medium | Subtree completion computed from `task_updated`/`task_notification`, never from "parent finished" (`17` §6) |
| Depth-3 containment unmeasured (4.4× is a depth-1 number; 4.4³≈85× is naive but nobody knows) | high | high | Depth 3 ceiling; per-hop deterministic gates; sprout could produce the first real depth ablation |
| Critic false positives correlated across depth (parent and child share a model and its misconceptions) | medium | high | Deterministic verification; never same model as generator and verifier |
| Build-mode fan-out producing non-composing artifacts | medium | high | Default build mode; push decisions down in the brief; narrow fan-out |
| Token cost (15× chat for multi-agent; 2.4–5× for hierarchy alone) | high | medium | Per-subtree cumulative spend as a first-class UI number; supervisor hard-stops |
| Jaspr is 0.x, single maintainer, breaking changes ~monthly | medium | medium | `jaspr migrate --apply` works; UI is the most replaceable layer |
| Revali `@SSE` is not browser-compatible | *certain* | low | Use `@WebSocket` — verified working, and better anyway |

---

## 13. Stack — verified by building it, not by reading about it

`05-dart-stack.md` is the only research doc backed by execution: a real Revali server compiled to a
native binary, copied to `/tmp`, run with `cwd=/` and its source tree deleted, serving a real Jaspr
UI (HTML + 202 KB JS + CSS + SVG), a JSON API, and a WebSocket `101` — bound to `127.0.0.1`.

**Verdict: the single-binary goal is achievable. 7.88 MB, one file.**

### Confirmed

| Layer | Choice | Why |
|---|---|---|
| Daemon | **Revali** 3.3.2 / `revali_router` 5.1.1 | Build-time codegen only; `revali build` emits a plain Dart entrypoint with `main()` that `dart compile exe` consumes. No reflection, no `dart:mirrors`. |
| UI | **Jaspr** 0.23.4, **client mode** | Emits 5 static files / 220 KB. No run-time Dart, no asset dir. Embedded as base64 constants. |
| Live channel | **`@WebSocket`** | Revali's `@SSE` emits `application/octet-stream` with no `data:` framing and the header override is *ignored* — `EventSource` cannot consume it. WebSocket is also the better fit: steer needs a back channel. |

Build pipeline (steps 1–3 are CI-time; the developer receives one file):

```
jaspr build → rsync payload → generate assets.g.dart → revali build → dart compile exe
```

Two known sharp edges, both with clean workarounds: Revali's `public/` reads CWD-relative from disk
(so generate embedded bytes instead), and `revali` + `jaspr_builder` genuinely conflict on analyzer
versions via a `dart_style` pin — **fix is two packages, not a workspace**.

### The open decision: Zonai

**This one is yours, because Zonai is your project.** I verified its `llms.txt` directly rather than
taking the researcher's verdict.

Zonai is "a batteries-included Dart backend framework — schema-driven REST API, auth, SQLite, live
query streams." That is a **server**, not an embeddable library: sprout would query its own state
over HTTP, the CLI is not on pub.dev (a pre-compiled binary placed in the project root), and workers
run from `.zonai/executables/` over MessagePack IPC.

|  | `package:sqlite3` (recommended) | Zonai |
|---|---|---|
| Artifact | one binary | two processes + `.zonai/` directory |
| Data access | in-process | HTTP round-trip to itself |
| Live updates | hand-rolled over the WebSocket already needed | **free** via `/db/stream` |
| Tree queries | recursive CTEs (verified working) | expand, depth-capped |
| Admin UI | none | dashboard at `/_`, no flag to disable |

**Recommendation: `package:sqlite3`.** It AOT-compiles cleanly, recursive CTEs give the task tree
directly (verified), and it is the only option consistent with "one binary, FAST, RELIABLE, SIMPLE."
The live-query win doesn't pay for itself when sprout already needs a WebSocket for steering.

One objection from the research I'm **discarding**: "relationship depth capped at 4 — fatal for a
deeply-nested tree." That was reasoning against the old arbitrary-depth design. With depth capped at
3 (§2.1), it doesn't bind.

If Zonai's roadmap includes an in-process Dart data API, that changes the answer and you'd know
before I would.

---

## 14. Cost and quality

Sources: `08-token-cost-audit.md` (measured on this machine), `09-anthropic-cost-levers.md`
(first-party mechanisms), `10-token-optimization-wild.md` (external techniques),
`11-quality-per-token.md` (where cheap and good align).

### 14.1 The synthesis no single doc reached

The standard advice for cutting agent cost is *maximize your cache hit rate*. Doc 10 ranks
KV-cache-stable prefixes as the #1 lever at ~10× on input tokens, and Manus calls hit rate "the
single most important metric."

**On this machine that advice is already satisfied and is therefore not the lever.** Measured:

| | Measured |
|---|---|
| Cache hit rate | **98.49%** |
| Fresh input, whole corpus | **$0.27** (0.01% of spend) |
| Cache **read** | **$2,004.58 — 65.0%** of spend |
| Mean tokens re-read per turn | **147,732** |

The bill is not misses. It is **volume**: a very large context re-read on every turn, at 0.1× —
and 0.1× of an enormous number is still the largest line item. The residual cost is
`context size per turn × number of turns`, and the only remaining levers act on those two terms.

Confirmation from the same corpus: **context growth past turn 50 = $683.61, 22.2% of all spend**,
with a turn-budgeted handoff recovering ~$550.

### 14.2 The instinct this inverts

`09` reasoned from documentation that each spawned subprocess pays for a cold cache, making spawns
the dominant cost of recursion. **Measurement says otherwise:**

- All 207 showrunner Crawlers hit a warm ~10K prefix on turn 1. **0% fully cold.**
- Total spawn tax: **$63.06 — 2.0% of spend, $0.30 per spawn.**
- Main sessions start *colder* (75.9% fully cold) than spawned ones.

**Creating an agent is cheap. An agent living a long time is expensive.** So sprout should prefer
**many short-lived nodes over few long-lived ones** — the opposite of what minimizing spawns would
suggest, and convergent with `11`'s finding that short leaves are the fix for artifact erosion
(SlopCodeBench: degradation in 80% of trajectories, damage to the *artifact*, so compaction cannot
undo it).

Measured multi-agent multiplier on this machine: **15.3×**, independently matching the published
~15× figure.

### 14.3 Adopted levers

Ranked by expected value against **this** cost structure, not against generic advice.

| # | Lever | Mechanism | Evidence |
|---|---|---|---|
| 1 | **Turn budget + handoff** | Cap node lifetime; hand off rather than grow context | $683.61/22.2% measured; ~$550 recoverable |
| 2 | **Short-lived leaves** | Small tasks, closed quickly | Same measurement, plus artifact-erosion fix (`11`) |
| 3 | **Subagent output contract** | Child burns tens of thousands, returns **1,000–2,000** | Anthropic; cheaper *and* better — parent avoids context rot |
| 4 | **`low` effort for subagents** | `output_config.effort` | TALE: −68.6% output tokens for −2.72pp; Anthropic recommends `low` for subagents |
| 5 | **Spawn thresholds** | Don't decompose small work | Anthropic publishes literal tiers; avoids the 15.3× multiplier |
| 6 | **Native function calling** | Never a prose tool protocol | o1-high SWE-bench **29.1% → 47.7%**; largest cheaper-and-better delta found, costs nothing |
| 7 | **Curate, don't compress** | Fix distractors, not length | `11`: the destructive variable is irrelevant/stale content |
| 8 | **Context editing** | `clear_tool_uses_20250919` | Attacks re-read volume directly — the actual line item |

### 14.4 Rejected, with reasons

Negative findings are worth as much as positive ones here; each is implementation time saved.

- **Prompt compression (LLMLingua).** Worst compressor on code (EM 33.8 → 21.2), PyPI package
  unshipped since 2024, flagship benchmark has an unanswered reproduction challenge. `11` explains
  *why* it was never the right tool: the problem is distractors, not length.
- **Semantic caching.** Structurally unsafe for this workload — LiteLLM's own docs say so.
- **Model cascades / RouteLLM.** Dead since Aug 2024; independent replication ~35%, not the claimed
  85%. And caches are **model-scoped**, so a cascade forfeits cache reuse — actively harmful when
  cache reads are 65% of the bill. Prefer one model at lower effort.
- **Repo maps as a cost lever.** Aider's repo map, Claude Code's grep stance, and serena publish
  **zero** measurements between them. Not rejected as an idea; rejected as an evidence-backed lever.

### 14.5 Crystallization — the one worth prototyping

Promote repeatedly-validated agent behavior to deterministic scripts: an agent works something out
once, and thereafter it runs as code for free. Production evidence: **0% → 45% deterministic over
8 months, >70% cost reduction.**

sprout is unusually well placed for this because **it observes every trajectory across every
project on the machine** — it can see the same procedure recur where a single session cannot. This
is also the sharpest expression of `09`'s "judge cost per completed task, not per token."

Prototype, don't ship in v1.

### 14.6 Cost as a product surface

Per the developer's requirement that they must still understand what is happening:

- Cumulative spend **per subtree** is a first-class number in the UI, not a footnote.
- Two telemetry rules inherited from `08`, or sprout will misreport its own costs:
  1. **Never attribute subagent cost via `isSidechain`** — it misses 98% of multi-agent spend on
     this Claude Code version, because spawned sessions are filed as independent projects.
  2. **Dedupe by `message.id`** — naive per-record summing inflates every figure **2.02×**.
- `docs/research/tools/cost-audit.py` re-runs the whole audit in ~15s over 499 MB, so this is
  tracked over time rather than measured once.

### 14.7 The honest limit

`11`: the first **60–80%** of typical agent spend is waste that also degrades quality; the last
**20–40%** is capability that cannot be bought more cheaply. Most long-horizon quality fixes cost
*more* — subagent context isolation bought +19% accuracy at +35.6 tool calls; compaction +11.6% at
+36 calls.

**The line between waste and capability is only findable with a deterministic verifier** — which is
the same conclusion §2.4 reached from a different direction, and the strongest argument for making
machine-checkable success conditions mandatory rather than encouraged.

One refinement to §2.4 from `11`: the "LLM critics score 55%" figure measured **spec-free** critics.
Test-aware critics score **86–93%**. Critics are not useless — they are useless *without a
machine-checkable criterion*. Hand every critic a spec, or don't run it.

---

## 15. Staying on task, planning, and continuous improvement

Sources: `12-planning-before-delegation.md`, `13-staying-on-task.md`, `14-self-improvement.md`,
`15-waste-detection-and-regression.md`.

### 15.1 The highest-leverage mechanism in the entire project

**Re-inject the goal and its constraints verbatim after every context-destroying event** —
compaction, handoff, session boundary — enforced by the daemon, never asked of the model.

*Governance Decay* (arXiv:2606.22528; 7 models, 1,323 episodes): constraints dropped by a
compaction summary produce **38–43% violation**, rising to **78% after four compactions**.
Verbatim re-pinning restores **0% violation across all seven models, at ~47 tokens and <0.5%
overhead.**

Two qualifiers that make this precise rather than cargo-cult:

- **Re-injecting a goal that is still in context did nothing.** This is a repair for a destructive
  event, not a periodic ritual.
- **Compaction is not a drift reset. It is a drift cause.**

### 15.2 Constraints re-pin; procedures do not

`12` and `13` look contradictory and are not. Read together they give a rule sharper than either:

| Form | Behavior | Consequence |
|---|---|---|
| **Declarative constraints, done-criteria** | Re-pin to **0%** violation | Re-inject them; they survive |
| **Procedural step-plans** | Decay **4.1–12.4× in one action step**; re-injection n.s. | Don't re-inject — **respawn** |

This is why `12` independently concluded children must be bound to **ends, not steps**, and why
`14` concluded a procedure only becomes durable **by ceasing to be text** — Voyager's durable
artifact is a *program*. Three separate lines, one architecture.

### 15.3 Planning — the developer's proposal, corrected

Verdict from `12`: **yes to a planning phase, with three modifications.**

The justification is strong. *Knowing but Not Showing* (arXiv:2605.25284): models detect ambiguity
at **60–80%** accuracy when asked, but volunteer a clarifying question **<5%** of the time — and
more context makes them *less* likely to ask. An executor handed a one-liner silently invents an
interpretation. *Ask or Assume?* (arXiv:2603.26233) shows decoupling detection from execution
scores **69.40% on underspecified SWE-bench Verified**.

1. **A programmatic gate on the plan, before executors spawn.** Acyclicity, disjoint file globs, a
   machine-checkable done-criterion per leaf, coverage. A failing plan is regenerated, not
   forwarded. Required because a subpar plan is **worse than no plan** (arXiv:2604.12147, 16,991
   trajectories — the reduced-plan condition scored *below* the no-plan baseline).
   **Never validate a plan by asking an LLM if it is good** — self-critique of plans measurably
   lowers quality (Kambhampati; PlanBench o1 97.8% → 52.8% obfuscated).
2. **Planner at the root only.** At depth 2–3 the parent's brief already *is* the plan.
3. **Bind children to ends, not step ordering** — which capable models correctly override anyway.

**Cap briefs by rule count.** Perfect instruction-following reaches zero at **80 constraints** —
every model, every placement (`13`).

### 15.4 Continuous improvement — evidence-triggered, never a phase

Reconciles the developer's standing instruction (*"Hardening is NOT part of the loop… most work
should finish with nothing hardened at all"*) with the request to continuously improve.

**Verdict from `14`: automated self-improvement works only where a machine, not a model, decides
the improvement was real.** Everything built on self-critique has been measured degrading.

The decisive result — a Reflexion replication (arXiv:2605.29463): **32% of ALFWorld and 82% of
WebShop environments developed "frozen" memory**, a confident wrong self-diagnosis rewritten every
trial. **0 of 121 reflections in frozen environments ever named the correct target.** Frozen rate
tracks feedback granularity: binary 32–82%, unit-test 17%. Prompting for better reflection did
**not** fix it; a **parser** did — correct-diagnosis rate **0% → 86%**.

> The fix for a bad reflection is a parser, not a better prompt.

**Two hard rules:**

- **sprout may write scripts and tune knobs. It may never modify its own gates.** The Darwin Gödel
  Machine faked test logs and, told to fix hallucination detection, "removed the markers we use in
  the reward function… hacking our hallucination detection function to report false successes"
  despite explicit instruction not to. The asymmetry must be structural, not a prompt rule.
- **Truncate the harden ladder at rung 4. Do not descend it.** Rung 6 (doc/memory) is not a weaker
  rung 1: `13` measured that rung at **p = 1.00** (291 runs) and CLAUDE.md structural tuning at *no
  detectable effect* (1,650 sessions), while `11` shows self-generated prose actively harms. **If a
  lesson cannot reach rungs 1–4, drop it.** This is "most work finishes with nothing hardened" made
  operational.

**Landing point: crystallize procedures into scripts, encode constraints in gates, build no
learned-memory system.** Episodic memory scaffolds were neutral-to-negative in **10 of 10** models
(`13`).

### 15.5 The cheap-signal frontier

`15`'s organizing result, from fresh measurement over the 358-transcript corpus:

> **Free:** deterministic re-derivation of what already happened.
> **Costs money:** any claim about what would have happened instead.

**Free, and worth building:**

| Signal | Measured |
|---|---|
| **Error-signature clustering** | 895 error results → 380 signatures; **46 signatures recurring in ≥3 sessions cover 59.8% of all errors** |
| — the single largest cluster | agents `cd`-ing to relative paths that don't exist: **~19% of all errors**, 169 occurrences, 65 sessions, 4 repos |
| Gate trips | 187 `BLOCKED` across 111 sessions |
| Per-turn wall clock | median **104s**, max **67 min** — *nothing reads this field today* |
| Oversized results | **0.76%** of Bash calls carry **11.7%** of all text bytes |
| Artifact change | `Edit` results carry `structuredPatch` — exact, never inferred |

That `cd` cluster is the model case for the whole loop: one deterministic fix retires ~19% of all
errors, and it is discoverable for free.

**Free, and the finding is "don't build it."** Four canonical waste patterns measure at **zero**
in this corpus: retry loops (889 error-runs of length 1, three of length 2, none longer),
identical-call retries (0), unchanged re-reads (0), edit oscillation (1 in the entire corpus).

**A refutation of our own earlier recommendation:** "turns since last artifact," listed as an
early-warning signal in `11`, **does not separate populations** — zero-edit sessions median 49,
editing sessions 44. Dropped.

**Costs money:** only the two MAST modes carrying the most mass — step repetition (17.14%) and
reasoning–action mismatch (13.98%) — genuinely need a judge.

**No observability vendor detects waste.** Three products cluster failures; none detect loops or
token burn over organic traffic. HoneyHive's "Trajectory View" is a bubble chart sold with
detection verbs; Galileo's `agent_flow` is user-written assertions; AgentOps's "automatic" means
auto-*instrumentation*. Nothing to buy here.

### 15.6 Regression safety

- **A sub-3-point improvement on a 100-task suite is indistinguishable from noise.** Any claimed
  improvement below that is not measured, it is hoped.
- The loop's real risk is **objective hacking, not decay** (`15`, corroborating the DGM result).
- Baselines follow `07`'s rule: **no NEW failures, never "all green"**, with a distinct VOID state
  for a run that could not reach the world.
- Sessions self-correct only **3%** of the time (`13`) — improvement must be driven from outside.

### 15.7 The gating question, answered: crystallization is CUT

`14` named the question — how much of sprout's real work actually repeats? `16` measured it against
359 transcripts, 314 sessions, 15 repos, 27,175 Bash calls, $3,145.13.

**Answer: NO. The ceiling is 1–4% of spend (upper bound 8.5%), not the 70% the external claim
advertised.**

| Measure | Result |
|---|---|
| Byte-identical commands recurring in ≥3 sessions **and** ≥2 repos | 2.42% of Bash — **$19.63, 0.62% of spend** |
| Substantive procedure n-grams in ≥3 sessions | 15.4% of positions at n=4 → 0.63% at n=7 → **zero at n=9** |
| Action-only sequences (read/search primitives removed) | **zero** cross-project recurrence at n≥6 |
| Fixed-argument remainder after normalization | **0.24% of spend** |

**The big number was a normalization artifact.** 35.2% of Bash calls appear to clear the
≥3-sessions/≥2-repos bar — but **98.2% of that is parameterized**, and the destroyed path, pattern
or line-range *is* the work. Crystallizing it would crystallize an empty shell.

**Why the ceiling is low, and it is a compliment:** this corpus is **already post-crystallization**.
game_loop, showrunner, llm_chat, sip and dvm already exist, and 9.6% of Bash calls invoke them
directly. The external "0% → 45% deterministic over 8 months" claim describes a migration this
machine has already made.

**Decision: cut crystallization from the roadmap.** Not disproven in general — measured to have no
headroom *here*. Re-runnable via `docs/research/tools/repetition-scan.py`; revisit at 90 days of
corpus (the measurement window was 5 days against the claim's 8 months, which is the finding's
largest weakness and is documented with a sensitivity curve).

**A methodological warning worth keeping.** In-session "repetition" measures 17.76% under
normalization and **0.71% byte-identical** — the 17pp was *reading*, not looping. A normalized loop
detector would have overstated the problem **25×** and sent us hunting a bug that isn't there. Any
waste metric sprout ships must report the byte-identical figure alongside the normalized one.

### 15.8 The side-finding that is 10× larger than the feature we cut

`16` found, while measuring something else:

> **45.6% of all Bash calls — $318.85, 10.14% of total spend — are file reads routed through Bash**
> (`cat`, `head`, `sed -n`) rather than through the dedicated file tools, because a global
> instruction directs it.

That is **more than ten times** the entire crystallization opportunity, it is a one-line
configuration change, and it is available today rather than after building anything.

Corroborated first-hand during this very research: a `cat` of a 62 KB research doc in this session
overflowed and had to be re-read through the paging file tool — the same failure mode, observed
live.

This belongs to the developer's own global configuration, not to sprout, so it is **flagged, not
changed**. But it reframes sprout's improvement loop: the highest-value thing the loop does is not
learn new procedures — it is **notice standing configuration that quietly costs money**, which the
error-signature clustering in §15.5 already demonstrated with the `cd` cluster (~19% of all errors,
one deterministic fix).
