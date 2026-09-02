# sprout

**A machine-wide Dart harness that orchestrates recursive Claude Code sessions and watches them
from *outside* the sessions.**

> Give sprout a task with minimal explanation, walk away, come back in a few hours, and find it
> either done or visibly in progress — with a web UI that shows every agent, from the top-level
> down to the deepest nested one, and what each is doing right now.

**Status: in development.** Phases 0–2 are built, tested and verified against a compiled binary.
Phase 3 is under way: the UI package builds, and the compiled binary serves it at `/` out of its own
constants. See [Where it actually is](#where-it-actually-is).

---

## Why it exists

Two harnesses already run agent work on this machine — `game_loop` (write guard, claim gate,
verify gate, mandate, watchdog) and `showrunner` (leaf graph, waves, worktrees, reconcile and
integrate). Both fire **every gate from inside the session that stopped working.**

A real run sat inert for six hours with all gates reporting healthy. That is not a bug in either
harness; it is the shape of the design. **A stuck session cannot notice it is stuck.**

sprout is the outside observer. State comes from hooks firing on real tool calls and real session
lifecycle events, streamed into a local daemon. An agent claiming it is 80% done is not evidence;
what it actually ran is.

## Design principles

- **Autonomy is the default; consultation is opt-in.** A recorded decision you can later disagree
  with beats a blocking question.
- **Terse or it didn't happen.** Every surface is budgeted. Recaps are banned — the UI is the recap.
- **Observed, not narrated.** Hooks, not self-report.
- **One definition, everywhere.** Roles and policies live in one machine-wide place. Projects
  override, never redefine.
- **Recursive but bounded.** Hard limits on depth, fan-out and budget, because unbounded recursion
  is how an autonomous system burns a night.
- **Fast, reliable, simple.** One compiled binary. Starting sprout should feel like running `ls`.

Full rationale: [`docs/00-vision.md`](docs/00-vision.md).

## Architecture

```
  sprout CLI  ──────────────┐
  (task entry, status)      │
                            ▼
              ┌──────────────────────────┐        ┌──────────────────┐
              │   sproutd  (Revali)      │◀──────▶│  sqlite3 store   │
              │   - task graph           │        │  tasks, nodes,   │
              │   - scheduler / budgets  │        │  decisions,      │
              │   - hook ingest endpoint │        │  heartbeats      │
              │   - WebSocket stream     │        └──────────────────┘
              └────────┬────────┬────────┘
                       │        │
             spawns    │        │  serves
                       ▼        ▼
     ┌──────────────────────┐   ┌────────────────────────┐
     │ agent sessions       │   │  web UI (Jaspr)        │
     │ (recursive; each     │   │  live tree, heartbeats,│
     │  reports via hooks)  │   │  decisions, steer box  │
     └──────────────────────┘   └────────────────────────┘
```

Dart throughout: [Revali](https://docs.revali.dev) for the daemon, `package:sqlite3` for
persistence, [Jaspr](https://docs.jaspr.site) for the web UI, compiled to a single binary.

## Where it actually is

| Phase | What it is | State |
|---|---|---|
| 0 | Ground truth — observed control-plane schemas | ✅ done |
| 1 | Daemon skeleton — store, stream parser, containment, runner | ✅ done, 135 tests |
| 2 | Observation — protocol, snapshot, `watch --since`, WebSocket | ✅ done, 242 tests |
| 3 | The UI — live tree over the socket | 🟡 in progress — payload builds, binary serves it at `/` |
| 4–7 | Roles, endings, steer | ⬜ not started |

**Phase 0** settled the stream envelope, `parent_tool_use_id` sufficiency, the real hook field
names and mid-run steering against a live CLI (v2.1.252, six probes, $0.34). Raw captures are on
disk under `docs/research/fixtures/phase0/` — six earlier documented claims turned out wrong,
including a Stop-hook exit code that was inverted and would have made every gate **fail open**.

**Phase 2** ships the observation protocol: a cursor is `s1.<instance>.<seq>`, so a consumer
reconnecting to a *restarted* daemon is refused rather than silently resumed at a sequence number
that has come to mean something else. `snapshot` is the whole world at one cursor; `watch --since`
replays, emits exactly one `ready`, then live deltas, with `heartbeat` on an idle stream and a
`bye` that carries its own reason.

Verified against the compiled binary run from `/`, not just on a branch — the socket opens with
`snapshot` then `ready` and heartbeats at +15s and +30s over a connection held 40 seconds.

### Known defects

[`docs/02-open-findings.md`](docs/02-open-findings.md) is the real list — five defects observed
during real runs and deliberately left unrepaired, each because the fix lies in a file the leaf
that found it did not own. Three of them block Phase 3. Nothing is closed there by being read.

## Repo layout

```
sproutd/            the daemon and CLI — Dart, the whole implementation
  lib/protocol.dart   cursors and the wire frames
  lib/snapshot.dart   the whole world at one cursor
  lib/watch.dart      replay then live deltas
  routes/             Revali controllers
docs/00-vision.md   what this is for
docs/01-plan.md     the plan; §11 is the build order, §13 the stack decisions
docs/02-open-findings.md  observed defects, unrepaired
docs/research/      17 research documents, plus raw captures and tooling
```

Development runs through the `game_loop` and `showrunner` harnesses (`.game_loop/`,
`.showrunner/`). They are not required to read the code.

## A note on the research documents

`docs/research/` is kept because it is *checkable*, not because it is tidy. The governing rule is
that a control-plane fact is observed or it is not a fact — so the raw captures stay on disk and
the documents can be argued with. Several were:
`docs/research/06-claude-code-control-plane.md` is superseded and carries a banner; never take a
field name from it.

Fixture paths under `docs/research/fixtures/` were sanitized to `/Users/USER/` before this repo
was first published. They are otherwise verbatim captures.

## License

None yet.
