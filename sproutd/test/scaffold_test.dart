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
const libraries = {
  'store',
  'stream',
  'policy',
  'runner',
  'protocol',
  'snapshot',
  'watch',
  'ui',
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
