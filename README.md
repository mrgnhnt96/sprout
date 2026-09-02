# sprout

**A machine-wide Dart harness that orchestrates recursive Claude Code sessions and watches them
from *outside* the sessions.**

> Give sprout a task with minimal explanation, walk away, come back in a few hours, and find it
> either done or visibly in progress — with a web UI that shows every agent, from the top-level
> down to the deepest nested one, and what each is doing right now.

**Status: in development.** Phases 0–3 and 6 are built, tested and verified against a compiled
binary run from `/`. `sprout ui` starts the daemon and serves the web UI out of the binary's own
constants; the UI builds the live tree from one snapshot plus deltas; and a watchdog outside the
sessions notices when one stops working. See [Where it actually is](#where-it-actually-is).

## Seeing it

```
sprout ui
```

Prints the URL and stays in the foreground until Ctrl-C:

```
http://127.0.0.1:8787/
db  /Users/you/.sprout/sprout.db
Ctrl-C to stop.
```

That is the whole thing — no arguments, no environment to set, the same database `sprout run`
writes. `SPROUT_PORT` and `SPROUT_DB` override the port and the file if you need them to. The
daemon binds `127.0.0.1` and nothing else: the LAN address and `[::1]` are refused, which is not
an accident and must not be relaxed for convenience (`sproutd/routes/main_app.dart` says why).

It is a foreground process and deliberately nothing more — no backgrounding, no PID file, no
restart, no `sprout stop`. If the port is taken it says so and exits `7` rather than starting a
second daemon.

## Building it

**One binary**, as of P4-01 — `sprout` is the CLI *and* the daemon:

```
cd sprout_ui && dart run jaspr_cli:jaspr build      # 1. the web UI
rsync -a --exclude=packages/ \
      sprout_ui/build/jaspr/ sproutd/web/           # 2. the payload: top-level files ONLY
cd sproutd && dart run tool/embed_assets.dart       # 3. -> lib/src/ui/assets.g.dart
cd sproutd && dart run revali build                 # 4. -> .revali/server/
cd sproutd && dart compile exe bin/sprout.dart -o sprout
```

Step 2 takes the top-level files and nothing else on purpose. `build/jaspr` also carries a
`packages/` tree of data files pulled in by *dev* dependencies — several megabytes that are not
the UI — and embedding the directory wholesale would put all of it in the binary.
`sprout_ui/test/payload_test.dart` enforces that, rather than leaving it as a note here.

Steps 1–3 are only needed when the UI changed; `assets.g.dart` is committed. Step 4 is only
needed when `routes/` changed; `.revali/` is committed too, and for the same reason —
`bin/sprout.dart` imports it, and three test files import `bin/sprout.dart`, so a checkout without
it would neither analyze nor run its tests. **Touch `routes/`, run step 4, commit the diff.**

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
persistence, [Jaspr](https://docs.jaspr.site) for the web UI, compiled to a single binary — one
8.5 MB executable that is the CLI, the daemon and the UI's own asset store. Measured, not
aspirational: see [Building it](#building-it).

## Where it actually is

| Phase | What it is | State |
|---|---|---|
| 0 | Ground truth — observed control-plane schemas | ✅ done |
| 1 | Daemon skeleton — store, stream parser, containment, runner | ✅ done, 135 tests |
| 2 | Observation — protocol, snapshot, `watch --since`, WebSocket | ✅ done, 242 tests |
| 3 | The UI — live tree over the socket | ✅ done, 338 tests |
| 4–5 | Delegation, autonomy | ⬜ not started |
| 6 | The watchdog — outside the sessions | ✅ done, 443 tests |
| 7 | Steer | ⬜ not started |

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

[`docs/02-open-findings.md`](docs/02-open-findings.md) is the real list, and the rule is that an
entry leaves it in exactly one way: a commit that fixes it, which deletes the entry and says so.
Nothing is closed there by being read.

Eleven have been recorded so far and ten are fixed. One is open, and it is not sprout's.

**F-08** is `game_loop`'s rather than sprout's: its rule-file guard reads the command string, so a
`python3` heredoc writes a policy file without passing through the authorization that would record
a human's words. Observed twice, once accidentally and once while holding a valid grant that then
went unspent.

## Repo layout

```
sproutd/            the daemon and CLI — Dart, the whole implementation
  bin/sprout.dart     the single entrypoint: run, snapshot, watch, ui
  lib/protocol.dart   cursors and the wire frames
  lib/snapshot.dart   the whole world at one cursor
  lib/watch.dart      replay then live deltas
  routes/             Revali controllers
  .revali/            generated by `revali build`, COMMITTED — see Building it
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
