/// The wire vocabulary of `snapshot` and `watch --since <cursor>`.
///
/// **A re-export.** The protocol itself lives in `package:sprout_protocol`,
/// which reaches neither `dart:io` nor `dart:ffi` so that the browser client
/// can compile it — see that package's `pubspec.yaml`, and finding F-07, for
/// why the split was not optional. Start there for what a cursor and a frame
/// *are*; nothing is declared in this file.
///
/// This path is kept rather than retired because it is what `bin/sprout.dart`,
/// `routes/controllers/tree_controller.dart`, `lib/snapshot.dart`,
/// `lib/watch.dart` and the tests already import. A re-export means those
/// importers read the *same declarations* they did before — not a second
/// definition that agrees today, which is the F-01 bug the split exists to
/// avoid repeating.
library;

export 'package:sprout_protocol/protocol.dart';
