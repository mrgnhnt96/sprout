/// What the watchdog treats as a contradiction — and what it refuses to.
library;

import '../../liveness.dart';

/// The two verdicts that are contradictions, and so the only two that ring.
///
/// **The definition, stated so it can be disagreed with.** `docs/01-plan.md`
/// §11 says the watchdog is *"contradiction-triggered"* and does not define
/// the word, so this is the leaf's call:
///
/// > A **contradiction** is a node whose *recorded* state and whose *observed*
/// > state cannot both be true. The tree says the node is working; the
/// > measurement taken from outside it says nothing is working.
///
/// Which is exactly what [Liveness.stalled] and [Liveness.abandoned] already
/// mean, because [LivenessMeasure] only reaches them for a node that recorded
/// no ending:
///
/// - **abandoned** — the tree holds a `runner.spawned` and no ending, and no
///   process is there. Recorded *running*, observed *gone*.
/// - **stalled** — the pid is alive and start-time-verified, and neither its
///   transcript nor any descendant's has grown past the freeze threshold.
///   Recorded *advancing*, observed *advancing nowhere*.
///
/// The three that are **not** contradictions, each for its own reason:
///
/// - [Liveness.live] — recorded and observed agree, including the waiting
///   case, where the node is frozen and a descendant is not.
/// - [Liveness.ended] — the node reached one of §5's endings, so there is no
///   claim left to contradict.
/// - [Liveness.unmeasured] — **nothing was observed**, so there is nothing for
///   the record to contradict. See [Blindness].
///
/// **What this deliberately excludes is a trend.** §2.5 rejected *"a drift
/// dashboard → per-hop gates"* and §12 warns that *"monitoring trends would
/// mostly display noise and miss the actual failures"*. So the watchdog never
/// rings on a rate, a slope, a budget burning down, or an elapsed timer on its
/// own. A timer decides *when to look*; only a contradiction decides whether
/// to ring.
const Set<Liveness> ringingVerdicts = {Liveness.stalled, Liveness.abandoned};

/// A node whose recorded state and observed state cannot both be true.
final class Contradiction {
  /// Wraps [verdict], which must be one of [ringingVerdicts].
  Contradiction(this.verdict)
    : assert(
        ringingVerdicts.contains(verdict.liveness),
        'only stalled and abandoned are contradictions',
      );

  /// The measurement this was drawn from, with all of its evidence.
  final LivenessVerdict verdict;

  /// The node the tree and the world disagree about.
  String get nodeId => verdict.nodeId;

  /// Which contradiction it is: [Liveness.stalled] or [Liveness.abandoned].
  Liveness get liveness => verdict.liveness;

  /// The measurement's own sentence, carried through to the human unedited.
  String get because => verdict.because;

  /// The freshness reference the ring is judged productive against.
  ///
  /// The transcript mtime, or the spawn time when nothing has been written
  /// yet. Null for a node whose process was never found, which has no
  /// freshness to move — such a node's ring count resets only when the
  /// contradiction itself clears. See `RingLedger`.
  DateTime? get mark => verdict.lastWrite;

  @override
  String toString() => 'Contradiction(${verdict.nodeId}: ${liveness.wire})';
}

/// A node the measurement could not look at.
///
/// Kept as its own kind, and never folded into [Contradiction], because the
/// two carry opposite information. A contradiction is something the watchdog
/// saw. Blindness is something it did not see, and *"a failed read is not a
/// fact about the world"* — a `ps` that could not run is not evidence a
/// process is gone.
///
/// **It never rings, and it is never counted healthy.** Both halves matter and
/// they pull in opposite directions:
///
/// - Not rung, because there is no contradiction to ring about. A watchdog
///   that pages every time `ps` is missing is muted within a day.
/// - Not healthy, because a sweep that could not see half the tree and reports
///   "nothing to ring" is the blind watchdog reporting green — the exact
///   failure `docs/01-plan.md` §1 was written about. So every blind node is
///   named in the sweep record and in its `why`, and `SweepRecord` offers no
///   `healthy` getter for a caller to read the silence as one.
///
/// **This disagrees with `Liveness.pages`, on purpose.** P6-01 shipped
/// `Liveness.pages` returning true for [Liveness.unmeasured]. Nothing consumed
/// it; this is the first consumer, and it does not use it. Recorded as F-13 in
/// `docs/02-open-findings.md` so the disagreement is visible rather than
/// silent.
final class Blindness {
  /// Wraps an [Liveness.unmeasured] verdict.
  Blindness(this.verdict)
    : assert(
        verdict.liveness == Liveness.unmeasured,
        'blindness is unmeasured and nothing else',
      );

  /// The measurement that failed, carrying why it failed.
  final LivenessVerdict verdict;

  /// The node that could not be looked at.
  String get nodeId => verdict.nodeId;

  /// What went wrong, in the measurement's own words.
  String get because => verdict.because;

  @override
  String toString() => 'Blindness(${verdict.nodeId}: ${verdict.because})';
}
