import 'package:sproutd/policy.dart';
import 'package:test/test.dart';

/// A policy with room to spare on every bound except the one under test, so a
/// refusal in any given test can only have come from the bound being exercised.
const roomy = ContainmentPolicy(
  subtreeBudgetUsd: 1000,
  runBudgetUsd: 1000,
  maxLiveChildren: 1000,
  maxLiveNodes: 1000,
);

/// A chain root → n1 → n2 → …, each node spending [costUsd].
List<NodeSpend> chain(int length, {double costUsd = 0, bool live = false}) => [
  for (var i = 0; i < length; i++)
    NodeSpend(
      id: 'n$i',
      parentId: i == 0 ? null : 'n${i - 1}',
      costUsd: costUsd,
      isLive: live,
    ),
];

SpawnRequest under(
  String? parentId,
  List<NodeSpend> nodes, {
  double estimate = 0,
}) => SpawnRequest(
  ledger: SpendLedger.of(nodes),
  parentId: parentId,
  estimatedCostUsd: estimate,
);

void main() {
  group('depth cap', () {
    test('defaults to 3, the number §2.1 argues for', () {
      expect(defaultMaxDepth, 3);
      expect(
        const ContainmentPolicy(subtreeBudgetUsd: 1, runBudgetUsd: 1).maxDepth,
        3,
      );
    });

    test('permits one below the cap, at the cap, and refuses above it', () {
      // n0 is depth 0, so a child of n2 is depth 3 — exactly at the cap — and a
      // child of n3 is depth 4. The permitted cases are here alongside the
      // refused one on purpose (INV8): a policy mutated to refuse everything
      // fails the first two, one mutated to permit everything fails the third.
      final nodes = chain(4);
      expect(roomy.decide(under('n1', nodes)), isA<SpawnPermit>());
      expect(roomy.decide(under('n2', nodes)), isA<SpawnPermit>());

      final refusal = roomy.decide(under('n3', nodes));
      expect(refusal, isA<SpawnRefusal>());
      expect((refusal as SpawnRefusal).reason, RefusalReason.depthCap);
      expect(refusal.explanation, contains('depth 4'));
      expect(refusal.explanation, contains('cap of 3'));
    });

    test('a root spawn is depth 0 and permitted against an empty tree', () {
      final decision = roomy.decide(SpawnRequest(ledger: SpendLedger.empty()));
      expect(decision, isA<SpawnPermit>());
      expect((decision as SpawnPermit).depth, 0);
    });

    test('honours a configured cap other than the default', () {
      const shallow = ContainmentPolicy(
        maxDepth: 1,
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
      );
      final nodes = chain(2);
      expect(shallow.decide(under('n0', nodes)), isA<SpawnPermit>());
      expect(shallow.decide(under('n1', nodes)), isA<SpawnRefusal>());
    });

    test(
      'refuses beneath a parent whose own depth already exceeds the cap',
      () {
        // Depth is read off the parent chain, not off a counter a node could be
        // spawned with, so a node already too deep cannot spawn its way deeper.
        final nodes = chain(6);
        final refusal = roomy.decide(under('n5', nodes)) as SpawnRefusal;
        expect(refusal.reason, RefusalReason.depthCap);
        expect(refusal.explanation, contains('depth 6'));
      },
    );
  });

  group('subtree budget', () {
    test('permits exactly at the ceiling and refuses one cent over', () {
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 2.50,
        runBudgetUsd: 1000,
      );
      // n0 has spent $2.40; a child estimated at $0.10 lands the subtree on
      // $2.50 exactly, and $0.11 lands it a cent over.
      final nodes = [const NodeSpend(id: 'n0', costUsd: 2.40)];
      expect(
        policy.decide(under('n0', nodes, estimate: 0.10)),
        isA<SpawnPermit>(),
      );
      final refusal =
          policy.decide(under('n0', nodes, estimate: 0.11)) as SpawnRefusal;
      expect(refusal.reason, RefusalReason.budget);
      expect(refusal.explanation, contains(r'$2.51'));
      expect(refusal.explanation, contains(r'$2.50'));
      expect(refusal.explanation, contains('n0'));
    });

    test('exact-at-ceiling survives spend that does not sum in binary', () {
      // 0.1 + 0.2 > 0.3 is true in doubles. Three nodes at $0.10 against a
      // $0.30 ceiling must be permitted, and $0.300001 more must not be.
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 0.30,
        runBudgetUsd: 1000,
      );
      final nodes = [
        const NodeSpend(id: 'n0', costUsd: 0.1),
        const NodeSpend(id: 'n1', parentId: 'n0', costUsd: 0.1),
        const NodeSpend(id: 'n2', parentId: 'n1', costUsd: 0.1),
      ];
      expect(SpendLedger.of(nodes).subtreeMicroUsd('n0'), 300000);
      expect(policy.decide(under('n2', nodes)), isA<SpawnPermit>());
      expect(
        policy.decide(under('n2', nodes, estimate: 0.000001)),
        isA<SpawnRefusal>(),
      );
    });

    test('a grandchild is charged against every ancestor, not just its parent', () {
      // The whole point of rolling up: n2's parent has spent almost nothing, so
      // a per-parent-only check would permit this. The root has spent $9.90.
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 10,
        runBudgetUsd: 1000,
      );
      final nodes = [
        const NodeSpend(id: 'n0', costUsd: 9.90),
        const NodeSpend(id: 'n1', parentId: 'n0', costUsd: 0.01),
        const NodeSpend(id: 'n2', parentId: 'n1', costUsd: 0.01),
      ];
      final ledger = SpendLedger.of(nodes);
      expect(ledger.subtreeCostUsd('n1'), closeTo(0.02, 1e-9));
      expect(ledger.subtreeCostUsd('n0'), closeTo(9.92, 1e-9));

      // Under the parent's own ceiling, over the root's: refused, naming n0.
      final refusal =
          policy.decide(under('n2', nodes, estimate: 0.50)) as SpawnRefusal;
      expect(refusal.reason, RefusalReason.budget);
      expect(refusal.explanation, contains('n0'));
      // The paired positive: an estimate that clears the root's ceiling too is
      // permitted, so this test cannot pass by refusing everything.
      expect(
        policy.decide(under('n2', nodes, estimate: 0.05)),
        isA<SpawnPermit>(),
      );
    });

    test('the refusal names the nearest binding ancestor', () {
      const policy = ContainmentPolicy(subtreeBudgetUsd: 5, runBudgetUsd: 1000);
      final nodes = [
        const NodeSpend(id: 'n0', costUsd: 0.10),
        const NodeSpend(id: 'n1', parentId: 'n0', costUsd: 4.90),
      ];
      // Both n0 ($5.00) and n1 ($4.90) are near the ceiling; n1 is nearer.
      final refusal =
          policy.decide(under('n1', nodes, estimate: 0.20)) as SpawnRefusal;
      expect(refusal.explanation, contains('n1'));
      expect(refusal.explanation, isNot(contains('n0')));
    });

    test('a root spawn is still bound by the per-subtree ceiling', () {
      // The one case with no ancestor to charge: without a check on the child
      // itself, a first node could be launched estimated above any ceiling.
      const policy = ContainmentPolicy(subtreeBudgetUsd: 1, runBudgetUsd: 1000);
      final empty = SpendLedger.empty();
      expect(
        policy.decide(SpawnRequest(ledger: empty, estimatedCostUsd: 1)),
        isA<SpawnPermit>(),
      );
      final refusal = policy.decide(
        SpawnRequest(ledger: empty, estimatedCostUsd: 1.01),
      ) as SpawnRefusal;
      expect(refusal.reason, RefusalReason.budget);
    });
  });

  group('run budget', () {
    test('sums across separate trees the subtree ceiling never sees', () {
      const policy = ContainmentPolicy(subtreeBudgetUsd: 1000, runBudgetUsd: 3);
      final nodes = [
        const NodeSpend(id: 'a0', costUsd: 1.50),
        const NodeSpend(id: 'b0', costUsd: 1.40),
      ];
      expect(
        policy.decide(under('a0', nodes, estimate: 0.10)),
        isA<SpawnPermit>(),
      );
      final refusal =
          policy.decide(under('a0', nodes, estimate: 0.11)) as SpawnRefusal;
      expect(refusal.reason, RefusalReason.budget);
      expect(refusal.explanation, contains('whole run'));
      expect(refusal.explanation, contains(r'$3.01'));
    });
  });

  group('concurrency', () {
    test('bounds live children of one node, counting only live ones', () {
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
        maxLiveChildren: 2,
      );
      NodeSpend child(String id, {required bool live}) =>
          NodeSpend(id: id, parentId: 'n0', costUsd: 0, isLive: live);

      final oneLive = [
        const NodeSpend(id: 'n0', costUsd: 0),
        child('c1', live: true),
        child('c2', live: false),
      ];
      // Two children exist but only one is running, so this is permitted — the
      // bound is on concurrency, not on fan-out over the life of the node.
      expect(policy.decide(under('n0', oneLive)), isA<SpawnPermit>());

      final twoLive = [
        const NodeSpend(id: 'n0', costUsd: 0),
        child('c1', live: true),
        child('c2', live: true),
      ];
      final refusal = policy.decide(under('n0', twoLive)) as SpawnRefusal;
      expect(refusal.reason, RefusalReason.concurrency);
      expect(refusal.explanation, contains('limit of 2'));
    });

    test('bounds live nodes across the whole tree', () {
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
        maxLiveNodes: 3,
      );
      expect(
        policy.decide(under('n0', chain(3, live: true))),
        isA<SpawnRefusal>(),
      );
      expect(
        policy.decide(under('n0', chain(2, live: true))),
        isA<SpawnPermit>(),
      );
    });

    test('has knob defaults, distinct from the evidence-backed depth cap', () {
      expect(defaultMaxLiveChildren, 4);
      expect(defaultMaxLiveNodes, 12);
    });
  });

  group('permit', () {
    test('is a value carrying real numbers, not merely the absence of a throw', () {
      // INV8: if `decide` returned a bare "allowed" the permitted path would be
      // silence, and a policy mutated to allow everything would pass. These
      // assertions are what such a mutant fails.
      const policy = ContainmentPolicy(
        subtreeBudgetUsd: 100,
        runBudgetUsd: 100,
      );
      final nodes = [
        const NodeSpend(id: 'n0', costUsd: 1),
        const NodeSpend(id: 'n1', parentId: 'n0', costUsd: 2),
      ];
      final permit =
          policy.decide(under('n1', nodes, estimate: 0.50)) as SpawnPermit;
      expect(permit.isPermitted, isTrue);
      expect(permit.depth, 2);
      // The worst ancestor is the root: $3.00 already spent plus the estimate.
      expect(permit.projectedSubtreeCostUsd, closeTo(3.50, 1e-9));
      expect(permit.projectedRunCostUsd, closeTo(3.50, 1e-9));
    });

    test('a refusal is not permitted and a permit is', () {
      final nodes = chain(4);
      expect(roomy.decide(under('n3', nodes)).isPermitted, isFalse);
      expect(roomy.decide(under('n2', nodes)).isPermitted, isTrue);
    });
  });

  group('refusal counting (INV14)', () {
    test('starts at zero on every reason, with every key present', () {
      final gate = ContainmentGate(roomy);
      expect(gate.refusals.total, 0);
      expect(gate.permitted, 0);
      expect(gate.refusals.toWireMap(), {
        'depthCap': 0,
        'budget': 0,
        'concurrency': 0,
      });
    });

    test('counts each reason separately, and does not count permits', () {
      const policy = ContainmentPolicy(
        maxDepth: 1,
        subtreeBudgetUsd: 1,
        runBudgetUsd: 1000,
        maxLiveChildren: 1,
      );
      final gate = ContainmentGate(policy);

      // A permit first. The paired positive: if permits also incremented, or if
      // nothing incremented at all, one of these two halves fails.
      final ok = [const NodeSpend(id: 'n0', costUsd: 0)];
      expect(gate.admit(under('n0', ok)), isA<SpawnPermit>());
      expect(gate.permitted, 1);
      expect(gate.refusals.total, 0);

      gate.admit(under('n1', chain(2)));
      expect(gate.refusals[RefusalReason.depthCap], 1);
      expect(gate.refusals.total, 1);

      gate.admit(under('n0', ok, estimate: 1.01));
      expect(gate.refusals[RefusalReason.budget], 1);

      gate.admit(
        under('n0', [
          const NodeSpend(id: 'n0', costUsd: 0),
          const NodeSpend(id: 'c1', parentId: 'n0', costUsd: 0, isLive: true),
        ]),
      );
      expect(gate.refusals[RefusalReason.concurrency], 1);

      // Same reason twice accumulates rather than latching at one.
      gate.admit(under('n1', chain(2)));
      expect(gate.refusals[RefusalReason.depthCap], 2);

      expect(gate.refusals.total, 4);
      expect(gate.permitted, 1);
      expect(gate.refusals.toWireMap(), {
        'depthCap': 2,
        'budget': 1,
        'concurrency': 1,
      });
    });

    test('the counts view cannot be written through', () {
      final gate = ContainmentGate(roomy);
      expect(
        () => gate.refusals.byReason[RefusalReason.budget] = 99,
        throwsUnsupportedError,
      );
    });
  });

  group('the policy is an input, never an output (INV9)', () {
    test('reason wire names are fixed and match the exposed counters', () {
      expect(
        RefusalReason.values.map((r) => r.wire),
        containsAll(<String>['depthCap', 'budget', 'concurrency']),
      );
    });

    test('every refusal explains itself in a sentence a model can act on', () {
      // One policy per reason, so all three refusal strings are exercised. A
      // reason whose explanation was left empty, or which stopped being
      // reachable at all, fails here rather than being reported as clean.
      final cases = <RefusalReason, SpawnDecision>{
        RefusalReason.depthCap: const ContainmentPolicy(
          maxDepth: 0,
          subtreeBudgetUsd: 1000,
          runBudgetUsd: 1000,
        ).decide(under('n0', chain(1))),
        RefusalReason.budget: const ContainmentPolicy(
          subtreeBudgetUsd: 0,
          runBudgetUsd: 1000,
        ).decide(under('n0', chain(1), estimate: 1)),
        RefusalReason.concurrency: const ContainmentPolicy(
          subtreeBudgetUsd: 1000,
          runBudgetUsd: 1000,
          maxLiveNodes: 0,
        ).decide(under('n0', chain(1))),
      };
      expect(cases.keys, unorderedEquals(RefusalReason.values));
      for (final MapEntry(key: reason, value: decision) in cases.entries) {
        final refusal = decision as SpawnRefusal;
        expect(refusal.reason, reason);
        expect(refusal.explanation.length, greaterThan(40));
        expect(refusal.explanation, endsWith('.'));
        // Additive, never an override: no "STOP", no "ignore".
        expect(refusal.explanation.toLowerCase(), isNot(contains('ignore')));
      }
    });
  });

  group('ledger', () {
    test('rolls a cost up into every ancestor and into the run total', () {
      final ledger = SpendLedger.of([
        const NodeSpend(id: 'n0', costUsd: 1),
        const NodeSpend(id: 'n1', parentId: 'n0', costUsd: 2),
        const NodeSpend(id: 'n2', parentId: 'n1', costUsd: 4),
        const NodeSpend(id: 'm0', costUsd: 8),
      ]);
      expect(ledger.subtreeCostUsd('n2'), 4);
      expect(ledger.subtreeCostUsd('n1'), 6);
      expect(ledger.subtreeCostUsd('n0'), 7);
      expect(ledger.subtreeCostUsd('m0'), 8);
      expect(ledger.totalCostUsd, 15);
      expect(ledger.depthOf('n2'), 2);
      expect(ledger.depthOf('m0'), 0);
      expect(ledger.ancestryOf('n2'), ['n0', 'n1', 'n2']);
    });

    test(
      'an unrecorded parent makes a fragment root, and is never a spawn',
      () {
        // The store records a child seen before its parent rather than dropping
        // it, so the ledger has to represent one — at depth 0, as `TreeNode`
        // does. But a spawn *beneath* it cannot be bounded, because its real
        // depth is unknown, so `decide` refuses to guess and throws instead.
        final ledger = SpendLedger.of([
          const NodeSpend(id: 'orphan', parentId: 'missing', costUsd: 1),
        ]);
        expect(ledger.depthOf('orphan'), 0);
        expect(ledger.contains('missing'), isFalse);
        expect(ledger.subtreeCostUsd('missing'), 0);

        // The permitted half: a spawn under the orphan itself is fine.
        expect(
          roomy.decide(SpawnRequest(ledger: ledger, parentId: 'orphan')),
          isA<SpawnPermit>(),
        );
        expect(
          () => roomy.decide(SpawnRequest(ledger: ledger, parentId: 'missing')),
          throwsArgumentError,
        );
      },
    );

    test('refuses a corrupt graph loudly rather than interpreting it', () {
      expect(
        () => SpendLedger.of([
          const NodeSpend(id: 'a', parentId: 'b', costUsd: 0),
          const NodeSpend(id: 'b', parentId: 'a', costUsd: 0),
        ]),
        throwsArgumentError,
      );
      expect(
        () => SpendLedger.of([
          const NodeSpend(id: 'a', costUsd: 0),
          const NodeSpend(id: 'a', costUsd: 0),
        ]),
        throwsArgumentError,
      );
      // The paired positive: the same shape without the cycle or the duplicate
      // builds fine, so this is not passing because construction always throws.
      expect(SpendLedger.of(chain(2)).depthOf('n1'), 1);
    });

    test('counts live nodes and live children, ignoring finished ones', () {
      final ledger = SpendLedger.of([
        const NodeSpend(id: 'n0', costUsd: 0, isLive: true),
        const NodeSpend(id: 'c1', parentId: 'n0', costUsd: 0, isLive: true),
        const NodeSpend(id: 'c2', parentId: 'n0', costUsd: 0),
      ]);
      expect(ledger.liveNodes, 2);
      expect(ledger.liveChildrenOf('n0'), 1);
      expect(ledger.liveChildrenOf('c1'), 0);
    });
  });
}
