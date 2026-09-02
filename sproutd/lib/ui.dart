/// The embedded web UI: the payload compiled into this binary, and the
/// `content-type` each file in it is served with.
///
/// Start at [UiAssets]. It wraps the base64 constants
/// `tool/embed_assets.dart` writes into `lib/src/ui/assets.g.dart`, decodes
/// them on first use and keeps them. `routes/controllers/ui_controller.dart`
/// is the only consumer in this repo.
///
/// The generated constants themselves are deliberately not exported: a caller
/// that reached them directly would be a second decode path with a second
/// answer about content types, and one of the two would be the one nobody
/// tested.
library;

export 'src/ui/content_types.dart';
export 'src/ui/ui_assets.dart';
