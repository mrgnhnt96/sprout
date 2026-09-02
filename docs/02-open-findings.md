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

## F-04 — `lib/protocol.dart` has no `SnapshotFrame`

**Status:** OPEN · **Found by:** P2-05 · **Fix lives in:** `sproutd/lib/protocol.dart`

The sealed `ProtocolFrame` covers `ready`, `heartbeat`, `bye` and `delta` — but not `snapshot`,
which is the frame the socket *opens with*. `ProtocolFrame.decodeLine` therefore throws
`"unknown frame type"` on the very first thing a consumer reads, and every consumer needs one
special-case branch before it can use a single decoder. Phase 3's client will hit this in its first
hour.

Adding `SnapshotFrame` belongs in that library, alongside the frames it already owns.

---

## Notes that are not findings

These are true, cost nothing to know, and would cost real time to rediscover.

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
