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

## F-01 — The CLI and the daemon do not agree on an instance id

**Status:** BLOCKING Phase 3 · **Found by:** P2-04, confirmed by P2-05 · **Fix lives in:**
`sproutd/lib/protocol.dart`

`SproutInstance.current` is generated **per process**. `sprout snapshot` and the daemon are
different processes, so the cursor a user copies out of `sprout snapshot` is refused by the
WebSocket as foreign, every time. The join that the whole protocol exists to protect — take a
snapshot, then apply deltas from its cursor — is broken between the two surfaces sprout actually
ships.

P2-04 hit this first and it nearly made its own leaf impossible: `snapshot` and `watch` are also
two processes, so every cursor the CLI minted would have been refused by the CLI itself. Its
workaround, in `bin/sprout.dart`, derives the id from a hash of the **absolute database path** plus
the identity of the feed's **first** event. The feed is append-only, so that id is stable while it
is the same feed, and it changes the moment the file is replaced — meaning a database deleted and
recreated at the same path is still correctly refused.

**The fix** is lifting that derivation into `lib/protocol.dart` as `SproutInstance.forStore(...)`
and calling it from both `bin/` and the controller. **Do not fork a second hash that happens to
agree today** — two independent derivations that must stay equal is the bug, not the repair.

**Already pinned:** `sproutd/test/ws_test.dart` carries a test named *"the CLI and the daemon do not
agree on an instance id so a cursor sprout snapshot minted is refused by the socket"*. It asserts
today's broken behaviour on purpose, so it **fails the day the fix lands** and cannot be forgotten.
Update it in the same commit.

---

## F-02 — Creating a subagent node appends no event

**Status:** BLOCKING Phase 3 · **Found by:** P2-04's end-to-end test · **Fix lives in:**
`sproutd/lib/src/runner/projection.dart:143`

`StoreProjection._syncSubagents` writes a subagent's node row with `putNode` and appends **no
event**, while every frame it goes on to emit is attributed to the emitting node. The consequence
is precise: a consumer holding a snapshot **plus every delta after it** still does not know that
subagent node exists. Only a fresh `snapshot` reveals it.

A new *root* does announce itself, via `runner.spawned` — so this is a gap in one path, not a
missing mechanism.

This blocks Phase 3 directly. A live UI is built on the promise that `snapshot` once + `watch`
forever keeps you current; here it silently does not, and the failure looks like a subagent that
never appeared rather than like an error. P2-05 was explicitly told **not** to paper over it by
re-snapshotting on the socket, and did not.

**The fix** is appending a node-created event in the same write that creates the row, so the two
cannot diverge. P2-04 asserted the gap rather than repairing it or relaxing its test around it;
that assertion will fail when the event is added, which is the point.

---

## F-03 — `@WebSocket.ping(...)` is silently dropped, and that leaks a session per disconnect

**Status:** BLOCKING Phase 3 · **Found by:** P2-05 · **Fix lives in:** upstream
`revali_construct`, or a local workaround in `sproutd/routes/controllers/`

`revali_construct 3.0.0`'s `WebSocketAnnotation.fromAnnotation` reads `Duration`'s **private
`_duration`** field, which Dart **3.13.2** replaced with the public `inMicroseconds`. The read
yields null, `create_child_route.dart:48` emits no ping, and **`revali build` succeeds with no
warning** — the annotation is accepted and then discarded.

Why that is a leak rather than a cosmetic loss: while `runHandler(onConnect)` is streaming,
`execute()` has not yet reached `listenToMessages()`. Nobody is reading the socket, so the peer's
close frame is never processed, `closeCode` stays `null`, and `webSocket.add` keeps succeeding into
a client that is gone. **A client hang-up is never noticed, and every disconnect leaks a watch
session together with its 15s heartbeat timer and its 250ms poll timer.** A daemon that has been up
for a day has one per browser refresh.

**Measured on a real loopback socket, both halves:** still subscribed **12s** after the client left
with no ping; torn down in **2219ms** at ping 1s and **1213ms** at 500ms. Paired tests in
`sproutd/test/ws_test.dart` pin both — that teardown *does* work when the transport reports the
disconnect, and that nothing reports it through the generated route today.

**The fix:** passing a `Duration` straight to `WebSocketRoute(ping: ...)` works, so **only the
annotation path is broken**. Either patch upstream, or bypass the annotation locally. Do not
"solve" it with an application-level timeout — the socket is unread, so an application-level timer
is watching the wrong thing.

---

## F-04 — `lib/protocol.dart` has no `SnapshotFrame`

**Status:** OPEN · **Found by:** P2-05 · **Fix lives in:** `sproutd/lib/protocol.dart`

The sealed `ProtocolFrame` covers `ready`, `heartbeat`, `bye` and `delta` — but not `snapshot`,
which is the frame the socket *opens with*. `ProtocolFrame.decodeLine` therefore throws
`"unknown frame type"` on the very first thing a consumer reads, and every consumer needs one
special-case branch before it can use a single decoder. Phase 3's client will hit this in its first
hour.

Adding `SnapshotFrame` belongs in that library, alongside the frames it already owns.

---

## F-05 — Two-way is the right mode, but the back channel cannot be concurrent yet

**Status:** OPEN, blocks nothing before Phase 7 · **Found by:** P2-05 · **Fix lives in:** upstream
`revali_router`

`revali_router 5.1.1`'s `execute()` awaits `runHandler(onConnect)` **to completion** before calling
`listenToMessages()`. On a long-lived socket the connect handler never completes, so the back
channel is never serviced concurrently with server push. The socket is correctly negotiated as
`twoWay` and the mode is the right choice — Phase 7's steer needs it — but a steer arriving on that
channel needs a revali-side change, not just an application-side handler. Note this is the same
underlying behaviour as F-03: nothing reads the socket while the handler streams.

---

## Notes that are not findings

These are true, cost nothing to know, and would cost real time to rediscover.

- **Every WebSocket message arrives as a *binary* frame**, never text — `BodyImpl.read()` is
  `Stream<List<int>>` whatever the payload type. Phase 3's browser client must set `binaryType`
  and decode. (P2-05)
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
