/// Deciding and *counting* — one check, at one moment, against one brief.
library;

import 'package:sproutd/decomposition.dart';

import 'condition_runner.dart';
import 'outcome.dart';

/// sprout's own tally of the acceptance checks it has made, by outcome.
///
/// INV14's shape, and for INV14's measured reason: in
/// `docs/research/fixtures/phase0/streams/E.ndjson` a `PreToolUse` hook denied
/// an `Agent` call and all three of the platform's own `subagent_stats.refused`
/// counters stayed `0` — **the platform counts only its own refusals.** An
/// acceptance check makes no tool call at all, so nothing outside sprout could
/// ever see it happen; a check sprout does not count is one that is
/// indistinguishable from a check that never ran (INV8).
///
/// [accepted] is the positive control the same invariant asks for. A tally
/// showing no rejections is meaningless without it: zero refusals and zero
/// judgements look identical, and only one of them is a working gate.
final class AcceptanceCounts {
  AcceptanceCounts._(this._rejected, this._undecidable);

  /// A tally with every outcome at zero.
  factory AcceptanceCounts.zero() => AcceptanceCounts._(
    {for (final r in RejectionReason.values) r: 0},
    {for (final r in UndecidableReason.values) r: 0},
  );

  final Map<RejectionReason, int> _rejected;
  final Map<UndecidableReason, int> _undecidable;

  /// How many children were accepted.
  int get accepted => _accepted;
  int _accepted = 0;

  /// How many were rejected for [reason].
  int rejected(RejectionReason reason) => _rejected[reason] ?? 0;

  /// How many were undecidable for [reason].
  int undecidable(UndecidableReason reason) => _undecidable[reason] ?? 0;

  /// How many were rejected, for any reason.
  int get rejectedTotal => _rejected.values.fold(0, (sum, n) => sum + n);

  /// How many were undecidable, for any reason.
  int get undecidableTotal => _undecidable.values.fold(0, (sum, n) => sum + n);

  /// How many judgements have been made at all.
  int get total => accepted + rejectedTotal + undecidableTotal;

  /// The tally, for a log or an event payload.
  ///
  /// Every key is present even at zero, on `RefusalCounts.toWireMap`'s
  /// argument: a key that vanishes when its count is zero makes "never
  /// happened" and "not being counted" look the same, which is the confusion
  /// this class exists to prevent. Reasons are namespaced by outcome so that a
  /// rejection reason and an undecidable reason can never collide on one key.
  Map<String, int> toWireMap() => {
    'accepted': accepted,
    for (final MapEntry(key: reason, value: count) in _rejected.entries)
      'rejected.${reason.wire}': count,
    for (final MapEntry(key: reason, value: count) in _undecidable.entries)
      'undecidable.${reason.wire}': count,
  };

  @override
  String toString() => 'AcceptanceCounts(${toWireMap()})';
}

/// The parent's per-return acceptance check, against the brief it wrote.
///
/// `docs/01-plan.md` §5 puts this in the node lifecycle: *"… → parent
/// acceptance check against the brief it wrote → close with a real artifact"*.
/// §2.5 says what it deliberately is **not**:
///
/// > DELEGATE-52's mechanical detail: degradation is sparse and catastrophic,
/// > not diffuse — models hold near-perfect reconstruction then lose 10–30
/// > points in a single round trip, and these sparse failures explain ~80% of
/// > total degradation.
/// >
/// > **Decision:** no trend gauge. A per-return acceptance check by the parent,
/// > against the brief it wrote. Monitoring trends would mostly display noise
/// > and miss the actual failures.
///
/// So there is no score here, no rolling average, and nothing to plot. One
/// check, at one moment — the child's return — against the **specific**
/// [SuccessCondition]s that child's own brief carried.
///
/// **[judge] is the only entry point.** It answers *and* records, on
/// `ContainmentGate.admit`'s exact shape: running a condition without going
/// through it is a judgement nobody counted, which INV8 makes
/// indistinguishable from a check that never ran.
///
/// ## The order, and why it is fixed
///
/// 1. The **return** first — did the child answer, and had its subtree
///    drained. Both are facts the runner already established, both are free,
///    and running a verifier over the workspace of a session that has not
///    finished reports on a moving target.
/// 2. Then every declared condition, in the order the brief declared them,
///    stopping at the first that decides. A condition that **could not be run**
///    ends the check as undecidable; a condition that ran and failed ends it as
///    rejected.
/// 3. Accepted only when every condition ran and passed.
///
/// Ties are broken by that order and it is asserted in the suite, because an
/// order that is merely emergent is one a refactor can reverse without any
/// test noticing.
///
/// ## What is deliberately not here
///
/// **No LLM critic, in any position.** §2.4 measured a self-critiquing GPT-4 at
/// 55/100 against an external sound verifier's 88/100, with a **38%
/// false-positive rate on approve**, and decided: *"an LLM critic is weak
/// evidence, never a gate, and never the same model that produced the
/// artifact."* §14.7 refines it — the 55% figure measured spec-free critics and
/// test-aware ones score 86–93%, so *"hand every critic a spec, or don't run
/// it"* — which is an argument for a critic that reads the condition, still
/// beside the result and never in place of it. This type has no field for one
/// because nothing in this build produces one, and an unused field with no
/// producer is a decision made by whoever eventually guesses at it.
///
/// **No branch for a child with no conditions.** [judge] throws on an empty
/// list rather than inventing an outcome for it, and that is not a formality:
/// `PlannedChild`'s constructor already refuses a child that declares none, so
/// an *outcome* arm for the empty case would be an arm no plan could reach —
/// the shape `.showrunner/p4-05-mutations.md` records, where a guard's two arms
/// are separated by a condition an earlier constructor already made impossible
/// and its own tests cannot say so. A throw is reachable from any caller, and
/// the suite reaches it.
///
/// **Nothing here acts.** [judge] runs the declared commands and answers. It
/// does not tear a worktree down, does not merge, does not close a node and
/// does not authorize anything: §6's *"a brief is not a human"* means a
/// parent's judgement of a child can never grant what only the developer can.
/// The caller decides what an acceptance is worth — `bin/sprout.dart` offers an
/// accepted child's worktree for teardown, and the teardown still refuses when
/// removing it would lose work.
final class AcceptanceCheck {
  /// Creates a check with a fresh, zeroed tally.
  AcceptanceCheck({this.runner = const ProcessConditions()})
    : counts = AcceptanceCounts.zero();

  /// Runs a declared condition. Replaced in tests that need an outcome a real
  /// command would be awkward to stage — never to replace the real one in the
  /// tests that prove the check itself (INV8).
  final ConditionRunner runner;

  /// What this check has answered so far, by outcome.
  ///
  /// Final: the tally can be read and it can be advanced by [judge], but it
  /// cannot be swapped for a fresh one to make a run look clean.
  final AcceptanceCounts counts;

  /// Judges [returned] against [conditions], counting the outcome either way.
  ///
  /// [workspace] is where the conditions run — the child's own project
  /// directory, which is its worktree when it had one. A
  /// [SuccessCondition.workingDirectory] is resolved beneath it.
  ///
  /// Throws [ArgumentError] if [conditions] is empty. §2.4 says every leaf
  /// **must** declare a machine-checkable success condition, and a check that
  /// answered "accepted" for a child that declared none would be exactly the
  /// silent pass that requirement exists against.
  Future<AcceptanceOutcome> judge({
    required ChildReturn returned,
    required List<SuccessCondition> conditions,
    required String workspace,
  }) async {
    if (conditions.isEmpty) {
      throw ArgumentError.value(
        conditions,
        'conditions',
        'is empty. docs/01-plan.md §2.4: every leaf must declare a '
            'machine-checkable success condition, so there is nothing here to '
            'check and "accepted" would be a verdict sprout never reached',
      );
    }
    final outcome = await _judge(returned, conditions, workspace);
    switch (outcome) {
      case ChildAccepted():
        counts._accepted++;
      case ChildRejected(:final reason):
        counts._rejected[reason] = counts.rejected(reason) + 1;
      case AcceptanceUndecidable(:final reason):
        counts._undecidable[reason] = counts.undecidable(reason) + 1;
    }
    return outcome;
  }

  Future<AcceptanceOutcome> _judge(
    ChildReturn returned,
    List<SuccessCondition> conditions,
    String workspace,
  ) async {
    // INV12, and it is checked before anything is run rather than after: "the
    // parent finished" is not "the subtree finished", and neither is the exit
    // code. `exitCode` is carried in the payload and is never read here.
    if (!returned.answered) {
      return ChildRejected(
        returned: returned,
        conditions: const [],
        reason: RejectionReason.noResult,
        explanation:
            'the session ended with no result frame, so it died before '
            'answering (exit ${returned.exitCode})',
      );
    }
    if (!returned.drained) {
      return ChildRejected(
        returned: returned,
        conditions: const [],
        reason: RejectionReason.subtreeNotDrained,
        explanation:
            '${returned.incompleteSubagents} subagent(s) had not completed '
            'when the process ended, so the subtree the child answered for was '
            'still running',
      );
    }

    final runs = <ConditionRun>[];
    for (final condition in conditions) {
      final run = await runner.run(condition, workspace: workspace);
      runs.add(run);
      switch (run) {
        case ConditionCouldNotRun(:final why):
          return AcceptanceUndecidable(
            returned: returned,
            conditions: List.unmodifiable(runs),
            reason: UndecidableReason.conditionUnrunnable,
            explanation: 'could not run $condition: $why',
          );
        case ConditionRan(:final exitCode) when exitCode != 0:
          return ChildRejected(
            returned: returned,
            conditions: List.unmodifiable(runs),
            reason: RejectionReason.conditionFailed,
            explanation: run.label,
          );
        case ConditionRan():
          continue;
      }
    }
    return ChildAccepted(
      returned: returned,
      conditions: List.unmodifiable(runs),
    );
  }

  @override
  String toString() => 'AcceptanceCheck($counts)';
}
