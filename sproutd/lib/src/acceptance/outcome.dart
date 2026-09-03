/// What a child returned, and the three answers a parent may give about it.
library;

import 'package:sprout_protocol/values.dart';
import 'package:sproutd/runner.dart';

import 'condition_runner.dart';

/// The facts about a finished child that an acceptance check is allowed to
/// judge on.
///
/// **A projection of [EndedSession], never a re-derivation of it.**
/// [ChildReturn.of] copies three fields the runner already computed; nothing
/// here re-reads a transcript or recounts a subtree. Re-deriving them would be
/// two derivations of one rule that agree today (F-01's shape), and the runner
/// is the half that owns the stream.
///
/// It is a separate value rather than the session itself for one reason that is
/// about the check and not about tidiness: `EndedSession`'s constructor is
/// private, so a suite that judged sessions directly could only reach a
/// *drained* one by replaying a capture that happens to contain one. The three
/// arms of the check have to be reachable from a constructible input or they
/// are arms nothing exercises — which is exactly the failure P4-05 recorded in
/// `.showrunner/p4-05-mutations.md`, one library over.
final class ChildReturn {
  /// Records what a child returned.
  const ChildReturn({
    required this.nodeId,
    required this.exitCode,
    required this.hasResult,
    required this.incompleteSubagents,
  });

  /// Reads it off a session the runner finished.
  factory ChildReturn.of(EndedSession ended) => ChildReturn(
    nodeId: ended.nodeId,
    exitCode: ended.exitCode,
    hasResult: ended.hasResult,
    incompleteSubagents: ended.incompleteTasks.length,
  );

  /// sprout's id for the child.
  final String nodeId;

  /// The process exit code. **Carried and never branched on** — see
  /// [answered].
  final int exitCode;

  /// Whether any `result` frame arrived before the process ended.
  final bool hasResult;

  /// Subagents whose last seen status was not `completed` when the process
  /// ended: the part of the subtree that had not drained (INV12).
  final int incompleteSubagents;

  /// Whether the child answered at all.
  ///
  /// This, and not [exitCode], is what "the session finished" means here.
  /// INV12, quoting `EndedSession`'s own doc: *"a zero exit with `hasResult`
  /// false is a session that died before answering; a non-zero exit after two
  /// results is a run that answered twice and then was killed. Neither is
  /// 'done' or 'failed' on the exit code alone."*
  bool get answered => hasResult;

  /// Whether the child's subtree had drained when its process ended.
  ///
  /// **What this does not catch,** per INV6: `TaskLifecycles` also tracks
  /// `backgroundTasks`, the full restatement of what is still running, and
  /// `EndedSession` does not expose it. A grandchild that was launched async
  /// and never mentioned in a `system/task_*` frame is invisible here. The
  /// remedy is a field on `EndedSession`, not a second count taken in this
  /// library from the transcript — that is the re-derivation this value exists
  /// to avoid.
  bool get drained => incompleteSubagents == 0;

  /// These facts as part of an event payload.
  Map<String, Object?> toJson() => {
    'node_id': nodeId,
    'exit_code': exitCode,
    'has_result': hasResult,
    'incomplete_subagents': incompleteSubagents,
  };

  @override
  String toString() =>
      'ChildReturn($nodeId, exit $exitCode, '
      'result ${hasResult ? 'yes' : 'no'}, '
      '$incompleteSubagents incomplete)';
}

/// Why a parent said no, having looked.
///
/// Every reason here is something sprout **observed**. A reason for something
/// sprout could not observe belongs on [UndecidableReason], and the two are
/// separate enums so that the distinction cannot be lost by adding a value to
/// the wrong one.
enum RejectionReason {
  /// A declared success condition ran and exited non-zero.
  ///
  /// The gate `docs/01-plan.md` §2.4 argues for: an external verifier scored
  /// 88/100 against a self-critiquing model's 55/100, and the critic approved
  /// wrongly 38% of the time.
  conditionFailed('conditionFailed'),

  /// The child's process ended without ever emitting a `result` frame.
  ///
  /// It died before answering. Accepting on the exit code alone is the exact
  /// mistake INV12 names.
  noResult('noResult'),

  /// The child answered, but subagents beneath it had not finished.
  ///
  /// *"The parent finished" is not "the subtree finished"* (INV12). Observed
  /// in `fixtures/phase0/streams/B.ndjson`: a subagent answered and stopped
  /// while its own child was still running, and that child's result was
  /// delivered two levels up, to the root.
  subtreeNotDrained('subtreeNotDrained');

  const RejectionReason(this.wire);

  /// The string used in explanations and anything persisted. Written out
  /// rather than derived from [name], on `NodeStatus.wire`'s reason: these go
  /// into an append-only `kind` payload with no rewrite path.
  final String wire;
}

/// Why a parent could not decide at all.
///
/// One value, and it is one value because only one of these has ever been
/// observed: a command sprout was handed and could not execute. A second
/// reason is owed the same evidence — INV4, no gate without a logged, observed
/// failure — so this stays an enum rather than a bare flag to leave room for
/// one, not because a second is expected.
enum UndecidableReason {
  /// A declared condition could not be run: no such executable, no such
  /// working directory, the fork failed.
  ///
  /// *"A pass that is silence proves nothing on its own"* (INV8). There is no
  /// exit code here to be lenient or strict about; there is no exit code.
  conditionUnrunnable('conditionUnrunnable');

  const UndecidableReason(this.wire);

  /// The string used in explanations and anything persisted.
  final String wire;
}

/// A parent's answer about one child, as a value.
///
/// **Three arms, and *undecidable* is not a variety of rejected.** A condition
/// sprout could not evaluate proves nothing in either direction, and a check
/// that folded it into "rejected" would be reporting a judgement it never made
/// — while one that folded it into "accepted" would be the silent pass INV8 is
/// about. The same line `WorktreeUnreadable` draws against `WorktreeObserved`,
/// and `UnknownFiles` against `TouchesNothing`, one library over each.
///
/// Sealed and a value, not a bool and not a throw: rejection is an *expected*
/// outcome, and an expected outcome delivered as an exception is one a caller
/// eventually wraps in a bare `catch`.
sealed class AcceptanceOutcome {
  const AcceptanceOutcome({required this.returned, required this.conditions});

  /// What the child returned, as the check saw it.
  final ChildReturn returned;

  /// Every condition that was actually attempted, in the order declared.
  ///
  /// **Empty when the return itself decided the answer.** A child that never
  /// produced a result is rejected before any command is run, because running
  /// a verifier over the workspace of a session that is still draining reports
  /// on a moving target.
  final List<ConditionRun> conditions;

  /// The child this is about.
  String get nodeId => returned.nodeId;

  /// The feed kind this outcome is appended under.
  ///
  /// On the outcome rather than at the call site, and the strings themselves
  /// live in `package:sprout_protocol`. That is findings F-11 and F-12, each of
  /// which cost a leaf to undo: a `kind` spelled where it is written is a
  /// second declaration of wire vocabulary the browser also reads.
  String get kind;

  /// Whether the child's work was accepted.
  bool get isAccepted => this is ChildAccepted;

  /// Why, in a sentence a human can act on.
  String get explanation;

  /// The one-line rendering, for an operator watching a run.
  String get label;

  /// This outcome as an event payload.
  Map<String, Object?> toJson() => {
    'returned': returned.toJson(),
    'conditions': [for (final run in conditions) run.toJson()],
  };
}

/// Every declared condition passed, and the child had really finished.
final class ChildAccepted extends AcceptanceOutcome {
  /// Records an acceptance.
  const ChildAccepted({required super.returned, required super.conditions});

  @override
  String get kind => acceptanceAcceptedKind;

  @override
  String get explanation =>
      '${conditions.length} condition(s) passed; the child answered and its '
      'subtree had drained';

  @override
  String get label => 'accepted ${returned.nodeId}: $explanation';

  @override
  String toString() => 'ChildAccepted($label)';
}

/// sprout looked, and the answer was no.
final class ChildRejected extends AcceptanceOutcome {
  /// Records a rejection.
  const ChildRejected({
    required super.returned,
    required super.conditions,
    required this.reason,
    required this.explanation,
  });

  /// Which of the three.
  final RejectionReason reason;

  @override
  final String explanation;

  @override
  String get kind => acceptanceRejectedKind;

  @override
  String get label =>
      'rejected ${returned.nodeId} (${reason.wire}): '
      '$explanation';

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'reason': reason.wire,
    'explanation': explanation,
  };

  @override
  String toString() => 'ChildRejected($label)';
}

/// sprout could not evaluate the condition it was given.
///
/// Not an acceptance, not a rejection, and never quietly either.
final class AcceptanceUndecidable extends AcceptanceOutcome {
  /// Records that the check could not be made.
  const AcceptanceUndecidable({
    required super.returned,
    required super.conditions,
    required this.reason,
    required this.explanation,
  });

  /// Which of the — currently one — reasons.
  final UndecidableReason reason;

  @override
  final String explanation;

  @override
  String get kind => acceptanceUndecidableKind;

  @override
  String get label =>
      'undecidable ${returned.nodeId} (${reason.wire}): '
      '$explanation';

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'reason': reason.wire,
    'explanation': explanation,
  };

  @override
  String toString() => 'AcceptanceUndecidable($label)';
}
