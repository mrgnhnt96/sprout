/// The UI payload, held in memory and served from the binary's own constants.
///
/// See `tool/embed_assets.dart` for how [embeddedAssetsBase64] is produced and
/// `routes/controllers/ui_controller.dart` for how it reaches the wire.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sproutd/src/ui/assets.g.dart';
import 'package:sproutd/src/ui/content_types.dart';

/// The static files `jaspr build` emitted, addressed by their payload names.
///
/// **Nothing here touches the filesystem, and that is the whole point.**
/// Revali's `public/` directory is served by a generated handler whose body is
/// `File(p.join('public', <path>))` — a *relative* path, resolved against the
/// process working directory on every request (`revali` 3.3.2,
/// `lib/server/makers/part_files/public_file_maker.dart`). sprout is a single
/// relocatable binary that runs from `/` with no source tree beside it, so
/// that handler answers 404 for every asset in production while working
/// perfectly in the worktree. `docs/01-plan.md` §13 records embedded bytes as
/// the chosen way around it.
final class UiAssets {
  /// Wraps a name-to-base64 map. Tests build their own; production takes
  /// [embedded].
  UiAssets(this.encoded);

  /// The payload compiled into this binary.
  ///
  /// A `static final` and not a `static const`: the instance owns a decode
  /// cache, which is mutable state.
  static final UiAssets embedded = UiAssets(embeddedAssetsBase64);

  /// The document served at `/`.
  static const String indexName = 'index.html';

  /// Base64 by asset name, straight out of `assets.g.dart`.
  final Map<String, String> encoded;

  final Map<String, Uint8List> _decoded = {};

  /// Every asset name in the payload.
  Iterable<String> get names => encoded.keys;

  /// Whether [name] is in the payload.
  bool has(String name) => encoded.containsKey(name);

  /// The bytes of [name], or null when it is not in the payload.
  ///
  /// Decoded on first use and kept. Decoding at startup would pay for the
  /// whole payload on a daemon nobody opens a browser against, and decoding
  /// per request would pay for the bundle on every reload.
  Uint8List? bytesFor(String name) {
    if (_decoded[name] case final cached?) return cached;
    final encodedBytes = encoded[name];
    if (encodedBytes == null) return null;
    return _decoded[name] = base64Decode(encodedBytes);
  }

  /// The `content-type` [name] must be served with, or null if unknown.
  ///
  /// Never `application/octet-stream` as a fallback: see
  /// `content_types.dart`. `tool/embed_assets.dart` refuses to embed a file
  /// this returns null for, so a null here means the payload and the table
  /// have drifted rather than that a type is merely missing.
  String? contentTypeFor(String name) => contentTypeForAsset(name);
}
