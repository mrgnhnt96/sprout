@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:test/test.dart';

/// The three files that ARE the payload — the whole of what P3-03 embeds into
/// the sproutd binary.
const payload = ['index.html', 'main.css', 'main.client.dart.js'];

void main() {
  late Directory out;
  late String log;

  setUpAll(() async {
    // Runs the real build rather than inspecting a leftover one. A stale
    // build/ directory would let every assertion below pass while the current
    // sources do not compile at all, which is the exact shape of failure this
    // file exists to catch.
    //
    // The CLI comes from the `jaspr_cli` dev dependency, not from a globally
    // activated `jaspr`, so this runs on a machine that has never run
    // `dart pub global activate`. P3-03 should automate this same command.
    final result = await Process.run('dart', [
      'run',
      'jaspr_cli:jaspr',
      'build',
    ], workingDirectory: Directory.current.path);

    expect(
      result.exitCode,
      0,
      reason: 'jaspr build failed:\n${result.stdout}\n${result.stderr}',
    );
    log = '${result.stdout}\n${result.stderr}';
    out = Directory('build/jaspr');
  });

  test('build_web_compilers did not skip the entrypoint', () {
    // The MECHANISM, asserted next to the artifact, because the two fail
    // apart. This is finding F-07 in one line: reaching a library that imports
    // dart:io or dart:ffi through the transitive import graph downgrades the
    // refusal to a WARNING, and the build still exits 0.
    //
    // The test below catches that today by finding no bundle. This one catches
    // it even if the build were ever to leave a stale bundle behind, and it
    // names the reason rather than the symptom — which is the difference
    // between a failure someone can act on and one they have to investigate.
    expect(
      log,
      isNot(contains('Skipping compiling')),
      reason:
          'build_web_compilers skipped the entrypoint. Something in the '
          'import graph of lib/main.client.dart now reaches a dart: library '
          'the browser does not have. That is F-07: it is a WARNING, the '
          'build still exits 0, and the page is left loading a script that '
          '404s.',
    );
  });

  test('the build emits the client bundle, and it is not empty', () {
    // THE assertion in this package.
    //
    // `jaspr build` exits 0 when build_web_compilers refuses the entrypoint.
    // Reaching one unsupported `dart:` library through the import graph — the
    // way `package:sproutd/protocol.dart` reaches dart:io and dart:ffi —
    // downgrades the refusal to "Skipping compiling ... with ddc because some
    // of its transitive libraries have sdk dependencies that are not supported
    // on this platform", writes no .js, and reports success. The index.html
    // then loads a script that 404s.
    //
    // So a green `jaspr build` proves nothing on its own (INV8). The presence
    // of a non-empty bundle is what proves it.
    final bundle = File('${out.path}/main.client.dart.js');
    expect(
      bundle.existsSync(),
      isTrue,
      reason:
          'no bundle: the build skipped '
          'the entrypoint. Check the build log for "Skipping compiling".',
    );
    expect(bundle.lengthSync(), greaterThan(10000));
  });

  test('the bundle is THIS app, not a stale or empty one', () {
    // Existing is not working. dart2js minifies identifiers but keeps string
    // literals, so the app's own copy is a fingerprint that a leftover bundle
    // from a different revision would not carry.
    final js = File('${out.path}/main.client.dart.js').readAsStringSync();
    expect(js, contains('The UI payload is served'));
    expect(js, contains('sprout-shell'));
  });

  test('the stylesheet is generated from the @css getters', () {
    // main.css is emitted by jaspr_builder from App.styles; it is not a file
    // anyone wrote. If the styles builder is skipped this is absent or empty
    // and the page renders unstyled with the build still green.
    final css = File('${out.path}/main.css').readAsStringSync();
    expect(css, contains('.sprout-shell'));
    expect(css, contains('height: 100vh'));
  });

  test('index.html is copied through and still names the bundle', () {
    final built = File('${out.path}/index.html').readAsStringSync();
    expect(built, contains('main.client.dart.js'));
    for (final name in payload) {
      expect(
        File('${out.path}/$name').existsSync(),
        isTrue,
        reason: '$name missing from the payload',
      );
    }
  });

  test('the payload is the three root files, and nothing under packages/', () {
    // A note for P3-03, enforced rather than written down. `build/jaspr` also
    // contains a `packages/` tree of data files pulled in by DEV dependencies
    // — analyzer fix_data, win32 fix templates, the test runner's browser
    // host — several megabytes of material that is not the UI. Embedding
    // `build/jaspr/**` wholesale would put all of it in the binary.
    //
    // The rsync step takes the top-level files only.
    final roots = out
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => !n.startsWith('.'))
        .toList();
    expect(roots..sort(), payload.toList()..sort());

    // The half that makes the warning above evidence rather than a note: the
    // directory really is there, and really is large. If a future jaspr stops
    // emitting it this fails and the rsync step can be simplified on purpose
    // instead of by accident.
    final extra = Directory('${out.path}/packages');
    expect(extra.existsSync(), isTrue);
    expect(extra.listSync(recursive: true).whereType<File>(), isNotEmpty);
  });
}
