/// Turns the built UI payload in `web/` into Dart source the compiler can
/// swallow: `lib/src/ui/assets.g.dart`, one base64 constant per file.
///
/// Step 3 of the five-step pipeline in `README.md`, and the reason sprout is
/// still one file. Dart has no `//go:embed`, and Revali's `public/` reads from
/// disk relative to the process working directory — see [UiAssets] for the
/// generated handler that does it. sprout runs from `/` with no source tree,
/// so the bytes have to be *in* the binary.
///
/// Run it from the `sproutd` package root:
///
/// ```bash
/// dart run tool/embed_assets.dart           # write lib/src/ui/assets.g.dart
/// dart run tool/embed_assets.dart --check   # fail if it is out of date
/// ```
///
/// `--check` is what makes the committed generated file honest. It rebuilds
/// the same text and compares; a payload that has been rebuilt without
/// re-running step 3 fails here rather than shipping a binary serving the
/// previous UI.
///
/// **Exit codes are distinguished on purpose.** `1` means the payload and the
/// committed file disagree — a real failure. `2` means there was no payload to
/// look at, which is *not* the same answer and must never be reported as
/// agreement (INV8): a `--check` that passed because it could not look is the
/// exact shape of a check that cannot fail.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/src/ui/content_types.dart';

/// Where `rsync` puts the output of `jaspr build` (step 2).
///
/// Git-ignored: it is a copy of another package's build output, and the bytes
/// are already committed once, in the generated file below.
const String payloadDirectory = 'web';

/// The file this writes, relative to the package root.
const String generatedPath = 'lib/src/ui/assets.g.dart';

/// Base64 characters per source line.
///
/// Chosen so the longest emitted line — six spaces of indent, two quotes and
/// this many characters — stays inside 80 columns, which is what keeps the
/// output stable under `dart format`. The gate runs
/// `dart format --set-exit-if-changed .` over this package, so an emitter that
/// disagrees with the formatter fails every commit.
const int lineWidth = 68;

Future<int> run(List<String> args) async {
  final check = args.contains('--check');
  final unknown = args.where((a) => a != '--check');
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'embed_assets: unrecognised arguments: ${unknown.join(' ')}',
    );
    return 64;
  }

  final directory = Directory(payloadDirectory);
  if (!directory.existsSync()) {
    stderr
      ..writeln('embed_assets: no $payloadDirectory/ directory.')
      ..writeln(
        '  Run steps 1 and 2 of the pipeline in README.md first: build the '
        'UI in sprout_ui and rsync its payload here.',
      );
    return 2;
  }

  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((f) => !p.basename(f.path).startsWith('.'))
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  if (files.isEmpty) {
    stderr.writeln('embed_assets: $payloadDirectory/ holds no files.');
    return 2;
  }

  final untyped = [
    for (final file in files)
      if (contentTypeForAsset(p.basename(file.path)) == null)
        p.basename(file.path),
  ];
  if (untyped.isNotEmpty) {
    // Refused rather than typed `application/octet-stream`. A browser drops a
    // stylesheet and refuses a script served that way, and it does both
    // without an error the user can see: the page is simply blank. Adding the
    // extension to `assetContentTypes` is a one-line decision; guessing it
    // here would be an invisible one.
    stderr
      ..writeln('embed_assets: no content-type for: ${untyped.join(', ')}')
      ..writeln(
        '  Add the extension to assetContentTypes in '
        'lib/src/ui/content_types.dart. It is deliberately not defaulted: '
        'application/octet-stream makes a browser discard the response with '
        'no visible error.',
      );
    return 1;
  }

  final generated = await _format(_source(files));

  if (!check) {
    File(generatedPath).writeAsStringSync(generated);
    final bytes = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    stdout.writeln(
      'embed_assets: wrote $generatedPath — ${files.length} files, '
      '$bytes bytes, ${generated.length} characters of source.',
    );
    return 0;
  }

  final existing = File(generatedPath);
  if (!existing.existsSync()) {
    stderr.writeln('embed_assets: $generatedPath does not exist.');
    return 1;
  }
  if (existing.readAsStringSync() != generated) {
    stderr
      ..writeln('embed_assets: $generatedPath is out of date.')
      ..writeln('  Run: dart run tool/embed_assets.dart');
    return 1;
  }
  stdout.writeln(
    'embed_assets: $generatedPath matches $payloadDirectory/ '
    '(${files.length} files).',
  );
  return 0;
}

Future<void> main(List<String> args) async => exit(await run(args));

/// The generated source, before formatting.
String _source(List<File> files) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED BY tool/embed_assets.dart — DO NOT EDIT.')
    ..writeln('//')
    ..writeln('// Regenerate with:  dart run tool/embed_assets.dart')
    ..writeln('// Verify with:      dart run tool/embed_assets.dart --check')
    ..writeln('//')
    ..writeln(
      '// This file is COMMITTED, unlike .revali/ and web/. It has to be: it '
      'is a',
    )
    ..writeln(
      '// library the package imports, so a clean checkout without it does '
      'not',
    )
    ..writeln(
      '// analyze, does not test and does not compile. The cost of that '
      'choice is',
    )
    ..writeln(
      '// that the payload is in git twice over — once here as base64, once '
      'as the',
    )
    ..writeln(
      '// sprout_ui sources it was built from — and that a rebuilt UI is '
      'stale here',
    )
    ..writeln(
      '// until step 3 is re-run. `--check` is what turns that staleness '
      'into a',
    )
    ..writeln('// failure instead of a wrong binary.')
    ..writeln()
    ..writeln('/// The UI payload, base64 by file name.')
    ..writeln('///')
    ..writeln(
      '/// Read through [UiAssets], which decodes lazily and caches. The '
      'names are',
    )
    ..writeln(
      '/// the paths the browser asks for, so `index.html` is what `/` '
      'serves.',
    )
    ..writeln('library;')
    ..writeln()
    ..writeln('const Map<String, String> embeddedAssetsBase64 = {');

  for (final file in files) {
    final name = p.basename(file.path);
    final encoded = base64Encode(file.readAsBytesSync());
    buffer.writeln("  '$name':");
    for (var i = 0; i < encoded.length; i += lineWidth) {
      final end = i + lineWidth;
      final chunk = encoded.substring(
        i,
        end < encoded.length ? end : encoded.length,
      );
      buffer.writeln("      '$chunk'");
    }
    // An empty file would emit no chunk at all and leave a dangling entry, so
    // it gets an explicit empty literal. Not hypothetical: jaspr emits an
    // empty main.css when a build produces no @css rules.
    if (encoded.isEmpty) buffer.writeln("      ''");
    buffer.writeln('      ,');
  }

  return (buffer..writeln('};')).toString();
}

/// Runs [source] through `dart format`.
///
/// The output is committed and the gate runs
/// `dart format --set-exit-if-changed .` over this package, so the generator
/// has to agree with the formatter exactly. Rather than emit text that
/// happens to match, this shells out to the formatter itself — which also
/// makes `--check` compare like with like, since both sides come through
/// here.
Future<String> _format(String source) async {
  final directory = Directory.systemTemp.createTempSync('sprout_embed');
  try {
    final file = File(p.join(directory.path, 'assets.g.dart'))
      ..writeAsStringSync(source);
    final result = await Process.run(Platform.executable, [
      'format',
      file.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('dart format failed: ${result.stdout}${result.stderr}');
    }
    return file.readAsStringSync();
  } finally {
    directory.deleteSync(recursive: true);
  }
}
