import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'event.dart';
import 'node.dart';
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
  SproutStore._(this._db);

  /// Opens the store at [path], creating the file and its directory if needed.
  ///
  /// [path] defaults to [defaultDatabasePath]. Tests should pass a temp path
  /// or use [SproutStore.memory]; nothing in the suite may touch the real
  /// `~/.sprout/sprout.db`.
  factory SproutStore.open({String? path}) {
    final file = path ?? defaultDatabasePath();
    Directory(p.dirname(file)).createSync(recursive: true);
    final db = sqlite3.open(file);
    _configure(db);
    migrate(db);
    return SproutStore._(db);
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
    return SproutStore._(db);
  }

  final Database _db;

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

  /// Inserts [node], or replaces the row with the same [SproutNode.id].
  void putNode(SproutNode node) {
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
  }

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
