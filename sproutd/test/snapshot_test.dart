import 'package:sproutd/policy.dart';
import 'package:sproutd/protocol.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:test/test.dart';

/// A fixed instance, so every asserted cursor is a literal.
const String testInstanceId = '0123456789abcdef';

/// A well-formed id that is *not* the one under test — the other sproutd.
const String otherInstanceId = 'ffffffffffffffff';

/// The instant every snapshot in this file is taken at.
final DateTime takenAt = DateTime.utc(2026, 9, 1, 14, 15);

/// A `since` twelve minutes before [takenAt], so the rendered age is a literal.
final DateTime twelveMinutesAgo = DateTime.utc(2026, 9, 1, 14, 3);

/// A check-in fifteen minutes after [takenAt].
final DateTime inFifteenMinutes = DateTime.utc(2026, 9, 1, 14, 30);

/// A [SnapshotSource] whose feed fails, and whose graph does not.
///
/// This is the seam the interface exists for: an unreadable event feed cannot
/// be produced through `SproutStore`'s public API, and `journal_unreadable` is
/// a branch that only matters when it can actually be reached. The paired
/// positive control — that a *real* [StoreSnapshotSource] also throws, so the
/// catch is not defended only by this fake — is asserted below.
final class BrokenFeedSource implements SnapshotSource {
  BrokenFeedSource(this.store, {this.failsOnPosition = true});

  final SproutStore store;
  final bool failsOnPosition;

  @override
  int feedPosition() {
    if (failsOnPosition) throw const FileSystemException('feed is gone');
    return store.cursor;
  }

  @override
  List<SproutEvent> eventsUpTo(int position) =>
      throw const FileSystemException('payload could not be read');

  @override
  List<TreeNode> tree() => store.tree();
}

/// Stands in for `dart:io`'s, so the test has no io import for one message.
final class FileSystemException implements Exception {
  const FileSystemException(this.message);
  final String message;
  @override
  String toString() => 'FileSystemException: $message';
}

void putNode(
  SproutStore store,
  String id, {
  String? parentId,
  NodeStatus status = NodeStatus.working,
  String project = '/w/root',
  String? task,
  DateTime? since,
  DateTime? nextCheckin,
}) {
  store.putNode(
    SproutNode(
      id: id,
      parentId: parentId,
      project: project,
      status: status,
      currentTask: task,
      since: since,
      nextCheckin: nextCheckin,
    ),
  );
}

/// Appends the frame a dollar figure actually arrives on.
int appendResult(SproutStore store, String nodeId, double costUsd) =>
    store.append(
      nodeId: nodeId,
      kind: resultEventKind,
      payload: {totalCostUsdField: costUsd, 'subtype': 'success'},
    );

SproutSnapshot snapshotOf(SnapshotSource source) => takeSnapshot(
  source,
  instance: SproutInstance(testInstanceId),
  now: () => takenAt,
);

/// The line [id] renders on, or null if it does not render at all.
String? lineFor(SproutSnapshot snapshot, String id) {
  for (final line in snapshot.render().split('\n')) {
    if (line.contains(' $id ·')) return line;
  }
  return null;
}

/// The node [id] in [snapshot], failing loudly rather than returning null.
SnapshotNode nodeFor(SproutSnapshot snapshot, String id) =>
    snapshot.nodes.firstWhere((SnapshotNode n) => n.node.id == id);

/// A depth-3 forest with two branches, and spend on some of it.
///
/// ```
/// root                 $1.00        d0
///   a                  (unreported) d1
///     a1               $0.25        d2
///       a1x            (unreported) d3
///   b                  $0.50        d1
///     b1               $0.10        d2
/// ```
///
/// Chosen so that one subtree is **complete** (`b`), one is **partial** (`a`,
/// `root`) and one is **unknown** (`a1x`) — all three states of
/// [SubtreeSpend] in one fixture, so none of them can pass by being the only
/// case the test ever builds.
SproutStore twoBranchTree() {
  final store = SproutStore.memory();
  putNode(store, 'root', task: 'orchestrate', since: twelveMinutesAgo);
  putNode(store, 'a', parentId: 'root');
  putNode(store, 'a1', parentId: 'a');
  putNode(store, 'a1x', parentId: 'a1');
  putNode(store, 'b', parentId: 'root');
  putNode(store, 'b1', parentId: 'b');
  appendResult(store, 'root', 1.0);
  appendResult(store, 'a1', 0.25);
  appendResult(store, 'b', 0.5);
  appendResult(store, 'b1', 0.1);
  return store;
}

void main() {
  late SproutStore store;

  setUp(() => store = SproutStore.memory());
  tearDown(() => store.close());

  group('an empty store', () {
    test('is a valid snapshot, not an error', () {
      final snapshot = snapshotOf(StoreSnapshotSource(store));

      expect(snapshot.nodes, isEmpty);
      expect(snapshot.resources, isEmpty);
      expect(snapshot.cursor, Cursor(instanceId: testInstanceId, position: 0));
      expect(snapshot.journalUnreadable, isNull);
      expect(snapshot.takenAt, takenAt);
    });

    test('renders something rather than nothing, and stops when there is '
        'something to say', () {
      final empty = snapshotOf(StoreSnapshotSource(store)).render();

      // A snapshot that renders to an empty string is INV8 in one line: a
      // report that prints nothing when all is well cannot be told apart from
      // one that never ran.
      expect(empty, contains(noNodesText));
      expect(empty, contains(nothingHeldText));
      expect(empty, contains(journalReadableText));

      // The pair. Each of those three lines has to disappear when it is no
      // longer true, or it is a constant rather than an observation.
      putNode(store, 'root');
      final full = snapshotOf(StoreSnapshotSource(store)).render();
      expect(full, isNot(contains(noNodesText)));
      expect(full, isNot(contains(nothingHeldText)));
      expect(full, contains('holds /w/root · root'));
    });
  });

  group('the tree', () {
    test('carries every node with the depth the store assigned', () {
      final tree = twoBranchTree();
      addTearDown(tree.close);

      final snapshot = snapshotOf(StoreSnapshotSource(tree));
      expect(snapshot.nodes.length, 6);
      expect(
        {for (final node in snapshot.nodes) node.node.id: node.depth},
        {'root': 0, 'a': 1, 'a1': 2, 'a1x': 3, 'b': 1, 'b1': 2},
      );
      expect(nodeFor(snapshot, 'a1x').node.parentId, 'a1');
    });

    test('lists parents before children, depth-first, siblings by id', () {
      final tree = twoBranchTree();
      addTearDown(tree.close);

      expect(
        [
          for (final node in snapshotOf(StoreSnapshotSource(tree)).nodes)
            node.node.id,
        ],
        ['root', 'a', 'a1', 'a1x', 'b', 'b1'],
      );
    });

    test('reports a node whose parent was never recorded, at depth 0', () {
      // The runaway. `SproutStore.tree` makes it the root of its own fragment
      // rather than dropping it, and the snapshot must not undo that: a node
      // missing from the picture is indistinguishable from one that does not
      // exist.
      putNode(store, 'orphan', parentId: 'never-recorded');
      putNode(store, 'root');

      final snapshot = snapshotOf(StoreSnapshotSource(store));
      expect(nodeFor(snapshot, 'orphan').depth, 0);
      expect(snapshot.nodes.length, 2);
    });
  });

  group('subtree spend', () {
    late SproutStore tree;
    late SproutSnapshot snapshot;

    setUp(() {
      tree = twoBranchTree();
      snapshot = snapshotOf(StoreSnapshotSource(tree));
    });
    tearDown(() => tree.close());

    test('rolls a node\'s dollars up onto every ancestor', () {
      expect(nodeFor(snapshot, 'root').spend.knownMicroUsd, 1850000);
      expect(nodeFor(snapshot, 'b').spend.costUsd, 0.6);
      expect(nodeFor(snapshot, 'b1').spend.costUsd, 0.1);
      expect(nodeFor(snapshot, 'a').spend.costUsd, 0.25);
    });

    test('says how much of a subtree it could not see', () {
      expect(nodeFor(snapshot, 'root').spend.nodes, 6);
      expect(nodeFor(snapshot, 'root').spend.unknownNodes, 2);
      expect(nodeFor(snapshot, 'root').spend.isComplete, isFalse);

      // The pair: a subtree where everything reported is COMPLETE, so
      // "partial" is a measurement and not the only answer the code can give.
      expect(nodeFor(snapshot, 'b').spend.isComplete, isTrue);
      expect(nodeFor(snapshot, 'b').spend.unknownNodes, 0);
    });

    test('never renders an unobserved cost as \$0.00', () {
      final unknown = nodeFor(snapshot, 'a1x').spend;
      expect(unknown.isUnknown, isTrue);
      expect(unknown.costUsd, isNull);
      expect(unknown.label, 'spend ?');
      expect(unknown.label, isNot(contains('0.00')));

      // A floor is never printed as a total, and a total is never dressed as
      // a floor.
      expect(nodeFor(snapshot, 'root').spend.label, '>=\$1.8500 (2 unknown)');
      expect(nodeFor(snapshot, 'b').spend.label, '\$0.6000');
    });

    test('takes the LAST result, because total_cost_usd is cumulative', () {
      // `B.ndjson` runs 0.2316953 → 0.2415507 across two result frames
      // (INV12). Stopping at the first understates the run.
      putNode(store, 'root');
      appendResult(store, 'root', 0.2316953);
      appendResult(store, 'root', 0.2415507);

      final one = snapshotOf(StoreSnapshotSource(store));
      // Own cost is what the control plane said, verbatim. Subtree spend is a
      // SUM, and sums of money are taken in micro-dollars, so it is quantised
      // to six decimal places — `SpendLedger`'s deliberate choice, because
      // `0.1 + 0.2 > 0.3` in binary floating point.
      expect(nodeFor(one, 'root').ownCostUsd, 0.2415507);
      expect(nodeFor(one, 'root').spend.costUsd, 0.241551);
    });

    test('ignores a dollar figure on any other kind of event', () {
      putNode(store, 'root');
      store.append(
        nodeId: 'root',
        kind: 'runner.spawned',
        payload: {totalCostUsdField: 99.0},
      );
      expect(
        nodeFor(snapshotOf(StoreSnapshotSource(store)), 'root').ownCostUsd,
        isNull,
      );

      // The pair: the same payload on a `result` IS read, so the assertion
      // above is about the kind and not about the fold being broken.
      appendResult(store, 'root', 99.0);
      expect(
        nodeFor(snapshotOf(StoreSnapshotSource(store)), 'root').ownCostUsd,
        99.0,
      );
    });

    test('agrees with a SpendLedger built over the same nodes', () {
      // The roll-up is `SpendLedger`'s, not a second implementation of it.
      final ledger = SpendLedger.of([
        for (final node in snapshot.nodes)
          NodeSpend(
            id: node.node.id,
            parentId: node.node.parentId,
            costUsd: node.ownCostUsd ?? 0,
          ),
      ]);
      for (final node in snapshot.nodes) {
        expect(
          node.spend.knownMicroUsd,
          ledger.subtreeMicroUsd(node.node.id),
          reason: 'subtree spend for ${node.node.id}',
        );
      }
    });
  });

  group('the three fields that survive any compression', () {
    test('next check-in prints NONE SCHEDULED rather than a blank', () {
      putNode(store, 'none');
      putNode(store, 'some', nextCheckin: inFifteenMinutes);

      final snapshot = snapshotOf(StoreSnapshotSource(store));
      expect(lineFor(snapshot, 'none'), contains('next NONE SCHEDULED'));

      // The pair (INV8). A field that always prints the same words is not
      // reporting anything; the scheduled case has to print the time.
      expect(lineFor(snapshot, 'some'), contains('next 14:30Z'));
      expect(lineFor(snapshot, 'some'), isNot(contains(noCheckinText)));

      // And the blank the constant exists to prevent, in the exact shape it
      // would take: two separators with nothing between them.
      expect(lineFor(snapshot, 'none'), isNot(contains('next  ·')));
      expect(lineFor(snapshot, 'none'), isNot(endsWith('next ')));
    });

    test('an age is never estimated: since ? when there is no frame', () {
      putNode(store, 'nosince');
      putNode(store, 'measured', since: twelveMinutesAgo);

      final snapshot = snapshotOf(StoreSnapshotSource(store));
      expect(lineFor(snapshot, 'nosince'), contains('since ?'));
      expect(lineFor(snapshot, 'nosince'), isNot(contains('0m')));

      // The pair: a real `since` renders a real, measured age against the
      // instant the snapshot was taken.
      expect(lineFor(snapshot, 'measured'), contains('since 14:03Z (12m)'));
    });

    test('a held resource always names its holder', () {
      putNode(store, 'live', status: NodeStatus.working, project: '/w/one');
      putNode(store, 'gone', status: NodeStatus.cleared, project: '/w/two');

      final snapshot = snapshotOf(StoreSnapshotSource(store));
      expect(snapshot.resources, [
        HeldResource(name: '/w/one', holder: 'live'),
      ]);
      expect(snapshot.render(), contains('holds /w/one · live'));

      // The pair: a node that has ended holds nothing, so the list is an
      // observation rather than one entry per node.
      expect(snapshot.render(), isNot(contains('/w/two')));
    });

    test('a resource cannot exist without a named holder', () {
      // Enforcement, not a paragraph (INV1): the type refuses, so no caller
      // can render "something is locked" without saying by whom.
      expect(
        () => HeldResource(name: '/w/one', holder: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => HeldResource(name: '', holder: 'live'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('two nodes in one project show as two holders, not one', () {
      putNode(store, 'first', project: '/w/shared');
      putNode(store, 'second', project: '/w/shared');

      expect(snapshotOf(StoreSnapshotSource(store)).resources, [
        HeldResource(name: '/w/shared', holder: 'first'),
        HeldResource(name: '/w/shared', holder: 'second'),
      ]);
    });
  });

  group('journal_unreadable', () {
    test('is set when the feed cannot be read, and unset when it can', () {
      putNode(store, 'root');
      appendResult(store, 'root', 1.0);

      final broken = snapshotOf(BrokenFeedSource(store));
      expect(broken.isJournalUnreadable, isTrue);
      expect(broken.journalUnreadable, contains('feed is gone'));
      expect(broken.render(), contains('journal_unreadable: '));

      // The pair, over the same store. Without it, "sets the flag" would pass
      // just as well against code that sets it unconditionally.
      final read = snapshotOf(StoreSnapshotSource(store));
      expect(read.isJournalUnreadable, isFalse);
      expect(read.journalUnreadable, isNull);
      expect(read.render(), contains(journalReadableText));
      expect(read.render(), isNot(contains(journalUnreadableKey)));
    });

    test('is set when the events fail even though the position read', () {
      putNode(store, 'root');
      appendResult(store, 'root', 1.0);

      final snapshot = snapshotOf(
        BrokenFeedSource(store, failsOnPosition: false),
      );
      expect(snapshot.journalUnreadable, contains('payload could not be read'));
    });

    test('still returns the graph, and refuses to guess a position', () {
      putNode(store, 'root');
      putNode(store, 'child', parentId: 'root');
      appendResult(store, 'root', 1.0);

      final snapshot = snapshotOf(BrokenFeedSource(store));

      // The picture is still worth having: the nodes read fine.
      expect(snapshot.nodes.length, 2);
      expect(snapshot.resources, isNotEmpty);

      // But nothing that came out of the feed is asserted. A position read
      // from a feed nobody could read would be a guess, and a consumer
      // resuming from it would skip whatever it named.
      expect(snapshot.cursor.position, 0);
      expect(nodeFor(snapshot, 'root').ownCostUsd, isNull);
      expect(nodeFor(snapshot, 'root').spend.isUnknown, isTrue);
      expect(lineFor(snapshot, 'root'), contains('spend ?'));
    });

    test('the real source can fail too, so the branch is not fake-only', () {
      // The positive control. `BrokenFeedSource` proves the snapshot handles a
      // throwing feed; this proves a throwing feed is a thing that happens —
      // otherwise the whole `journal_unreadable` path is defended only by the
      // test that invented it.
      final closed = SproutStore.memory();
      final source = StoreSnapshotSource(closed);
      expect(source.feedPosition(), 0);
      closed.close();
      expect(source.feedPosition, throwsA(anything));
      expect(() => source.eventsUpTo(0), throwsA(anything));
    });
  });

  group('the cursor', () {
    test('is a namespaced token, not a bare seq', () {
      putNode(store, 'root');
      final seq = appendResult(store, 'root', 1.0);

      final snapshot = snapshotOf(StoreSnapshotSource(store));
      expect(snapshot.cursor.position, seq);
      expect(snapshot.cursor.encode(), 's1.$testInstanceId.$seq');
      expect(snapshot.toJson()['cursor'], 's1.$testInstanceId.$seq');
    });

    test('is one this instance accepts back, and another refuses', () {
      putNode(store, 'root');
      appendResult(store, 'root', 1.0);
      final token = snapshotOf(StoreSnapshotSource(store)).cursor.encode();

      // The whole point of the round trip: `watch --since <that token>`.
      expect(
        SproutInstance(testInstanceId).accept(token),
        isA<CursorAccepted>(),
      );

      // The pair. A restarted sproutd must refuse it rather than resume at a
      // seq that has come to mean something else.
      expect(
        SproutInstance(otherInstanceId).accept(token),
        isA<CursorFromAnotherInstance>(),
      );
    });

    test('defaults to this process\'s instance', () {
      final snapshot = takeSnapshot(StoreSnapshotSource(store));
      expect(snapshot.cursor.instanceId, SproutInstance.current.id);
    });

    test('fixes the feed at one position, ahead of which nothing is read', () {
      // The mechanism behind "one instant": events at or below the position
      // can never change, so reading them later still lands at the cursor.
      putNode(store, 'root');
      final first = appendResult(store, 'root', 1.0);
      appendResult(store, 'root', 2.0);

      final events = StoreSnapshotSource(store).eventsUpTo(first);
      expect([for (final event in events) event.seq], [first]);
      expect(StoreSnapshotSource(store).eventsUpTo(first + 1).length, 2);
    });
  });

  group('rendering', () {
    test('is one line per node, indented by depth', () {
      final tree = twoBranchTree();
      addTearDown(tree.close);

      final lines = snapshotOf(StoreSnapshotSource(tree)).render().split('\n');
      expect(lines.first, startsWith('cursor s1.$testInstanceId.'));
      expect(
        lines.where((String l) => l.startsWith('working · root')),
        hasLength(1),
      );
      expect(
        lines.where((String l) => l.startsWith('  working · a ·')),
        hasLength(1),
      );
      expect(
        lines.where((String l) => l.startsWith('      working · a1x ·')),
        hasLength(1),
      );
    });

    test('renders the whole line for a node with everything filled in', () {
      putNode(
        store,
        'root',
        task: 'fix   the\n  parser',
        since: twelveMinutesAgo,
        nextCheckin: inFifteenMinutes,
      );
      appendResult(store, 'root', 0.2415507);

      expect(
        lineFor(snapshotOf(StoreSnapshotSource(store)), 'root'),
        'working · root · fix the parser · since 14:03Z (12m) · '
        'next 14:30Z · \$0.2416',
      );
    });

    test('says it does not know a task rather than printing a gap', () {
      putNode(store, 'root');
      expect(
        lineFor(snapshotOf(StoreSnapshotSource(store)), 'root'),
        contains('· ? ·'),
      );
    });

    test('refuses to turn a clock skew into a measured age', () {
      // A `since` in the future is not an age. `?` says so; `0m` would be a
      // guess wearing a measurement's clothes.
      putNode(store, 'skewed', since: takenAt.add(const Duration(hours: 1)));
      expect(
        lineFor(snapshotOf(StoreSnapshotSource(store)), 'skewed'),
        contains('since 15:15Z (?)'),
      );
    });

    test('formats an age at every scale it has one for', () {
      expect(formatAge(const Duration(minutes: 12)), '12m');
      expect(formatAge(Duration.zero), '0m');
      expect(formatAge(const Duration(hours: 3, minutes: 4)), '3h04m');
      expect(formatAge(const Duration(days: 2, hours: 3)), '2d03h');
      expect(formatAge(const Duration(minutes: -1)), unknownValueText);
    });

    test('formats a clock in UTC, marked as such', () {
      expect(formatClock(DateTime.utc(2026, 9, 1, 9, 5)), '09:05Z');
      expect(
        formatClock(
          DateTime.utc(2026, 9, 1, 9, 5).add(const Duration(hours: 2)),
        ),
        '11:05Z',
      );
    });
  });

  group('as JSON', () {
    test(
      'always carries every key, with an explicit null for what is absent',
      () {
        putNode(store, 'root');

        final json = snapshotOf(StoreSnapshotSource(store)).toJson();
        expect(
          json.keys,
          containsAll(<String>[
            'cursor',
            'taken_at',
            journalUnreadableKey,
            'nodes',
            'resources',
          ]),
        );
        expect(json[journalUnreadableKey], isNull);

        final node =
            (json['nodes']! as List<Object?>).single! as Map<String, Object?>;
        // An omitted key is the JSON spelling of a blank field, which is the
        // failure `NONE SCHEDULED` exists to prevent one layer up.
        expect(
          node.keys,
          containsAll(<String>[
            'id',
            'parent_id',
            'depth',
            'project',
            'role',
            'status',
            'current_task',
            'since',
            'next_checkin',
            'own_cost_usd',
            'subtree_cost_usd',
            'subtree_cost_is_complete',
            'subtree_unknown_cost_nodes',
          ]),
        );
        expect(node['next_checkin'], isNull);
        expect(node['since'], isNull);
        expect(node['subtree_cost_usd'], isNull);
        expect(node['subtree_unknown_cost_nodes'], 1);
      },
    );

    test('carries the instants in ISO-8601 UTC', () {
      putNode(
        store,
        'root',
        since: twelveMinutesAgo,
        nextCheckin: inFifteenMinutes,
      );

      final json = snapshotOf(StoreSnapshotSource(store)).toJson();
      final node =
          (json['nodes']! as List<Object?>).single! as Map<String, Object?>;
      expect(json['taken_at'], takenAt.toIso8601String());
      expect(node['since'], twelveMinutesAgo.toIso8601String());
      expect(node['next_checkin'], inFifteenMinutes.toIso8601String());
    });

    test('carries every holder', () {
      putNode(store, 'root', project: '/w/one');
      final json = snapshotOf(StoreSnapshotSource(store)).toJson();
      expect(json['resources'], [
        {'name': '/w/one', 'holder': 'root'},
      ]);
    });
  });
}
