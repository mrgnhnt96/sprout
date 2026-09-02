/// The live tree, driven by a real capture: one snapshot, then deltas only.
///
/// This is the leaf's claim, made against bytes rather than against a
/// construction. `live_wire.bin` was recorded from the compiled daemon running
/// from `/` while the compiled CLI replayed
/// `docs/research/fixtures/phase0/streams/B.ndjson` — a root and two nested
/// subagents. The client attached **before** the run started, so the tree here
/// is built out of deltas and nothing else: exactly one `snapshot` frame goes
/// in, and it is empty.
library;

import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_protocol/snapshot.dart';
import 'package:sprout_protocol/values.dart';
import 'package:sprout_ui/app.dart';
import 'package:sprout_ui/src/live_tree.dart';
import 'package:test/test.dart';

import 'wire_fixture.dart';

/// The two subagents `B.ndjson` produces, by the tool-use id they are named
/// after. The second is a child of the first, so the tree has real depth.
const child = 'toolu_013CdYLPDjwGfSwE5gL5Q7BK';
const grandchild = 'toolu_01HLJXeJprJTzcM7oW2Zz1vp';

/// Replays [frames] and returns the tree after each one.
List<LiveTree> replay(List<ProtocolFrame> frames) {
  var tree = LiveTree.attaching;
  return [for (final frame in frames) tree = tree.apply(frame)];
}

SnapshotNode? nodeEndingIn(LiveTree tree, String suffix) {
  for (final node in tree.nodes) {
    if (node.node.id.endsWith(suffix)) return node;
  }
  return null;
}

void main() {
  final frames = WireFixture.read('live_wire').frames();
  final steps = replay(frames);
  final settled = steps.last;

  group('before anything arrives', () {
    test('attaching is not an empty tree', () {
      // INV8 in one assertion. A tree that has not been fetched and a tree
      // with nothing in it must not render the same, and the board says which.
      expect(LiveTree.attaching.isAttached, isFalse);
      expect(App.liveness(LiveTree.attaching), startsWith('ATTACHING'));
      expect(App.lines(LiveTree.attaching), isNot(contains(noNodesText)));
      expect(App.lines(LiveTree.attaching).first, 'cursor ?');
    });
  });

  group('the capture is what it claims to be', () {
    test('exactly one snapshot went in, and it was empty', () {
      // The load-bearing precondition. Everything below is a claim about
      // deltas, and it is only a claim about deltas if no second picture
      // arrived to do the work.
      final snapshots = frames.whereType<SnapshotFrame>().toList();
      expect(snapshots, hasLength(1));
      expect(snapshots.single.snapshot.nodes, isEmpty);
      expect(frames.first, same(snapshots.single));
      expect(steps.first.nodes, isEmpty);
      expect(steps.first.isAttached, isTrue);
      expect(App.lines(steps.first), contains(noNodesText));
    });
  });

  group('the tree grows from deltas', () {
    test('BOTH subagents render, at the depth their parents give them', () {
      // F-02's repair made visible. A UI showing only the root has exactly the
      // silent failure F-02 described: the tree is wrong and nothing says so.
      final one = nodeEndingIn(settled, child);
      final two = nodeEndingIn(settled, grandchild);
      expect(one, isNotNull, reason: 'the first subagent never arrived');
      expect(two, isNotNull, reason: 'the second subagent never arrived');
      expect(two!.node.parentId, one!.node.id);
      expect(one.depth, two.depth - 1);
      expect(settled.nodes.map((n) => n.node.id), [one.node.id, two.node.id]);
    });

    test('a NODE LINE CHANGES from a delta, not from a re-snapshot', () {
      // The demonstration this leaf exists for.
      //
      // Both subagents are announced by `runner.observed` with a **null**
      // `current_task` and given one seconds later by `runner.updated`. A
      // client that handled creation and ignored updates would render two
      // permanently blank tasks and look entirely healthy doing it — which is
      // why the assertion is on the line BEFORE and the line AFTER, with the
      // count of snapshots in between pinned at zero.
      final born = steps.indexWhere((t) => nodeEndingIn(t, child) != null);
      expect(born, greaterThan(0));
      final atBirth = nodeEndingIn(steps[born], child)!;
      expect(atBirth.node.currentTask, isNull);
      expect(atBirth.render(steps[born].asOf!), contains(' · ? · since '));

      final named = steps.indexWhere(
        (t) => nodeEndingIn(t, child)?.node.currentTask != null,
      );
      expect(named, greaterThan(born));
      expect(
        frames.sublist(born + 1, named + 1).whereType<SnapshotFrame>(),
        isEmpty,
        reason: 'the line changed because a delta changed it',
      );
      expect(
        nodeEndingIn(steps[named], child)!.node.currentTask,
        'Nested subagent chain test',
      );
      expect(
        nodeEndingIn(settled, grandchild)!.node.currentTask,
        'Reply with single word',
      );
    });

    test('and so does a status, working → checkpointed', () {
      final working = steps.firstWhere((t) => nodeEndingIn(t, child) != null);
      expect(nodeEndingIn(working, child)!.node.status, NodeStatus.working);
      expect(
        nodeEndingIn(settled, child)!.node.status,
        NodeStatus.checkpointed,
      );
    });

    test('every ancestor counts a new node into its unknown spend', () {
      // A floor presented as if it were nearly a total is INV7's failure. The
      // first subagent gains a child, so its subtree is two nodes and both are
      // unmeasured — `spend ?`, never `$0.0000`.
      final one = nodeEndingIn(settled, child)!;
      expect(one.spend.nodes, 2);
      expect(one.spend.unknownNodes, 2);
      expect(one.spend.isUnknown, isTrue);
      expect(one.spend.label, 'spend ?');
    });
  });

  group('the stream state is read off the frames, never guessed', () {
    test('replay ends on `ready` and on nothing else', () {
      // `marksEndOfReplay` is true on ReadyFrame alone. A delta carrying no
      // events is a position update, not the end of replay.
      final ready = frames.indexWhere((f) => f is ReadyFrame);
      expect(ready, greaterThan(0));
      expect(steps[ready - 1].replayComplete, isFalse);
      expect(steps[ready].replayComplete, isTrue);
      for (final frame in frames) {
        expect(
          frame.marksEndOfReplay,
          frame is ReadyFrame,
          reason: '${frame.type} must not claim to end replay',
        );
      }
    });

    test('an empty delta advances the cursor and nothing else', () {
      final tree = LiveTree.attaching.apply(
        DeltaFrame(cursor: settled.cursor!, events: const []),
      );
      expect(tree.replayComplete, isFalse);
      expect(tree.cursor, settled.cursor);
      expect(tree.nodes, isEmpty);
    });

    test('liveness comes from the heartbeat, so quiet is not dead', () {
      final beats = frames.whereType<HeartbeatFrame>().toList();
      expect(beats, isNotEmpty);
      expect(settled.lastHeartbeat, beats.last.sentAt);
      expect(App.liveness(settled), startsWith('LIVE · heartbeat '));
      expect(App.liveness(settled), contains(formatClock(beats.last.sentAt)));
    });

    test('ages are measured against the daemon, never the browser clock', () {
      // `asOf` only ever moves forward, and only to an instant the daemon
      // put on the wire. Nothing here reads `DateTime.now()`.
      DateTime? previous;
      for (final step in steps) {
        final at = step.asOf;
        if (at == null) continue;
        if (previous != null) expect(at.isBefore(previous), isFalse);
        previous = at;
      }
      expect(settled.asOf, isNotNull);
      final stamps = {
        for (final frame in frames)
          if (frame is HeartbeatFrame) frame.sentAt,
        for (final frame in frames)
          if (frame is SnapshotFrame) frame.snapshot.takenAt,
        for (final frame in frames)
          if (frame is DeltaFrame)
            for (final event in frame.events) event.ts,
      };
      expect(stamps, contains(settled.asOf));
    });
  });

  group('what the feed does not describe is shown, never dropped', () {
    test('the root is a stranger, because nothing announced it', () {
      // Not a defensive flourish: measured. `SproutStore.putNode` writes no
      // event, so a root created after this client attached reaches the feed
      // only as `runner.spawned` — a pid and a command line, not a node row.
      // Recorded in `docs/02-open-findings.md`.
      expect(settled.strangers, hasLength(1));
      final root = settled.strangers.entries.single;
      expect(root.key, isNot(contains('/')), reason: 'a root has no parent');
      expect(root.value, greaterThan(50));
      expect(
        settled.nodes.map((n) => n.node.id),
        everyElement(startsWith('${root.key}/')),
      );
    });

    test('and it gets a line on the board saying so', () {
      final lines = App.lines(settled);
      final stranger = lines.firstWhere((l) => l.contains(strangerText));
      expect(stranger, startsWith('? · '));
      expect(stranger, endsWith(' events'));
    });
  });

  group('the three fields that survive any compression', () {
    final lines = App.lines(settled);

    test('next check-in prints NONE SCHEDULED, never blank', () {
      // Absence must never look like presence. Nothing in this capture ever
      // sets a check-in, so every node line has to carry the loud version.
      for (final node in settled.nodes) {
        expect(node.node.nextCheckin, isNull);
      }
      expect(
        lines.where((l) => l.contains('next $noCheckinText')),
        hasLength(settled.nodes.length),
      );
    });

    test('a held resource would be shown with its holder', () {
      // Nothing is held here, and the permissive half needs its own bit or
      // being satisfied looks exactly like never having run.
      expect(settled.resources, isEmpty);
      expect(lines, contains(nothingHeldText));
    });

    test('journal_unreadable is surfaced when set', () {
      expect(settled.isJournalUnreadable, isFalse);
      expect(lines.any((l) => l.startsWith(journalUnreadableKey)), isFalse);
      final broken = settled.apply(
        SnapshotFrame(
          snapshot: SproutSnapshot(
            cursor: settled.cursor!,
            takenAt: settled.asOf!,
            nodes: const [],
            resources: const [],
            journalUnreadable: 'database is locked',
          ),
        ),
      );
      expect(
        App.lines(broken),
        contains('$journalUnreadableKey: database is locked'),
      );
    });

    test('an age is never estimated', () {
      // `since ?` when there is no frame, never a guess. A node with no
      // `since` must not borrow one from anywhere.
      final line = SnapshotNode(
        node: SproutNode(id: 'n', project: '/tmp', status: NodeStatus.working),
        depth: 0,
        ownCostUsd: null,
        spend: const SubtreeSpend(knownMicroUsd: 0, nodes: 1, unknownNodes: 1),
      ).render(settled.asOf!);
      expect(line, contains('since ?'));
      expect(line, isNot(contains('0m')));
    });
  });

  group('the board is a board', () {
    test('one line per node, and the whole board fits a phone', () {
      // `docs/01-plan.md` §8, applied at tree scope: one line per node, no
      // prose. The count is exact — a header, a liveness line, the nodes, the
      // stranger and the held-resources line.
      final lines = App.lines(settled);
      expect(lines, hasLength(2 + settled.nodes.length + 1 + 1));
      for (final line in lines) {
        expect(line.split('\n'), hasLength(1), reason: 'no multi-line rows');
      }
    });

    test('every node line is the protocol\'s own rendering', () {
      // One derivation, not two that agree: `sprout snapshot` on a terminal
      // and this page print the same words about the same node.
      final at = settled.asOf!;
      for (final node in settled.nodes) {
        expect(App.lines(settled), contains(node.render(at)));
      }
    });

    test('describe covers every frame type in the capture', () {
      for (final frame in frames) {
        expect(App.describe(frame), isNotEmpty);
      }
      expect(App.describe(null), 'not attached');
    });
  });

  group('a settled tree renders from the snapshot alone', () {
    // The other half of the model. Attaching to a daemon that already has a
    // tree must show it at once — *"so attaching is never a blank screen"*.
    final wire = WireFixture.read('settled_wire');
    final tree = replay(wire.frames()).last;

    test('three nodes, depth 0, 1 and 2, in depth-first order', () {
      expect(tree.nodes.map((n) => n.depth), [0, 1, 2]);
      expect(tree.strangers, isEmpty);
      expect(App.lines(tree), hasLength(2 + 3 + 1));
    });

    test('the root reports its own dollars and a partial subtree', () {
      // A sum is not a distribution (INV7). Two subagents reported nothing, so
      // the root's subtree is a floor and says how many are missing.
      final root = tree.nodes.first;
      expect(root.ownCostUsd, closeTo(0.2415507, 1e-9));
      expect(root.spend.isComplete, isFalse);
      expect(root.spend.label, '>=\$0.2416 (2 unknown)');
      expect(tree.nodes[1].spend.label, 'spend ?');
    });
  });

  group('a refused cursor', () {
    // What a daemon restart looks like from the client: the cursor is not
    // corrupt, it is meaningless here, and the remedy is a fresh attach rather
    // than a retry of the same cursor.
    final tree = replay(WireFixture.read('refused_wire').frames()).last;

    test('is one bye and no picture', () {
      expect(tree.frames, 1);
      expect(tree.ended, isNotNull);
      expect(tree.ended!.reason, ByeReason.refused);
      expect(tree.nodes, isEmpty);
    });

    test('and the board prints the reason it carried', () {
      // *"A stream that simply stops did not end, it broke."*
      final live = App.liveness(tree);
      expect(live, startsWith('STREAM ENDED · refused · '));
      expect(live, contains('take a fresh snapshot'));
      expect(live, contains('deadbeefdeadbeef'));
    });
  });
}
