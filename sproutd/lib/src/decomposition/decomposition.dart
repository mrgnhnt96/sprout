/// A parent that has decided to split a task, as a value.
library;

import 'estimate.dart';
import 'mode.dart';

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
/// **The mode lives on the [Decomposition], not here.** P4-04 left the seam
/// open with the note that *"an unused field with no producer is a decision
/// made by whoever eventually guesses at it"*; P4-05 filled it, and put the
/// choice one level up because `docs/01-plan.md` §2.3 is about the shape of a
/// *split* — whether the children are independent or have to compose — which
/// is not a property any one child can hold. A per-child mode would let a
/// parent declare half a fan-out map and half of it build, which is not a
/// distinction §2.3 draws and not one the wave planner could act on.
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
/// the empty case is what kept that seam visible for P4-05, which owns the
/// floor; representing it as an empty list would let a caller "decompose" into
/// nothing and get a plan back that runs no work and says nothing is wrong.
/// `DelegationFloor` is the other half of that seam: a decomposition is a
/// *proposal*, and the floor is what decides whether making it was worth the
/// coordination it costs.
///
/// **Every decomposition carries a [ModeChoice], and it is required.** §2.3
/// says sprout must *"pick the mode explicitly and default build for code"*, so
/// an unset mode is not `map` and not anything else — it does not compile. The
/// only way to take the default is [ModeChoice.defaulted], which produces
/// `build` and records that nobody chose it.
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
    required ModeChoice mode,
    List<String> sharedDecisions = const [],
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
    final decisions = <String>[];
    for (final decision in sharedDecisions) {
      final trimmed = decision.trim();
      if (trimmed.isEmpty) {
        throw ArgumentError.value(
          sharedDecisions,
          'sharedDecisions',
          'contains a blank decision',
        );
      }
      decisions.add(trimmed);
    }
    if (!mode.isBuild && decisions.isNotEmpty) {
      throw ArgumentError.value(
        sharedDecisions,
        'sharedDecisions',
        'is not empty on a map decomposition. §2.3 maps by *isolating* child '
            'context; a parent with decisions that have to reach its children '
            'has children that are not independent, which is the definition of '
            'build-shaped work. Declare build, or drop the decisions',
      );
    }
    return Decomposition._(
      trimmedParent,
      task.trim(),
      List.unmodifiable(children),
      mode,
      List.unmodifiable(decisions),
    );
  }

  const Decomposition._(
    this.parentId,
    this.task,
    this.children,
    this.mode,
    this.sharedDecisions,
  );

  /// The node doing the splitting.
  final String parentId;

  /// The task being split, in the parent's own words.
  final String task;

  /// The children, in the parent's order. Never empty, ids unique.
  final List<PlannedChild> children;

  /// map or build, and whether anybody chose (`docs/01-plan.md` §2.3).
  ///
  /// Read by [briefFor], which pushes [sharedDecisions] down only in build, and
  /// by `planWaves`, which narrows a build plan to `buildWaveWidth`. A mode
  /// nothing read would be a field, not a decision.
  final ModeChoice mode;

  /// What the parent has already settled, which every child must follow rather
  /// than re-decide. Empty unless [mode] is build.
  ///
  /// This is §2.3's Context column for build — *"push shared decisions down"*
  /// — as a real field rather than an instruction to whoever writes the
  /// briefs. The failure it exists against is the one the plan names: children
  /// that each re-decide the same thing produce *"a Mario background and a bird
  /// that isn't Flappy"*, and the decisions were never in dispute, only never
  /// transmitted.
  ///
  /// A **map** decomposition may not carry any, and the constructor refuses one
  /// that does. Map isolates context by definition, so decisions that have to
  /// reach the children mean the children are not independent; letting both
  /// coexist would leave the field silently dropped at [briefFor], which is the
  /// same class of bug one layer down.
  final List<String> sharedDecisions;

  /// The prompt [child] is actually given — the first place [mode] bites.
  ///
  /// §2.3's Context column, as two branches:
  ///
  /// - **map** hands over the child's own task and **nothing else**. That is
  ///   *"isolate"*, and the evidence behind it (RAH 81→90%, Anthropic +90.2%)
  ///   is about children that do not share context, so adding the parent's
  ///   framing back in would be running build's context policy under map's
  ///   name.
  /// - **build** carries the parent's own [task] down as well, and then every
  ///   one of its [sharedDecisions]. Build children produce artifacts that have
  ///   to compose, and a child that does not know what whole it is part of
  ///   re-decides that for itself — *"a Mario background and a bird that isn't
  ///   Flappy"* is four children each answering a question the parent had
  ///   already answered and never transmitted.
  ///
  /// The parent's task is in the build branch and not only the decisions
  /// because it makes the two branches differ for **every** decomposition. This
  /// was found by mutation, per INV8: an earlier version differed only by
  /// [sharedDecisions], and since the constructor already refuses a map
  /// decomposition that carries any, no constructible input could tell the two
  /// branches apart — a `briefFor` mutated to push decisions down in map too
  /// passed the whole suite. The guarantee was really the constructor's, and
  /// this method's switch was decoration that read like enforcement.
  ///
  /// **What this still does not catch,** per INV6: nothing here checks that the
  /// child *read* the decisions, only that they were in the brief it was given.
  /// INV11 is the general form — a message that was accepted is not an
  /// instruction that was obeyed — and the acceptance check for a child's work
  /// is P4-06's `SuccessCondition`, not this string.
  ///
  /// Throws [ArgumentError] if [child] is not one of this decomposition's, so a
  /// brief cannot be built from a decomposition that never planned the child it
  /// describes.
  String briefFor(PlannedChild child) {
    if (!children.any((c) => identical(c, child) || c.id == child.id)) {
      throw ArgumentError.value(
        child.id,
        'child',
        'is not a child of this decomposition, so its brief would carry '
            'decisions made for a different split',
      );
    }
    return switch (mode.mode) {
      DelegationMode.map => child.task,
      DelegationMode.build => [
        child.task,
        '',
        'This is one part of: $task',
        if (sharedDecisions.isNotEmpty) ...[
          '',
          'Decisions the parent has already made. Follow them; do not '
              're-decide them:',
          for (final decision in sharedDecisions) '- $decision',
        ],
      ].join('\n'),
    };
  }

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
      '${unestimableChildren.length} unestimable, ${mode.label})';
}
