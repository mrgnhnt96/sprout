/// Persistence for sprout's task graph and event feed.
///
/// One SQLite file under `~/.sprout/`, opened in-process via `package:sqlite3`
/// with `journal_mode=WAL` so the CLI can read while the daemon writes. The
/// tree is `node(id, parent_id, …)` and the feed is an append-only
/// `event(seq, node_id, ts, kind, payload)`; the tree is read back with a
/// recursive CTE rather than repeated point queries.
///
/// Implementation lives under `lib/src/store/`. See `docs/01-plan.md` §13.
library;

export 'src/store/event.dart' show SproutEvent;
export 'src/store/node.dart' show NodeStatus, SproutNode, TreeNode;
export 'src/store/schema.dart' show SchemaVersionError, currentSchemaVersion;
export 'src/store/sprout_store.dart' show SproutStore, TreeIntegrityError;
