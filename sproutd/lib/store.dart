/// Persistence for sprout's task graph and event feed.
///
/// One SQLite file under `~/.sprout/`, opened in-process via `package:sqlite3`
/// with `journal_mode=WAL` so the CLI can read while the daemon writes. The
/// tree is `node(id, parent_id, …)` and the feed is an append-only
/// `event(seq, node_id, ts, kind, payload)`; the tree is read back with a
/// recursive CTE rather than repeated point queries.
///
/// Implementation lives under `lib/src/store/`. See `docs/01-plan.md` §13.
///
/// **The row types themselves are not here.** `SproutEvent`, `SproutNode`,
/// `NodeStatus` and `TreeNode` are pure values that both ends of the protocol
/// need and only one end has a database for, so they live in
/// `package:sprout_protocol/values.dart` and are re-exported below. That was
/// finding F-07: this library's own `dart:io` and `package:sqlite3` imports
/// travelled to the browser through them and silently broke the web build.
/// The re-export is what keeps every existing `package:sproutd/store.dart`
/// importer reading the same declarations from the same path.
library;

export 'package:sprout_protocol/values.dart'
    show NodeStatus, SproutEvent, SproutNode, TreeNode;

export 'src/store/schema.dart' show SchemaVersionError, currentSchemaVersion;
export 'src/store/sprout_store.dart'
    show SproutStore, TreeIntegrityError, nodeObservedKind, nodeUpdatedKind;
