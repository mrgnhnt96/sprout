import 'dart:io';

import 'package:test/test.dart';

/// The versions `docs/01-plan.md` §13 pinned *exactly*, because the
/// single-binary pipeline was executed against these and not merely declared
/// compatible with them. A caret here would silently float the stack.
const pinnedExactly = {
  'sqlite3': '2.9.4',
  'revali_router': '5.1.1',
  'revali': '3.3.2',
};

/// Dependencies with no verified-version claim behind them, so a caret range
/// is correct. Asserting this alongside [pinnedExactly] is what stops the pin
/// test from passing vacuously: if the two sets were swapped, or if a pin were
/// quietly loosened to `^`, exactly one of the two groups would fail.
const caretRanged = {'args', 'path', 'test', 'lints'};

/// The libraries the leaves land in. One top-level library per area,
/// deliberately with no shared barrel, so the leaves cannot collide on a
/// single file.
///
/// This is a registry, not a ceiling: a phase that adds an area adds its name
/// here in the same change. `protocol` is Phase 2's, and the wire vocabulary
/// of `snapshot` / `watch --since <cursor>` lives in it.
///
/// The set did **not** change when P3-05 lifted the protocol into
/// `package:sprout_protocol`. `lib/protocol.dart` is still here and still
/// means the same thing to an importer — it re-exports rather than
/// re-declares, which is what keeps `bin/sprout.dart`,
/// `routes/controllers/tree_controller.dart`, `lib/snapshot.dart`,
/// `lib/watch.dart` and every test reading one set of declarations instead of
/// two that agree today. See [reExportedWholesale].
///
/// `ui` is P3-03's: the UI payload compiled into this binary and the
/// `content-type` each file in it is served with. It is an area rather than a
/// corner of an existing library because its bytes are generated —
/// `lib/src/ui/assets.g.dart`, written by `tool/embed_assets.dart` — and
/// generated source that nothing names is the hazard `.game_loop/verify.yaml`
/// opens with.
///
/// `liveness` is P6-01's: live / stalled / abandoned, derived now from a pid
/// beside a transcript mtime. It is its own area rather than part of `runner`
/// because it reads a session it did not spawn — that is the whole point of
/// watching from outside — and because nothing in it may ever act on what it
/// finds, which is easier to keep true of a library than of a corner of one.
///
/// `watchdog` is P6-02's: the loop that runs `liveness` on a schedule, decides
/// when a verdict is worth a human's attention, and rings. Separate from
/// `liveness` because the two answer different questions — one measures, the
/// other decides — and because the never-act rule has to be true of *both*
/// independently. `test/watchdog_test.dart` greps this area's source for a
/// kill or a signal exactly as `test/liveness_test.dart` greps that one, and
/// two areas means two guards rather than one guard covering whichever files
/// happened to sit beside it.
///
/// `hooks` is P8-01's: the parser for the payloads Claude Code delivers on a
/// hook's stdin, which is the second of the two observation paths in
/// `docs/01-plan.md` §4 and the only one that can see a session sprout did not
/// launch. It is its own area rather than a corner of `stream` even though both
/// are pure functions over control-plane bytes, because the two read *different
/// producers* under different promises — `stream` may crash and take only the
/// daemon with it, while a hook runs inside the developer's own session and a
/// throw there breaks the thing sprout was watching. Keeping them apart is what
/// lets that stricter promise be a property of an area rather than a habit.
///
/// `worktree` is P4-03's: `git worktree add` for one node's session, and the
/// safe teardown that mostly refuses. It is its own area rather than a corner
/// of `runner` on exactly the argument above — it shells out to `git` and
/// deletes directories under a promise the runner does not make, that it never
/// destroys work — and being an area is what lets `test/worktree_test.dart`
/// read the whole of `lib/src/worktree/` and assert that `--force` and
/// `git branch -D` appear nowhere in it, the way `test/liveness_test.dart`
/// greps its own area for a kill. A guard over a corner of another library
/// would cover whichever files happened to sit beside it.
///
/// It is named `worktree` and not `workspace`, which was the obvious choice:
/// `workspace` is a first-class pubspec concept in Dart 3.6 and up, and this is
/// a Dart monorepo, so a `lib/workspace.dart` would name the one thing in the
/// repository it is not about.
///
/// `decomposition` is P4-04's: the value a parent produces when it decides to
/// split a task, and the pure function that lays its children out into waves
/// whose estimated file sets do not overlap. It is its own area rather than a
/// corner of `policy` on the `liveness`/`watchdog` argument — the two answer
/// different questions. `policy` asks what a node is *allowed* to start,
/// judged against a `SpendLedger` at one moment; `decomposition` asks what
/// *should* run together, judged against a plan and nothing else. The
/// dependency runs one way (a wave is never planned wider than the gate could
/// admit, and the gate knows nothing about plans), and `lib/policy.dart` says
/// of itself that `ContainmentGate.admit` is "the only entry point", which a
/// planner living there would make false.
///
/// Being an area is also what makes its one promise assertable:
/// `test/decomposition_test.dart` greps the whole of `lib/src/decomposition/`
/// for `dart:io`, `DateTime.now`, `Random` and `package:sqlite3` and asserts
/// none appear, exactly as `test/worktree_test.dart` greps its area for
/// `--force`. A planner whose output depends on a clock or on map iteration
/// order is one nobody can diff, and a guard over a corner of another library
/// would cover whichever files happened to sit beside it.
///
const libraries = {
  'store',
  'stream',
  'policy',
  'runner',
  'protocol',
  'snapshot',
  'watch',
  'ui',
  'liveness',
  'watchdog',
  'hooks',
  'worktree',
  'decomposition',
};

/// The libraries whose declarations now live in `package:sprout_protocol`.
///
/// Each maps a path under `lib/` to the export line that has to be in it. The
/// pure-value half of sprout was lifted out so the browser could decode the
/// frames the daemon emits — `package:sproutd/protocol.dart` reached dart:io
/// and package:sqlite3's dart:ffi through `store.dart`, and
/// build_web_compilers refuses an entrypoint on its transitive library import
/// graph. That was finding F-07.
const reExportedWholesale = {
  'lib/protocol.dart': "export 'package:sprout_protocol/protocol.dart';",
  'lib/snapshot.dart': "export 'package:sprout_protocol/snapshot.dart';",
  'lib/store.dart': "export 'package:sprout_protocol/values.dart'",
};

/// Reads the resolved version of [package] out of `pubspec.lock`.
///
/// The lockfile rather than `pubspec.yaml` on purpose: a constraint that is
/// merely *written* proves nothing, and this asserts what version solving
/// actually chose.
String? lockedVersion(String lock, String package) {
  final start = lock.indexOf('\n  $package:\n');
  if (start < 0) return null;
  final version = RegExp(
    r'^    version: "([^"]+)"$',
    multiLine: true,
  ).firstMatch(lock.substring(start));
  return version?.group(1);
}

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final lock = File('pubspec.lock').readAsStringSync();

  group('pubspec', () {
    test('names the package sproutd on a Dart 3.13 SDK', () {
      expect(pubspec, contains('name: sproutd'));
      expect(pubspec, contains('sdk: ^3.13.0'));
    });

    test('pins the verified versions exactly and floats only the rest', () {
      for (final MapEntry(key: name, value: version) in pinnedExactly.entries) {
        expect(
          pubspec,
          contains('  $name: $version\n'),
          reason: '$name must be pinned to exactly $version, with no caret',
        );
      }
      for (final name in caretRanged) {
        expect(
          RegExp('^  $name: \\^', multiLine: true).hasMatch(pubspec),
          isTrue,
          reason: '$name has no verified-version claim, so it takes a caret',
        );
      }
    });

    test('version solving actually chose the pinned versions', () {
      // Distinct from the test above: that one reads what we asked for, this
      // one reads what pub resolved. A pin that cannot be satisfied fails here.
      for (final MapEntry(key: name, value: version) in pinnedExactly.entries) {
        expect(lockedVersion(lock, name), version, reason: '$name in the lock');
      }
    });

    test('depends on revali but not the superseded revali_server package', () {
      // revali 3.3.2 registers revali_server as a BUILT-IN construct pointing
      // at its own lib/server/server.dart (see revali's constructs_handler.dart
      // line 112). The standalone revali_server 2.4.1 on pub.dev still requires
      // revali_router ^3.4.0, so depending on it makes the tree unresolvable.
      // The positive half of this pair is what keeps the negative honest.
      expect(lockedVersion(lock, 'revali'), isNotNull);
      expect(lockedVersion(lock, 'revali_server'), isNull);
    });
  });

  group('the sprout_protocol split', () {
    // P3-05, closing finding F-07.
    test('sproutd depends on sprout_protocol by path', () {
      expect(
        RegExp(
          r'^  sprout_protocol:\n    path: \.\./sprout_protocol$',
          multiLine: true,
        ).hasMatch(pubspec),
        isTrue,
      );
      // A path dependency resolves to no version, so `lockedVersion` cannot
      // speak for it. What the lock does record is that pub saw it at all.
      expect(lock, contains('\n  sprout_protocol:\n'));
    });

    test('the old import paths still work and are re-exports', () {
      // The compatibility promise, asserted as text because the rest of this
      // suite asserts it by USE: every other test file here imports
      // `package:sproutd/protocol.dart` and `package:sproutd/store.dart` and
      // would fail to compile if these shims stopped carrying the types.
      //
      // Text as well as use, because a shim could be replaced by a second
      // DECLARATION of the same types and every one of those tests would keep
      // passing — right up until the two copies drifted. That is finding F-01,
      // and it is the one failure a green suite cannot see.
      for (final MapEntry(key: path, value: line)
          in reExportedWholesale.entries) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path is missing');
        expect(
          file.readAsStringSync(),
          contains(line),
          reason: '$path must re-export from sprout_protocol, not redeclare',
        );
      }
    });

    test('nothing sprout_protocol offers reaches dart:io or dart:ffi', () {
      // The invariant that makes the browser build possible, asserted at the
      // source. It is asserted here as well as in sprout_ui because the two
      // packages are gated by different rules in .game_loop/verify.yaml, and
      // because the failure it prevents is a SILENT one: build_web_compilers
      // skips the entrypoint with a WARNING and `jaspr build` still exits 0.
      final banned = RegExp(
        r"import 'dart:(io|ffi|mirrors|isolate)'|package:sqlite3",
      );
      final offenders = Directory('../sprout_protocol/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => banned.hasMatch(f.readAsStringSync()))
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty);
    });

    test('and it declares no dependencies at all', () {
      // The stronger form of the test above, and the reason it is not
      // redundant: a banned import can arrive through a package rather than
      // through a `dart:` URI, and nothing in sprout_protocol's own source
      // would show it. Every dependency added there is compiled into the
      // browser bundle, so each one has to be a decision.
      final theirs = File('../sprout_protocol/pubspec.yaml').readAsStringSync();
      expect(
        RegExp(r'^dependencies:', multiLine: true).hasMatch(theirs),
        isFalse,
        reason:
            'sprout_protocol took a dependency. It is compiled for the web; '
            'check the new one is too, then relax this test on purpose.',
      );
    });
  });

  group('libraries', () {
    test('one non-empty top-level library exists per area', () {
      for (final name in libraries) {
        final file = File('lib/$name.dart');
        expect(file.existsSync(), isTrue, reason: 'lib/$name.dart is missing');
        expect(file.readAsStringSync(), contains('library;'));
      }
    });

    test('there is no shared barrel file', () {
      // The paired negative: a `lib/sproutd.dart` barrel would be the obvious
      // thing to add and is exactly what the four libraries above exist to
      // avoid, since it would put every leaf back on one file.
      expect(File('lib/sproutd.dart').existsSync(), isFalse);
      expect(
        Directory('lib')
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last),
        unorderedEquals(libraries.map((n) => '$n.dart')),
      );
    });
  });
}
