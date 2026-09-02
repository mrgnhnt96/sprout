import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/src/store/schema.dart' as schema;
import 'package:sproutd/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// A node with the required fields filled in, so each test only states the
/// field it is actually about.
SproutNode aNode(String id, {String? parent, NodeStatus? status}) {
  return SproutNode(
    id: id,
    parentId: parent,
    project: '/tmp/project',
    status: status ?? NodeStatus.working,
  );
}

/// The depth the tree query reported for [id].
int depthOf(List<TreeNode> tree, String id) =>
    tree.firstWhere((t) => t.node.id == id).depth;

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    // Every test writes here and nowhere else. Nothing in this file may open
    // SproutStore.open() with no path: that is ~/.sprout/sprout.db, the real
    // machine-wide database the daemon uses.
    tmp = Directory.systemTemp.createTempSync('sprout_store_test');
    dbPath = p.join(tmp.path, 'sprout.db');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('opening', () {
    test(
      'journal_mode is WAL on disk, and the check can tell when it is not',
      () {
        final store = SproutStore.open(path: dbPath);
        addTearDown(store.close);

        final reader = sqlite3.open(dbPath);
        addTearDown(reader.dispose);
        expect(reader.select('PRAGMA journal_mode').first.values.first, 'wal');

        // The paired negative. Without it, `expect(…, 'wal')` could be passing
        // because every SQLite database says 'wal', and this test would prove
        // nothing (INV8). A second database left in the default rollback mode
        // must report something else through the very same assertion.
        final plainPath = p.join(tmp.path, 'plain.db');
        final plain = sqlite3.open(plainPath);
        addTearDown(plain.dispose);
        expect(
          plain.select('PRAGMA journal_mode').first.values.first,
          isNot('wal'),
        );
      },
    );

    test('a second connection reads while a write transaction is open', () {
      final writer = SproutStore.open(path: dbPath);
      addTearDown(writer.close);
      writer.putNode(aNode('root'));

      final reader = SproutStore.open(path: dbPath);
      addTearDown(reader.close);

      // Take the write lock and keep it: BEGIN IMMEDIATE acquires it up front
      // rather than on first write, so there is no window where this test
      // passes because the writer had not started yet.
      final raw = sqlite3.open(dbPath);
      addTearDown(raw.dispose);
      raw.execute('BEGIN IMMEDIATE');
      raw.execute(
        "INSERT INTO node (id, project, status) VALUES ('mid-write', '/x', "
        "'working')",
      );

      // The reader is not blocked, and it sees the pre-commit snapshot.
      expect(reader.nodes().map((n) => n.id), ['root']);

      raw.execute('COMMIT');

      // The other half of the pair: the row does show up once committed, so
      // the assertion above is about isolation and not about the insert
      // having silently failed.
      expect(reader.nodes().map((n) => n.id), ['mid-write', 'root']);
    });

    test('an open reader does not block the daemon from writing', () {
      // This is what WAL actually buys, and unlike the two assertions above
      // it cannot pass in the default rollback-journal mode: there, the
      // reader's SHARED lock blocks the writer's COMMIT with SQLITE_BUSY, so
      // a long `sprout status` would stall the daemon.
      final writer = SproutStore.open(path: dbPath);
      addTearDown(writer.close);
      writer.putNode(aNode('root'));

      final reader = sqlite3.open(dbPath);
      addTearDown(reader.dispose);
      reader.execute('BEGIN');
      expect(reader.select('SELECT id FROM node').length, 1);

      // The read transaction is still open here, deliberately.
      writer.putNode(aNode('written-under-a-reader'));
      expect(writer.nodes().length, 2);

      // And the reader keeps its snapshot until it ends the transaction,
      // which is the paired half: the write landed without the reader's view
      // shifting under it mid-query.
      expect(reader.select('SELECT id FROM node').length, 1);
      reader.execute('COMMIT');
      expect(reader.select('SELECT id FROM node').length, 2);
    });

    test('creates the parent directory when it does not exist', () {
      final nested = p.join(tmp.path, 'does', 'not', 'exist', 'sprout.db');
      expect(File(nested).existsSync(), isFalse);
      SproutStore.open(path: nested).close();
      expect(File(nested).existsSync(), isTrue);
    });

    test('the default path is ~/.sprout/sprout.db', () {
      // `home` is injected so this asserts the path-building rule without
      // reading, or creating, anything under the developer's real home.
      expect(
        SproutStore.defaultDatabasePath(home: '/home/dev'),
        p.join('/home/dev', '.sprout', 'sprout.db'),
      );
      // Paired: an explicit path is used verbatim, so the default is a
      // fallback rather than something appended to whatever it is given.
      final store = SproutStore.open(path: dbPath);
      addTearDown(store.close);
      expect(File(dbPath).existsSync(), isTrue);
      expect(
        File(p.join(tmp.path, '.sprout', 'sprout.db')).existsSync(),
        isFalse,
      );
    });
  });

  group('schema versioning', () {
    test('a fresh database is stamped at the current version', () {
      final store = SproutStore.open(path: dbPath);
      addTearDown(store.close);
      expect(store.schemaVersion, currentSchemaVersion);
      expect(
        schema.migrations.length,
        currentSchemaVersion,
        reason: 'every migration must be reachable from the version constant',
      );
    });

    test('reopening applies nothing and keeps the data', () {
      final first = SproutStore.open(path: dbPath);
      first.putNode(aNode('root'));
      final seq = first.append(nodeId: 'root', kind: 'spawned');
      first.close();

      final second = SproutStore.open(path: dbPath);
      addTearDown(second.close);
      expect(second.schemaVersion, currentSchemaVersion);
      expect(second.node('root'), isNotNull);
      expect(second.cursor, seq);
      // A migration re-run would recreate the tables and lose these rows, so
      // the surviving data is the assertion — a version number alone would
      // still read correctly after a destructive re-run.
      expect(second.eventsSince(0).map((e) => e.kind), [
        nodeObservedKind,
        'spawned',
      ]);
    });

    test('refuses a database written by a newer sprout', () {
      SproutStore.open(path: dbPath).close();
      final raw = sqlite3.open(dbPath);
      raw.execute(
        'INSERT INTO schema_version (version, applied_at) VALUES (?, ?)',
        [currentSchemaVersion + 1, DateTime.now().toUtc().toIso8601String()],
      );
      raw.dispose();

      expect(
        () => SproutStore.open(path: dbPath),
        throwsA(isA<SchemaVersionError>()),
      );
    });
  });

  group('nodes', () {
    test('round-trips every column, including the nullable ones', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      final since = DateTime.utc(2026, 9, 1, 12);
      store.putNode(
        SproutNode(
          id: 'a',
          project: '/repo',
          role: 'lead',
          status: NodeStatus.armed,
          currentTask: 'waiting on a decision',
          since: since,
          nextCheckin: since.add(const Duration(minutes: 15)),
        ),
      );

      final read = store.node('a')!;
      expect(read.parentId, isNull);
      expect(read.project, '/repo');
      expect(read.role, 'lead');
      expect(read.status, NodeStatus.armed);
      expect(read.currentTask, 'waiting on a decision');
      expect(read.since, since);
      expect(read.nextCheckin, since.add(const Duration(minutes: 15)));
      // The paired absence: a node that set none of the optional columns
      // reads back null rather than inheriting the previous row's values.
      store.putNode(aNode('b'));
      expect(store.node('b')!.role, isNull);
      expect(store.node('b')!.since, isNull);
    });

    test('putNode updates an existing node in place', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store.putNode(aNode('a'));
      store.putNode(aNode('a').copyWith(status: NodeStatus.cleared));
      expect(store.nodes().length, 1);
      expect(store.node('a')!.status, NodeStatus.cleared);
    });

    test('an unknown status is rejected rather than defaulted', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store.putNode(aNode('a', status: NodeStatus.working));
      expect(store.node('a')!.status, NodeStatus.working);
      expect(
        () => NodeStatus.fromWire('probably-fine'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('tree', () {
    test('reports depth through three levels across two branches', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store
        ..putNode(aNode('root'))
        ..putNode(aNode('left', parent: 'root'))
        ..putNode(aNode('right', parent: 'root'))
        ..putNode(aNode('left-a', parent: 'left'))
        ..putNode(aNode('right-a', parent: 'right'))
        ..putNode(aNode('deep', parent: 'left-a'));

      final tree = store.tree();
      expect(tree.length, 6);
      expect(depthOf(tree, 'root'), 0);
      expect(depthOf(tree, 'left'), 1);
      expect(depthOf(tree, 'right'), 1);
      expect(depthOf(tree, 'left-a'), 2);
      expect(depthOf(tree, 'right-a'), 2);
      expect(depthOf(tree, 'deep'), 3);
      // Parents precede children, so a consumer can render in one pass.
      final order = tree.map((t) => t.node.id).toList();
      expect(order.indexOf('left'), lessThan(order.indexOf('left-a')));
      expect(order.indexOf('left-a'), lessThan(order.indexOf('deep')));
    });

    test('a node whose parent is missing is still in the tree', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store
        ..putNode(aNode('root'))
        ..putNode(aNode('child', parent: 'root'))
        ..putNode(aNode('runaway', parent: 'never-recorded'));

      final tree = store.tree();
      // The failure this guards is silence: with a plain `parent_id IS NULL`
      // anchor, 'runaway' is simply absent and the caller sees a two-node
      // tree that looks entirely healthy.
      expect(tree.map((t) => t.node.id), contains('runaway'));
      expect(tree.length, 3);
      // It is the root of its own fragment, not smuggled in at some other
      // depth, and its recorded parent survives for a caller to report.
      expect(depthOf(tree, 'runaway'), 0);
      expect(
        tree.firstWhere((t) => t.node.id == 'runaway').node.parentId,
        'never-recorded',
      );

      // The paired positive: the same node, once its parent exists, is a
      // child at depth 1. Without this half, an implementation that put every
      // node at depth 0 would pass the assertions above.
      store.putNode(aNode('never-recorded', parent: 'root'));
      final joined = store.tree();
      expect(joined.length, 4);
      expect(depthOf(joined, 'never-recorded'), 1);
      expect(depthOf(joined, 'runaway'), 2);
    });

    test('a parent cycle fails loudly instead of dropping nodes', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store
        ..putNode(aNode('a', parent: 'b'))
        ..putNode(aNode('b', parent: 'a'));
      // Neither is a root and neither is reachable from one, so a tree query
      // that just returned its rows would report an empty graph while two
      // nodes sit in the table.
      expect(
        store.tree,
        throwsA(
          isA<TreeIntegrityError>().having((e) => e.missing, 'missing', {
            'a',
            'b',
          }),
        ),
      );
    });

    test('an empty database has an empty tree', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      expect(store.tree(), isEmpty);
      store.putNode(aNode('root'));
      expect(store.tree().length, 1);
    });

    test('children returns only direct descendants', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store
        ..putNode(aNode('root'))
        ..putNode(aNode('kid', parent: 'root'))
        ..putNode(aNode('grandkid', parent: 'kid'));
      expect(store.children('root').map((n) => n.id), ['kid']);
      expect(store.children('kid').map((n) => n.id), ['grandkid']);
      expect(store.children('grandkid'), isEmpty);
    });
  });

  group('events', () {
    test('seq is monotonic and gapless, including after a refused write', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      // The row's own announcement is seq 1; everything below counts on
      // from there.
      expect(store.putNode(aNode('root')), 1);

      expect(store.append(nodeId: 'root', kind: 'a'), 2);
      expect(store.append(nodeId: 'root', kind: 'b'), 3);
      expect(store.append(nodeId: 'root', kind: 'c'), 4);

      // A rejected insert must not burn a cursor value: Phase 2's
      // `watch --since` treats a gap as events it missed, so a hole here
      // reads as data loss that never happened.
      expect(
        () => store.append(nodeId: 'no-such-node', kind: 'x'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.append(nodeId: 'root', kind: 'd'), 5);
      expect(store.cursor, 5);
    });

    test('foreign_keys is ON: an event needs a node that exists', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      // The negative and the positive together. On a connection that left
      // foreign_keys at its default OFF, the first expectation fails — which
      // is what makes this a test of the pragma and not of the API.
      expect(
        () => store.append(nodeId: 'ghost', kind: 'spawned'),
        throwsA(isA<SqliteException>()),
      );
      expect(store.putNode(aNode('ghost')), 1);
      expect(store.append(nodeId: 'ghost', kind: 'spawned'), 2);
    });

    test('the feed is append-only, enforced by the database', () {
      final store = SproutStore.open(path: dbPath);
      addTearDown(store.close);
      store.putNode(aNode('root'));
      store.append(nodeId: 'root', kind: 'spawned', payload: {'depth': 0});

      // Raw SQL on a separate connection, deliberately: the point is that the
      // guarantee does not depend on going through SproutStore, which is the
      // only thing an API with no update method can promise.
      final raw = sqlite3.open(dbPath);
      addTearDown(raw.dispose);
      expect(
        () => raw.execute("UPDATE event SET kind = 'rewritten'"),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => raw.execute('DELETE FROM event'),
        throwsA(isA<SqliteException>()),
      );
      // The paired positive: inserts on that same connection still work, so
      // the two refusals above are about update and delete specifically and
      // not about the table being unwritable.
      raw.execute(
        "INSERT INTO event (node_id, ts, kind, payload) VALUES ('root', "
        "'2026-09-01T00:00:00.000Z', 'later', '{}')",
      );
      expect(store.eventsSince(0).map((e) => e.kind), [
        nodeObservedKind,
        'spawned',
        'later',
      ]);
    });

    test('round-trips ts and a JSON payload', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      final base = store.putNode(aNode('root'))!;
      final ts = DateTime.utc(2026, 9, 1, 12, 30);
      store.append(
        nodeId: 'root',
        kind: 'tool_use',
        ts: ts,
        payload: {
          'name': 'Bash',
          'nested': <String, Object?>{'n': 1},
        },
      );

      final event = store.eventsSince(base).single;
      expect(event.ts, ts);
      expect(event.kind, 'tool_use');
      expect(event.payload['name'], 'Bash');
      expect(event.payload['nested'], {'n': 1});
    });

    test('eventsSince resumes strictly after the cursor', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      // Measured from after the row's announcement, so the five events below
      // are the whole of what this test put in the feed.
      final base = store.putNode(aNode('root'))!;
      for (var i = 0; i < 5; i++) {
        store.append(nodeId: 'root', kind: 'e$i');
      }

      expect(store.eventsSince(base).map((e) => e.kind), [
        'e0',
        'e1',
        'e2',
        'e3',
        'e4',
      ]);
      // Exclusive on the low end: the event at the cursor was already handled,
      // and redelivering it would double-count in Phase 2's consumer.
      expect(store.eventsSince(base + 2).map((e) => e.kind), [
        'e2',
        'e3',
        'e4',
      ]);
      expect(store.eventsSince(base + 5), isEmpty);
      expect(store.eventsSince(base, limit: 2).map((e) => e.kind), [
        'e0',
        'e1',
      ]);
    });

    test('eventsSince can filter to one node without dropping the rest', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store
        ..putNode(aNode('a'))
        ..putNode(aNode('b'));
      final base = store.cursor;
      store
        ..append(nodeId: 'a', kind: 'from-a')
        ..append(nodeId: 'b', kind: 'from-b');

      expect(store.eventsSince(base, nodeId: 'a').map((e) => e.kind), [
        'from-a',
      ]);
      // Paired: with no filter both are still there, so the filter is
      // selecting rather than the second event having failed to land.
      expect(store.eventsSince(base).map((e) => e.kind), ['from-a', 'from-b']);
    });

    test('the cursor starts at zero and tracks the last append', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      expect(store.cursor, 0);
      // A node row moves the cursor too, because writing one appends its
      // announcement — see the `putNode announces` group.
      store.putNode(aNode('root'));
      expect(store.cursor, 1);
      store.append(nodeId: 'root', kind: 'spawned');
      expect(store.cursor, 2);
    });
  });

  group('putNode announces the node it writes', () {
    test('a new row appends runner.observed carrying the whole node', () {
      final store = SproutStore.memory();
      addTearDown(store.close);

      final seq = store.putNode(
        SproutNode(
          id: 'root',
          project: '/w/root',
          status: NodeStatus.spawning,
          currentTask: 'orchestrate',
        ),
      );

      final event = store.eventsSince(0).single;
      expect(seq, event.seq);
      expect(event.kind, nodeObservedKind);
      // Attributed to the node's own id, exactly as `runner.spawned` is, so a
      // consumer folding by `node_id` files it against the right node.
      expect(event.nodeId, 'root');
      // The whole row, so a consumer that attached before this node existed
      // can build it from the feed alone and never re-`snapshot`. This is the
      // half F-10 was missing for the root.
      expect(event.payload, {
        'parent_id': null,
        'project': '/w/root',
        'status': NodeStatus.spawning.wire,
        'current_task': 'orchestrate',
      });
    });

    test('a real change appends runner.updated with only what moved', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store.putNode(aNode('root', status: NodeStatus.spawning));
      final base = store.cursor;

      store.putNode(aNode('root', status: NodeStatus.working));

      final event = store.eventsSince(base).single;
      expect(event.kind, nodeUpdatedKind);
      // Not a second creation, and not a restatement of the unchanged fields:
      // spelling those out would make a status flip indistinguishable from a
      // node being recreated.
      expect(event.payload, {
        'status': {
          'from': NodeStatus.spawning.wire,
          'to': NodeStatus.working.wire,
        },
      });
    });

    test('a write that moves nothing a board renders appends nothing', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      store.putNode(aNode('root'));
      final base = store.cursor;

      // The status-poll case: the same row written again. An event per write
      // would turn a poll into a flood on the feed a UI reads.
      expect(store.putNode(aNode('root')), isNull);
      expect(store.eventsSince(base), isEmpty);

      // The paired positive, so the silence above is suppression and not a
      // store that has stopped announcing altogether.
      expect(
        store.putNode(aNode('root', status: NodeStatus.checkpointed)),
        isNotNull,
      );
      expect(store.eventsSince(base).single.kind, nodeUpdatedKind);
    });

    test('announce rides along and cannot overwrite the row', () {
      final store = SproutStore.memory();
      addTearDown(store.close);

      store.putNode(
        aNode('root'),
        announce: {'tool_use_id': 'toolu_1', 'status': 'nonsense'},
      );

      final event = store.eventsSince(0).single;
      // The extra fact travels: `tool_use_id` is the one thing about a
      // subagent the row does not hold.
      expect(event.payload['tool_use_id'], 'toolu_1');
      // ...but a caller cannot describe the row as something other than what
      // was written, or the feed and the table would disagree.
      expect(event.payload['status'], NodeStatus.working.wire);
      expect(store.node('root')!.status, NodeStatus.working);
    });

    test('the announcement carries the timestamp it was given', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      final ts = DateTime.utc(2026, 9, 1, 12, 30);

      store.putNode(aNode('root'), ts: ts);

      expect(store.eventsSince(0).single.ts, ts);
    });
  });
}
