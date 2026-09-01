# sproutd

`sproutd` is the sprout daemon: a machine-wide Dart service that spawns recursive Claude Code
sessions and watches them from *outside* the sessions. It owns the task graph (depth-capped at 3),
the per-subtree budgets, the append-only event feed, and the process supervision — all of it in one
package, backed by a single SQLite file and served over a Revali HTTP/WebSocket API bound literally
to `127.0.0.1`. It ships as one relocatable binary with no run-time toolchain, `pub get`, or asset
directory: copied anywhere and run from any working directory, it works. The web UI is a *separate*
package (`sprout_ui`, Phase 3) because `revali` and `jaspr_builder` conflict on analyzer versions
via a `dart_style` pin — they must never share a package and never a Dart workspace.

The single binary is produced by a five-step pipeline (`docs/research/05-dart-stack.md`, verified end
to end on macOS arm64 at 7.88 MB):

```bash
# 1. Build the UI — client mode, 5 files, ~220 KB of pure static output.
cd sprout_ui && dart pub get && dart run jaspr_cli:jaspr build

# 2. Copy that payload into this package (drop packages/ and .build.manifest).
rsync -a --exclude 'packages/' --exclude '.dart_tool/' --exclude '.build.manifest' \
      build/jaspr/ ../sproutd/web/

# 3. Generate lib/src/assets.g.dart from web/ — base64 constants plus a MIME map.
cd ../sproutd && dart run tool/embed_assets.dart

# 4. Revali codegen → .revali/server/server.dart, a plain entrypoint with main().
dart run revali build

# 5. The binary.
mkdir -p build && dart compile exe .revali/server/server.dart -o build/sproutd
```

Steps 1–3 are **CI-time only**. They exist solely to turn the UI into Dart source that the compiler
can swallow, because Dart has no `//go:embed` and Revali's `public/` reads files from disk relative
to the process working directory — which returns HTTP 500 the moment the binary is run from
anywhere but its source tree. A developer installing sprout never runs any of them, never sees
`web/`, and receives exactly one file. Only steps 4 and 5 are needed to build the daemon from a
clean checkout without a UI.
