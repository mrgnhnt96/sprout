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

import 'dart:io';

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
      // Not a defensive flourish: measured. `live_wire.bin` was captured from
      // a daemon predating F-10, when `SproutStore.putNode` wrote a row and no
      // event, so a root created after this client attached reached the feed
      // only as `runner.spawned` — a pid and a command line, not a node row.
      //
      // **The capture is kept exactly as it was, and so is this test.** F-10
      // made the root announce itself (see the group below, which builds one
      // the way a daemon does today), but an id sprout emits events about with
      // no node row behind it is still real, and a client that hid it would
      // report a smaller tree than exists. This is the proof that path still
      // works, paired with the positive rather than replaced by it.
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
      // prose. The count is exact — a header, a liveness line, the watchdog
      // line, the nodes, the stranger and the held-resources line.
      //
      // The watchdog line is unconditional and there is no sweep in this
      // capture, so it reads `no sweep yet`. That is the point of counting it:
      // a board that printed nothing when the daemon had not swept would be
      // indistinguishable from one whose watchdog says the tree is fine.
      final lines = App.lines(settled);
      expect(lines, hasLength(3 + settled.nodes.length + 1 + 1));
      expect(lines[2], 'WATCHDOG · $noSweepYetText');
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

  group('a root announced by the feed is a node, not a stranger', () {
    // F-10, from the consumer's side. `live_wire.bin` cannot show this — it
    // was recorded before the fix — so the frames here are built the way the
    // daemon builds them now: `runner.observed` carrying the whole row when
    // the root is created, then `runner.updated` when `_markRoot` moves it.
    // The payload shapes are the ones `kinds_test.dart` pins against the
    // producer's own source.
    const instanceId = '0123456789abcdef';
    final at = DateTime.utc(2026, 9, 1, 14, 15);

    SproutEvent event(
      int seq,
      String nodeId,
      String kind,
      Map<String, Object?> payload,
    ) => SproutEvent(
      seq: seq,
      nodeId: nodeId,
      ts: at,
      kind: kind,
      payload: payload,
    );

    DeltaFrame delta(List<SproutEvent> events) => DeltaFrame(
      cursor: Cursor(instanceId: instanceId, position: events.last.seq),
      events: events,
    );

    final announced = LiveTree.attaching.apply(
      delta([
        event(1, 'root-1', nodeObservedKind, {
          'parent_id': null,
          'project': '/w/sprout',
          'status': 'spawning',
          'current_task': 'map the repo and delegate two probes',
        }),
        event(2, 'root-1', 'runner.spawned', {'pid': 4242}),
        event(3, 'root-1', nodeUpdatedKind, {
          'status': {'from': 'spawning', 'to': 'working'},
        }),
      ]),
    );

    test('it arrives with its project, task and status, from deltas alone', () {
      // No snapshot went in: `LiveTree.attaching` holds nothing, and every
      // field below came off the feed. That is the whole claim of F-10 — the
      // bug was invisible to anything that re-snapshotted.
      expect(announced.strangers, isEmpty);
      final root = announced.nodes.single;
      expect(root.node.id, 'root-1');
      expect(root.depth, 0);
      expect(root.node.project, '/w/sprout');
      expect(root.node.currentTask, 'map the repo and delegate two probes');
      // The update was applied, not just the creation: a board that handled
      // creation alone would show `spawning` here for the whole run.
      expect(root.node.status, NodeStatus.working);
    });

    test('and its line is a real one, not the `?` a stranger gets', () {
      final lines = App.lines(announced);
      expect(lines.where((l) => l.contains(strangerText)), isEmpty);
      expect(lines, contains(announced.nodes.single.render(at)));
    });

    test('a subagent announced after it nests under the root', () {
      // The order the daemon really emits: the root first, then children whose
      // `parent_id` names it. Before F-10 the root was absent, so a subagent's
      // parent was unknown and it rendered at depth 0.
      final withChild = announced.apply(
        delta([
          event(4, 'root-1/$child', nodeObservedKind, {
            'tool_use_id': child,
            'parent_id': 'root-1',
            'project': '/w/sprout',
            'status': 'working',
            'current_task': 'Nested subagent chain test',
          }),
        ]),
      );
      expect(withChild.nodes.map((n) => n.depth), [0, 1]);
      expect(withChild.strangers, isEmpty);
    });

    test('an id nothing described is still a stranger', () {
      // The paired negative (INV8). The fix must not make the stranger path
      // unreachable: a `frame.*` event about an id with no row behind it is
      // exactly the runaway sprout exists to surface.
      final withGhost = announced.apply(
        delta([event(4, 'ghost', 'frame.assistant', const {})]),
      );
      expect(withGhost.strangers, {'ghost': 1});
      expect(withGhost.nodes.map((n) => n.node.id), ['root-1']);
      expect(
        App.lines(withGhost).where((l) => l.contains(strangerText)),
        hasLength(1),
      );
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
      expect(App.lines(tree), hasLength(3 + 3 + 1));
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

  group('the watchdog on the board', () {
    // P6-03. A `watchdog` frame is a LEVEL, not an event: it carries the whole
    // current verdict every sweep, which is the only way a board can show a
    // node **stop** being stalled without anything writing a status row.
    // `NodeStatus` has no `stalled` member for exactly that reason.
    final base = replay(WireFixture.read('settled_wire').frames()).last;
    final rootId = base.nodes.first.node.id;

    WatchdogFrame sweep({
      List<StalledNode> stalled = const [],
      List<UnmeasuredNode> blind = const [],
      String? failure,
      String why = 'no ring: the 3 node(s) that could be measured were live',
      int at = 46,
    }) => WatchdogFrame(
      cursor: base.cursor!,
      sweptAt: DateTime.utc(2026, 9, 2, 21, at),
      why: why,
      nodesSwept: 3,
      stalled: stalled,
      blind: blind,
      failure: failure,
    );

    StalledNode stall({int rings = 1, bool silenced = false}) => StalledNode(
      nodeId: rootId,
      liveness: 'stalled',
      because:
          'pid 33134 is alive and started at 2026-09-02 21:45:48.000Z; '
          'the transcript last grew 3s ago (threshold 2s ago)',
      consecutiveRings: rings,
      silenced: silenced,
    );

    test('before any sweep the board says so, and never says ok', () {
      expect(App.watchdog(base), 'WATCHDOG · $noSweepYetText');
      expect(base.lastSweep, isNull);
      expect(base.stalled, isEmpty);
      // INV8: "the watchdog has not run" and "the tree is fine" must not read
      // the same, so there is no green line for either.
      expect(App.lines(base).join('\n').toLowerCase(), isNot(contains('ok')));
    });

    test('a stall arrives, and the node is visibly stalled', () {
      final stalled = base.apply(sweep(stalled: [stall()]));
      expect(stalled.stallOf(rootId), isNotNull);
      expect(App.lines(stalled), contains(App.stallLine(stall())));
      expect(
        App.lines(stalled).firstWhere((l) => l.startsWith('STALLED')),
        allOf(contains(rootId), contains('33134'), contains('ring 1')),
      );
      // Alongside the node, not inside it: the stored status is untouched, and
      // that is what makes recovery possible without a write.
      expect(stalled.nodes.first.node.status, base.nodes.first.node.status);
      expect(stalled.nodes.first.node.status.wire, isNot('stalled'));
    });

    test('and then it stops being stalled, with nothing written', () {
      final stalled = base.apply(sweep(stalled: [stall()]));
      final recovered = stalled.apply(sweep(at: 47));
      expect(recovered.stallOf(rootId), isNull);
      expect(recovered.stalled, isEmpty);
      expect(
        App.lines(recovered).where((l) => l.startsWith('STALLED')),
        isEmpty,
      );
      // The node line itself is byte-identical to before the stall: nothing
      // about the node changed, only what the watchdog concluded about it.
      expect(
        App.lines(recovered).where((l) => l.contains(rootId)),
        App.lines(base).where((l) => l.contains(rootId)),
      );
    });

    test(
      'a silenced node is still shown as stalled, and says it is capped',
      () {
        final capped = base.apply(
          sweep(stalled: [stall(rings: 3, silenced: true)]),
        );
        expect(capped.stallOf(rootId), isNotNull);
        final line = App.lines(capped)
            .firstWhere((l) => l.startsWith('STALLED'));
        expect(line, contains('ring cap'));
        expect(line, contains('still stalled'));
      },
    );

    test('a sweep that could not look is NOT a recovery', () {
      // The failure this whole phase exists to prevent, in one assertion: a
      // watchdog that could not see must never read as a watchdog that saw
      // nothing wrong. The stall stays on the board and the line says why.
      final stalled = base.apply(sweep(stalled: [stall()]));
      final blindSweep = stalled.apply(
        sweep(
          at: 47,
          failure: 'ps: command not found',
          why: 'no sweep was taken: the measurement threw',
          stalled: const [],
        ),
      );
      expect(blindSweep.stallOf(rootId), isNotNull, reason: 'still stalled');
      expect(App.watchdog(blindSweep), startsWith('WATCHDOG COULD NOT LOOK'));
      expect(App.watchdog(blindSweep), contains('ps: command not found'));
    });

    test('a blind sweep names the node and calls it neither', () {
      final blindSweep = base.apply(
        sweep(
          blind: [
            UnmeasuredNode(nodeId: rootId, because: 'could not look at pid 1'),
          ],
          why:
              'no ring: not one of the 3 node(s) could be measured, so this '
              'sweep establishes nothing about any of them',
        ),
      );
      expect(blindSweep.stalled, isEmpty);
      expect(blindSweep.unmeasuredOf(rootId), isNotNull);
      final line = App.lines(blindSweep)
          .firstWhere((l) => l.startsWith('UNMEASURED'));
      expect(line, contains('NOT'));
      expect(App.watchdog(blindSweep), contains('establishes nothing'));
    });

    test('the board prints the sweep own sentence, not a summary of it', () {
      // One derivation: the same string the daemon appended to its NDJSON
      // journal. A board that paraphrased could drift into "all good".
      final why =
          'no ring: 1 node(s) advanced, so their ring counts reset (n1)';
      expect(App.watchdog(base.apply(sweep(why: why))), endsWith(why));
    });

    test('a stalled node this client has never seen is still shown', () {
      final ghost = base.apply(
        sweep(
          stalled: [
            const StalledNode(
              nodeId: 'never-described',
              liveness: 'abandoned',
              because: 'no live process and no ending recorded',
              consecutiveRings: 2,
              silenced: false,
            ),
          ],
        ),
      );
      expect(
        App.lines(ghost).where((l) => l.contains('never-described')),
        hasLength(1),
      );
    });

    test('a sweep moves nothing about the tree or the feed', () {
      final after = base.apply(sweep(stalled: [stall()]));
      expect(after.nodes, base.nodes);
      expect(after.cursor!.encode(), base.cursor!.encode());
      expect(after.asOf, base.asOf);
      expect(after.events, base.events);
      expect(after.replayComplete, base.replayComplete);
      expect(after.lastHeartbeat, base.lastHeartbeat);
    });

    test('nothing in sprout_ui can act on a node', () {
      // The third copy of the guard P6-01 and P6-02 each carry for their own
      // directory. This package is the one a person clicks, so "clean up the
      // stalled node" would land here as a button — and a button needs a
      // handler and a request, so both are what this looks for. §5: the real
      // incident behind that rule held four uncommitted files and a green test
      // suite.
      // Comments are stripped first. The words below are exactly the words
      // this package's prose uses to explain why none of them is here — the
      // note on `TreeSocket` says the daemon's ping "reclaims a peer" — so a
      // guard reading raw text would fail on its own justification and be
      // weakened to get green.
      String code(File file) => file
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      final offenders = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) => RegExp(
              r'\bbutton\(|onClick|addEventListener|HttpRequest|\bfetch\('
              r'|kill|terminate|reclaim',
            ).hasMatch(code(f)),
          )
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'the board surfaces and pages. Acting on a stalled node belongs '
            'to a human, and to nothing on this page.',
      );
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
