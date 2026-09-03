/// A parent that has decided to split a task, as a value.
library;

import 'estimate.dart';

/// One machine-checkable condition a planned child must satisfy to be accepted.
///
/// `docs/01-plan.md` §2.4 is the reason this is a required, structured field
/// rather than a sentence: Blocksworld scored 40/100 with no verification,
/// 55/100 with GPT-4 critiquing itself, and **88/100 with an external sound
/// verifier** — and the critic approved wrongly **38%** of the time. The
/// decision it argues to is *"every leaf must declare a machine-checkable
/// success condition (tests, build, analyzer, diff applies). An LLM critic is
/// weak evidence, never a gate."*
///
/// So the field is an **argv and a directory**, not prose. A model cannot
/// satisfy this type by writing "the tests should pass"; it has to name a
/// command something can run and read an exit code from. That is the
/// difference between a condition and an intention, and it is enforced in the
/// constructor rather than checked later, because a check that runs later runs
/// after a child has already been spawned against an unverifiable brief.
///
/// argv rather than a shell line on purpose. `.game_loop/verify.yaml` writes
/// its checks as `cd sproutd && dart test`, which needs a shell to run and a
/// shell to parse; splitting the `cd` out into [workingDirectory] leaves a
/// command that can be handed to `Process.run` with no interpreter between the
/// declaration and what executes. An interpreter in that gap is finding F-08 in
/// a different costume.
///
/// **Evaluating these is P4-06's**, not this library's. This is the field it
/// reads.
final class SuccessCondition {
  /// Records a condition, as the argv of a command and where to run it.
  ///
  /// Throws [ArgumentError] if [command] is empty or its executable is blank —
  /// an empty argv is a condition that cannot fail, and a condition that cannot
  /// fail is the shape `.game_loop/verify.yaml` opens by warning about.
  factory SuccessCondition(List<String> command, {String? workingDirectory}) {
    if (command.isEmpty || command.first.trim().isEmpty) {
      throw ArgumentError.value(
        command,
        'command',
        'names no executable. A success condition has to be something a '
            'machine can run and read an exit code from',
      );
    }
    return SuccessCondition._(
      List.unmodifiable(command),
      workingDirectory?.trim().isEmpty ?? true
          ? null
          : workingDirectory!.trim(),
    );
  }

  const SuccessCondition._(this.command, this.workingDirectory);

  /// The command and its arguments. Never empty.
  final List<String> command;

  /// Where to run it, relative to the repository root, or null for the root.
  final String? workingDirectory;

  @override
  String toString() => workingDirectory == null
      ? command.join(' ')
      : '($workingDirectory) ${command.join(' ')}';
}

/// One child a parent plans to spawn: the task, the blast radius, the gate.
///
/// A value, not a handle — no process, no store, no clock — for the reason
/// `lib/policy.dart` gives about its own area: it is what makes the thing
/// testable enough to be trusted. Nothing in this library spawns anything.
///
/// **There is deliberately no `mode` field here.** map versus build
/// (`docs/01-plan.md` §2.3) and the delegation floor (§3) are P4-05's leaf, and
/// an unused field with no producer is a decision made by whoever eventually
/// guesses at it. The seam is this sentence.
final class PlannedChild {
  /// Records a planned child.
  ///
  /// Throws [ArgumentError] if [id] or [task] is blank, if
  /// [successConditions] is empty, or if [estimatedCostUsd] is negative.
  ///
  /// The empty-conditions case is the one worth naming: §2.4 says every leaf
  /// **must** declare a machine-checkable success condition, and a `must` that
  /// a later check complains about is a `should`. A child with no condition is
  /// a thing this type refuses to hold.
  factory PlannedChild({
    required String id,
    required String task,
    required FileEstimate files,
    required List<SuccessCondition> successConditions,
    double? estimatedCostUsd,
  }) {
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'is blank');
    }
    if (task.trim().isEmpty) {
      throw ArgumentError.value(
        task,
        'task',
        'is blank. The task is the prompt the child is given, in the parent\'s '
            'own words',
      );
    }
    if (successConditions.isEmpty) {
      throw ArgumentError.value(
        successConditions,
        'successConditions',
        'is empty. docs/01-plan.md §2.4: every leaf must declare a '
            'machine-checkable success condition — tests, build, analyzer, '
            'diff applies. An LLM critic is weak evidence, never a gate',
      );
    }
    if (estimatedCostUsd != null && estimatedCostUsd < 0) {
      throw ArgumentError.value(
        estimatedCostUsd,
        'estimatedCostUsd',
        'is negative',
      );
    }
    return PlannedChild._(
      trimmedId,
      task.trim(),
      files,
      List.unmodifiable(successConditions),
      estimatedCostUsd,
    );
  }

  const PlannedChild._(
    this.id,
    this.task,
    this.files,
    this.successConditions,
    this.estimatedCostUsd,
  );

  /// A stable name for this child within its decomposition.
  ///
  /// Not a sprout node id — nothing has been spawned. It is what a wave layout
  /// prints and what the planner orders by, so it has to be stable and unique
  /// within one [Decomposition], which that class enforces.
  final String id;

  /// The prompt the child will be given, in the parent's own words.
  final String task;

  /// What it is expected to touch, or that nobody could say.
  final FileEstimate files;

  /// What must pass, mechanically, for the child's work to be accepted.
  ///
  /// Never empty. P4-06 evaluates these against what the child returned; this
  /// leaf only guarantees there is something to evaluate.
  final List<SuccessCondition> successConditions;

  /// What this child is expected to cost, in dollars, or **null for unknown**.
  ///
  /// Nullable rather than defaulting to 0, and this is the same trap as
  /// [FileEstimate] wearing different clothes. `SpawnRequest.estimatedCostUsd`
  /// defaults to 0 and documents why that is right *there* — it makes the
  /// budget check ask "has this subtree already blown its ceiling?" rather than
  /// "would it?", which errs toward refusing, and F-23 confirms a refusal on
  /// budget is the sound half of that gate.
  ///
  /// A **plan** errs the other way. A decomposition that carries 0 for a child
  /// nobody costed adds up to a total that reads as an estimate and is not one:
  /// that is F-23 exactly, and INV7 — a sum is not a distribution. So the
  /// unknown is kept as a third value here and collapsed to 0 only at the
  /// boundary where a `SpawnRequest` is built, where erring low means erring
  /// toward the check that binds. See [Decomposition.knownEstimatedCostUsd],
  /// which cannot be read without also reading how many children are missing.
  final double? estimatedCostUsd;

  @override
  String toString() => 'PlannedChild($id: ${files.label})';
}

/// A parent's decision to split a task, and the children it plans to spawn.
///
/// Immutable, ordered, and pure. The order of [children] is the parent's own
/// and is preserved everywhere downstream, because a plan whose output depends
/// on map iteration order is one nobody can diff.
///
/// **A decomposition always has at least one child.** "Do it yourself" is a
/// first-class branch — `docs/01-plan.md` §3 calls it the default for small
/// tasks and *"the cheapest performance win in the whole design"* — but it is
/// not a decomposition with zero children, it is the absence of one. Refusing
/// the empty case here is what keeps that seam visible for P4-05, which owns
/// the floor; representing it as an empty list would let a caller "decompose"
/// into nothing and get a plan back that runs no work and says nothing is
/// wrong.
final class Decomposition {
  /// Records a parent's decision to split [task] into [children].
  ///
  /// Throws [ArgumentError] on a blank parent id or task, an empty child list,
  /// or two children sharing an id. The duplicate case is `SpendLedger.of`'s
  /// reasoning: a plan that names two different children the same thing cannot
  /// be reported on, and a corrupt input stops the run loudly rather than being
  /// quietly interpreted.
  factory Decomposition({
    required String parentId,
    required String task,
    required List<PlannedChild> children,
  }) {
    final trimmedParent = parentId.trim();
    if (trimmedParent.isEmpty) {
      throw ArgumentError.value(parentId, 'parentId', 'is blank');
    }
    if (task.trim().isEmpty) {
      throw ArgumentError.value(task, 'task', 'is blank');
    }
    if (children.isEmpty) {
      throw ArgumentError.value(
        children,
        'children',
        'is empty. Not decomposing is a decision (docs/01-plan.md §3), not a '
            'decomposition into nothing',
      );
    }
    final seen = <String>{};
    for (final child in children) {
      if (!seen.add(child.id)) {
        throw ArgumentError.value(child.id, 'children', 'duplicate child id');
      }
    }
    return Decomposition._(
      trimmedParent,
      task.trim(),
      List.unmodifiable(children),
    );
  }

  const Decomposition._(this.parentId, this.task, this.children);

  /// The node doing the splitting.
  final String parentId;

  /// The task being split, in the parent's own words.
  final String task;

  /// The children, in the parent's order. Never empty, ids unique.
  final List<PlannedChild> children;

  /// The children nobody could estimate a file set for, in order.
  ///
  /// Each of these costs a whole wave. Exposed so a plan can be explained
  /// before it is run rather than only after it is slow.
  List<PlannedChild> get unestimableChildren =>
      children.where((c) => c.files is UnknownFiles).toList();

  /// The dollars actually estimated, summing only the children that carry one.
  ///
  /// **Read with [childrenWithoutCostEstimate] or not at all.** The name says
  /// `known` because that is all it is: F-23 is the finding that a sum with no
  /// third state for *unknown* turns an unmeasured node into a measured zero,
  /// and INV7 is the general form. `sprout run` already prints its own spend as
  /// `>=$X over N nodes (k unknown)` for the same reason; this pair is the
  /// planning-side half of that label.
  double get knownEstimatedCostUsd =>
      children.fold(0, (total, child) => total + (child.estimatedCostUsd ?? 0));

  /// How many children carry no cost estimate at all.
  int get childrenWithoutCostEstimate =>
      children.where((c) => c.estimatedCostUsd == null).length;

  @override
  String toString() =>
      'Decomposition($parentId → ${children.length} children, '
      '${unestimableChildren.length} unestimable)';
}
