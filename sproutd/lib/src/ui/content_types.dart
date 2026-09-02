/// The `content-type` every embedded asset is served with, by file extension.
///
/// **This table is read twice and written once.** `tool/embed_assets.dart`
/// consults it at generation time to refuse a payload it cannot type, and
/// [UiAssets.contentTypeFor] consults it at request time to set the header.
/// A second table in the generator would be two lists that must stay equal —
/// the shape of finding F-01 — so the generator imports this one.
///
/// **Why this is load-bearing rather than a nicety.** A browser applies strict
/// MIME checking to two of the three files in sprout's payload: a stylesheet
/// served as `application/octet-stream` is dropped, and a script served as
/// anything but a JavaScript type is refused. Neither produces an error the
/// user sees — the page renders blank, or unstyled, with the server reporting
/// 200 for every request. That is why [contentTypeForAsset] returns null for
/// an extension it does not know instead of falling back to
/// `application/octet-stream`: the fallback is exactly the value that fails
/// silently, and `tool/embed_assets.dart` turns the null into a build error
/// naming the file.
library;

/// Extension (with its dot, lower-case) to the full header value.
///
/// `charset=utf-8` is spelled out on every text type. Dart writes these files
/// as UTF-8 and a browser defaults a `text/*` response without a charset to a
/// locale-dependent encoding, so omitting it makes the rendering of a
/// non-ASCII byte depend on the machine that opened the page.
const Map<String, String> assetContentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  // `text/javascript` and not `application/javascript`: the latter is
  // obsolete per the WHATWG MIME sniffing standard, and the former is the
  // only spelling every browser accepts for a module script.
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  // Source maps are JSON. Only a devtools instance asks for one.
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
};

/// The `content-type` for [name], or null when the extension is unknown.
///
/// Null is the honest answer and never a default. See the library comment:
/// the plausible fallback is the value that makes a browser silently discard
/// the response.
///
/// The extension is the text from the last dot, so `main.client.dart.js`
/// resolves as `.js` — which is the actual name of the payload's bundle.
String? contentTypeForAsset(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return assetContentTypes[name.substring(dot).toLowerCase()];
}
