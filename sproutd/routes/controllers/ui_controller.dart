/// The web UI, served out of the binary's own constants at `/`.
///
/// This is P3-03. `jaspr build` emits a static payload, `tool/embed_assets.dart`
/// turns it into `lib/src/ui/assets.g.dart`, and this controller answers with
/// those bytes. Nothing here opens a file, and that is the requirement rather
/// than a preference: `sprout` is one relocatable binary that runs from `/`
/// with its source tree unavailable.
///
/// **Why not Revali's `public/`.** The generated handler for a public file is
/// `context.response.body = File(p.join('public', <path>))` — read in
/// `revali` 3.3.2, `lib/server/makers/part_files/public_file_maker.dart`. That
/// path is relative, so it resolves against the process working directory on
/// every request. It works in the worktree and answers 404 everywhere else,
/// which is the worst failure shape there is: the developer who wrote it
/// cannot reproduce it. `docs/01-plan.md` §13 records embedded bytes as the
/// way around it, and this is that.
///
/// **Why the app has no prefix any more.** `AppConfig.prefix` wraps *every*
/// controller route — the generated server does
/// `_routes = [Route(prefix, routes: _routes)]` — and only the `public` routes
/// and the health probes are registered outside it (`revali` 3.3.2,
/// `lib/server/makers/server_file_maker.dart`). A prefixed app therefore has
/// no way to answer at `/` at all. So the prefix moved into the path of the
/// controller that wants it: see `daemonPrefix` and `main_app.dart`. The API
/// URLs did not change, and `test/ui_test.dart` asserts that against a router
/// built the way `revali build` builds it.
library;

import 'dart:io';

import 'package:revali_router/revali_router.dart';
import 'package:sproutd/ui.dart';

/// The stylesheet `jaspr_builder` renders from the `@css` getters in
/// `sprout_ui`.
const String stylesheetName = 'main.css';

/// The compiled client bundle `index.html` loads.
const String bundleName = 'main.client.dart.js';

/// Every name this controller declares a route for.
///
/// **This set and the payload have to be equal, and a test compares them.**
/// One route per file is not a preference — see [UiController.stylesheet] for
/// why a wildcard cannot work here — so the file names are written twice: once
/// in `assets.g.dart`, which the build generates, and once in the annotations
/// below, which a person writes. Two lists that must stay equal is the shape
/// of finding F-01, and the thing that made F-01 a bug was not the duplication
/// but that nothing compared the two. `test/ui_test.dart` compares them, so a
/// payload that grows a file fails there rather than 404ing in a browser.
const Set<String> servedAssetNames = {
  UiAssets.indexName,
  stylesheetName,
  bundleName,
};

/// The `content-type` the 404 body is served with.
const String errorContentType = 'text/plain; charset=utf-8';

/// The 404 body for [name], as a sentence.
///
/// Reached when a route below names a file the embedded payload does not have
/// — a binary generated from a payload this source predates. `name` is always
/// a compile-time constant from an annotation and never anything a client
/// sent, so there is nothing here to reflect back.
String assetNotFoundText(String name) => 'sprout: no such asset: $name';

/// Serves the embedded UI: `index.html` at `/`, and each asset by its name.
@Controller('')
class UiController {
  /// Takes nothing.
  ///
  /// **Deliberately zero-argument.** `revali` fills a controller's first
  /// constructor parameter from DI (`RequestScopedDI.getFrom(di)` in the
  /// generated `__routes.dart`), so a parameter here — even an optional one —
  /// becomes a DI lookup for a type nothing registers. The payload is a
  /// compile-time constant rather than a dependency; a test that wants a
  /// different one calls [write] directly.
  const UiController();

  /// `GET /` — the page.
  @Get()
  Future<void> index(Response response) async =>
      write(UiAssets.embedded, UiAssets.indexName, response);

  /// `GET /main.css` — the stylesheet.
  ///
  /// **One route per file, because a wildcard route genuinely does not work
  /// here.** `@Get('*asset')` under `@Controller('')` builds
  /// `Route('', routes: [Route('*asset', …)])`, and `Find` reaches a child
  /// through an empty-path parent only when the requested segment *equals the
  /// child's own path* — `route.path.isEmpty && path == proxy?.path`
  /// (`revali_router` 5.1.1, `lib/src/router/find.dart`). `'main.css'` is
  /// never equal to `'*asset'`, so every asset fell through to the router's
  /// own 404. That was observed against the compiled binary, not reasoned
  /// about: the wildcard was built, run and returned `Not Found` with revali's
  /// own body. A `:asset` parameter fails the same comparison for the same
  /// reason. Static names are what the router can actually reach, and
  /// [servedAssetNames] is what stops them drifting from the payload.
  @Get(stylesheetName)
  Future<void> stylesheet(Response response) async =>
      write(UiAssets.embedded, stylesheetName, response);

  /// `GET /main.client.dart.js` — the compiled Jaspr client.
  @Get(bundleName)
  Future<void> bundle(Response response) async =>
      write(UiAssets.embedded, bundleName, response);
}

/// Writes [name] out of [assets] onto [response].
///
/// A free function so a test can drive it against a payload of its own without
/// going through the router, and so all three routes have exactly one body.
///
/// **The `content-type` is set on the response's own headers rather than left
/// to the body.** A `List<int>` body becomes a `BinaryBodyData`, which reports
/// `application/octet-stream` and nothing else (`revali_router` 5.1.1,
/// `lib/src/body/response_body/binary_body_data.dart`).
/// `Response.joinedHeaders` merges the body's headers in with
/// `headers[key] ??= …`, so a header set here wins and the body's is only a
/// fallback.
///
/// **`MemoryFile` is the trap this avoids.** Revali's in-memory file body
/// carries the right mime type *and* sets `content-disposition: attachment`,
/// because `MemoryFileBodyData.headers` assigns `filename` and
/// `HeadersImpl.filename` writes `attachment; filename="…"`. A browser handed
/// that downloads the page instead of rendering it — the same class of thing
/// as finding F-03, where `@SSE` shipped `application/octet-stream` with the
/// handler's override ignored. The header you set is not always the header
/// that ships, so `test/ui_test.dart` reads every one of them off the wire.
void write(UiAssets assets, String name, Response response) {
  final bytes = assets.bytesFor(name);
  final contentType = assets.contentTypeFor(name);

  if (bytes == null || contentType == null) {
    response
      ..statusCode = HttpStatus.notFound
      ..body = assetNotFoundText(name)
      ..headers.contentTypeString = errorContentType;
    return;
  }

  response
    ..statusCode = HttpStatus.ok
    ..body = bytes
    ..headers.contentTypeString = contentType
    // The bundle's name carries no content hash, so an upgraded binary would
    // otherwise be shadowed by the previous one's script sitting in the
    // browser's cache — a UI that is silently a version behind. Revalidating
    // costs nothing over loopback.
    ..headers['cache-control'] = 'no-cache';
}
