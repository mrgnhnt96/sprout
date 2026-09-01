/// The decision itself: may this child be launched?
library;

import 'refusal.dart';
import 'spend.dart';

/// The default depth cap, and the number `docs/01-plan.md` §2.1 argues for.
///
/// RAH's entire recursion control is a static cap, default 3, which its authors
/// state they never ablate. DELEGATE-52 measured frontier models corrupting
/// ~25% of content over 20 hops with **no plateau** (79.7% at 10 hops down to
/// 58.7% at 100). Kim et al. contained trace-level error amplification to 4.4×
/// with centralized coordination — measured at *one* orchestrator level, with
/// no published number for depth 3. So 3 is where the evidence stops, and above
/// it the policy refuses by default rather than extrapolating.
const int defaultMaxDepth = 3;

/// Everything about one proposed spawn that a containment decision needs.
///
/// A value, not a handle: no process, no store, no clock. The runner assembles
/// it and the policy reads it.
final class SpawnRequest {
  /// Describes a spawn the runner is about to perform.
  const SpawnRequest({
    required this.ledger,
    this.parentId,
    this.estimatedCostUsd = 0,
  });

  /// The tree as it stands right now.
  final SpendLedger ledger;

  /// The node asking to spawn, or null for a root spawn.
  final String? parentId;

  /// What the child is expected to cost, in dollars.
  ///
  /// Defaults to 0, which makes the budget check ask "has this subtree already
  /// blown its ceiling?" rather than "would it?". A caller with an estimate
  /// should pass it; a caller without one is not forced to invent a number,
  /// because a fabricated estimate is worse than none.
  final double estimatedCostUsd;
}

/// The bounds a spawn is judged against.
///
/// **Every field is final and there is no setter anywhere in this class.** That
/// is INV9 and it is structural, not stylistic: a depth cap, a budget ceiling
/// and a concurrency limit are inputs to sprout, never outputs of it. If a
/// running node could reach these, the guardrail would be a suggestion. The
/// Darwin Gödel Machine, given the ordinary incentive to make its score go up,
/// faked test logs and deleted the reward markers it was told not to touch
/// (`docs/01-plan.md` §9); the way to not have that problem is for there to be
/// no path, not for there to be an instruction.
///
/// The class is `final` so no subclass can override [decide] into something
/// permissive, and the constructor is `const` so a policy can be a compile-time
/// constant the run is handed rather than a mutable object it holds.
final class ContainmentPolicy {
  /// Constructs a policy from its bounds. Nothing here changes afterwards.
  const ContainmentPolicy({
    this.maxDepth = defaultMaxDepth,
    required this.subtreeBudgetUsd,
    required this.runBudgetUsd,
    this.maxLiveChildren = defaultMaxLiveChildren,
    this.maxLiveNodes = defaultMaxLiveNodes,
  });

  /// The deepest a node may sit. A root is depth 0, so 3 permits four levels.
  ///
  /// Configurable, and **default-refuse above the configured value** — the
  /// refusal is what happens when the cap is reached, not a warning.
  final int maxDepth;

  /// The dollar ceiling on any one node's subtree, charged cumulatively.
  ///
  /// A child's cost counts against this ceiling for the child *and every
  /// ancestor above it*, so a subtree that is quietly burning money is refused
  /// at whichever ancestor is nearest its ceiling — usually the root, which is
  /// the point.
  final double subtreeBudgetUsd;

  /// The dollar ceiling on the whole run, across every tree in the ledger.
  final double runBudgetUsd;

  /// How many direct children of one node may be live at once.
  final int maxLiveChildren;

  /// How many nodes may be live at once across the whole tree.
  final int maxLiveNodes;

  /// Decides whether the child described by [request] may be launched.
  ///
  /// Pure: no I/O, no clock, no process, no SQL. The same request always yields
  /// the same decision, which is what makes a containment gate testable enough
  /// to be trusted, and what makes it impossible to talk out of anything.
  ///
  /// Checks run in a fixed order — depth, budget, concurrency — so a request
  /// that breaches more than one bound always reports the same reason, and a
  /// refusal string is stable enough to be asserted on.
  ///
  /// Throws [ArgumentError] if [SpawnRequest.parentId] names a node the ledger
  /// has never seen. That is deliberately not a refusal: an unknown parent has
  /// no known depth, so treating it as a fragment root would hand a child that
  /// might be at depth 7 a fresh budget of three more levels. It is the one
  /// case where the honest answer is that the gate cannot decide, and it fails
  /// loudly rather than permissively.
  SpawnDecision decide(SpawnRequest request) {
    final ledger = request.ledger;
    final parentId = request.parentId;
    if (parentId != null && !ledger.contains(parentId)) {
      throw ArgumentError.value(
        parentId,
        'request.parentId',
        'not in the ledger, so its depth is unknown and no spawn beneath it '
            'can be bounded',
      );
    }

    final depth = parentId == null ? 0 : ledger.depthOf(parentId)! + 1;
    if (depth > maxDepth) {
      return SpawnRefusal(
        reason: RefusalReason.depthCap,
        explanation:
            'This child would sit at depth $depth, past sprout\'s depth cap of '
            '$maxDepth. Delegation stops here; do the work in this session, or '
            'hand it back with what is still outstanding.',
      );
    }

    final estimate = microUsd(request.estimatedCostUsd);
    final subtreeCeiling = microUsd(subtreeBudgetUsd);
    final ancestry = parentId == null
        ? const <String>[]
        : ledger.ancestryOf(parentId);
    if (estimate > subtreeCeiling) {
      // The child's own subtree, which is just the child until it spawns. This
      // is the only ceiling a root spawn has above it, so without it a first
      // node could be launched with an estimate larger than any subtree is
      // allowed to spend.
      return SpawnRefusal(
        reason: RefusalReason.budget,
        explanation:
            'This child is estimated at ${formatUsd(request.estimatedCostUsd)}, '
            'already past the ${formatUsd(subtreeBudgetUsd)} ceiling any one '
            'subtree is allowed. Narrow the task, or hand back and let the '
            'developer raise the ceiling.',
      );
    }
    // Charged against every ancestor, nearest ceiling first, so the refusal
    // names the node that actually binds.
    for (final ancestorId in ancestry.reversed) {
      final projected = ledger.subtreeMicroUsd(ancestorId) + estimate;
      if (projected > subtreeCeiling) {
        return SpawnRefusal(
          reason: RefusalReason.budget,
          explanation:
              'This child would take the subtree under $ancestorId to '
              '${formatUsd(projected / 1e6)}, past its ceiling of '
              '${formatUsd(subtreeBudgetUsd)} '
              '(${formatUsd(ledger.subtreeCostUsd(ancestorId))} spent so far). '
              'Finish within this session rather than delegating, or hand back '
              'and let the developer raise the ceiling.',
        );
      }
    }

    final projectedRun = ledger.totalMicroUsd + estimate;
    final runCeiling = microUsd(runBudgetUsd);
    if (projectedRun > runCeiling) {
      return SpawnRefusal(
        reason: RefusalReason.budget,
        explanation:
            'This child would take the whole run to '
            '${formatUsd(projectedRun / 1e6)}, past its ceiling of '
            '${formatUsd(runBudgetUsd)} '
            '(${formatUsd(ledger.totalCostUsd)} spent so far). Finish within '
            'this session rather than delegating, or hand back and let the '
            'developer raise the ceiling.',
      );
    }

    if (ledger.liveNodes >= maxLiveNodes) {
      return SpawnRefusal(
        reason: RefusalReason.concurrency,
        explanation:
            'sprout already has ${ledger.liveNodes} nodes running, at its '
            'limit of $maxLiveNodes across the tree. Continue with the work '
            'you have, and delegate this once something finishes.',
      );
    }

    if (parentId != null &&
        ledger.liveChildrenOf(parentId) >= maxLiveChildren) {
      return SpawnRefusal(
        reason: RefusalReason.concurrency,
        explanation:
            'This node already has ${ledger.liveChildrenOf(parentId)} children '
            'running, at its limit of $maxLiveChildren. Continue with the work '
            'you have, and delegate this once one of them finishes.',
      );
    }

    var worstSubtree = estimate;
    for (final ancestorId in ancestry) {
      final projected = ledger.subtreeMicroUsd(ancestorId) + estimate;
      if (projected > worstSubtree) worstSubtree = projected;
    }
    return SpawnPermit(
      depth: depth,
      projectedSubtreeCostUsd: worstSubtree / 1e6,
      projectedRunCostUsd: projectedRun / 1e6,
    );
  }

  @override
  String toString() =>
      'ContainmentPolicy(depth $maxDepth, subtree '
      '${formatUsd(subtreeBudgetUsd)}, run ${formatUsd(runBudgetUsd)}, '
      'live $maxLiveChildren/$maxLiveNodes)';
}

/// Default cap on one node's simultaneously-live children.
///
/// Unlike [defaultMaxDepth] this number has **no research behind it.** §2.1
/// argues depth from three measured sources; nothing in the plan or the
/// fixtures fixes a fan-out. It is a knob set low enough that a runaway is
/// caught early, and it is stated as a knob rather than dressed as a finding.
const int defaultMaxLiveChildren = 4;

/// Default cap on live nodes across the whole tree. Also a knob, not a finding.
const int defaultMaxLiveNodes = 12;
