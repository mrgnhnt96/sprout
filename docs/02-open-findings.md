# Open findings — things observed, not repaired

Every entry here was **observed during a real run**, not inferred from a document. Each was found
by the leaf named in it, and each was deliberately left unrepaired because the fix lies in a file
that leaf did not own — reaching outside a leaf is how two concurrent Crawlers corrupt each other's
work, so the rule is *report it, do not reach for it*.

That rule is only honest if the report survives the session that wrote it. This file is where it
survives. **A finding leaves this file in exactly one way: a commit that fixes it, which deletes
its entry and says so.** Nothing here is closed by being read.

Status vocabulary: **OPEN** — nobody has taken it. **BLOCKING <phase>** — that phase cannot be
finished correctly while it stands. **ACCEPTED** — a human decided to live with it, and their words
are quoted in the entry.

---

## Open

### F-07 — `package:sproutd/protocol.dart` cannot be compiled for the web, and says so silently

**Status: BLOCKING P3-04.** Found by P3-02. The fix is in `sproutd/lib/`, which P3-02 does not own.

`docs/01-plan.md` §13 and P3-02's own brief both assume the browser client will import
`package:sproutd/protocol.dart` rather than carry a second copy of the wire format — correctly,
because two independent derivations that must stay equal is what F-01 was. That import does not
compile for the web today. Observed by building it, not read:

    Skipping compiling sprout_ui|web/main.client.dart with ddc because some of its
    transitive libraries have sdk dependencies that are not supported on this platform:

    ... -> package:sproutd/protocol.dart -> package:sproutd/src/protocol/frame.dart
        -> package:sproutd/store.dart -> package:sproutd/src/store/sprout_store.dart
        (which imports dart:io)
    ... -> package:sproutd/store.dart -> package:sproutd/src/store/schema.dart
        -> package:sqlite3/sqlite3.dart -> ... (which imports dart:ffi)

The brief predicted that an *unused* transitive dependency would not be compiled. That reasoning
does not apply: `frame.dart` genuinely imports `store.dart` for `SproutEvent` and `SproutNode`, and
`store.dart` re-exports `sprout_store.dart` and `schema.dart` in the same library. The rejection is
made on the **library import graph**, before any tree-shaking, so an unused symbol does not help.

**The dangerous half is the reporting.** This is a WARNING, not an error. `jaspr build` prints
`Completed building project`, exits **0**, writes `index.html` and `main.css`, and writes **no**
`main.client.dart.js` — leaving a page whose one `<script>` 404s. A pipeline that gates on the exit
code sees a clean build of a UI that cannot run. Note the dependency alone is harmless: declared
and unimported, the payload builds fine. It is reaching `protocol.dart` from an import that breaks
it.

`sprout_ui/test/payload_test.dart` is the check that survives this: it asserts the bundle exists,
is non-empty, and contains this app's own strings. Measured against the failure above, four of its
five tests fail while `jaspr build` reports success.

**Smallest fix that keeps one definition** (not applied — it is sproutd's to make): lift
`lib/protocol.dart`, `lib/src/protocol/`, and the pure-value types `protocol` needs out of
`lib/store.dart` (`SproutEvent`, `SproutNode`, `NodeStatus`, `TreeNode`) into a third package
depending on neither `dart:io` nor `dart:ffi`, which both `sproutd` and `sprout_ui` then depend on.
The split point is `sprout_store.dart` and `schema.dart` — the two files that reach the outside
world — and nothing in `src/protocol/` needs either.

**Do not resolve this by copying the decoder into `sprout_ui`.** That is F-01 again, and it would
be invisible: two decoders that agree today, in different packages, with no test that compares
them.

---

## Notes that are not findings

These are true, cost nothing to know, and would cost real time to rediscover.

- **`jaspr create` scaffolds a project that does not resolve.** Its template pins
  `build_web_compilers: ^4.8.10`, which wants `analyzer >=13.3.0`, while `jaspr_builder 0.23.4`
  wants `analyzer ^12.1.0`. `sprout_ui/pubspec.yaml` holds `build_web_compilers` to
  `">=4.8.0 <4.8.6"` and `scaffold_test.dart` asserts the bound, because a caret would float
  silently past it. Raise it only together with `jaspr_builder`. (P3-02)
- **The `revali`/`jaspr_builder` clash is on `analyzer` directly, not via `dart_style`.** Resolving
  one package declaring both: *"revali >=2.1.0 depends on analyzer ^10.0.0 and jaspr_builder
  >=0.23.2 depends on analyzer ^12.1.0"*. `docs/01-plan.md` §13 and `sproutd/pubspec.yaml`'s comment
  name a `dart_style` pin, which is one hop further out than what pub reports. The conflict is real
  either way and two packages is still the fix — and it only works because `revali` is a **dev**
  dependency of sproutd: a path dependency pulls a package's regular dependencies, never its dev
  ones. (P3-02)
- **`jaspr build` writes 4.4 MB of `build/jaspr/packages/` that is not the payload** — analyzer
  `fix_data`, win32 fix templates, the `test` runner's browser host — pulled in by *dev*
  dependencies. The payload is the three top-level files (`index.html`, `main.css`,
  `main.client.dart.js`). P3-03's rsync step must take the top level only, or the binary carries
  all of it. `payload_test.dart` asserts both halves. (P3-02)
- **Every WebSocket message arrives as a *binary* frame**, never text — `BodyImpl.read()` is
  `Stream<List<int>>` whatever the payload type. Phase 3's browser client must set `binaryType`
  and decode. (P2-05)
- **The socket's connect handler must complete immediately, and the frames go out through
  `AsyncWebSocketSender`.** `revali_router 5.1.1`'s `HandleWebSocket.execute()` awaits
  `runHandler(onConnect)` before `listenToMessages()`, which is the only `webSocket.listen` in the
  package — and `dart:io` keeps a socket's protocol subscription *paused* until something listens
  (`websocket_impl.dart`: `subscription.pause()`, resumed by `_controller.onListen`). A connect
  handler that streams therefore leaves the socket unread: no inbound pong, no inbound close, no
  inbound message. That was F-05 and F-06, one unread socket seen from two sides, and both are
  closed by `attachTreeSocket` in `routes/controllers/tree_controller.dart`. Anything new on this
  socket pushes through the sender; it does not yield. (F-06)
- **The back channel is serviced now, but nothing interprets a client message.** revali registers
  the one annotated method as both `onConnect` and `onMessage`, so an inbound message re-invokes
  the handler — `attachTreeSocket` keeps its session in the request's `Data` and returns an empty
  stream on re-entry, which is what stops a second snapshot-and-watch opening on the same socket.
  Phase 7's steer is the thing that will read those messages; the transport no longer needs a
  revali-side change for it. (F-06)
- **`.revali/` is a gitignored build artifact, and `dart test` reads it.** A stale one in the main
  checkout made `showrunner integrate` fail twice on tests that pass in every worktree, because the
  suite was comparing P2-05's controller against Phase 1's generated route. **Run `dart run revali
  build` before integrating any change under `routes/`.** (Phase 2 integration)
- **`SproutStore` has no transaction seam.** `takeSnapshot` orders its reads so the picture can only
  run *ahead* of its cursor, never behind — a consumer may double-apply, never gap. That is safe,
  not exact; a `readTransaction` on `lib/store.dart` would make it exact. (P2-02)
- **Subtree spend is structurally partial by observation, not by omission.** All six Phase 0
  captures carry `parent_tool_use_id: null` on every `result` frame, so `total_cost_usd` exists
  only for the root. A subagent's own cost is `null`, never `0`, and a subtree with an unreported
  node renders `>=$X (n unknown)` rather than a total. Do not "fix" this into a sum: a sum is not a
  distribution (INV7), and a guessed total is indistinguishable from a measured one. (P2-02)
- **`microUsd` / `formatUsd` are not exported from `lib/policy.dart`.** P2-02 used
  `SpendLedger.subtreeMicroUsd` plus a local formatter rather than edit a file outside its leaf.
  Subtree spend is quantised to micro-dollars (`0.2415507` → `0.241551`) while a node's *own* cost
  is the control-plane figure verbatim — they are deliberately not equal. (P2-02)
- **`async*` + `await for` leaks on an idle stream.** A consumer's `cancel()` never completes while
  the tree is quiet (dart-lang/sdk#26686, reproduced standalone by P2-03). `watchFrames` is
  StreamController-driven for exactly this reason. Any new long-lived stream should be too. (P2-03)
- **`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` is not set from the policy**, so behaviour at the limit
  is unobserved. P1-04's concurrency defaults (4 per node, 12 tree-wide) have no research behind
  them, unlike the depth cap of 3 — they are knobs, not findings. (Phase 1)
- **`Notification`, `PreCompact` and `PostCompact` hook payloads remain uncaptured.** Nothing before
  Phase 5 needs them. (Phase 0)
