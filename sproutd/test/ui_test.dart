/// Tests for the embedded UI: the payload in the binary, and what a browser
/// actually receives when it asks for it.
///
/// **The assertions that matter here are read off the wire.** A browser
/// silently discards a stylesheet or a script served with the wrong
/// `content-type`, and downloads a page served with `content-disposition:
/// attachment` instead of rendering it — three failures that look like a blank
/// page and report 200. Revali has shipped exactly that shape before: finding
/// F-03 was `@SSE` emitting `application/octet-stream` with the handler's own
/// override ignored. So nothing below asserts what the controller *set*; every
/// header is read from a real `HttpServer` over a real socket.
///
/// The router is built here rather than imported from `.revali/server/`,
/// which is generated: a test that imported it would assert the generator
/// against itself. It mirrors what `revali build` emits verbatim, and `the
/// generated shape` group reads the generated file and fails if the two have
/// drifted. That group no longer skips itself — P4-01 committed `.revali/`
/// because `bin/sprout.dart` imports it, so its absence is now a broken tree
/// rather than a clean checkout. The run of the *compiled binary* — copied out of the source tree
/// and started with `cwd=/` — is in the commit message, which is the only
/// proof that covers `dart compile exe` itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:revali_router/revali_router.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/ui.dart';
import 'package:test/test.dart';

import '../routes/controllers/tree_controller.dart';
import '../routes/controllers/ui_controller.dart';
import '../routes/main_app.dart';

void main() {
  group('the content-type table', () {
    test('types every file in the payload', () {
      // The whole reason the generator can refuse a payload: a name with no
      // entry here would be served as octet-stream and dropped by the browser
      // with no error anywhere.
      for (final name in UiAssets.embedded.names) {
        expect(
          contentTypeForAsset(name),
          isNotNull,
          reason:
              '$name has no content-type; add its extension to '
              'assetContentTypes',
        );
      }
    });

    test('resolves the payload names to the types a browser demands', () {
      expect(contentTypeForAsset('index.html'), 'text/html; charset=utf-8');
      expect(contentTypeForAsset(stylesheetName), 'text/css; charset=utf-8');
      // The bundle's extension is the text after the LAST dot. A resolver that
      // split on the first would call `main.client.dart.js` a `.client` file.
      expect(contentTypeForAsset(bundleName), 'text/javascript; charset=utf-8');
    });

    test('returns null for an unknown extension rather than octet-stream', () {
      // Null is what `tool/embed_assets.dart` turns into a build failure. A
      // fallback of application/octet-stream would make the same payload build
      // green and render blank.
      expect(contentTypeForAsset('thing.bin'), isNull);
      expect(contentTypeForAsset('no-extension'), isNull);
      expect(contentTypeForAsset(''), isNull);
    });
  });

  group('the embedded payload', () {
    test('carries the three files jaspr build emits, and none of the rest', () {
      // `build/jaspr` also contains a multi-megabyte `packages/` tree from dev
      // dependencies. Step 2 of the pipeline drops it; this is what says so.
      expect(UiAssets.embedded.names.toSet(), {
        'index.html',
        stylesheetName,
        bundleName,
      });
    });

    test('decodes to the real files, not to empty ones', () {
      final index = utf8.decode(UiAssets.embedded.bytesFor('index.html')!);
      expect(index, contains('<!DOCTYPE html>'));
      // The page has to actually load the bundle this daemon serves.
      expect(index, contains(bundleName));
      expect(index, contains(stylesheetName));

      final css = utf8.decode(UiAssets.embedded.bytesFor(stylesheetName)!);
      expect(css, contains('.sprout-shell'));

      final js = utf8.decode(UiAssets.embedded.bytesFor(bundleName)!);
      // dart2js minifies identifiers and keeps string literals, so the app's
      // own copy is a fingerprint a stale or empty bundle would not carry.
      // These come from `package:sprout_protocol`, in code dart2js keeps only
      // because the UI really decodes and renders frames (P3-04): a binary
      // embedding the pre-P3-04 stub fails here rather than serving a page
      // that attaches to nothing.
      expect(js, contains('NONE SCHEDULED'));
      expect(js, contains('unknown frame type'));
      expect(js.length, greaterThan(10000));
    });

    test('decodes once and hands back the same list', () {
      // Not a micro-optimisation: without the cache the 107 KB bundle is
      // base64-decoded on every page load.
      final assets = UiAssets(UiAssets.embedded.encoded);
      expect(
        identical(assets.bytesFor(bundleName), assets.bytesFor(bundleName)),
        isTrue,
      );
    });

    test('answers null for a name it does not have', () {
      expect(UiAssets.embedded.bytesFor('nope.css'), isNull);
    });
  });

  group('the routes and the payload agree', () {
    test('a route is declared for every embedded asset, and no other', () {
      // THE drift guard. One route per file is forced by the router (see
      // UiController.stylesheet), so the names are written twice — here is the
      // comparison that stops the two spellings from diverging. A payload that
      // grows a file fails here rather than 404ing in a browser.
      expect(servedAssetNames, UiAssets.embedded.names.toSet());
    });
  });

  group('over a real socket', () {
    late _Bound bound;

    tearDown(() => bound.close());

    test('serves the page at / with the type a browser will render', () async {
      bound = await _bind();
      final response = await bound.get('/');

      expect(response.statusCode, 200);
      expect(response.contentType, 'text/html; charset=utf-8');
      // The trap. `MemoryFileBodyData` sets `filename`, which
      // `HeadersImpl.filename` writes as `attachment; filename="…"` — a page
      // the browser downloads instead of rendering, with a 200 in the log.
      expect(response.headers['content-disposition'], isNull);
      expect(response.bytes, UiAssets.embedded.bytesFor('index.html'));
    });

    test('serves the stylesheet as text/css', () async {
      bound = await _bind();
      final response = await bound.get('/$stylesheetName');

      expect(response.statusCode, 200);
      // A stylesheet served as anything else is dropped by the browser and
      // the page renders unstyled with no error reported anywhere.
      expect(response.contentType, 'text/css; charset=utf-8');
      expect(response.headers['content-disposition'], isNull);
      expect(response.bytes, UiAssets.embedded.bytesFor(stylesheetName));
    });

    test('serves the bundle as javascript, all of it', () async {
      bound = await _bind();
      final response = await bound.get('/$bundleName');

      expect(response.statusCode, 200);
      expect(response.contentType, 'text/javascript; charset=utf-8');
      expect(response.headers['content-disposition'], isNull);
      // Byte-for-byte: a truncated script fails in the browser's console and
      // nowhere the server can see.
      expect(response.bytes, UiAssets.embedded.bytesFor(bundleName));
      expect(response.bytes.length, greaterThan(10000));
    });

    test('tells a browser not to reuse the bundle across upgrades', () async {
      // The bundle's name carries no content hash, so a cached copy would
      // outlive the binary that served it.
      bound = await _bind();
      final response = await bound.get('/$bundleName');
      expect(response.headers['cache-control'], 'no-cache');
    });

    test('does not shadow GET /api/tree', () async {
      // The UI controller is mounted at '' and the API at 'api/tree'. `Find`
      // sorts static routes by specificity, so the API is tried first — but
      // that is a claim about a dependency's sort order, and this is the
      // assertion that makes it a fact about this server.
      bound = await _bind();
      final response = await bound.get('/api/tree');

      expect(response.statusCode, 200);
      final body = jsonDecode(utf8.decode(response.bytes)) as Map;
      expect((body['data']! as Map)['nodes'], isEmpty);
    });

    test('404s a path that is in neither', () async {
      bound = await _bind();
      final response = await bound.get('/nope.css');
      expect(response.statusCode, 404);
    });
  });

  group('a payload that is missing a file', () {
    test('404s with a sentence rather than 500ing', () async {
      // Reachable when `assets.g.dart` was generated from a payload this
      // source predates. Driven through `write` directly: there is no route to
      // a name the payload lacks, which is the point of the drift guard above.
      final response = _capture();
      write(UiAssets(const {}), stylesheetName, response);

      expect(response.statusCode, 404);
      expect(await _read(response), 'sprout: no such asset: $stylesheetName');
    });
  });

  group('the generated shape', () {
    // `.revali/` is COMMITTED as of P4-01 (`bin/sprout.dart` imports it to be
    // the daemon as well as the CLI), so these read it unconditionally. They
    // used to skip when it was absent; a missing file is now a real failure,
    // because a tree without it does not build at all.
    final ui = File('.revali/server/routes/__r0_route.dart');
    final api = File('.revali/server/routes/__api_tree_route.dart');

    test('the generated tree is committed, so nothing below can skip', () {
      // The guard on the two tests after this one. They assert the CONTENTS of
      // these files; if the files vanished those tests would fail with a
      // filesystem error that reads like a broken test rather than like the
      // real cause, which is that someone re-ignored `.revali/`.
      expect(ui.existsSync(), isTrue, reason: 'run `dart run revali build`');
      expect(api.existsSync(), isTrue, reason: 'run `dart run revali build`');
      expect(
        File('.gitignore').readAsStringSync(),
        isNot(matches(RegExp(r'^\.revali/', multiLine: true))),
        reason: '.revali/ must stay tracked: bin/sprout.dart imports it',
      );
    });

    test('mounts the UI controller at the root', () {
      final source = ui.readAsStringSync();
      // The container route is the empty path; that is what puts the page at
      // `/` rather than under a prefix.
      expect(source, contains("Route(\n    '',"));
      for (final name in servedAssetNames) {
        if (name == UiAssets.indexName) continue;
        expect(
          source,
          contains("'$name'"),
          reason: '$name has no generated route',
        );
      }
    });

    test('leaves the API on /api/tree', () {
      // The prefix moved from the app to the controller in P3-03. The URL did
      // not, and this is the file that would show it if it had.
      expect(api.readAsStringSync(), contains("Route(\n    'api/tree',"));
      expect(treeControllerPath, 'api/tree');
      expect(MainApp().prefix, isEmpty);
    });
  });

  group('the generator', () {
    test('reports the committed assets.g.dart as current', () async {
      // Freshness, not shape. `web/` is git-ignored, so this can only run
      // where steps 1 and 2 of the pipeline have been run — and when it
      // cannot, it says so instead of passing.
      if (!Directory('web').existsSync()) {
        markTestSkipped(
          'no web/ payload in this tree, so the committed assets.g.dart could '
          'not be compared against one. NOT a pass.',
        );
        return;
      }
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/embed_assets.dart',
        '--check',
      ], workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason:
            'lib/src/ui/assets.g.dart is stale against web/:\n'
            '${result.stdout}\n${result.stderr}',
      );
    });
  });
}

/// A response object with no request behind it, for driving [write] directly.
ResponseImpl _capture() => ResponseImpl(requestHeaders: HeadersImpl());

/// The body [response] would send, as text.
Future<String> _read(ResponseImpl response) async =>
    utf8.decode(await response.body.read()!.expand((e) => e).toList());

/// Binds a real loopback server carrying the UI controller and the API route.
///
/// The routes mirror `.revali/server/routes/__r0_route.dart` and
/// `__api_tree_route.dart` verbatim — the `generated shape` group is what
/// checks that claim.
Future<_Bound> _bind() async {
  const controller = UiController();
  final store = SproutStore.memory();
  final tree = TreeController(store);

  final router = Router(
    routes: [
      Route(
        '',
        routes: [
          Route(
            '',
            method: 'GET',
            handler: (context) async => controller.index(context.response),
          ),
          Route(
            stylesheetName,
            method: 'GET',
            handler: (context) async => controller.stylesheet(context.response),
          ),
          Route(
            bundleName,
            method: 'GET',
            handler: (context) async => controller.bundle(context.response),
          ),
        ],
      ),
      Route(
        treeControllerPath,
        routes: [
          Route(
            '',
            method: 'GET',
            handler: (context) async {
              context.response.body = {'data': tree.snapshot()};
            },
          ),
        ],
      ),
    ],
  );

  // 127.0.0.1 literally, never 'localhost': the generated `_bindServer` maps
  // exactly that string to InternetAddress.anyIPv6, which is every interface.
  final server = await HttpServer.bind('127.0.0.1', 0);
  unawaited(handleRouterRequests(server, router, router.close));
  return _Bound(server: server, store: store);
}

/// A bound server and the client that reads off it.
final class _Bound {
  _Bound({required this.server, required this.store});

  final HttpServer server;
  final SproutStore store;
  final HttpClient _client = HttpClient();

  /// Issues `GET [path]` and drains the whole response.
  Future<_Wire> get(String path) async {
    final request = await _client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );

    return _Wire(
      statusCode: response.statusCode,
      headers: {
        for (final name in _headerNames(response))
          name: response.headers.value(name),
      },
      bytes: bytes,
    );
  }

  Future<void> close() async {
    _client.close(force: true);
    await server.close(force: true);
    store.close();
  }
}

List<String> _headerNames(HttpClientResponse response) {
  final names = <String>[];
  response.headers.forEach((name, _) => names.add(name));
  return names;
}

/// What a client actually got.
final class _Wire {
  const _Wire({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });

  final int statusCode;
  final Map<String, String?> headers;
  final List<int> bytes;

  /// The `content-type` as it was sent, not as it was intended.
  String? get contentType => headers['content-type'];
}
