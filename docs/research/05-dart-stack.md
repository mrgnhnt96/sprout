# Dart stack — Revali / Zonai / Jaspr feasibility notes

**Sources:**

AI reference sheets — searched for all three:
- `https://docs.revali.dev/llms.txt` — **FOUND** (15 KB index). `llms-full.txt` → 404. Better: `dart run revali ai claude` emits a **35 KB condensed reference** into the project. Used heavily below.
- `https://docs.zonai.dev/llms.txt` — **FOUND** (16 KB, explicitly "a curated index for LLMs and coding agents"). `llms-full.txt` → 404. `zonai ai <tool>` installs project-local rules.
- `https://docs.jaspr.site/llms.txt` — **FOUND** (10 KB index) **and `llms-full.txt` — FOUND (366 KB, full corpus)**. Also `jaspr install-skills` ships versioned Agent Skills.
- Both mrgnhnt96 sites also serve a full-text corpus at `/search-index.json` (revali 594 KB / zonai 434 KB, one record per page split by heading). Jaspr does not.

Doc pages fetched: docs.revali.dev {`/revali`, `/revali/getting-started/{installation,run-the-server}`, `/revali/cli/build`, `/revali/app-configuration/create-an-app`, `/constructs/revali_server/response/{server-sent-events,websockets,public}`, `/constructs/revali_server/context/reflect`, `/constructs/revali_docker/deploy`}; docs.zonai.dev {`/`, `/getting-started/*`, `/core-concepts/*`, `/operations/*`, `/database/*`, `/deployment/*`, `/cli/*`, `/dashboard/overview`, `/configuration/environment-variables`}; docs.jaspr.site {`/dev/{modes,server,client,cli,deploying,static_sites,ai}`, `/going_further/backend`, `/concepts/data_fetching`, `/api/utils/{run_app,at_client,sync_state_mixin}`, `/releases/v/0.22.0`}; pub.dev API for `revali`, `revali_router`, `revali_server`, `jaspr`, `jaspr_builder`, `jaspr_cli`, `jaspr_web_compilers`, `zonai*`, `sqlite3`; github.com/mrgnhnt96/zonai releases.

**Confidence: HIGH.** This is not a docs-only survey. I built and ran the stack on this machine (Dart 3.13.1, macOS arm64): a real Revali server compiled to a native binary, a real `jaspr build`, the two combined, and `sqlite3` AOT-compiled. Every claim marked ✅VERIFIED was executed. Inference is marked **[inferred]**.

---

## Verdict up front

**YES-WITH-CAVEATS — but the stack is 2-of-3, not 3-of-3.**

Revali + Jaspr + `sqlite3` gives you exactly the artifact you want, and I proved it end to end: **a single 7.9 MB `dart compile exe` binary, copied to `/tmp`, run with `cwd=/` and its source tree deleted, served the full Jaspr web UI (HTML + 202 KB JS + CSS + SVG, correct content types), a JSON API, and a WebSocket `101 Switching Protocols` — bound to `127.0.0.1` only.** Nothing on disk, no toolchain, no `pub get` at run time.

**Zonai must be dropped.** It is not persistence — it is a competing HTTP server framework, and it is the one thing in the stack that *cannot* be a single binary. It is not on pub.dev, has no in-process Dart data API (your own code queries it over HTTP), spawns child executables from a `.zonai/executables/` directory at run time, ships as a *directory* you must keep together, and always exposes an admin dashboard at `/_` with no flag to disable. Use `package:sqlite3` directly — Revali's own docs recommend exactly that, it AOT-compiles cleanly, and recursive CTEs give you the task tree for free (✅VERIFIED).

Two caveats that will bite on day one, both verified and both with clean workarounds: **Revali's `@SSE` does not emit browser-compatible Server-Sent Events** (wrong content-type, no `data:` framing, not overridable) — use `@WebSocket`, which works and is the better fit anyway since the UI must send corrections back. And **Revali's `public/` directory reads files from disk relative to CWD**, so it is unusable here — generate a Dart file of embedded bytes instead (~40 lines of tooling).

---

## Revali

`revali` **3.3.2** (dev-dependency, the codegen CLI) · `revali_router` **5.1.1** (the *only* runtime dependency) · `revali_server` 2.4.1. First 1.0 in Nov 2024, 31 releases, last 2026-08-17. Mature by the standards of this list.

### Programming model

Annotation-driven, **build-time** codegen — no reflection, no runtime scanning. Two filesystem conventions: a `routes/` directory scanned for `*_app.dart` and `*_controller.dart`, and a generated `.revali/` you never hand-edit.

```dart
// routes/main_app.dart
@App()
final class MainApp extends AppConfig {
  const MainApp() : super(host: '127.0.0.1', port: 8787);
  @override
  Future<void> configureDependencies(DI di) async {
    di.registerLazySingleton<Store>(() => Store.open());
  }
}

// routes/controllers/tree_controller.dart
@Controller('tree')
class TreeController {
  const TreeController(this._store);   // constructor injection
  final Store _store;

  @Get()
  Map<String, Object?> snapshot() => _store.snapshot();
}
```

`revali build` generates `.revali/server/server.dart` — a **plain, self-contained Dart file with a `main()`**. That is the whole trick: codegen is strictly build-time, and the output is an ordinary entrypoint you hand to `dart compile exe`. ✅VERIFIED: 7.42 MB Mach-O arm64 in ~2 s.

Note: **the default route prefix is `api`** even when you pass none — routes land at `/api/tree`, not `/tree`. Cost me a confused 404. Set `prefix:` explicitly.

### Streaming — the important gotcha

Both `@SSE` and `@WebSocket` exist. **`@SSE` is not usable from a browser.** ✅VERIFIED against the compiled binary:

```
$ curl -N http://127.0.0.1:8787/api/tree/events | xxd
{"data":"tick0"}{"data":"tick1"}{"data":"tick2"}
content-type: application/octet-stream
content-disposition: attachment; filename="file.txt"
```

No `data: ` prefix, no `\n\n` record separator, no `text/event-stream`. `EventSource` cannot consume this. It is a chunked-JSON stream shaped for Revali's *generated Dart client*, not for the web. I tried overriding the header inside the handler (`res.headers.set('content-type', 'text/event-stream')`) — **ignored**, the response still went out as `application/octet-stream` with `content-disposition: attachment`. Revali's own AI reference lists "WebSocket/SSE handler lifecycle details" as a known documentation gap.

**`@WebSocket` works properly** — ✅VERIFIED real `HTTP/1.1 101 Switching Protocols` with correct `upgrade`/`connection` headers from the compiled binary. Modes: `twoWay` (default), `receiveOnly`, `sendOnly`. `AsyncWebSocketSender<T>` pushes without client input; `CloseWebSocket` closes.

```dart
@WebSocket('events')                       // ws://127.0.0.1:8787/api/tree/events
String events(@Body() String msg, AsyncWebSocketSender<String> sender) {
  bus.stream.listen(sender.send);          // server → UI: live tree + decisions
  return handleCorrection(msg);            // UI → server: correction to a node
}
```

This is the right choice regardless: sprout's UI needs a *back* channel ("send a correction to any node"), which SSE could never provide.

### Static assets — does not embed

`public/` generates one route per file, and each one reads from disk **relative to the process CWD**:

```dart
// .revali/server/definitions/__public.dart  (GENERATED)
Route('index.html', method: 'GET', ignorePathPattern: true,
  handler: (context) async {
    context.response.body = File(p.join('public', 'index.html'));  // ← CWD-relative
  }),
```

✅VERIFIED: running the compiled binary from `/` returns **HTTP 500**, `FileSystemException: Cannot resolve symbolic links, path = 'public/index.html'`. For a machine-wide binary launched from anywhere, `public/` is unusable. See the build pipeline below for the fix.

### Lifecycle, DI, localhost bind

- **DI**: `configureDependencies(DI di)` with `registerLazySingleton` / `registerSingleton` / `registerFactory`; resolved into controller constructors automatically. `RequestScopedDI` for per-request state.
- **Middleware**: one `LifecycleComponent` class; the *return type* of each method picks its role (middleware / guard / interceptor / exception-catcher). Order: Request → Wrapper → Observer → Middleware → Guard → Interceptor → Pipes → Endpoint → (post phases reversed).
- **Localhost-only bind**: just `host: '127.0.0.1'`. ✅VERIFIED — the LAN interface refuses connections (curl exit 7). Do **not** use `host: 'localhost'`: the generated code special-cases that string to `InternetAddress.anyIPv6`, which binds *every* interface. That is a genuine footgun for a security-relevant default.
- Free extras: graceful shutdown w/ in-flight draining, health probes, W3C trace context, gzip, worker isolates (`app.workers`, shared-port).
- No ORM; the docs' database chapter demonstrates `sqlite3` and a repository class behind DI — exactly sprout's shape.

---

## Zonai

**Recommendation: do not use it for sprout.** This is the critical finding of the report.

Zonai is **not a persistence library**. Its own docs: *"Not a full application framework — Zonai is an API server… Not a general-purpose ORM."* It is a batteries-included, self-hosted backend-as-a-service — schema, auth, rules, cron, rate limiting, email, push, and an admin dashboard — i.e. a **direct competitor to Revali**, not a layer under it. Adopting both means running two servers.

Why it cannot satisfy the single-binary requirement:

1. **Not on pub.dev.** `pub.dev/packages/zonai` → 404. Only `zonai_schema` (0.4.2) and `zonai_client` (0.2.2) are published. The `zonai` CLI is a pre-compiled binary downloaded from GitHub Releases and placed in the project root as `./zonai`. You cannot `dependencies: zonai` and call it in-process.
2. **No in-process data API.** Operations return a *query object*, not rows: *"They do not execute the SQL — they return a structured query to the Zonai server."* All reads/writes go over HTTP/JSON (`/db`, `/db/list`, `/db/count`). sproutd would be making HTTP calls to a second local server to store its own task tree.
3. **It is multi-process.** `config`, `extensions`, `rate_limit`, and `crons` run as **separate compiled child executables spawned from `.zonai/executables/`**, IPC via length-prefixed MessagePack on stdin/stdout.
4. **`zonai build` produces a directory, not a binary** — `build/{zonai, .zonai/executables/, migrations/, email_templates/, zonai.yaml}`, and the docs say *"Ship this entire directory to your server."* Files next to it are required at run time.
5. **The "single binary" the user is remembering is the *installer*, not the server.** The GitHub release asset is a ~35 MiB self-extracting launcher with per-OS/arch binaries embedded, which *"decompresses and caches the binary"* on first run. That is a fat multi-arch bootstrapper that writes to a cache — a legitimately clever trick, but it is not what makes a *server* one file, and it is not the mechanism sprout needs.
6. **Always-on admin dashboard at `/_`** in dev *and* production: *"There is no flag that turns it off."* Unwanted attack surface on a developer machine.
7. **Single-writer by design.** Writes serialize on the host, queue cap 64 → `503 WriteBackpressureException`; `ZONAI_HTTP_WORKERS` must stay `1` (*">1 currently regresses list throughput against one SQLite file"*). No multi-OS-process writer story, no user-facing transaction API.
8. **No recursive CTEs.** Zero doc hits for `WITH RECURSIVE`. Relationship traversal is `expand` over FK paths, **server-capped at depth 4**. sprout's tree is *deeply nested by definition* — this alone disqualifies it.
9. **Maturity.** Repo created 2026-04-25 (~4 months old), 2 stars, v0.6.1 → v0.9.0 in 16 days, pub packages first published 2026-08-10. Docs are genuinely excellent; the code is very young. Also — worth saying plainly — it is authored by the same person as sprout, so "use Zonai" may be a preference rather than a requirement.

### Use `sqlite3` instead ✅VERIFIED

`sqlite3` 2.9.4 AOT-compiles and runs from an arbitrary CWD (system libsqlite3 **3.51.0** on macOS), and the recursive CTE that Zonai lacks works directly:

```dart
final r = db.select('''
  WITH RECURSIVE t(id,parent_id,title,depth) AS (
    SELECT id,parent_id,title,0 FROM node WHERE parent_id IS NULL
    UNION ALL
    SELECT n.id,n.parent_id,n.title,t.depth+1 FROM node n JOIN t ON n.parent_id=t.id)
  SELECT * FROM t ORDER BY depth''');
// → 0 a root / 1 b child / 2 c grand
```

Shape for sprout: `node(id, parent_id, project, role, status, current_task, since, next_checkin)` + append-only `event(seq INTEGER PRIMARY KEY AUTOINCREMENT, node_id, ts, kind, payload JSON)`. Enable `PRAGMA journal_mode=WAL` for concurrent CLI readers alongside the daemon writer, and `PRAGMA foreign_keys=ON`. One file under `~/.sprout/sprout.db` covers machine-wide + multi-project.

⚠️ macOS links the *system* libsqlite3, so the binary is self-contained on macOS but **[inferred]** you would need `sqlite3_native_assets` (or a bundled lib) for a portable Linux build.

---

## Jaspr

`jaspr` **0.23.4** / `jaspr_builder` / `jaspr_cli` 0.23.4 (2026-08-14). **0.x, 73 releases, single maintainer** (schultek), ~747 likes. Real breaking changes roughly monthly (0.21 rewrote the component factory API; 0.22 split entrypoints and discontinued `jaspr_web_compilers` in favour of `build_web_compilers`), mitigated by a working `jaspr migrate --apply`.

### Modes

| Mode | Run-time requirement | Fit for sprout |
|---|---|---|
| **static** | none — pre-rendered `.html` files | ok |
| **client** | none — `index.html` + dart2js JS | **best fit** |
| **server** | a Dart process **plus** `build/jaspr/web/` kept next to the executable | avoid — reintroduces an asset dir |

Only `server` mode supports "backend integration" per the official matrix; `static` and `client` are pure files. For sprout, **client mode** is right: the UI is a live dashboard behind localhost, SEO is irrelevant, and the data arrives over WebSocket anyway.

### The crux: can it be embedded? — YES ✅VERIFIED

`jaspr build` (client mode) emits a small, flat, fully static payload:

```
build/jaspr/index.html               732 B
build/jaspr/main.client.dart.js      200 KB   (dart2js release)
build/jaspr/main.css                1.8 KB
build/jaspr/favicon.ico, images/logo.svg
build/jaspr/.build.manifest                   (newline list of outputs)
build/jaspr/packages/**              670 KB   ← build_web_compilers junk, droppable
```

**Real payload: 5 files, 220 KB.** That is trivially embeddable as byte constants. I did exactly that and served it from the Revali binary — see the pipeline below. There is no run-time Dart, no server, no asset directory.

The alternative — AOT'ing Jaspr *server* mode into your binary — technically works but has an undocumented landmine: `webDir` walks up from `Platform.script` looking for `pubspec.yaml` and throws `Could not resolve project directory containing pubspec.yaml` when run standalone. Workaround is compiling with `-Djaspr.dev.web=/nonexistent/web`. Avoid the whole area; client mode has none of this.

### Backend integration

**There is no Revali integration, documented or otherwise** (pub search: nothing). Jaspr's docs say integration *"works best when the backend framework is also compatible with shelf"* — shelf is the assumed backend, plus Serverpod and dart_frog. `revali_router` is built on `dart:io`, **not shelf**, so `serveApp()` (a shelf `Handler`) does not apply.

This does not matter in client mode — Revali just serves bytes. If you ever want SSR, the framework-neutral escape hatch is `renderComponent()`, which returns a plain record rather than a shelf `Response`:

```dart
typedef ResponseLike = ({int statusCode, Uint8List body, Map<String,List<String>> headers});
Future<ResponseLike> renderComponent(Component app, {Request? request, bool standalone = false});
// requires Jaspr.initializeApp(options: defaultServerOptions) first, else exit(-1)
```

### Codegen and live data

`jaspr_builder` + `build_web_compilers` are **dev-dependencies** driven by `build_runner` — strictly build-time, nothing at run time. ✅VERIFIED no `dart:mirrors` anywhere.

State: `StatefulComponent`, `InheritedComponent`, `jaspr_riverpod`. **There is no documented SSE/WebSocket pattern** — the docs state plainly that `@sync` data flow is *"one-directional, server→client, once at initial render"* and that *"if you need … continuous loading of data, you should use a normal server-side api or realtime communication system like websockets."* So the live tree is **[inferred]** hand-rolled: a `@client` `StatefulComponent` that opens a `WebSocket` in `initState` and calls `setState` on each frame. That is ~30 lines and entirely conventional, but it is *your* code, not a framework feature.

---

## The single-binary build pipeline

Verified end to end on this machine. Two packages, deliberately — see the version conflict below.

```
sprout/
├─ sprout_ui/          # jaspr client-mode app   (dev: jaspr_builder, build_web_compilers)
└─ sproutd/            # revali server + CLI     (dev: revali)
   ├─ routes/{main_app.dart, controllers/*.dart}
   ├─ tool/embed_assets.dart
   └─ lib/src/assets.g.dart   # GENERATED
```

```bash
# 1. Build the UI → 5 files, 220 KB of pure static output
cd sprout_ui && dart pub get && dart run jaspr_cli:jaspr build

# 2. Copy the payload into the server package (skip packages/ and .build.manifest)
rsync -a --exclude 'packages/' --exclude '.dart_tool/' --exclude '.build.manifest' \
      build/jaspr/ ../sproutd/web/

# 3. Generate lib/src/assets.g.dart from sproutd/web/  (base64 constants + MIME map)
cd ../sproutd && dart run tool/embed_assets.dart

# 4. Revali codegen → .revali/server/server.dart (a plain entrypoint with main())
dart run revali build

# 5. THE single binary
mkdir -p build && dart compile exe .revali/server/server.dart -o build/sproutd
```

Result: **7.88 MB** (7.42 MB before the UI; +460 KB for 220 KB of assets — base64 inflation). Steps 1–3 are CI-time only; the developer receives one file.

### Embedding assets

Dart has no `//go:embed`. The idiomatic approach is exactly what you'd expect — generate a Dart source file of constants — and **neither Revali nor Jaspr offers anything better** (Revali's `public/` is worse: CWD-relative disk reads). ~40 lines of tooling:

```dart
// tool/embed_assets.dart  (build-time)
for (final f in Directory('web').listSync(recursive: true).whereType<File>()) {
  final rel = f.path.substring(4);
  b.writeln('  ${jsonEncode(rel)}: ${jsonEncode(base64Encode(f.readAsBytesSync()))},');
}
// emits: const _b = <String,String>{...}; Uint8List? asset(String p) => ...
```

Served from an ordinary controller — no `public/`, no disk:

```dart
@Controller('ui')
class UiController {
  const UiController();
  @Get()             Future<void> root(Response r)                  => _send('index.html', r);
  @Get(':one')       Future<void> one(@Param() String a, Response r) => _send(a, r);
  @Get(':one/:two')  Future<void> two(@Param() String a, @Param() String b, Response r)
                                                                     => _send('$a/$b', r);
  Future<void> _send(String p, Response res) async {
    final bytes = assets.asset(p);
    if (bytes == null) { res.statusCode = 404; res.body = 'not found'; return; }
    res.headers.set('content-type', assets.types[p] ?? 'application/octet-stream');
    res.body = bytes;
  }
}
```

Revali has **no wildcard/catch-all route**, hence one handler per path depth. Cleaner long-term option **[inferred, untested]**: write a custom **Revali construct** that generates embedded-byte routes the way the built-in one generates `File()` routes — Revali explicitly supports third-party constructs, and this is precisely the use case.

### Proof

```
$ cp build/sproutd /tmp/ && rm -rf web/ && cd / && /tmp/sproutd
Serving at http://127.0.0.1:8787/api

api/ui                        HTTP 200     732 B  text/html
api/ui/main.client.dart.js    HTTP 200  202086 B  application/javascript
api/ui/main.css               HTTP 200    1873 B  text/css
api/ui/images/logo.svg        HTTP 200    3669 B  image/svg+xml
api/ui/nope.js                HTTP 404
```

Source tree deleted, `cwd=/`, binary relocated. It works.

### AOT / macOS arm64

✅VERIFIED all three AOT-compile to Mach-O arm64. I grepped every `lib/` in the resolved dependency graph (36 packages): **zero `dart:mirrors`** — the only hits were test files and a changelog. Revali's `context.reflect` is *not* runtime reflection; it is a generated `Set<ReflectData>` (`.revali/server/definitions/__reflects.dart`), so it is AOT-safe by construction. Jaspr's server side is mirror-free; its client side is dart2js and never enters the exe.

### Version conflicts ⚠️ REAL

**`revali` and `jaspr_builder` cannot live in the same package's `dev_dependencies` at current versions.** ✅VERIFIED:

```
Because revali >=2.1.0 depends on dart_style >=3.1.4 <3.1.8 and full depends on
jaspr ^0.23.4, revali >=2.1.0 is incompatible with jaspr_builder.
```

Root cause: `jaspr_builder` ≥0.23.2 requires `analyzer ^12.1.0`; `revali` 3.3.2's `dart_style >=3.1.4 <3.1.8` pin drags in `analyzer ^10`.

- **Fix (recommended): two packages**, as above. Their dev-dependencies never co-resolve, so the conflict cannot arise. ⚠️ Do **not** join them with a Dart *workspace* (`resolution: workspace`) — a workspace shares one resolution and will reproduce the conflict.
- Fix (single package, fragile): pin `jaspr: ^0.23.1` / `jaspr_builder: ^0.23.1` (analyzer ^10). ✅VERIFIED the whole stack then resolves in one pubspec: jaspr 0.23.1, revali 3.3.2, revali_router 5.1.1, sqlite3 2.9.4, dart_style 3.1.7, analyzer 10.2.0. But it strands you a release behind and will break again.

Separately: **`jaspr create` emits a pubspec that does not resolve.** ✅VERIFIED — the generated `build_web_compilers: ^4.8.10` conflicts with `jaspr_builder`; downgrading to `^4.8.5` fixes it. Independently hit twice. Expect ~10 minutes of constraint-wrangling on first scaffold, and note that the *discontinued* `jaspr_web_compilers` caps at SDK `<3.11.0-z` — if you add it by mistake on Dart 3.13 the build **silently "succeeds" while emitting no JS at all** (42 MB of raw `.dart` sources and an `index.html` pointing at a nonexistent `main.dart.js`). Use `build_web_compilers`.

One more documented-vs-actual gap: `revali.yaml`'s `build:` block is documented to run `dart compile exe` for you. ✅VERIFIED it does **not** — with `target_os: macos, target_arch: [arm64]` no executable was produced. Harmless: invoke `dart compile exe` yourself (step 5), which works perfectly.

---

## Risks and fallbacks

| Risk | Likelihood | Impact | Fallback |
|---|---|---|---|
| **Zonai is a server framework, not persistence; cannot be a single binary** | **Certain** (verified) | **Critical** — blocks the core requirement | **Drop it. Use `package:sqlite3` + WAL.** Revali's own docs recommend this. Costs you auth/rules/dashboard you don't need on localhost. |
| **`@SSE` emits non-standard, non-overridable framing; unusable from `EventSource`** | **Certain** (verified) | High — this is the live-UI transport | Use **`@WebSocket`** (verified `101`). Better anyway: sprout needs a back channel for corrections. |
| **`public/` reads from CWD; breaks a relocatable binary** | **Certain** (verified: HTTP 500) | High | Generate `assets.g.dart` (~40 lines, verified). Optionally a custom Revali construct later. |
| **`revali` + `jaspr_builder` dependency conflict** | **Certain** (verified) | Medium | **Two packages** (recommended, structural). Or pin jaspr 0.23.1. Never a shared workspace. |
| `jaspr create` scaffolds an unresolvable pubspec | High (hit twice) | Low | Pin `build_web_compilers: ^4.8.5`. |
| Jaspr is 0.x with ~monthly breaking changes, one maintainer | High | Medium | `jaspr migrate --apply` exists and works. Pin exact versions; the UI is an isolated package. **Fallback: hand-written HTML+JS served from the same embedded-asset mechanism** — the embedding is framework-agnostic, so dropping Jaspr costs you the UI code only, not the architecture. |
| No Revali↔Jaspr integration exists; you are the first | Certain | Low | Irrelevant in client mode — Revali serves bytes. Only matters if you later want SSR. |
| `host: 'localhost'` silently binds all interfaces | Certain (read in generated source) | Medium (security) | Always use `host: '127.0.0.1'`. Verified LAN-unreachable. |
| Revali is a small-ecosystem framework by a solo author | Medium | Medium | Runtime surface is one lean package (`revali_router`); generated `server.dart` is readable, ~200 lines, and could be forked or replaced with `shelf` without touching business logic. |
| sqlite3 links *system* libsqlite3 (portable on macOS, not Linux) | Low (macOS-only target) | Low | `sqlite3_native_assets` or bundle the lib for Linux. |
| WebSocket lifecycle under-documented (framework's own AI sheet flags it) | Medium | Low | Verified working at the handshake level; budget time for reconnect/backpressure testing. |

---

## Takeaways for sprout

1. **Ship the stack as Revali + Jaspr (client mode) + `package:sqlite3`.** The single-binary goal is proven, not theorised: 7.9 MB, relocatable, zero run-time disk dependencies.
2. **Cut Zonai now.** It is the wrong shape (a competing HTTP server), the wrong distribution (a directory of child executables), and the wrong data model (no in-process API, `expand` capped at depth 4 vs. sprout's arbitrarily deep tree). Deciding this on day one saves a rewrite later. Keep one idea from it: the self-extracting multi-arch launcher, if you ever want one download for macOS + Linux.
3. **Use `@WebSocket`, not `@SSE`,** for the live tree, the decision feed, and node corrections. `@SSE` is browser-incompatible and cannot be fixed from user code; WebSocket is bidirectional, which the "send a correction to any node" requirement demands anyway.
4. **Write `tool/embed_assets.dart` early** and treat `web/` as build-time-only. Never use Revali's `public/`. This mechanism is framework-agnostic insurance: it keeps Jaspr swappable.
5. **Split `sprout_ui` and `sproutd` into two packages** and do not use a Dart workspace. This structurally dissolves the `revali`/`jaspr_builder` analyzer conflict rather than pinning around it.
6. **Bind `127.0.0.1` explicitly.** `host: 'localhost'` is special-cased in generated code to `InternetAddress.anyIPv6` and exposes the daemon to the LAN.
7. **Model the tree as `node(id, parent_id, …)` and the feed as an append-only `event` table**, queried with recursive CTEs (verified). WAL mode lets `sprout status` read while sproutd writes.
8. **Pin every version and commit the lockfiles.** Jaspr 0.x moves monthly; `jaspr create` already ships broken constraints. Treat "the build resolves" as a CI check.
9. **Budget ~1 day of integration friction**, not a week — the failure modes are known, reproduced, and each has a verified workaround.

---

## Open questions

1. **WebSocket fan-out at scale.** Verified only the handshake and a single echo. Unknown: many concurrent sockets, one per browser tab, with a shared broadcast bus; reconnect semantics; backpressure when a node emits faster than the UI drains. Revali's own AI reference lists WS/SSE lifecycle as a documentation gap.
2. **Does `@WebSocket` interact correctly with `app.workers > 1`?** Worker isolates share the port but not memory, so a broadcast bus in one isolate will not reach sockets in another. Probably means `workers: 1` for sproutd — unverified.
3. **Hot-restart story for the daemon.** sproutd must survive its own upgrades while agent sessions are mid-flight. Revali has graceful shutdown with in-flight draining, but the interaction with long-lived WebSockets is untested.
4. **Linux portability of the sqlite3 link** — needs `sqlite3_native_assets` or a bundled library; untested here (macOS-only run).
5. **Is a custom Revali construct the right way to generate embedded-asset routes?** It would replace the hand-rolled `tool/embed_assets.dart` and the depth-limited `:one/:two` handlers with generated per-file routes. Plausible and idiomatic, but unbuilt.
6. **Jaspr's `@client` hydration boundary** — how much of the deeply-nested tree view should be a single `@client` island vs. many. Affects the 200 KB JS payload and re-render cost. Not investigated.
7. **Multi-project isolation in one SQLite file** — whether one `sprout.db` with a `project` column is preferable to one DB per project for backup/corruption blast radius. A product decision, not a technical blocker.
