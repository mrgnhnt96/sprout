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
/// The event `kind` strings live here too, for the same reason the types do:
/// the producer writes them into a column that travels over the socket and the
/// browser branches on what it reads back, so they are wire vocabulary that
/// both ends need one declaration of. That was finding F-11.
///
/// Implementation lives under `lib/src/values/`.
library;

export 'src/values/event.dart' show SproutEvent;
export 'src/values/kinds.dart' show nodeObservedKind, nodeUpdatedKind;
export 'src/values/node.dart' show NodeStatus, SproutNode, TreeNode;
