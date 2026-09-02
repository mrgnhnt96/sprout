/// The values that travel on the wire and sit in the store.
///
/// Pure data with no I/O of any kind: a [SproutEvent] is a row that was read
/// back, a [SproutNode] is one agent session, and neither knows how it was
/// obtained. They live here rather than in `package:sproutd/store.dart`
/// because both ends of the protocol need them and only one end has a database
/// — that was finding F-07, and `pubspec.yaml` records what it cost.
///
/// `package:sproutd/store.dart` re-exports this library, so every existing
/// importer of `SproutEvent`, `SproutNode`, `NodeStatus` and `TreeNode` reads
/// exactly the same declarations from exactly the same path as before.
///
/// Implementation lives under `lib/src/values/`.
library;

export 'src/values/event.dart' show SproutEvent;
export 'src/values/node.dart' show NodeStatus, SproutNode, TreeNode;
