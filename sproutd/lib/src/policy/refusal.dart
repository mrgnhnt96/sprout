/// The answer to a spawn request, and the vocabulary of saying no.
library;

/// Why sprout refused a spawn.
///
/// Three reasons, and deliberately no `other`: a refusal sprout cannot name is
/// a refusal it cannot count, and INV14 exists because uncounted refusals are
/// invisible. The names match the three counters Claude Code keeps for its own
/// refusals (`subagent_stats.refused.depth_limit` / `.concurrency_limit` /
/// `.budget`, observed in `docs/research/fixtures/phase0/streams/E.ndjson`) so
/// the two tallies can be read side by side — **they are not the same number.**
/// In that fixture a hook-denied `Agent` call left all three of Claude Code's
/// counters at `0` while `permission_denials` gained an entry: the platform
/// counts only its own refusals, so sprout's have to be counted here.
enum RefusalReason {
  /// The child would sit deeper than the configured cap.
  depthCap('depthCap'),

  /// The child's projected cost would take a subtree, or the run, past its
  /// dollar ceiling.
  budget('budget'),

  /// Too many nodes are already live, under this parent or across the tree.
  concurrency('concurrency');

  const RefusalReason(this.wire);

  /// The string used in logs, counters and anything persisted.
  ///
  /// Written out rather than derived from [name] for the same reason
  /// `NodeStatus.wire` is: renaming a Dart identifier must not silently rewrite
  /// a counter key that something else is already reading.
  final String wire;
}

/// The outcome of asking `ContainmentPolicy` whether a child may be launched.
///
/// Sealed, and permission is a *value* rather than the absence of an exception.
/// That is INV8 applied to this file: a gate whose success is silence cannot be
/// told from a gate that never ran, so the permitted path returns a
/// [SpawnPermit] carrying the numbers it decided on. A policy mutated to allow
/// everything still has to produce the right depth and the right projected
/// spend, and the tests check those.
sealed class SpawnDecision {
  const SpawnDecision();

  /// Whether the child may be launched.
  bool get isPermitted => this is SpawnPermit;
}

/// The spawn is allowed, at [depth], with these projections.
final class SpawnPermit extends SpawnDecision {
  /// Records a permitted spawn.
  const SpawnPermit({
    required this.depth,
    required this.projectedSubtreeCostUsd,
    required this.projectedRunCostUsd,
  });

  /// Where the child would sit. 0 is a root.
  final int depth;

  /// What the child's own subtree chain would total, worst case: the highest
  /// projected total across the child and every ancestor above it.
  ///
  /// The *maximum* rather than the parent's, because a child's cost counts
  /// against every ancestor's ceiling and the binding constraint is whichever
  /// ancestor is closest to its own.
  final double projectedSubtreeCostUsd;

  /// What the whole run would total if this child spent its estimate.
  final double projectedRunCostUsd;

  @override
  String toString() =>
      'SpawnPermit(depth: $depth, subtree: $projectedSubtreeCostUsd, '
      'run: $projectedRunCostUsd)';
}

/// The spawn is refused, for exactly one [reason].
final class SpawnRefusal extends SpawnDecision {
  /// Records a refusal.
  const SpawnRefusal({required this.reason, required this.explanation});

  /// Which bound was hit.
  final RefusalReason reason;

  /// Why, in a sentence a model can act on.
  ///
  /// This string is what gets handed back as the deny reason, so it names the
  /// number that was hit and suggests what to do instead. A gate that blocks
  /// without explaining spends the turn and teaches the model nothing.
  ///
  /// Phrased **additively** — a statement of the bound plus an alternative,
  /// never "STOP" or "ignore your previous instruction". That phrasing rule is
  /// borrowed from INV11, where an override-shaped steer was refused outright
  /// as prompt injection while an additive one was acted on. The fixtures
  /// measured that for *steers*, not for deny reasons; this is the cautious
  /// carry-over, not an observed result about denials.
  final String explanation;

  @override
  String toString() => 'SpawnRefusal(${reason.wire}: $explanation)';
}
