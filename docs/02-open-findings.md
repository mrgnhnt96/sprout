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

## F-05 — Two-way is the right mode, but the back channel cannot be concurrent yet

**Status:** OPEN, blocks nothing before Phase 7 · **Found by:** P2-05 · **Fix lives in:** upstream
`revali_router`

`revali_router 5.1.1`'s `execute()` awaits `runHandler(onConnect)` **to completion** before calling
`listenToMessages()`. On a long-lived socket the connect handler never completes, so the back
channel is never serviced concurrently with server push. The socket is correctly negotiated as
`twoWay` and the mode is the right choice — Phase 7's steer needs it — but a steer arriving on that
channel needs a revali-side change, not just an application-side handler.

**Nothing reads the socket while the handler streams**, which is also why the socket carries a ping:
the ping is timer-driven rather than read-driven, so it is the only thing that notices a peer that
has gone. That half is fixed and pinned in `sproutd/test/ws_test.dart`; this half is not, and a
timer cannot substitute for it — an unread inbound message is not late, it is unread.

---

## F-06 — The ping closes healthy sockets too, at twice the ping interval

**Status:** BLOCKING Phase 3 · **Found by:** the trunk proof of F-03 · **Fix lives in:**
`sproutd/routes/controllers/tree_controller.dart`, or upstream `revali_router`

F-03's fix works: the annotation's ping now reaches the generated route, and a peer that has gone
away is reclaimed instead of leaking a watch session. But the teardown does not distinguish a live
peer from a dead one. **Every connection is closed at 2x the ping interval, whether or not the
client answers.**

Measured on trunk (HEAD `305e106`) against the compiled daemon run from `/`, on a real loopback
socket, with the generated route carrying `ping: Duration(microseconds: 15000000)`:

```
client that never pongs      +15.0s  <-- PING (opcode 9)
                             +30.0s  CLOSE code 1001
client that DOES pong        +15.0s  <-- PING, well-formed masked pong sent
                             +30.0s  CLOSE code 1001      <-- identical
```

Before the fix the same probe held a socket **40.0s with no close** (the Phase 2 proof), so the
close is new with this change and not pre-existing behaviour.

**The mechanism, stated at the confidence it was established:** the close at 1001 after an
unanswered ping is `dart:io`'s documented `WebSocket.pingInterval` behaviour, and that half is
directly observed. That the pong is *never seen* is inferred — but it follows from **F-05**, which
records that `revali_router 5.1.1`'s `execute()` awaits `runHandler(onConnect)` to completion
before calling `listenToMessages()`. Nothing reads the socket while the handler streams, so an
inbound pong is never processed and the ping timer cannot be satisfied by anything. **F-06 and F-05
are the same unread socket seen from two sides**, which is also why an application-level fix cannot
work — the same reason F-03 warned against an application-level timeout.

Why this blocks Phase 3: the UI's whole model is one long-lived socket carrying snapshot-then-
deltas. At 15s ping it is dropped every 30 seconds. A reconnect loop would paper over it and would
also re-send a full snapshot twice a minute, which is exactly the "attaching is never a blank
screen" property the protocol was built to provide, spent on a timer.

**Do not "fix" this by removing the ping** — that restores F-03's leak, and the two paired
`ws_test.dart` cases pin both halves. The honest options are a revali-side change so the socket is
serviced while the handler streams (which also closes F-05), or a local transport bypass that owns
its own liveness check and can actually observe the pong.

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
