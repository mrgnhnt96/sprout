import 'package:sqlite3/sqlite3.dart';

/// The schema version this code writes.
///
/// Bump it by appending to [migrations]; the two must stay equal, and
/// `store_test.dart` asserts that they do.
const int currentSchemaVersion = 1;

/// Thrown when a database was written by a newer sprout than this one.
///
/// Opening it read-only anyway would let an old binary write rows that the new
/// schema cannot represent, so this fails closed and names both versions.
class SchemaVersionError implements Exception {
  /// Creates the error.
  const SchemaVersionError({required this.found, required this.supported});

  /// The version stamped in the file.
  final int found;

  /// The newest version this binary understands.
  final int supported;

  @override
  String toString() =>
      'SchemaVersionError: database is at schema version $found but this '
      'build only understands up to $supported. Upgrade sprout.';
}

/// The ordered list of migrations. Index `i` produces schema version `i + 1`.
///
/// There is only one today. It is a list anyway because retrofitting a
/// migration seam onto a store that is already on disk in `~/.sprout/` is far
/// worse than carrying an empty seam now: the first upgrade would have to
/// guess which of several shipped shapes it was looking at.
const List<void Function(Database)> migrations = [_v1];

void _v1(Database db) {
  // `parent_id` carries NO foreign key, on purpose. sprout watches sessions
  // from outside, so a child can be observed before its parent row exists, and
  // an FK would refuse that insert — losing exactly the detached node the tree
  // query is supposed to surface. `SproutStore.tree` treats a node with a
  // missing parent as a root of its own fragment instead.
  db.execute('''
    CREATE TABLE node (
      id            TEXT PRIMARY KEY,
      parent_id     TEXT,
      project       TEXT NOT NULL,
      role          TEXT,
      status        TEXT NOT NULL,
      current_task  TEXT,
      since         TEXT,
      next_checkin  TEXT
    )
  ''');
  db.execute('CREATE INDEX node_parent_id ON node (parent_id)');

  // `event.node_id` DOES carry a foreign key, and this is the asymmetry that
  // makes `PRAGMA foreign_keys=ON` load-bearing: an event names a node sprout
  // itself created a moment earlier, so there is no ordering excuse for a
  // dangling one, and a feed of events about nothing is unreadable.
  db.execute('''
    CREATE TABLE event (
      seq      INTEGER PRIMARY KEY AUTOINCREMENT,
      node_id  TEXT NOT NULL REFERENCES node (id),
      ts       TEXT NOT NULL,
      kind     TEXT NOT NULL,
      payload  TEXT NOT NULL
    )
  ''');
  db.execute('CREATE INDEX event_node_id ON event (node_id)');

  // Append-only, enforced by the database rather than by the shape of the Dart
  // API. `SproutStore` exposes no update or delete for events, but that is a
  // convention a future method could break without noticing; these refuse the
  // statement even when it is issued as raw SQL on the same connection.
  db.execute('''
    CREATE TRIGGER event_is_append_only_update
    BEFORE UPDATE ON event
    BEGIN SELECT RAISE(ABORT, 'event is append-only: no update'); END
  ''');
  db.execute('''
    CREATE TRIGGER event_is_append_only_delete
    BEFORE DELETE ON event
    BEGIN SELECT RAISE(ABORT, 'event is append-only: no delete'); END
  ''');
}

/// Brings [db] up to [currentSchemaVersion], creating the version table first.
///
/// Every migration runs inside one transaction with its own version stamp, so
/// an interrupted upgrade leaves the file at the last version that fully
/// applied rather than at a half-applied shape no migration knows how to fix.
void migrate(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS schema_version (
      version     INTEGER PRIMARY KEY,
      applied_at  TEXT NOT NULL
    )
  ''');

  final found = readSchemaVersion(db);
  if (found > currentSchemaVersion) {
    throw SchemaVersionError(found: found, supported: currentSchemaVersion);
  }

  for (var version = found + 1; version <= migrations.length; version++) {
    db.execute('BEGIN');
    try {
      migrations[version - 1](db);
      db.execute(
        'INSERT INTO schema_version (version, applied_at) VALUES (?, ?)',
        [version, DateTime.now().toUtc().toIso8601String()],
      );
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

/// The highest version stamped in [db], or 0 for a database with no stamps.
int readSchemaVersion(Database db) {
  final rows = db.select(
    'SELECT COALESCE(MAX(version), 0) AS v FROM schema_version',
  );
  return rows.first['v'] as int;
}
