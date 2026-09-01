/// Deciding and *counting* — the half of containment the platform will not do.
library;

import 'containment_policy.dart';
import 'refusal.dart';

/// sprout's own tally of the spawns it refused, by reason.
///
/// This exists because of INV14, and the reason is observed rather than
/// theoretical. In `docs/research/fixtures/phase0/streams/E.ndjson` a
/// `PreToolUse` hook denied an `Agent` call; the model received the reason and
/// adapted without retrying; `subagent_stats.spawned` stayed `0` — and all
/// three of `subagent_stats.refused`'s counters (`depth_limit`,
/// `concurrency_limit`, `budget`) **also stayed `0`**, with the denial visible
/// only as one entry in `result.permission_denials`. The platform counts only
/// its own refusals. A refusal sprout issues is invisible to sprout unless
/// sprout writes it down here, and by INV8 an uncounted gate is
/// indistinguishable from a gate that never ran.
///
/// Related trap, from INV10's corollary: the spawn tool is named `Agent` in
/// `system/init` and in `PreToolUse.tool_name`, but `Task` in
/// `permission_denials[].tool_name` — E's denial entry says `Task`. Anything
/// reconciling this tally against the platform's has to match both names.
final class RefusalCounts {
  RefusalCounts._(this._counts);

  /// A tally with every reason at zero.
  factory RefusalCounts.zero() =>
      RefusalCounts._({for (final r in RefusalReason.values) r: 0});

  final Map<RefusalReason, int> _counts;

  /// How many spawns were refused for [reason].
  int operator [](RefusalReason reason) => _counts[reason] ?? 0;

  /// How many spawns were refused in total.
  int get total => _counts.values.fold(0, (sum, n) => sum + n);

  /// The tally, keyed by [RefusalReason.wire], for logging or the store.
  ///
  /// Every reason is present even at zero. A key that vanishes when its count
  /// is zero makes "never refused" and "not being counted" look the same, which
  /// is the exact confusion this class exists to prevent.
  Map<String, int> toWireMap() => {
    for (final MapEntry(key: reason, value: count) in _counts.entries)
      reason.wire: count,
  };

  /// A read-only view of the counts.
  Map<RefusalReason, int> get byReason => Map.unmodifiable(_counts);

  @override
  String toString() => 'RefusalCounts(${toWireMap()})';
}

/// A [ContainmentPolicy] together with the record of what it has refused.
///
/// The split is deliberate. The policy is immutable — its bounds are inputs to
/// the run and nothing in this API can raise them mid-run (INV9). The tally is
/// the only thing here that changes, and it only ever goes up. A caller holding
/// a gate can ask it questions and read its counts; it has no way to widen it.
final class ContainmentGate {
  /// Wraps [policy] with a fresh, zeroed tally.
  ContainmentGate(this.policy) : refusals = RefusalCounts.zero();

  /// The bounds. Final, and the object behind it is immutable.
  final ContainmentPolicy policy;

  /// What this gate has refused so far, by reason.
  ///
  /// Final: the tally can be read and it can be advanced by [admit], but it
  /// cannot be swapped for a fresh one to make a run look clean.
  final RefusalCounts refusals;

  /// How many spawns this gate has permitted.
  ///
  /// The positive control INV8 asks for. A gate that has permitted nothing and
  /// refused nothing has not run; without this number that state is
  /// indistinguishable from a run in which nothing needed refusing.
  int get permitted => _permitted;
  int _permitted = 0;

  /// Decides [request], counting the outcome either way.
  ///
  /// The only entry point the runner should use. Calling
  /// [ContainmentPolicy.decide] directly is a decision nobody counted.
  SpawnDecision admit(SpawnRequest request) {
    final decision = policy.decide(request);
    switch (decision) {
      case SpawnPermit():
        _permitted++;
      case SpawnRefusal(:final reason):
        refusals._counts[reason] = refusals[reason] + 1;
    }
    return decision;
  }

  @override
  String toString() =>
      'ContainmentGate($policy, permitted: $permitted, $refusals)';
}
