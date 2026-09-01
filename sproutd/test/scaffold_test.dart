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
const libraries = {
  'store',
  'stream',
  'policy',
  'runner',
  'protocol',
  'snapshot',
  'watch',
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
