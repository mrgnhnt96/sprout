import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sprout_protocol/values.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Thrown when the tree query does not account for every node exactly once.
///
/// A tree that quietly drops rows loses precisely the detached, runaway node
/// sprout exists to show you, and a silently short list looks identical to a
/// small tree. This turns that into a failure that names the ids.
class TreeIntegrityError implements Exception {
  /// Creates the error.
  const TreeIntegrityError({required this.missing, required this.duplicated});

  /// Node ids present in `node` but absent from the tree result.
  final Set<String> missing;

  /// Node ids the tree result returned more than once.
  final Set<String> duplicated;

  @override
  String toString() =>
      'TreeIntegrityError: the node graph is not a forest. '
      'missing: $missing, duplicated: $duplicated. '
      'A parent cycle is the usual cause.';
}

// `nodeObservedKind` and `nodeUpdatedKind` — the kinds [SproutStore.putNode]
// appends below — are declared in `package:sprout_protocol/values.dart`,
// imported above, and re-exported from `package:sproutd/store.dart` so that
// every importer of this store still reads them from the path it always did.
// They moved there because they are wire vocabulary rather than a fact about
// SQLite: the browser branches on the strings it reads back off the socket and
// cannot import this library, so it used to spell them a second time. That was
// finding F-11.

/// The node graph and the append-only event feed, on one SQLite file.
///
/// Callers get nodes and events, never a [Database]: the SQL — the recursive
/// CTE in particular — lives here so that the daemon and the CLI cannot drift
/// into two different ideas of what the tree is.
///
/// **Platform note.** `package:sqlite3` links the *system* `libsqlite3`. That
/// is fine on macOS, where a `dart compile exe` binary is self-contained
/// against the OS copy (3.51.0, verified in `docs/research/05-dart-stack.md`).
/// A portable Linux build will need `sqlite3_native_assets` or a bundled
/// library. Deliberately not solved here.
class SproutStore {
  SproutStore._(this._db, this.databasePath);

  /// Opens the store at [path], creating the file and its directory if needed.
  ///
  /// [path] defaults to [defaultDatabasePath]. Tests should pass a temp path
  /// or use [SproutStore.memory]; nothing in the suite may touch the real
  /// `~/.sprout/sprout.db`.
  factory SproutStore.open({String? path}) {
    final file = p.absolute(path ?? defaultDatabasePath());
    Directory(p.dirname(file)).createSync(recursive: true);
    final db = sqlite3.open(file);
    _configure(db);
    migrate(db);
    return SproutStore._(db, file);
  }

  /// Opens a throwaway in-memory store. For tests.
  ///
  /// Note that `journal_mode` is `memory` here and cannot be WAL — the
  /// concurrent-reader guarantee is a property of an on-disk database, so any
  /// test that means to prove it must use a file.
  factory SproutStore.memory() {
    final db = sqlite3.openInMemory();
    _configure(db);
    migrate(db);
    return SproutStore._(db, 'memory:${_memoryStores++}');
  }

  final Database _db;

  /// The database this store is a connection to, as an absolute path.
  ///
  /// **Absolute, always**, including when a relative path was passed to
  /// [SproutStore.open]. `SproutInstance.forFeed` hashes this to namespace the
  /// cursors taken against this feed, so a relative value would make a
  /// cursor's instance id depend on the process's working directory and two
  /// consumers of one database would refuse each other's cursors.
  ///
  /// An in-memory store has no file, so it reports `memory:<n>` with a counter
  /// that is unique within the process. Not cosmetic: two in-memory stores
  /// really are two different databases, and a shared literal would make two
  /// empty ones derive the same instance id — a collision that silently
  /// accepts a foreign cursor, which is the one outcome the instance id exists
  /// to prevent.
  final String databasePath;

  static int _memoryStores = 0;

  /// A generous ceiling on tree depth, used to bound the recursive CTE.
  ///
  /// sprout's real cap is depth 3, so nothing legitimate comes near this. It
  /// exists so that a `parent_id` cycle terminates instead of running until
  /// the process dies; the resulting short or repeated result is then caught
  /// by the integrity check in [tree] and reported as [TreeIntegrityError].
  static const int maxTreeDepth = 64;

  static void _configure(Database db) {
    // WAL is what lets `sprout status` read while the daemon writes. It is
    // persistent in the file, so it survives reopening, and it is a no-op that
    // reports `memory` for an in-memory database.
    db.execute('PRAGMA journal_mode = WAL');
    // Off by default in SQLite, per connection, and never inherited from the
    // file — so it has to be set on every connection, including a reader's.
    db.execute('PRAGMA foreign_keys = ON');
  }

  /// The default location: `~/.sprout/sprout.db`.
  ///
  /// [home] exists so this can be asserted in a test without reading, or
  /// creating, anything under the developer's real home directory.
  static String defaultDatabasePath({String? home}) {
    final root =
        home ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (root == null || root.isEmpty) {
      throw StateError(
        'no HOME in the environment, so the default database path cannot be '
        'resolved; pass an explicit path to SproutStore.open',
      );
    }
    return p.join(root, '.sprout', 'sprout.db');
  }

  /// The schema version of the open database.
  int get schemaVersion => readSchemaVersion(_db);

  /// The highest event [SproutEvent.seq] written, or 0 if the feed is empty.
  ///
  /// This is the cursor Phase 2's `watch --since` starts from.
  int get cursor {
    final rows = _db.select('SELECT COALESCE(MAX(seq), 0) AS c FROM event');
    return rows.first['c'] as int;
  }

  /// Inserts [node], or replaces the row with the same [SproutNode.id], and
  /// announces it on the feed.
  ///
  /// The event is appended in the same call as the row: [nodeObservedKind] the
  /// first time an id is written, [nodeUpdatedKind] when one of the rendered
  /// fields moves, and **nothing at all** when a write moves none of them. A
  /// caller therefore cannot put a node into the graph without an attached
  /// consumer learning of it, and cannot turn a repeated write into a flood.
  ///
  /// [announce] carries extra keys into that event's payload — facts about the
  /// node that the row itself does not hold, such as the `tool_use_id` a
  /// subagent was spawned by. The fields taken from [node] win over any key of
  /// the same name in [announce], so a caller cannot describe the row as
  /// something other than what was written.
  ///
  /// [ts] stamps the event and defaults to now; a caller holding an injected
  /// clock passes it, exactly as [append] takes one.
  ///
  /// Returns the [SproutEvent.seq] of the event appended, or null when the
  /// write changed nothing a consumer renders and so announced nothing.
  int? putNode(
    SproutNode node, {
    Map<String, Object?> announce = const {},
    DateTime? ts,
  }) {
    // Read before write: the row already in the database is the only honest
    // "previous", and an in-memory one would be wrong for any caller that did
    // not write the node itself.
    final previous = this.node(node.id);
    _db.execute(
      '''
      INSERT INTO node
        (id, parent_id, project, role, status, current_task, since,
         next_checkin)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        parent_id    = excluded.parent_id,
        project      = excluded.project,
        role         = excluded.role,
        status       = excluded.status,
        current_task = excluded.current_task,
        since        = excluded.since,
        next_checkin = excluded.next_checkin
      ''',
      [
        node.id,
        node.parentId,
        node.project,
        node.role,
        node.status.wire,
        node.currentTask,
        _instant(node.since),
        _instant(node.nextCheckin),
      ],
    );

    if (previous == null) {
      return append(
        nodeId: node.id,
        kind: nodeObservedKind,
        payload: {...announce, ..._observedPayload(node)},
        ts: ts,
      );
    }
    final patch = _updatedPayload(previous, node);
    if (patch.isEmpty) return null;
    return append(
      nodeId: node.id,
      kind: nodeUpdatedKind,
      payload: {...announce, ...patch},
      ts: ts,
    );
  }

  /// The whole node, so a consumer can build the row from this event alone
  /// rather than having to re-`snapshot` to learn the fields.
  static Map<String, Object?> _observedPayload(SproutNode node) => {
    'parent_id': node.parentId,
    'project': node.project,
    'status': node.status.wire,
    'current_task': node.currentTask,
  };

  /// Only what moved, each as `{from, to}`, and empty when nothing did.
  ///
  /// A consumer that has applied the [nodeObservedKind] event already holds the
  /// rest, and spelling out the unchanged fields would make a status flip
  /// indistinguishable from a re-creation in the feed.
  ///
  /// `project` is deliberately not compared: it is fixed for the life of a run
  /// and no consumer applies a patch to it, so a change there would produce an
  /// event nothing could read. `since`, `role` and `next_checkin` are left out
  /// for the same reason — the row is still updated with them, only the feed
  /// stays quiet.
  static Map<String, Object?> _updatedPayload(
    SproutNode previous,
    SproutNode next,
  ) => {
    if (previous.parentId != next.parentId)
      'parent_id': {'from': previous.parentId, 'to': next.parentId},
    if (previous.status != next.status)
      'status': {'from': previous.status.wire, 'to': next.status.wire},
    if (previous.currentTask != next.currentTask)
      'current_task': {'from': previous.currentTask, 'to': next.currentTask},
  };

  /// The node with [id], or null if there is none.
  SproutNode? node(String id) {
    final rows = _db.select('SELECT * FROM node WHERE id = ?', [id]);
    return rows.isEmpty ? null : _node(rows.first);
  }

  /// Every node, in insertion-independent id order.
  List<SproutNode> nodes() {
    return _db.select('SELECT * FROM node ORDER BY id').map(_node).toList();
  }

  /// The direct children of [id].
  List<SproutNode> children(String id) {
    final rows = _db.select(
      'SELECT * FROM node WHERE parent_id = ? ORDER BY id',
      [id],
    );
    return rows.map(_node).toList();
  }

  /// The whole forest, each node tagged with its depth, parents before
  /// children.
  ///
  /// The recursion starts from every node that has no parent **or whose parent
  /// is not in the table**. The second half is the point: with only the usual
  /// `parent_id IS NULL` anchor, a node whose parent was never recorded — the
  /// runaway — is silently absent from the result, and a caller cannot tell
  /// that from it not existing.
  ///
  /// Throws [TreeIntegrityError] if the result does not cover every node
  /// exactly once, which happens when `parent_id` forms a cycle.
  List<TreeNode> tree() {
    final rows = _db.select('''
      WITH RECURSIVE walk AS (
        SELECT n.*, 0 AS depth
          FROM node n
         WHERE n.parent_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM node p WHERE p.id = n.parent_id)
        UNION ALL
        SELECT c.*, w.depth + 1
          FROM node c
          JOIN walk w ON c.parent_id = w.id
         WHERE w.depth < $maxTreeDepth
      )
      SELECT * FROM walk ORDER BY depth, id
    ''');

    final result = <TreeNode>[];
    final seen = <String>{};
    final duplicated = <String>{};
    for (final row in rows) {
      final node = _node(row);
      if (!seen.add(node.id)) duplicated.add(node.id);
      result.add(TreeNode(node: node, depth: row['depth'] as int));
    }

    final all = _db
        .select('SELECT id FROM node')
        .map((Row r) => r['id'] as String)
        .toSet();
    final missing = all.difference(seen);
    if (missing.isNotEmpty || duplicated.isNotEmpty) {
      throw TreeIntegrityError(missing: missing, duplicated: duplicated);
    }
    return result;
  }

  /// Appends one event and returns its [SproutEvent.seq].
  ///
  /// There is no counterpart that edits or removes one, and adding one would
  /// be refused by the triggers in `schema.dart`, not merely discouraged here.
  int append({
    required String nodeId,
    required String kind,
    Map<String, Object?> payload = const {},
    DateTime? ts,
  }) {
    _db.execute(
      'INSERT INTO event (node_id, ts, kind, payload) VALUES (?, ?, ?, ?)',
      [
        nodeId,
        (ts ?? DateTime.now()).toUtc().toIso8601String(),
        kind,
        jsonEncode(payload),
      ],
    );
    return _db.lastInsertRowId;
  }

  /// Events with `seq > cursor`, oldest first.
  ///
  /// [limit] caps the batch; pass null for all of them. A caller resumes by
  /// passing the [SproutEvent.seq] of the last event it handled.
  List<SproutEvent> eventsSince(int cursor, {int? limit, String? nodeId}) {
    final rows = _db.select(
      '''
      SELECT * FROM event
       WHERE seq > ?
         AND (?2 IS NULL OR node_id = ?2)
       ORDER BY seq
       LIMIT ?3
      ''',
      [cursor, nodeId, limit ?? -1],
    );
    return rows.map(_event).toList();
  }

  /// The oldest event in the feed, or null while the feed is empty.
  ///
  /// The feed is append-only, so this row never changes while the database is
  /// the same database and is a different row the moment the file is replaced.
  /// That is what makes it the feed's identity, and it is read through one
  /// accessor rather than spelled as `eventsSince(0, limit: 1)` at each call
  /// site so that every surface fingerprints the same row. See
  /// `SproutInstance.forFeed`, its only caller in production.
  SproutEvent? get firstEvent {
    final rows = eventsSince(0, limit: 1);
    return rows.isEmpty ? null : rows.single;
  }

  /// Closes the underlying database. Further calls will throw.
  void close() => _db.dispose();

  static String? _instant(DateTime? value) => value?.toUtc().toIso8601String();

  static DateTime? _parseInstant(Object? value) =>
      value == null ? null : DateTime.parse(value as String).toUtc();

  static SproutNode _node(Row row) {
    return SproutNode(
      id: row['id'] as String,
      parentId: row['parent_id'] as String?,
      project: row['project'] as String,
      role: row['role'] as String?,
      status: NodeStatus.fromWire(row['status'] as String),
      currentTask: row['current_task'] as String?,
      since: _parseInstant(row['since']),
      nextCheckin: _parseInstant(row['next_checkin']),
    );
  }

  static SproutEvent _event(Row row) {
    return SproutEvent(
      seq: row['seq'] as int,
      nodeId: row['node_id'] as String,
      ts: DateTime.parse(row['ts'] as String).toUtc(),
      kind: row['kind'] as String,
      payload: (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>(),
    );
  }
}
