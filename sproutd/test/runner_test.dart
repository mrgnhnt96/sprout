/// Tests for `lib/runner.dart`.
///
/// Every test here replays a captured fixture through a fake process. None of
/// them invokes the `claude` binary; the one that does is skipped by default
/// and says so. See the last group.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/policy.dart';
import 'package:sproutd/runner.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/stream.dart';
import 'package:test/test.dart';

const _fixtureRoot = '../docs/research/fixtures/phase0/streams';

List<int> _fixture(String name) =>
    File('$_fixtureRoot/$name').readAsBytesSync();

/// Non-empty lines in a fixture, counted independently of the parser.
int _lineCount(List<int> bytes) => const LineSplitter()
    .convert(utf8.decode(bytes))
    .where((l) => l.trim().isNotEmpty)
    .length;

/// A process the test drives by hand: bytes in, exit code out.
final class FakeProcess implements SessionProcess {
  FakeProcess({this.pid = 4242});

  @override
  final int pid;

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> killed = [];

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  /// Whether the test has ended the process yet.
  bool get hasExited => _exit.isCompleted;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    return true;
  }

  /// Writes [bytes] to stdout in [chunkSize]-byte pieces, so line and
  /// character boundaries land mid-chunk the way a real pipe delivers them.
  void emit(List<int> bytes, {int chunkSize = 37}) {
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = i + chunkSize < bytes.length ? i + chunkSize : bytes.length;
      _stdout.add(bytes.sublist(i, end));
    }
  }

  /// Writes to stderr.
  void emitStderr(String text) => _stderr.add(utf8.encode(text));

  /// Closes both pipes and reports [code].
  Future<void> exit(int code) async {
    await _stdout.close();
    await _stderr.close();
    _exit.complete(code);
  }
}

/// A launcher that hands out prepared [FakeProcess]es and records launches.
final class FakeLauncher implements SessionLauncher {
  final List<SessionLaunch> launches = [];
  final List<FakeProcess> queue = [];
  Object? failWith;

  @override
  Future<SessionProcess> launch(SessionLaunch launch) async {
    launches.add(launch);
    if (failWith case final error?) throw error;
    return queue.removeAt(0);
  }
}

/// A launcher whose process replays [bytes] in full and exits with [code].
FakeLauncher _replaying(List<int> bytes, {int code = 0}) {
  final process = FakeProcess();
  final launcher = FakeLauncher()..queue.add(process);
  // Deliver after the runner has subscribed; a broadcast-free controller
  // buffers anyway, but this keeps the order honest.
  scheduleMicrotask(() async {
    process.emit(bytes);
    await process.exit(code);
  });
  return launcher;
}

const _policy = ContainmentPolicy(subtreeBudgetUsd: 1, runBudgetUsd: 5);

void main() {
  late Directory tmp;
  late SproutStore store;
  late ContainmentGate gate;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sprout_runner_test');
    store = SproutStore.memory();
    gate = ContainmentGate(_policy);
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  SessionRunner runner(SessionLauncher launcher) => SessionRunner(
    store: store,
    gate: gate,
    logDirectory: p.join(tmp.path, 'sessions'),
    launcher: launcher,
  );

  SessionRequest request({
    String nodeId = 'root',
    String? parentId,
    double estimate = 0,
  }) => SessionRequest(
    task: 'say hi',
    project: tmp.path,
    nodeId: nodeId,
    parentId: parentId,
    estimatedCostUsd: estimate,
  );

  List<SproutEvent> events([String? nodeId]) =>
      store.eventsSince(0, nodeId: nodeId);

  List<SproutEvent> frameEvents() =>
      events().where((e) => e.kind.startsWith(frameKindPrefix)).toList();

  group('the invocation', () {
    test('is the documented flag set, and --max-turns is not in it', () {
      final args = claudeArguments(task: 'do the thing', maxBudgetUsd: 0.25);
      expect(args.take(2), ['-p', 'do the thing']);
      for (final flag in [
        '--output-format',
        '--verbose',
        '--include-partial-messages',
        '--include-hook-events',
        '--forward-subagent-text',
        '--permission-mode',
        '--max-budget-usd',
      ]) {
        expect(args, contains(flag));
      }
      expect(args[args.indexOf('--output-format') + 1], 'stream-json');
      expect(args[args.indexOf('--permission-mode') + 1], 'acceptEdits');
      expect(args[args.indexOf('--max-budget-usd') + 1], '0.25');
      // Not a CLI flag in v2.1.252 (`17` §9); the positive half above keeps
      // this from passing against an empty list.
      expect(args, isNot(contains('--max-turns')));
    });

    test(
      'takes the budget from the policy: the tighter of the two ceilings',
      () {
        const policy = ContainmentPolicy(subtreeBudgetUsd: 2, runBudgetUsd: 5);
        expect(spawnBudgetUsd(policy, SpendLedger.empty()), 2.0);
        final spent = SpendLedger.of(const [
          NodeSpend(id: 'earlier', costUsd: 4.5),
        ]);
        expect(spawnBudgetUsd(policy, spent), closeTo(0.5, 1e-9));
      },
    );

    test('a child is handed what its ancestors have left, not a fresh '
        'ceiling', () {
      const policy = ContainmentPolicy(subtreeBudgetUsd: 2, runBudgetUsd: 100);
      final tree = SpendLedger.of(const [
        NodeSpend(id: 'root', costUsd: 1.5),
        NodeSpend(id: 'mid', parentId: 'root', costUsd: 0.25),
      ]);
      // A root sits under no ancestor, so it still sees only its own subtree
      // ceiling and the run's remainder.
      expect(spawnBudgetUsd(policy, tree), 2.0);
      // Under `mid`, two ancestors bind: mid's own subtree holds \$0.25 and
      // root's holds \$1.75. Root is the nearer to its ceiling and wins.
      // Without this, a child under a nearly-spent parent would be launched
      // with --max-budget-usd \$2.00 and could spend the ceiling twice.
      expect(
        spawnBudgetUsd(policy, tree, parentId: 'mid'),
        closeTo(0.25, 1e-9),
      );
    });
  });

  group('the gate is consulted before the spawn', () {
    test('a refusal starts no process and is recorded, on the gate and in the store', () async {
      final launcher = FakeLauncher();
      // Estimated past the subtree ceiling: refused for budget.
      final outcome = await runner(launcher).run(request(estimate: 3));

      expect(outcome, isA<RefusedSession>());
      final refused = outcome as RefusedSession;
      expect(refused.refusal.reason, RefusalReason.budget);
      expect(launcher.launches, isEmpty);
      expect(gate.refusals[RefusalReason.budget], 1);
      expect(gate.permitted, 0);

      // The node announced itself first: the row is written before the gate
      // is asked, so even a refusal is reported against a node an attached
      // consumer has already been told the shape of.
      expect(events('root').map((e) => e.kind), [
        nodeObservedKind,
        'runner.refused',
        // And then off `spawning` again, in the same breath as the refusal.
        // Until P4-09 this list ended at the refusal and the row stayed
        // `spawning` for ever, which made a spawn nothing ever started count
        // against the concurrency bound. See the P4-09 group below.
        nodeUpdatedKind,
      ]);
      final recorded = events('root')
          .firstWhere((e) => e.kind == runnerRefusedKind);
      expect(recorded.payload['reason'], 'budget');
      expect(recorded.payload['refusals'], {
        'depthCap': 0,
        'budget': 1,
        'concurrency': 0,
      });
      expect(store.node('root')!.status, NodeStatus.unlaunched);
    });

    test('a permit starts exactly one process at depth 0', () async {
      final launcher = _replaying(_fixture('A.ndjson'));
      final outcome = await runner(launcher).run(request(estimate: 0.5));

      expect(outcome, isA<EndedSession>());
      expect(launcher.launches, hasLength(1));
      expect(gate.permitted, 1);
      expect(gate.refusals.total, 0);

      final launch = launcher.launches.single;
      expect(launch.executable, 'claude');
      expect(launch.workingDirectory, tmp.path);
      expect(
        launch.arguments,
        claudeArguments(task: 'say hi', maxBudgetUsd: 1),
      );

      final spawned = events('root')
          .firstWhere((e) => e.kind == 'runner.spawned');
      expect(spawned.payload['pid'], 4242);
      expect((spawned.payload['permit'] as Map)['depth'], 0);
    });

    test(
      'a launcher that cannot start the process is recorded and rethrown',
      () async {
        final launcher = FakeLauncher()
          ..failWith = const ProcessException('claude', ['-p'], 'not found');
        await expectLater(
          runner(launcher).launch(request()),
          throwsA(isA<ProcessException>()),
        );
        expect(events('root').map((e) => e.kind), [
          nodeObservedKind,
          'runner.launch_failed',
          nodeUpdatedKind,
        ]);
        // Same repair as the refusal above: nothing was started, so the row
        // must not go on holding a slot.
        expect(store.node('root')!.status, NodeStatus.unlaunched);
      },
    );
  });

  group('the gate decides over the tree the store actually holds', () {
    // P4-02. Every one of these builds a real tree in a real `SproutStore`,
    // reads it back with `readLedger`, and asks for a child under a node in
    // it. Each refusal is paired with the request as it was made BEFORE this
    // leaf — no `parentId`, which is what every caller passed because the
    // field did not exist — and each of those pairs is a permit. That is the
    // negative control and it is the whole point: the gate ran on every
    // launch, and could not have said no to any of them (INV8).

    void put(
      String id, {
      String? parentId,
      NodeStatus status = NodeStatus.checkpointed,
    }) => store.putNode(
      SproutNode(id: id, parentId: parentId, project: tmp.path, status: status),
    );

    /// Appends the frame a dollar figure actually arrives on.
    void spend(String nodeId, double costUsd) => store.append(
      nodeId: nodeId,
      kind: resultEventKind,
      payload: {totalCostUsdField: costUsd},
    );

    SpendLedger storeLedger() => readLedger(StoreSnapshotSource(store)).ledger;

    /// Launches [request] and insists it was refused, returning why.
    Future<SpawnRefusal> refusalOf(
      SessionRequest request,
      SpendLedger ledger,
    ) async {
      final launcher = FakeLauncher();
      final start = await runner(launcher).launch(request, ledger: ledger);
      expect(
        start,
        isA<RefusedSession>(),
        reason: 'the gate permitted a spawn this tree should have refused',
      );
      // Nothing was started, which is the half a tally cannot show.
      expect(launcher.launches, isEmpty);
      return (start as RefusedSession).refusal;
    }

    /// Launches [request] and insists it was permitted, draining the process.
    Future<LiveSession> permitOf(
      SessionRequest request,
      SpendLedger ledger,
    ) async {
      final start = await runner(_replaying(const <int>[]))
          .launch(request, ledger: ledger);
      expect(start, isA<LiveSession>());
      final live = start as LiveSession;
      await live.done;
      return live;
    }

    group('the depth cap', () {
      // root → n1 → n2 → n3, so a child of n3 would be the fifth level.
      void chainOfFour() {
        put('n0');
        put('n1', parentId: 'n0');
        put('n2', parentId: 'n1');
        put('n3', parentId: 'n2');
      }

      test('refuses a child under a node at the cap, and counts it', () async {
        chainOfFour();
        final ledger = storeLedger();
        expect(ledger.depthOf('n3'), 3, reason: 'the store really is 4 deep');

        final refusal = await refusalOf(
          request(nodeId: 'child', parentId: 'n3'),
          ledger,
        );
        expect(refusal.reason, RefusalReason.depthCap);
        expect(refusal.explanation, contains('depth 4'));
        expect(gate.refusals[RefusalReason.depthCap], 1);

        // Not `.last`: since P4-09 the refusal is followed by the
        // `runner.updated` that moves the row off `spawning`.
        final recorded = events('child')
            .firstWhere((e) => e.kind == runnerRefusedKind);
        expect(recorded.payload['reason'], 'depthCap');
        expect(recorded.payload['refusals'], {
          'depthCap': 1,
          'budget': 0,
          'concurrency': 0,
        });
      });

      test(
        'the same tree permits the same spawn with no parent named',
        () async {
          chainOfFour();
          await permitOf(request(nodeId: 'child'), storeLedger());
          expect(gate.permitted, 1);
          expect(gate.refusals.total, 0);
        },
      );

      test(
        'an empty ledger cannot decide it at all, and writes nothing',
        () async {
          chainOfFour();
          await expectLater(
            runner(FakeLauncher()).launch(
              request(nodeId: 'child', parentId: 'n3'),
              ledger: SpendLedger.empty(),
            ),
            throwsArgumentError,
          );
          // Not a refusal, so not counted — and the row is not written either.
          // A parent of unknown depth might be at depth 7, and a spawn nobody
          // could decide must leave nothing behind that looks decided.
          expect(gate.refusals.total, 0);
          expect(gate.permitted, 0);
          expect(store.node('child'), isNull);
        },
      );
    });

    group('the subtree budget', () {
      // `_policy` allows $1 per subtree and $5 for the run, so a parent that
      // has reported $1.20 has spent its subtree's ceiling and not the run's.
      void overspentParent() {
        put('parent');
        spend('parent', 1.2);
      }

      test(
        'refuses a child under a subtree that has spent its ceiling',
        () async {
          overspentParent();
          final ledger = storeLedger();
          expect(ledger.subtreeCostUsd('parent'), closeTo(1.2, 1e-9));

          final refusal = await refusalOf(
            request(nodeId: 'child', parentId: 'parent'),
            ledger,
          );
          expect(refusal.reason, RefusalReason.budget);
          expect(refusal.explanation, contains('subtree under parent'));
          expect(gate.refusals[RefusalReason.budget], 1);
          expect(
            events('child')
                .firstWhere((e) => e.kind == runnerRefusedKind)
                .payload['reason'],
            'budget',
          );
        },
      );

      test(
        'the same tree permits the same spawn with no parent named',
        () async {
          overspentParent();
          // $1.20 is under the $5 run ceiling, and a root has no ancestor whose
          // subtree ceiling could bind. So this is permitted, and was.
          await permitOf(request(nodeId: 'child'), storeLedger());
          expect(gate.permitted, 1);
          expect(gate.refusals.total, 0);
        },
      );

      test(
        'an empty ledger sees no spend and no parent to charge it to',
        () async {
          overspentParent();
          expect(SpendLedger.empty().subtreeCostUsd('parent'), 0);
          await permitOf(request(nodeId: 'child'), SpendLedger.empty());
          expect(gate.permitted, 1);
        },
      );
    });

    group('the concurrency bound', () {
      void parentAtItsChildLimit() {
        put('parent');
        for (var i = 0; i < defaultMaxLiveChildren; i++) {
          put('c$i', parentId: 'parent', status: NodeStatus.working);
        }
      }

      test('refuses a child under a node already at maxLiveChildren', () async {
        parentAtItsChildLimit();
        final ledger = storeLedger();
        expect(ledger.liveChildrenOf('parent'), defaultMaxLiveChildren);
        // Below the tree-wide bound, so only the per-parent one can bite.
        expect(ledger.liveNodes, lessThan(defaultMaxLiveNodes));

        final refusal = await refusalOf(
          request(nodeId: 'child', parentId: 'parent'),
          ledger,
        );
        expect(refusal.reason, RefusalReason.concurrency);
        expect(refusal.explanation, contains('$defaultMaxLiveChildren'));
        expect(gate.refusals[RefusalReason.concurrency], 1);
        expect(
          events('child')
              .firstWhere((e) => e.kind == runnerRefusedKind)
              .payload['reason'],
          'concurrency',
        );
      });

      test(
        'the same tree permits the same spawn with no parent named',
        () async {
          parentAtItsChildLimit();
          await permitOf(request(nodeId: 'child'), storeLedger());
          expect(gate.permitted, 1);
          expect(gate.refusals.total, 0);
        },
      );

      test(
        'an empty ledger has nobody live, so nothing to be at a limit',
        () async {
          parentAtItsChildLimit();
          expect(SpendLedger.empty().liveNodes, 0);
          await permitOf(request(nodeId: 'child'), SpendLedger.empty());
          expect(gate.permitted, 1);
        },
      );
    });

    // Recorded as F-23. The concurrency bound is real now, and its
    // denominator counts every node whose status is still `spawning` or
    // `working` — including ones sprout cannot end.
    test('a session that dies without a result stays live in the ledger, and '
        'holds a concurrency slot nothing releases', () async {
      // A stream that ends with no `result` frame: the process is gone and
      // `SessionRunner` deliberately does not conclude completion from exit
      // (INV12), so the row stays where it was.
      final launcher = _replaying(utf8.encode('{"type":"system"}\n'));
      final start = await runner(launcher).launch(request(nodeId: 'dead'));
      await (start as LiveSession).done;

      // `working` — moved there by the first frame and never moved off it.
      expect(store.node('dead')!.status, NodeStatus.working);
      // And so it is still live in the ledger the NEXT decision reads. There
      // is no verb that moves it: the only writers of a node's status are the
      // runner, the stream projection and the hook projection, and each moves
      // a node only on evidence from a stream that has ended.
      expect(readLedger(StoreSnapshotSource(store)).ledger.liveNodes, 1);
    });

    group('a permitted child', () {
      test('is recorded under its parent and comes back at depth 1', () async {
        put('parent');
        final live = await permitOf(
          request(nodeId: 'child', parentId: 'parent'),
          storeLedger(),
        );

        // The permit is a value carrying the depth it decided on, not merely
        // the absence of a refusal (INV8).
        final spawned = events('child')
            .firstWhere((e) => e.kind == runnerSpawnedKind);
        expect((spawned.payload['permit']! as Map)['depth'], 1);

        // Written onto the ROW, which is what makes the next decision right:
        // read the store back and the child is in the tree at depth 1, so a
        // grandchild under it is decided at depth 2 rather than at 0.
        expect(store.node('child')!.parentId, 'parent');
        expect(
          readLedger(StoreSnapshotSource(store)).ledger.depthOf(live.nodeId),
          1,
        );
      });

      test(
        'is launched with what its parent has left, not a fresh ceiling',
        () async {
          put('parent');
          spend('parent', 0.75);
          final live = await permitOf(
            request(nodeId: 'child', parentId: 'parent'),
            storeLedger(),
          );
          // `_policy` allows $1 per subtree and parent's holds $0.75, so the
          // child may spend $0.25. Handed the full $1 it could take the subtree
          // to $1.75 without --max-budget-usd ever objecting.
          expect(double.parse(live.launch.arguments.last), closeTo(0.25, 1e-9));
        },
      );
    });
  });
  group('a refused spawn does not hold a concurrency slot', () {
    // P4-09, and it is the opposite case to F-24 rather than a variant of it.
    // F-24 is a session that really started and whose ending sprout cannot
    // observe, so repairing it means deciding who may reconcile a row against
    // a liveness measurement. Here sprout wrote the row and then refused the
    // launch **itself, in the same function**: nothing was ever started and
    // the code that knows it is right there, so there is no measurement to
    // take and no uncertainty to resolve.
    //
    // The row still has to exist — it is written before the gate is asked so
    // that a refusal is counted against a node the feed has described (INV14),
    // and a tally held only in memory dies with the daemon. What it must not
    // do is keep counting as live for ever.

    void put(
      String id, {
      String? parentId,
      NodeStatus status = NodeStatus.checkpointed,
    }) => store.putNode(
      SproutNode(id: id, parentId: parentId, project: tmp.path, status: status),
    );

    SpendLedger storeLedger() => readLedger(StoreSnapshotSource(store)).ledger;

    /// n0 → n1 → n2 → n3, so any child of n3 sits at depth 4 and is refused.
    void chainOfFour() {
      put('n0');
      put('n1', parentId: 'n0');
      put('n2', parentId: 'n1');
      put('n3', parentId: 'n2');
    }

    /// Asks for [nodeId] under `n3` and insists the depth cap refused it.
    Future<void> refuseAtDepth(String nodeId) async {
      final launcher = FakeLauncher();
      final start = await runner(launcher).launch(
        request(nodeId: nodeId, parentId: 'n3'),
        ledger: storeLedger(),
      );
      expect(start, isA<RefusedSession>());
      expect((start as RefusedSession).refusal.reason, RefusalReason.depthCap);
      // The half a tally cannot show: no process was started.
      expect(launcher.launches, isEmpty);
    }

    test('the row it leaves behind is not counted by the ledger', () async {
      chainOfFour();
      await refuseAtDepth('refused');

      expect(isHoldingStatus(store.node('refused')!.status), isFalse);
      final ledger = storeLedger();
      expect(ledger.liveNodes, 0);
      expect(ledger.liveChildrenOf('n3'), 0);
    });

    test('and the status moves where the refusal is recorded, so the feed '
        'carries both', () async {
      chainOfFour();
      await refuseAtDepth('refused');
      // Observed, refused, and moved off `spawning` — in that order and in
      // one call, so a consumer built from deltas alone cannot be left
      // showing a node that is spawning for ever.
      expect(events('refused').map((e) => e.kind), [
        nodeObservedKind,
        runnerRefusedKind,
        nodeUpdatedKind,
      ]);
      final patch = events('refused').last.payload['status']! as Map;
      expect(patch['from'], 'spawning');
      expect(patch['to'], store.node('refused')!.status.wire);
    });

    test('it is not announced as holding the project directory it never '
        'entered', () async {
      chainOfFour();
      await refuseAtDepth('refused');
      expect(
        heldResourcesOf(store.nodes()).map((r) => r.holder),
        isNot(contains('refused')),
      );
    });

    test('a launch that never started holds nothing either', () async {
      final launcher = FakeLauncher()
        ..failWith = const ProcessException('claude', ['-p'], 'not found');
      await expectLater(
        runner(launcher).launch(request(nodeId: 'never')),
        throwsA(isA<ProcessException>()),
      );
      // Same shape, same file, same function: the row exists and nothing is
      // running, and sprout knows it without measuring anything.
      expect(isHoldingStatus(store.node('never')!.status), isFalse);
      expect(storeLedger().liveNodes, 0);
      expect(events('never').map((e) => e.kind), [
        nodeObservedKind,
        runnerLaunchFailedKind,
        nodeUpdatedKind,
      ]);
    });

    test('so five refusals under one parent do not close that parent to a '
        'legitimate spawn', () async {
      put('p');
      // Five children refused for BUDGET — nothing to do with concurrency,
      // and none of them started a process.
      for (var i = 0; i < 5; i++) {
        final launcher = FakeLauncher();
        final start = await runner(launcher).launch(
          request(nodeId: 'over$i', parentId: 'p', estimate: 3),
          ledger: storeLedger(),
        );
        expect((start as RefusedSession).refusal.reason, RefusalReason.budget);
        expect(launcher.launches, isEmpty);
      }
      expect(gate.refusals[RefusalReason.budget], 5);

      // Now an ordinary child of an ordinary parent. Before this fix the five
      // rows above were still `spawning`, so `liveChildrenOf('p')` read 5
      // against a limit of 4 and this was refused for `concurrency` — a
      // denial of service sprout inflicted on itself with nothing running at
      // all, and the depth cap doing exactly what it is for.
      final launcher = FakeLauncher()..queue.add(FakeProcess());
      final start = await runner(launcher).launch(
        request(nodeId: 'ordinary', parentId: 'p'),
        ledger: storeLedger(),
      );
      expect(
        start,
        isA<LiveSession>(),
        reason: start is RefusedSession
            ? 'refused for ${start.refusal.reason.wire}: '
                  '${start.refusal.explanation}'
            : 'the parent was closed by its own refusals',
      );
      expect(launcher.launches, hasLength(1));
    });

    test('and twelve of them anywhere do not close the whole tree', () async {
      for (var i = 0; i < 12; i++) {
        final start = await runner(
          FakeLauncher(),
        ).launch(request(nodeId: 'root$i', estimate: 3), ledger: storeLedger());
        expect((start as RefusedSession).refusal.reason, RefusalReason.budget);
      }
      final start = await runner(FakeLauncher()..queue.add(FakeProcess()))
          .launch(request(nodeId: 'ordinary'), ledger: storeLedger());
      expect(
        start,
        isA<LiveSession>(),
        reason: start is RefusedSession
            ? 'refused for ${start.refusal.reason.wire}: '
                  '${start.refusal.explanation}'
            : 'the tree was closed by refusals nothing ever launched',
      );
    });

    test('but a node that really launched still holds its slot, and the '
        'bound still bites', () async {
      put('p');
      // Four children that really started a process and really reported a
      // frame, so each is `working` rather than merely written down.
      for (var i = 0; i < 4; i++) {
        final launcher = _replaying(utf8.encode('{"type":"system"}\n'));
        final start = await runner(launcher).launch(
          request(nodeId: 'live$i', parentId: 'p'),
          ledger: storeLedger(),
        );
        expect(launcher.launches, hasLength(1));
        await (start as LiveSession).done;
        expect(store.node('live$i')!.status, NodeStatus.working);
      }
      expect(storeLedger().liveChildrenOf('p'), 4);

      // The fifth is refused, which is the bound doing its job. This is the
      // positive control: the repair above must not have made concurrency
      // stop biting, and that bound only became real in P4-02.
      final launcher = FakeLauncher();
      final start = await runner(launcher).launch(
        request(nodeId: 'fifth', parentId: 'p'),
        ledger: storeLedger(),
      );
      expect(start, isA<RefusedSession>());
      expect(
        (start as RefusedSession).refusal.reason,
        RefusalReason.concurrency,
      );
      expect(launcher.launches, isEmpty);
    });
  });

  group('replaying A.ndjson (one root, no subagents)', () {
    late EndedSession ended;
    late List<int> bytes;

    setUp(() async {
      bytes = _fixture('A.ndjson');
      ended = await runner(_replaying(bytes)).run(request()) as EndedSession;
    });

    test('every frame is on disk, byte for byte, and in the store', () {
      expect(File(ended.rawLogPath).readAsBytesSync(), bytes);
      expect(frameEvents(), hasLength(_lineCount(bytes)));
      expect(frameEvents(), hasLength(ended.frameCount));
      expect(ended.malformed, isEmpty);
      expect(ended.duplicatesDropped, 0);
      expect(ended.framesWithoutUuid, 0);
      // Kinds are the frame's type and subtype, so the feed is filterable.
      final kinds = frameEvents().map((e) => e.kind).toSet();
      expect(
        kinds,
        containsAll(['frame.system.init', 'frame.assistant', 'frame.result']),
      );
    });

    test(
      'the store has exactly the root node, checkpointed, with its task',
      () {
        final nodes = store.nodes();
        expect(nodes, hasLength(1));
        expect(nodes.single.id, 'root');
        expect(nodes.single.parentId, isNull);
        expect(nodes.single.status, NodeStatus.checkpointed);
        expect(nodes.single.currentTask, 'say hi');
        expect(events().every((e) => e.nodeId == 'root'), isTrue);
      },
    );

    test('the run is bracketed by runner events carrying the summary', () {
      final kinds = events().map((e) => e.kind).toList();
      // The node introduces itself before the launch it is about: `putNode`
      // announces the row in the same call it writes it, so a consumer never
      // reads an event against a node it has not been told about. That
      // ordering is the whole of F-10.
      expect(kinds.first, nodeObservedKind);
      expect(kinds[1], 'runner.spawned');
      // The first frame off the stream moves the root to `working`, and that
      // transition reaches the feed too — a board built from deltas alone
      // would otherwise show the root stuck on `spawning` for the whole run.
      expect(kinds[2], nodeUpdatedKind);
      // A opens with a hook frame, not init; the session is recorded the
      // moment init is folded in, just before init's own event.
      expect(kinds[3], 'frame.system.hook_started');
      final init = kinds.indexOf('frame.system.init');
      expect(kinds.indexOf('runner.session'), init - 1);
      expect(kinds.last, 'runner.exited');
      final session = events().firstWhere((e) => e.kind == 'runner.session');
      expect(
        session.payload['session_id'],
        '5ef39020-313b-487f-8480-6fa2138a7f73',
      );
      expect(session.payload['model'], isA<String>());
      final exited = events().last.payload;
      expect(exited['exit_code'], 0);
      expect(exited['has_result'], true);
      expect(exited['result_count'], 1);
      expect(exited['total_cost_usd'], 0.023741);
      expect(exited['session_id'], '5ef39020-313b-487f-8480-6fa2138a7f73');
    });

    test('cost and session id come from the control plane', () {
      expect(ended.exitCode, 0);
      expect(ended.sessionId, '5ef39020-313b-487f-8480-6fa2138a7f73');
      expect(ended.hasResult, isTrue);
      expect(ended.totalCostUsd, 0.023741);
      expect(ended.totalMessageTokens, greaterThan(0));
    });
  });

  group('replaying B.ndjson (root, child, grandchild, two results)', () {
    late EndedSession ended;
    late List<int> bytes;
    const child = 'root/toolu_013CdYLPDjwGfSwE5gL5Q7BK';
    const grandchild = 'root/toolu_01HLJXeJprJTzcM7oW2Zz1vp';

    setUp(() async {
      bytes = _fixture('B.ndjson');
      ended = await runner(_replaying(bytes)).run(request()) as EndedSession;
    });

    test('the root can be rebuilt from the feed alone, status and all', () {
      // F-10. The bug this replaces was invisible to any test that read the
      // store afterwards, because a snapshot always shows the root; it only
      // appeared to a consumer that attached BEFORE the run existed and had
      // nothing but deltas to build from. So this asserts the feed, never
      // `store.node`.
      final own = events('root');

      final observed = own.firstWhere((e) => e.kind == nodeObservedKind);
      expect(own.first, observed, reason: 'nothing may precede the node');
      expect(
        own.where((e) => e.kind == nodeObservedKind),
        hasLength(1),
        reason: 'a node is created once, however often it changes',
      );
      expect(observed.payload['parent_id'], isNull);
      expect(observed.payload['project'], tmp.path);
      expect(observed.payload['current_task'], 'say hi');
      expect(observed.payload['status'], NodeStatus.spawning.wire);

      // Then every transition, in order, so a consumer folding creation and
      // updates arrives at the status the store holds rather than at the one
      // the root launched with.
      final statuses = own
          .where((e) => e.kind == nodeUpdatedKind)
          .map((e) => e.payload['status'])
          .whereType<Map<Object?, Object?>>()
          .toList();
      expect(statuses, [
        {'from': NodeStatus.spawning.wire, 'to': NodeStatus.working.wire},
        {'from': NodeStatus.working.wire, 'to': NodeStatus.checkpointed.wire},
      ]);
      expect(store.node('root')!.status, NodeStatus.checkpointed);
    });

    test('the root is announced once, not once per frame', () {
      // The other half of F-10's fix: `_markRoot` runs on every frame after
      // the first, and an event per call would turn the run into a flood on
      // the feed a UI reads. Bounded against the frame count, so this fails
      // loudly if the suppression is ever dropped.
      final announcements = events(
        'root',
      ).where((e) => e.kind == nodeObservedKind || e.kind == nodeUpdatedKind);
      expect(announcements, hasLength(3));
      expect(frameEvents(), hasLength(greaterThan(100)));
    });

    test('the subagents are nodes under the root, in the observed chain', () {
      final byId = {for (final n in store.nodes()) n.id: n};
      expect(byId.keys, unorderedEquals(['root', child, grandchild]));
      expect(byId[child]!.parentId, 'root');
      expect(byId[grandchild]!.parentId, child);
      expect(byId[child]!.currentTask, 'Nested subagent chain test');
      expect(byId[grandchild]!.currentTask, 'Reply with single word');
      expect(byId[child]!.project, tmp.path);

      final depths = {for (final t in store.tree()) t.node.id: t.depth};
      expect(depths, {'root': 0, child: 1, grandchild: 2});
    });

    test('frames are attributed to the node that emitted them', () {
      expect(events(child), isNotEmpty);
      expect(events(grandchild), isNotEmpty);
      expect(
        events('root').where((e) => e.kind == 'frame.result'),
        hasLength(2),
      );
      expect(frameEvents(), hasLength(_lineCount(bytes)));
    });

    test('the cost is the last result, not the first', () {
      expect(ended.results, hasLength(2));
      expect(ended.results.first.totalCostUsd, 0.2316953);
      expect(ended.totalCostUsd, 0.2415507);
      expect(ended.result!.isTaskNotified, isTrue);
      expect(ended.results.first.isTaskNotified, isFalse);
    });

    test('usage is deduplicated by message.id, not summed per frame', () {
      // Independent of the parser: read the fixture's assistant frames and
      // dedupe by hand.
      final seen = <String>{};
      var expected = 0;
      var assistantFrames = 0;
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        if (line.trim().isEmpty) continue;
        final frame = jsonDecode(line) as Map<String, Object?>;
        if (frame['type'] != 'assistant') continue;
        assistantFrames++;
        final message = frame['message'] as Map<String, Object?>;
        if (!seen.add(message['id'] as String)) continue;
        final usage = message['usage'] as Map<String, Object?>;
        for (final key in [
          'input_tokens',
          'output_tokens',
          'cache_creation_input_tokens',
          'cache_read_input_tokens',
        ]) {
          expected += (usage[key] as int?) ?? 0;
        }
      }
      expect(
        seen.length,
        lessThan(assistantFrames),
        reason: 'B splits messages across frames',
      );
      expect(ended.usageByMessageId, hasLength(seen.length));
      expect(ended.totalMessageTokens, expected);
    });

    test('each subagent announces itself before it emits anything', () {
      for (final id in [child, grandchild]) {
        final own = events(id);
        expect(
          own.first.kind,
          nodeObservedKind,
          reason:
              'the node event must precede the first frame attributed to it, '
              'or a consumer reads an event against a node it has not heard '
              'of',
        );
        expect(
          own.where((e) => e.kind == nodeObservedKind),
          hasLength(1),
          reason: 'a node is created once, however often it changes',
        );
      }

      final observed = events(child).first;
      expect(observed.payload['tool_use_id'], 'toolu_013CdYLPDjwGfSwE5gL5Q7BK');
      expect(observed.payload['parent_id'], 'root');
      expect(observed.payload['project'], tmp.path);
      expect(observed.payload['status'], NodeStatus.working.wire);
      // The node is known before its description is: B's subagent is first
      // seen on a partial tool-use whose input has not been assembled yet.
      // This is precisely why a creation event alone is not enough — the
      // label a live tree renders arrives afterwards, in an update.
      expect(observed.payload['current_task'], isNull);
      expect(store.node(child)!.currentTask, 'Nested subagent chain test');
    });

    test(
      'a subagent that finishes reports the change, not a second creation',
      () {
        // Both subagents end `checkpointed`, so both moved off `working` after
        // being announced. A feed that only announced them would leave a live
        // tree showing them still working forever.
        for (final id in [child, grandchild]) {
          final updates = events(id)
              .where((e) => e.kind == nodeUpdatedKind)
              .toList();
          expect(updates, isNotEmpty);
          final status = updates
              .map((e) => e.payload['status'])
              .whereType<Map<Object?, Object?>>()
              .toList();
          expect(status.last, {
            'from': NodeStatus.working.wire,
            'to': NodeStatus.checkpointed.wire,
          });
          // Only what moved: an update that reported every field would be
          // indistinguishable from a re-creation.
          expect(updates.last.payload.keys, isNot(contains('project')));

          // A consumer folding creation then updates arrives at the label the
          // store holds — the tree does not freeze on its first line.
          final task = updates
              .map((e) => e.payload['current_task'])
              .whereType<Map<Object?, Object?>>()
              .lastOrNull;
          expect(
            task?['to'] ?? events(id).first.payload['current_task'],
            store.node(id)!.currentTask,
            reason: 'the feed carries the label the tree renders',
          );
        }
      },
    );

    test('a consumer that only reads the feed learns every node', () {
      final named = {
        for (final event in events())
          if (event.kind == 'runner.spawned' || event.kind == nodeObservedKind)
            event.nodeId,
      };
      expect(named, {'root', child, grandchild});
      expect(
        named,
        containsAll(store.nodes().map((n) => n.id)),
        reason:
            'a node row the feed never announced is one only a fresh snapshot '
            'can reveal — the gap F-02 recorded',
      );
    });

    test('both subagents completed, so nothing is left incomplete', () {
      expect(ended.incompleteTasks, isEmpty);
      expect(store.node(child)!.status, NodeStatus.checkpointed);
      expect(store.node(grandchild)!.status, NodeStatus.checkpointed);
      expect(ended.transcript.tree.orphans, isEmpty);
    });
  });

  group('streaming', () {
    test('frames reach the store while the process is still running', () async {
      final bytes = _fixture('A.ndjson');
      final lines = const LineSplitter().convert(utf8.decode(bytes));
      final firstTen = utf8.encode('${lines.take(10).join('\n')}\n');
      final rest = utf8.encode(lines.skip(10).join('\n'));

      final process = FakeProcess();
      final launcher = FakeLauncher()..queue.add(process);
      final session = await runner(launcher).launch(request()) as LiveSession;

      final tenth = session.frames.skip(9).first;
      process.emit(firstTen);
      await tenth;

      // Observable mid-run: the store and the disk already have the frames,
      // and the process has not exited.
      expect(process.hasExited, isFalse);
      expect(frameEvents(), hasLength(10));
      expect(File(session.rawLogPath).lengthSync(), firstTen.length);
      expect(store.node('root')!.status, NodeStatus.working);
      expect(session.transcript.hasResult, isFalse);

      process.emit(rest);
      await process.exit(0);
      final ended = await session.done;
      expect(ended.hasResult, isTrue);
      expect(frameEvents(), hasLength(lines.length));
    });

    test('a process dying mid-line keeps every frame before the cut', () async {
      final bytes = _fixture('A.ndjson');
      // Cut inside the final line (the result frame), leaving no newline.
      final truncated = bytes.sublist(0, bytes.length - 40);
      expect(utf8.decode(truncated).endsWith('\n'), isFalse);

      final ended = await runner(
        _replaying(truncated, code: 137),
      ).run(request()) as EndedSession;

      expect(ended.exitCode, 137);
      expect(ended.frameCount, _lineCount(bytes));
      expect(ended.malformed, hasLength(1));
      expect(frameEvents().last.kind, 'frame.malformed');
      expect(frameEvents().last.payload['line'], isA<String>());
      expect(frameEvents(), hasLength(_lineCount(bytes)));
      expect(File(ended.rawLogPath).readAsBytesSync(), truncated);
      // The frame that was cut was the result, so there is none — and the
      // node is not checkpointed. Pairs with A's clean run above.
      expect(ended.hasResult, isFalse);
      expect(ended.totalCostUsd, isNull);
      expect(store.node('root')!.status, NodeStatus.working);
    });
  });

  group('process exit is not completion', () {
    test('a clean exit with no result frame reports no result', () async {
      final lines = const LineSplitter().convert(
        utf8.decode(_fixture('A.ndjson')),
      );
      final initOnly = utf8.encode('${lines.first}\n');

      final ended =
          await runner(_replaying(initOnly)).run(request()) as EndedSession;

      expect(ended.exitCode, 0);
      expect(ended.hasResult, isFalse);
      expect(ended.results, isEmpty);
      expect(ended.sessionId, isNotNull);
      final exited = events().last;
      expect(exited.kind, 'runner.exited');
      expect(exited.payload['has_result'], false);
      expect(exited.payload['exit_code'], 0);
      expect(store.node('root')!.status, NodeStatus.working);
    });

    test('and a non-zero exit after results still reports them', () async {
      final ended = await runner(
        _replaying(_fixture('B.ndjson'), code: -15),
      ).run(request()) as EndedSession;
      expect(ended.exitCode, -15);
      expect(ended.hasResult, isTrue);
      expect(ended.results, hasLength(2));
      expect(store.node('root')!.status, NodeStatus.checkpointed);
    });
  });

  group('the projection', () {
    test('an orphan subagent is kept as its own fragment, not attached to the root', () async {
      // A frame emitted by a subagent whose spawn was never seen.
      final orphan = jsonEncode({
        'type': 'assistant',
        'uuid': 'u-orphan',
        'session_id': 's',
        'parent_tool_use_id': 'toolu_orphan',
        'message': {'id': 'msg_o', 'role': 'assistant', 'content': <Object?>[]},
      });
      final ended = await runner(
        _replaying(utf8.encode('$orphan\n')),
      ).run(request()) as EndedSession;

      final node = store.node('root/toolu_orphan')!;
      expect(node.parentId, 'root/unobserved-parent');
      expect(store.node(node.parentId!), isNull);
      final depths = {for (final t in store.tree()) t.node.id: t.depth};
      expect(
        depths['root/toolu_orphan'],
        0,
        reason: 'a fragment root, reported not dropped',
      );
      expect(ended.transcript.tree.orphans, hasLength(1));
      expect(events('root/toolu_orphan').map((e) => e.kind), [
        nodeObservedKind,
        'frame.assistant',
      ], reason: 'even an orphan announces itself, ahead of its own frame');
      expect(
        events('root/toolu_orphan').first.payload['parent_id'],
        'root/unobserved-parent',
      );
    });

    test('an unchanged subagent appends no second event', () {
      // The volume guard. `_same` already suppresses the no-op *row* write,
      // and the event is appended beside the row, so a frame that changes
      // nothing costs nothing. An event per frame would flood the feed a live
      // UI reads.
      store.putNode(
        const SproutNode(id: 'root', project: 'p', status: NodeStatus.working),
      );
      final projection = StoreProjection(
        store: store,
        rootId: 'root',
        project: 'p',
        clock: DateTime.now,
      );
      final line = jsonEncode({
        'type': 'assistant',
        'uuid': 'u-1',
        'session_id': 's',
        'parent_tool_use_id': 'toolu_same',
        'message': {'id': 'msg_1', 'role': 'assistant', 'content': <Object?>[]},
      });
      final frame = parseStreamJson('$line\n').single;

      List<String> nodeEvents() =>
          events('root/toolu_same')
              .where((e) => !e.kind.startsWith(frameKindPrefix))
              .map((e) => e.kind)
              .toList();

      projection.observe(frame);
      expect(nodeEvents(), [nodeObservedKind]);

      projection.observe(frame);
      projection.observe(frame);
      expect(
        nodeEvents(),
        [nodeObservedKind],
        reason:
            'nothing about the node moved, so neither a creation nor an '
            'update belongs in the feed',
      );
      expect(store.node('root/toolu_same'), isNotNull);
    });

    test('the raw log is written before the store is', () async {
      // Close the store under the runner: the store write throws, `done`
      // fails — and the bytes are still on disk.
      final process = FakeProcess();
      final launcher = FakeLauncher()..queue.add(process);
      final session = await runner(launcher).launch(request()) as LiveSession;
      final line = utf8.encode(
        '${const LineSplitter().convert(utf8.decode(_fixture('A.ndjson'))).first}\n',
      );

      final failed = expectLater(session.done, throwsA(anything));
      store.close();
      process.emit(line);
      await process.exit(0);

      await failed;
      expect(File(session.rawLogPath).readAsBytesSync(), line);
      store =
          SproutStore.memory(); // so tearDown's close has something to close
    });
  });

  group('integration', () {
    test(
      'spawns a real claude -p and gets a result',
      () async {
        final tmpProject = Directory.systemTemp.createTempSync(
          'sprout_runner_real',
        );
        addTearDown(() => tmpProject.deleteSync(recursive: true));
        final real = SessionRunner(
          store: store,
          gate: ContainmentGate(
            const ContainmentPolicy(subtreeBudgetUsd: 0.1, runBudgetUsd: 0.1),
          ),
          logDirectory: p.join(tmp.path, 'sessions'),
        );
        final ended = await real.run(
          SessionRequest(
            task: 'Reply with exactly the word PONG and nothing else.',
            project: tmpProject.path,
          ),
        ) as EndedSession;

        expect(ended.exitCode, 0);
        expect(ended.hasResult, isTrue);
        expect(ended.result!.result, contains('PONG'));
        expect(ended.totalCostUsd, greaterThan(0));
        expect(ended.malformed, isEmpty);
        // Stdin was at EOF from the start, so the 3-second wait (`17` §10)
        // never happened.
        expect(
          File(ended.stderrLogPath).readAsStringSync(),
          isNot(contains('no stdin data received')),
        );
      },
      skip:
          'Spawns a real `claude -p` on this machine and COSTS MONEY (about '
          '\$0.02 on the fixture task). Run it deliberately:\n'
          '  cd sproutd && dart test test/runner_test.dart --run-skipped '
          '-N "spawns a real claude"',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
