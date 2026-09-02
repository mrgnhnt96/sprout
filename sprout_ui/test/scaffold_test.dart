import 'dart:io';

import 'package:test/test.dart';

/// Versions pinned with no caret, and the reason each pin exists.
///
/// `jaspr` and `jaspr_builder` are pinned because `docs/01-plan.md` §13
/// records 0.23.4 as the version the payload pipeline was *executed* against,
/// the same posture sproutd takes with `revali` and `sqlite3`.
const pinnedExactly = {'jaspr': '0.23.4', 'jaspr_builder': '0.23.4'};

/// Dependencies with no verified-version claim behind them, so a caret is
/// correct. Asserting this next to [pinnedExactly] is what keeps the pin test
/// from passing vacuously: swap the two sets and exactly one group fails.
const caretRanged = {'jaspr_cli', 'build_runner', 'lints', 'test'};

/// Reads the resolved version of [package] out of a `pubspec.lock`.
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
  final index = File('web/index.html').readAsStringSync();

  group('pubspec', () {
    test('names the package sprout_ui on a Dart 3.13 SDK', () {
      expect(pubspec, contains('name: sprout_ui'));
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
      for (final MapEntry(key: name, value: version) in pinnedExactly.entries) {
        expect(lockedVersion(lock, name), version, reason: '$name in the lock');
      }
    });

    test('holds build_web_compilers below the analyzer break at 4.8.6', () {
      // Not a preference. jaspr_builder 0.23.4 wants analyzer ^12.1.0 while
      // build_web_compilers >=4.8.6 wants analyzer >=13.3.0, so the two do not
      // resolve together — and `jaspr create` scaffolds ^4.8.10, which means
      // the generated project is broken out of the box. The upper bound is
      // load-bearing and a caret would silently float past it.
      expect(pubspec, contains('build_web_compilers: ">=4.8.0 <4.8.6"'));
      final resolved = lockedVersion(lock, 'build_web_compilers');
      expect(resolved, isNotNull);
      expect(
        Version.parse(resolved!) < const Version(4, 8, 6),
        isTrue,
        reason: 'resolved build_web_compilers $resolved is at or past 4.8.6',
      );
    });
  });

  group('the two-package split', () {
    // The constraint the whole package exists to satisfy. `revali` (sproutd's
    // codegen CLI) declares analyzer ^10.0.0 and `jaspr_builder` declares
    // ^12.1.0; a single resolution containing both fails. A `workspace:` key
    // is exactly how that single resolution would come back.
    final sproutdPubspec = File('../sproutd/pubspec.yaml');

    test('neither package joins a pub workspace', () {
      expect(
        RegExp(r'^workspace:', multiLine: true).hasMatch(pubspec),
        isFalse,
        reason: 'a workspace puts sprout_ui and sproutd in one solve',
      );
      expect(sproutdPubspec.existsSync(), isTrue, reason: '../sproutd is gone');
      expect(
        RegExp(
          r'^(workspace|resolution):',
          multiLine: true,
        ).hasMatch(sproutdPubspec.readAsStringSync()),
        isFalse,
        reason: 'sproutd must not become a workspace member either',
      );
    });

    test('sprout_ui does not depend on sproutd', () {
      // Reversing this is the obvious next move — P3-04 needs the protocol
      // decoder that `package:sproutd/protocol.dart` already defines, and
      // duplicating it here would be the F-01 bug again. It does not work
      // today, and the failure is SILENT: `protocol.dart` re-exports
      // `store.dart`, which reaches dart:io and package:sqlite3's dart:ffi,
      // so build_web_compilers skips the entrypoint, emits no
      // main.client.dart.js, and `jaspr build` still exits 0.
      //
      // Precisely: the DEPENDENCY alone is harmless — measured, the payload
      // builds fine with it declared and unused. What breaks the build is an
      // IMPORT that reaches protocol.dart. This test guards the dependency
      // anyway, because it is the only cheap thing to guard: an import cannot
      // exist without it, and the failure it prevents is invisible.
      //
      // Removing this needs the protocol types lifted out of sproutd first,
      // into a package that reaches neither dart:io nor dart:ffi.
      // Matched as a dependency DECLARATION, not as a substring: this
      // pubspec's own comments name sproutd repeatedly, and a plain
      // `contains` would fail on the explanation of why the dep is absent.
      expect(
        RegExp(r'^  sproutd:', multiLine: true).hasMatch(pubspec),
        isFalse,
        reason: 'sprout_ui declares a dependency on sproutd',
      );
      // And the paired check on what pub actually resolved, so a transitive
      // route in is caught too.
      expect(lockedVersion(lock, 'sproutd'), isNull);
    });
  });

  group('client mode', () {
    test('pubspec selects client rendering', () {
      expect(
        RegExp(r'^jaspr:\n  mode: client$', multiLine: true).hasMatch(pubspec),
        isTrue,
      );
    });

    test('there is exactly one client entrypoint', () {
      // jaspr compiles every `*.client.dart` under lib/ to its own bundle.
      // One entrypoint is what makes "the payload is three files" true.
      final entrypoints = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.client.dart'))
          .toList();
      expect(entrypoints, ['main.client.dart']);
    });

    test('index.html loads the bundle that entrypoint compiles to', () {
      // The pairing is by filename and nothing checks it at build time: a
      // renamed entrypoint leaves index.html requesting a 404 and the build
      // still succeeds.
      expect(index, contains('src="main.client.dart.js"'));
      expect(index, contains('href="main.css"'));
    });
  });
}

/// A three-part version, compared numerically.
///
/// `String.compareTo` gets this wrong — "4.8.10" sorts before "4.8.6" — and
/// that is precisely the comparison the build_web_compilers bound needs.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  factory Version.parse(String text) {
    final parts = text.split(RegExp('[-+]')).first.split('.');
    return Version(
      int.parse(parts[0]),
      int.parse(parts[1]),
      parts.length > 2 ? int.parse(parts[2]) : 0,
    );
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(Version other) => compareTo(other) < 0;
}
