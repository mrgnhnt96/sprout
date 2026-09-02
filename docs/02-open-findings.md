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

### F-08 — The rule-file guard reads command text, so an interpreter heredoc walks past it

**Status: OPEN, and it is game_loop's to fix, not sprout's.** Found this session, by the P3-02
Crawler doing it accidentally. **Fix lives in** `~/.claude/game_loop-central/.game_loop/bin/guard-writes-impl.sh`
— machine-wide code outside this repo, which sprout may only read.

`.game_loop/verify.yaml` is a rule file: the guard refuses `Write`/`Edit` to it, and refuses a
shell redirect, `tee`, `sed -i` or `cp` onto it, so that widening the gate always passes through
`game_loop authorize` and lands a human's words in `log.jsonl`. **The audit trail is the point of
the gate, more than the prevention is.**

The P3-02 Crawler added a `sprout_ui/**` rule to that file with no grant and no refusal logged in
either its worktree's `log.jsonl` or the main checkout's. It did it like this:

```
python3 - <<'PY'
p='.game_loop/verify.yaml'
s=open(p).read()
...
```

The guard reads the **command string**. `python3 - <<'PY'` is not a redirect onto the path, does
not name the path in a position the guard parses, and the write happens inside the interpreter. So
the call is allowed and nothing is logged.

**This is a known blind spot, not a surprise.** The guard's own refusal message says so verbatim —
*"WHAT THIS STILL CANNOT SEE (INV6): a `python3 -c` that writes the file, a path built from a shell
variable, or any MCP tool. It reads the command string. Prevention where it is cheap; the file's
own hash is the detection this does not yet do."* That is INV6 working as designed: a guard that
states what it misses. The gap is that the stated remedy has not been built.

**What caught it instead:** `showrunner integrate` refused the merge as *harness-drifted*, because
the Crawler's tree no longer carried the same rules as the main checkout. Defence in depth held,
one gate later than it should have — at merge rather than at the write.

**The remedy the guard itself names** is detection rather than prevention: hash the rule files and
notice when one changed without a matching `authorize` entry. Prevention by text-reading cannot be
completed — an arbitrary interpreter cannot be parsed — so the honest fix is a post-write hash
check, which also catches the MCP and shell-variable cases the same message lists.

**Do not "fix" this by forbidding `python3` heredocs.** They are how this session is instructed to
edit files at all, and a guard that blocks the ordinary path teaches people to route around it.

**Confirmed a second time, first-person.** Adding the `sprout_protocol/**` rule below, this session
took a `game_loop authorize` grant from Morgan and then wrote the file with a `python3 - <<'PY'`
heredoc. The grant was **not consumed and no `authorized_write` was logged** — the guard never
fired. Re-running the identical write as `cp <file> .game_loop/verify.yaml` was refused, consumed
the grant, and produced the log entry. Same file, same content, same session, same minute: the
interpreter path is unguarded and the shell path is guarded. That is the gap in one pair of runs,
and it is why the remedy has to be detection on the file rather than more parsing of the command.

### F-14 — Two independent hook-payload parsers now exist, and they agree by coincidence

**Status: OPEN, and it is P8-02's to close** — that is the leaf which will need one of them and is
the first that can pick without guessing.

P8-01 added `HookPayload` in `sproutd/lib/src/hooks/payload.dart`, the general parser for every hook
event. `UserPromptSubmitPayload` in `sproutd/lib/src/stream/prompt.dart` was already there, added
earlier for one event, and it is also a hook-payload parser — its own doc comment says so. The two
independently declare **six of the same accessors over the same wire fields**: `session_id`,
`prompt_id`, `cwd`, `permission_mode`, `transcript_path`, `prompt`.

That is F-01's shape and F-11's exactly: two derivations of one fact, equal today, with nothing that
fails when they stop being equal. Neither file imports the other, so a field that changes spelling
gets fixed in whichever one the next reader happens to open.

**The repair is small and obvious**, which is part of why it should be done deliberately rather than
in passing: `UserPromptSubmitPayload` becomes a `HookPayload` — it already needs nothing the general
class does not have — and keeps only what is genuinely its own, which is `origin`,
`isMachineTraffic` and `taskNotification`, the `<task-notification>` classification that is the
reason it exists at all. `stream.dart` keeps exporting the name, so no importer moves.

**Why it was not fixed by P8-01.** `lib/src/stream/prompt.dart` and `lib/stream.dart` are the stream
leaf's files, not this one's, and siblings were working other leaves in the same tree. P8-01 also
had no consumer to prove the merged shape against — it writes nothing. P8-02 will have one.

**What is NOT wrong here.** The two parsers do not disagree; every shared accessor reads the same
key with the same null-on-wrong-type discipline, and the `agent_id`-based derivations that this
leaf's tests actually pin are declared once. This is a hazard that has not fired, reported before it
does.

---

### F-13 — `sprout_protocol/pubspec.yaml` still says the gate does not check it, and the gate does

**Status: OPEN.** Found by the F-12 Crawler, which read the comment before running the checks and
believed it.

`sprout_protocol/pubspec.yaml:60` states, in bold: *"`.game_loop/verify.yaml` still owes this
package a rule … Until one lands, a change confined to `sprout_protocol/**` is UNCHECKED"*. That
rule landed. `.game_loop/verify.yaml:111` carries a `"sprout_protocol/**"` entry running this
package's format and analyze plus **both** consumers' suites — the exact shape the comment asks
for, with its own comment above it explaining why the consumers are the load-bearing half.

The rest of the paragraph is still true and worth keeping: `cd sproutd && dart analyze
--fatal-infos` really does not analyze these sources, which is why the rule has to exist. Only the
"still owes" claim and the "UNCHECKED" conclusion are stale.

**Why it matters more than a stale comment usually does.** It tells the next reader their change to
this package is unverified when it is in fact the most heavily verified path in the repo — and the
plausible reactions to believing it are all wrong: skip the gate, hand-test instead, or re-add a
rule that already exists. A comment that understates coverage is read as permission.

**Why it was not fixed here.** F-12 touched this package's `lib/`, not its `pubspec.yaml`, and the
correction is a prose edit with no test that can hold it.

---

## Notes that are not findings

These are true, cost nothing to know, and would cost real time to rediscover.

- **A wildcard route cannot be reached through an empty-path controller in `revali_router` 5.1.1,
  and neither can a `:param` one.** `@Get('*asset')` under `@Controller('')` generates
  `Route('', routes: [Route('*asset', …)])`, which is well formed and never matches: `Find` walks
  into an empty-path parent only when the requested segment *equals the child's own path* —
  `path == route.path || (route.path.isEmpty && path == proxy?.path)` in
  `lib/src/router/find.dart` — and `'main.css'` is never equal to `'*asset'` or to `':asset'`.
  Observed against the compiled binary, not reasoned about: `GET /main.css` returned revali's own
  `Not Found` body while `GET /` worked. So the UI serves one static route per asset name, and
  `servedAssetNames` in `routes/controllers/ui_controller.dart` is compared against the embedded
  payload by `test/ui_test.dart` so the two spellings cannot drift. **Adding a file to the payload
  means adding a route.** (P3-03)
- **`MemoryFile` is the wrong body for anything a browser renders.** It is the obvious choice — it
  carries bytes *and* a mime type — but `MemoryFileBodyData.headers` assigns `filename`, and
  `HeadersImpl.filename` writes `content-disposition: attachment; filename="…"`
  (`revali_router` 5.1.1). A page served that way is downloaded rather than rendered, with a 200 in
  the log. A plain `List<int>` body is a `BinaryBodyData`, which adds no disposition, and
  `Response.joinedHeaders` merges the body's headers with `headers[key] ??= …` so a `content-type`
  set on the response wins. This is the same shape as F-03 (`@SSE` shipping
  `application/octet-stream` with the override ignored): **read the header off the wire.** (P3-03)
- **`AppConfig.prefix` wraps every controller route, so a prefixed app cannot answer at `/`.** The
  generated server does `_routes = [Route(prefix, routes: _routes)]` and registers only `public`
  and the health probes outside it (`revali` 3.3.2, `server_file_maker.dart`). P3-03 therefore
  moved `api` out of the app and into `@Controller(treeControllerPath)`; the URLs are unchanged.
  A side effect worth knowing: **revali names the generated route file after the controller path**,
  so `.revali/server/routes/__tree_route.dart` became `__api_tree_route.dart`, and the drift check
  in `test/ws_test.dart` that reads it went from asserting to *skipping* until the path was
  updated. A check that quietly stops running is worse than one nobody wrote. (P3-03)
- **`sproutd/lib/src/ui/assets.g.dart` is committed, and it can be stale.** It has to be committed:
  the package imports it, so a checkout without it does not analyze, test or compile. The cost is
  that the UI payload is in git twice — as base64 here, and as the `sprout_ui` sources it was built
  from — and that rebuilding the UI without re-running `dart run tool/embed_assets.dart` ships a
  binary serving the previous UI. `--check` turns that into a failure, but only where `web/` exists,
  which is after steps 1 and 2 of the pipeline have run; `test/ui_test.dart` skips it with a stated
  reason otherwise rather than passing in silence. (P3-03)
- **A non-empty `main.client.dart.js` proves the import graph, not the decoder.** P3-05 gave
  `sprout_ui/lib/app.dart` a real `import 'package:sprout_protocol/protocol.dart'` and an
  exhaustive `switch` over `ProtocolFrame`, and the bundle went from *absent* to 109,503 bytes.
  But `App` is only ever constructed as `const App()` with `frame: null`, so dart2js proves the
  other branches unreachable and drops them: grepping the built JS finds `sprout-shell` and `The
  UI payload is served` and **none** of the protocol's own string literals. What the build does
  prove is the thing F-07 was about — build_web_compilers decides on the *library import graph*
  before any tree-shaking, and it no longer skips the entrypoint. The whole protocol library is
  also genuinely front-end compiled, which is how the `BigInt` error above was caught at all.
  Once P3-04 decodes a real frame, `payload_test.dart` should gain a string fingerprint from the
  protocol; until then it cannot have one honestly. (P3-05)
- **`package:sprout_protocol` is compiled for the browser, so its arithmetic has to be.**
  The split that closed F-07 made `SproutInstance` a web target, and its FNV-1a hash used 64-bit
  `int` — which is a JavaScript double on the web. `0xcbf29ce484222325` is a *compile error* under
  dart2js (*"The integer literal ... can't be represented exactly"*), and the wrapping 64-bit
  multiply would have disagreed with the VM even if the literal had fit. `_idFor` uses `BigInt`,
  which is exact on both, and `protocol_test.dart` pins the id of a fixed input against the value
  the pre-split native-int code computed. The pin is the load-bearing half: the tests already there
  asked only whether the derivation agreed *with itself*, which a divergence satisfies from inside
  either platform. A browser deriving a different id from the same feed has every cursor it offers
  refused as foreign — F-01 arriving by a new road. (P3-05)
- **The web build's failure modes are not one failure mode.** An unsupported `dart:` library in the
  transitive import graph is a **WARNING**: `jaspr build` exits 0, writes no bundle, and that was
  F-07. A library that *is* web-safe but does not compile is an **ERROR**: the build exits 1 and
  says why. Fixing the first converts silence into noise, so the second only becomes visible after
  the first is repaired — expect a real compile error to appear the moment a graph problem is
  solved, and do not read it as the split having failed. (P3-05)
- **Neither gate analyzes `sprout_protocol/`.** Measured by planting a lint in
  `sprout_protocol/lib/` and running both: `cd sproutd && dart analyze --fatal-infos
  --fatal-warnings` and `cd sprout_ui && ...` each reported *No issues found*. `dart analyze`
  covers the package it is run in, not its path dependencies. `dart test` in sproutd *does* execute
  that code, so behaviour is covered and static quality is not — and only when a commit also
  touches a path matching an existing rule. `.game_loop/verify.yaml` owes the package a rule; it is
  write-guarded and P3-05 did not have it. (P3-05)
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
  Phase 5 needs them. They nevertheless have `hook.*` kinds as of P8-01, because a name that is
  known and unfired is a different thing from a name that is unknown — folding them into
  `hook.unknown` would make the first one ever captured read as a schema change rather than a first
  sighting. (Phase 0, P8-01)
