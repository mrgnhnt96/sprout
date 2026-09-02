# sproutd

`sproutd` is the sprout daemon: a machine-wide Dart service that spawns recursive Claude Code
sessions and watches them from *outside* the sessions. It owns the task graph (depth-capped at 3),
the per-subtree budgets, the append-only event feed, and the process supervision — all of it in one
package, backed by a single SQLite file and served over a Revali HTTP/WebSocket API bound literally
to `127.0.0.1`. It ships as one relocatable binary with no run-time toolchain, `pub get`, or asset
directory: copied anywhere and run from any working directory, it works. The web UI is a *separate*
package (`sprout_ui`, Phase 3) because `revali` and `jaspr_builder` conflict on analyzer versions
via a `dart_style` pin — they must never share a package and never a Dart workspace.

The single binary is produced by a five-step pipeline (`docs/research/05-dart-stack.md`). As built
by P3-03 on macOS arm64: **8,080,208 bytes, one file**, serving a 110,640-byte UI payload.

```bash
# 1. Build the UI — client mode. Three files, 110,640 bytes of static output:
#    index.html, main.css, main.client.dart.js.
cd sprout_ui && dart pub get && dart run jaspr_cli:jaspr build

# 2. Copy that payload into this package (drop packages/ and .build.manifest).
rsync -a --exclude 'packages/' --exclude '.dart_tool/' --exclude '.build.manifest' \
      build/jaspr/ ../sproutd/web/

# 3. Generate lib/src/ui/assets.g.dart from web/ — one base64 constant per file.
cd ../sproutd && dart run tool/embed_assets.dart

# 4. Revali codegen → .revali/server/server.dart, a plain entrypoint with main().
dart run revali build

# 5. The binary.
mkdir -p build && dart compile exe .revali/server/server.dart -o build/sproutd
```

Steps 1–3 exist solely to turn the UI into Dart source the compiler can swallow, because Dart has
no `//go:embed` and Revali's `public/` reads files from disk relative to the process working
directory. The generated handler is `context.response.body = File(p.join('public', <path>))`
(`revali` 3.3.2, `public_file_maker.dart`) — a *relative* path, resolved against the CWD on every
request. `ResponseImpl.body=` stats that file and sets **404** when it is missing
(`revali_router` 5.1.1); `docs/research/05-dart-stack.md` recorded a 500 for the same situation, and
the two were not reconciled because neither status is one a UI can be served with. Either way a
`public/` UI works in the worktree and fails everywhere else. A developer installing sprout runs none of these steps, never sees `web/`, and
receives exactly one file.

**Steps 4 and 5 alone build a working daemon with a working UI**, because `assets.g.dart` is
committed. That is deliberate and it has a cost: the payload is in git twice, and a rebuilt UI is
stale until step 3 is re-run. `dart run tool/embed_assets.dart --check` fails on exactly that, and
`test/ui_test.dart` runs it wherever `web/` exists.

The content type of every asset comes from one table, `lib/src/ui/content_types.dart`, read by the
generator and by the route. An extension it does not know **fails step 3** rather than defaulting to
`application/octet-stream`: a browser discards a stylesheet or a script served that way with no
error anywhere, and the page simply renders blank.
