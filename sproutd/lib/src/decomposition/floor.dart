/// Refusing to decompose — and counting the refusal, because nobody else will.
library;

import '../../policy.dart';
import 'decomposition.dart';
import 'estimate.dart';
import 'waves.dart';

/// Why sprout declined to build a tree.
///
/// A small, closed vocabulary with **no `other`**, for `RefusalReason`'s exact
/// reason: a refusal sprout cannot name is a refusal it cannot count, and by
/// INV8 an uncounted gate is indistinguishable from one that never ran.
///
/// Each reason is a property of the *proposal*, computed from what sprout
/// actually holds at decision time. None of them is a score. See
/// [DelegationFloor] for the long form of why that matters and what it means
/// this floor cannot catch.
enum FloorReason {
  /// The split has exactly one child, so nothing is split.
  ///
  /// Decidable without planning anything, and the only rule here that is
  /// arithmetic rather than a property of a layout: at one child the
  /// parallelism gained is exactly zero and the coordination paid is strictly
  /// positive, whatever the coefficients are. `docs/01-plan.md` §3's power law
  /// has exponent 1.724 and no free term — the cost of a hop is not something a
  /// second session amortises.
  singleChild('singleChild'),

  /// Nobody could estimate any child's file set, so every child is isolated.
  ///
  /// Mechanically this produces the same fully-serial layout as
  /// [noConcurrencyWon], and it is a separate reason because the *remedy* is
  /// different — estimate the file sets, rather than split on different files —
  /// and a refusal that names the wrong remedy costs the turn it was supposed
  /// to save.
  nothingEstimable('nothingEstimable'),

  /// The plan is fully serial: every wave holds one child.
  ///
  /// N sessions of coordination bought no concurrency at all, so the split is
  /// strictly worse than doing the work in the session that already has the
  /// context.
  noConcurrencyWon('noConcurrencyWon');

  const FloorReason(this.wire);

  /// The string used in logs, counters and anything persisted.
  ///
  /// Written out rather than derived from [name], as `RefusalReason.wire` and
  /// `NodeStatus.wire` are: renaming a Dart identifier must not silently
  /// rewrite a counter key something else is already reading.
  final String wire;
}

/// The answer to *should this task be decomposed at all?*
///
/// Sealed, and permission is a **value** rather than the absence of a refusal.
/// `SpawnDecision` makes the same choice for the same reason: a gate whose
/// success is silence cannot be told from a gate that never ran, so the
/// permitted path returns a [DelegationPermit] carrying the plan it decided
/// over and the numbers it decided on.
sealed class FloorDecision {
  const FloorDecision();

  /// Whether the parent should go ahead and decompose.
  bool get shouldDecompose => this is DelegationPermit;
}

/// Decompose. Here is the layout it was judged on.
///
/// Carries the [plan] rather than only saying yes, so the caller does not
/// re-run `planWaves` and get a second layout that was never the one admitted.
final class DelegationPermit extends FloorDecision {
  /// Records a decomposition worth building.
  const DelegationPermit(this.plan);

  /// The wave layout the floor judged, mode already applied.
  final WavePlan plan;

  /// How many waves the plan runs in. Strictly fewer than the child count —
  /// that is what [FloorReason.noConcurrencyWon] guarantees about a permit.
  int get waveCount => plan.waves.length;

  /// How many children run at the widest point of the plan.
  int get widestWave => plan.waves.fold(
    0,
    (w, wave) => wave.children.length > w ? wave.children.length : w,
  );

  @override
  String toString() =>
      'DelegationPermit(${plan.decomposition.children.length} children in '
      '$waveCount waves, widest $widestWave, ${plan.decomposition.mode.label})';
}

/// Do not decompose. Do the work in the session that already has the context.
final class DelegationRefusal extends FloorDecision {
  /// Records a refusal to decompose, for exactly one [reason].
  const DelegationRefusal({required this.reason, required this.explanation});

  /// Which rule fired.
  final FloorReason reason;

  /// Why, in a sentence the parent can act on.
  ///
  /// Phrased **additively** — the observation plus what to do instead, never
  /// "STOP" or "ignore your plan" — following `SpawnRefusal.explanation`, which
  /// carries that rule over from INV11. As there, the phrasing rule was
  /// measured for *steers* and not for refusals; this is the cautious
  /// carry-over rather than an observed result.
  final String explanation;

  @override
  String toString() => 'DelegationRefusal(${reason.wire}: $explanation)';
}

/// sprout's own tally of the decompositions it refused, by reason.
///
/// A parallel to `RefusalCounts` and here for the same measured reason. In
/// `docs/research/fixtures/phase0/streams/E.ndjson` a `PreToolUse` hook denied
/// an `Agent` call and all three of `subagent_stats.refused`'s counters stayed
/// `0`: **the platform counts only its own refusals.** A decision not to
/// decompose is even less visible than that — no tool call is ever made, so
/// there is not even a `permission_denials` entry to reconcile against. If
/// sprout does not write it down here, the cheapest win in the whole design is
/// one that leaves no trace of having happened.
final class FloorCounts {
  FloorCounts._(this._counts);

  /// A tally with every reason at zero.
  factory FloorCounts.zero() =>
      FloorCounts._({for (final r in FloorReason.values) r: 0});

  final Map<FloorReason, int> _counts;

  /// How many decompositions were refused for [reason].
  int operator [](FloorReason reason) => _counts[reason] ?? 0;

  /// How many decompositions were refused in total.
  int get total => _counts.values.fold(0, (sum, n) => sum + n);

  /// The tally, keyed by [FloorReason.wire], for logging or the store.
  ///
  /// Every reason is present even at zero, for `RefusalCounts.toWireMap`'s
  /// reason: a key that vanishes when its count is zero makes "never refused"
  /// and "not being counted" look the same.
  Map<String, int> toWireMap() => {
    for (final MapEntry(key: reason, value: count) in _counts.entries)
      reason.wire: count,
  };

  /// A read-only view of the counts.
  Map<FloorReason, int> get byReason => Map.unmodifiable(_counts);

  @override
  String toString() => 'FloorCounts(${toWireMap()})';
}

/// The delegation floor of `docs/01-plan.md` §3, as a gate that counts itself.
///
/// > Kim et al.: above ~**45%** single-agent baseline accuracy, adding agents
/// > produces *negative* returns; coordination turn-count scales as a power law
/// > in agent count with exponent **1.724** (doubling agents ≈ 3.3× the turns).
/// >
/// > So "just do it yourself" is a first-class branch and the **default for
/// > small tasks**. sprout decomposes only when the root task is plausibly
/// > beyond one session. This is the cheapest performance win in the whole
/// > design and it consists of *not* building a tree.
///
/// ## What this floor is NOT, and it is the important part
///
/// **It does not score the task, and it does not implement "plausibly beyond
/// one session."** Neither of §3's two numbers is available at decision time.
/// 45% is a *baseline accuracy on a benchmark* — it needs a labelled task set
/// and a measured single-agent run, and sprout has neither when a parent hands
/// it a proposal. 1.724 is an exponent on a cost sprout pays but does not
/// observe in advance. Turning either into a threshold over some proxy — file
/// count, task string length, child count — would manufacture a score and dress
/// a guess as evidence, which is INV7's failure (*a sum is not a distribution*)
/// and INV10's (*a control-plane fact is observed or it is not a fact*).
///
/// So there is deliberately **no task-size rule here**, and the gap is written
/// down as a finding rather than filled. See `docs/02-open-findings.md` F-28.
///
/// ## What it does instead
///
/// Every rule below is a property of the **proposal and its own layout** — all
/// of them things sprout genuinely holds, none of them a number anyone invented.
/// The argument is §3's, used in the direction it actually supports:
/// coordination is a real cost that scales superlinearly, so a split that buys
/// no concurrency is strictly worse than not splitting, no matter what the
/// task's difficulty turns out to be. That conclusion needs no accuracy
/// estimate, which is exactly why it is the one this floor is built on.
///
/// Checks run in a **fixed order** — [FloorReason.singleChild],
/// [FloorReason.nothingEstimable], [FloorReason.noConcurrencyWon] — so a
/// proposal that trips more than one always reports the same reason and a
/// refusal string is stable enough to assert on. `ContainmentPolicy.decide`
/// fixes its order for the same reason. The first two are strictly narrower
/// cases of the third; they come first because they name the remedy.
///
/// ## What it does not catch, per INV6
///
/// - **It cannot tell a task that is too small to be worth splitting from one
///   that is not.** A two-child split of a ten-minute job across two disjoint
///   files is permitted here and should probably not have been proposed. This
///   floor catches splits that are *structurally* pointless, not ones that are
///   *merely* not worth it. That is the F-28 gap and it is the larger half.
/// - **It weighs concurrency, not isolation.** §2.3's evidence for map (RAH
///   81→90%) is an accuracy gain from isolating context, not a speed gain, so a
///   map decomposition could in principle be worth running fully serially. It
///   is refused anyway: a map plan only goes serial when the policy's width is
///   1, and *"fan out wide"* is not available at width 1, so the gain that
///   evidence measures is not on the table either. Stated because a reader will
///   reach for the exception.
/// - **It says nothing about money.** Budget is `ContainmentGate`'s, judged
///   against a `SpendLedger` at spawn time. Duplicating it here would be a
///   second ceiling that drifts from the first.
/// - **A refused proposal is not a stopped one.** This is a value returning a
///   value. Nothing here prevents a caller from spawning anyway; INV14's
///   enforcement point is `ContainmentGate.admit`, before the process exists.
///   This floor is upstream advice with a counter, and the counter is what
///   makes taking the advice auditable.
///
/// ## Why it counts
///
/// The split between [policy] and [refusals] is `ContainmentGate`'s, kept
/// deliberately: the bounds are immutable inputs (INV9) and the tally is the
/// only thing that changes, so a caller holding a floor can ask it questions
/// and read its counts with no way to widen it. [decide] is **the only entry
/// point**, and it is the only thing that advances either counter — the rules
/// are private for that reason, so a decision nobody counted cannot be reached.
final class DelegationFloor {
  /// Wraps [policy] with a fresh, zeroed tally.
  ///
  /// The policy is here because the floor's central rule is a property of the
  /// *layout*, and a layout does not exist without the width bound the policy
  /// sets. The same policy must be used to plan the waves that are eventually
  /// run, or the floor judged a plan nobody executed.
  DelegationFloor(this.policy) : refusals = FloorCounts.zero();

  /// The bounds a plan is laid out against. Final, and immutable behind it.
  final ContainmentPolicy policy;

  /// What this floor has refused so far, by reason.
  ///
  /// Final: the tally can be read and advanced by [decide], but it cannot be
  /// swapped for a fresh one to make a run look clean.
  final FloorCounts refusals;

  /// How many decompositions this floor has permitted.
  ///
  /// The positive control INV8 asks for. A floor that has permitted nothing and
  /// refused nothing has not run, and without this number that state is
  /// indistinguishable from a run in which every proposal was sound.
  int get permitted => _permitted;
  int _permitted = 0;

  /// Decides [decomposition], counting the outcome either way.
  ///
  /// The only entry point. Everything it can answer is derived from the
  /// decomposition and the layout `planWaves` gives it — no clock, no ledger,
  /// no I/O — so the same proposal always gets the same answer.
  FloorDecision decide(Decomposition decomposition) {
    final decision = _judge(decomposition);
    switch (decision) {
      case DelegationPermit():
        _permitted++;
      case DelegationRefusal(:final reason):
        refusals._counts[reason] = refusals[reason] + 1;
    }
    return decision;
  }

  FloorDecision _judge(Decomposition decomposition) {
    final children = decomposition.children;
    if (children.length == 1) {
      return DelegationRefusal(
        reason: FloorReason.singleChild,
        explanation:
            'This splits into one child, which is a handoff rather than a '
            'split: it wins no concurrency and still pays for a session, a '
            'brief and a return. Do the work in this session — '
            'docs/01-plan.md §3 makes "just do it yourself" a first-class '
            'branch — or split it into children that can genuinely run at the '
            'same time.',
      );
    }

    if (children.every((c) => c.files is UnknownFiles)) {
      return DelegationRefusal(
        reason: FloorReason.nothingEstimable,
        explanation:
            'No estimate exists for any of these ${children.length} children, '
            'so every one collides with every other and the plan is '
            '${children.length} waves of one. Estimate the file sets and '
            'propose again, or do the work in this session.',
      );
    }

    final plan = planWaves(decomposition, policy: policy);
    if (plan.waves.length == children.length) {
      return DelegationRefusal(
        reason: FloorReason.noConcurrencyWon,
        explanation:
            'These ${children.length} children lay out into '
            '${plan.waves.length} waves of one, so the split runs exactly as '
            'serially as one session would and adds ${children.length} '
            'handoffs on top. Coordination scales as a power law in agent '
            'count (docs/01-plan.md §3, exponent 1.724); concurrency is the '
            'return that pays for it, and there is none here. Do the work in '
            'this session, or split it on file sets that do not overlap.',
      );
    }

    return DelegationPermit(plan);
  }

  @override
  String toString() =>
      'DelegationFloor($policy, permitted: $permitted, $refusals)';
}
