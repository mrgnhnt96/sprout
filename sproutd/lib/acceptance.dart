/// The parent's acceptance check, against the brief it wrote.
///
/// `docs/01-plan.md` §5 puts one check at one moment in the node lifecycle:
///
/// ```
/// spawn → bind mandate → work → three honest endings
///       → parent acceptance check against the brief it wrote
///       → close with a real artifact
/// ```
///
/// Start at [AcceptanceCheck]. It takes what the child returned
/// ([ChildReturn], read off the runner's `EndedSession`) and the
/// `SuccessCondition`s that child's brief declared, runs them, and answers with
/// one of three things: [ChildAccepted], [ChildRejected], or
/// [AcceptanceUndecidable].
///
/// **Three answers, because *undecidable* is not a variety of rejected.** A
/// condition sprout could not run — no such executable, no such directory —
/// proves nothing in either direction, and INV8 is the reason it gets its own
/// arm: *"a pass that is silence proves nothing on its own"*, and a failure to
/// look is the purest form of that silence. `worktree` draws the same line with
/// [WorktreeUnreadable] against a clean `git status`, and `decomposition` with
/// `UnknownFiles` against `TouchesNothing`. Three libraries, one rule.
///
/// **What decides, and what merely gets recorded.** §2.4 measured Blocksworld
/// with GPT-4 as its own critic: no verification 40/100, LLM self-critique
/// 55/100, **external sound verifier 88/100**, with the critic approving
/// wrongly **38%** of the time. So the gate is the declared command's exit
/// code and nothing else. §14.7 adds the refinement that keeps a critic from
/// being useless — the 55% figure measured *spec-free* critics, and test-aware
/// ones score 86–93%, so *"hand every critic a spec, or don't run it"* — but a
/// critic still sits beside the result, never in place of it, and never as the
/// same model that produced the artifact. Nothing in this library asks a model
/// anything.
///
/// **Two things this check refuses to accept on.** Neither is the exit code:
///
/// - a child that produced **no result** ended before it answered, whatever it
///   exited with;
/// - a child whose **subtree had not drained** answered for work that was still
///   running.
///
/// Both are INV12 — *"the parent finished" is not "the subtree finished"* —
/// and both are read from fields `EndedSession` already computes rather than
/// derived a second time here.
///
/// **Counted, like every refusal sprout makes.** [AcceptanceCheck.judge] is the
/// only entry point and it records every answer on [AcceptanceCounts],
/// `ContainmentGate.admit`'s shape and INV14's reason: the platform counts only
/// its own refusals, an acceptance check makes no tool call at all, and a
/// judgement sprout does not count is one that never happened as far as sprout
/// can tell. [AcceptanceCounts.accepted] is the positive control, because zero
/// rejections and zero checks look identical without it.
///
/// **On the feed.** Every outcome carries its own [AcceptanceOutcome.kind],
/// declared in `package:sprout_protocol` with the rest of the wire vocabulary
/// rather than spelled at the call site that writes it — findings F-11 and
/// F-12, each of which cost a leaf to undo.
///
/// **Its own area rather than a corner of `runner` or `decomposition`.**
/// `decomposition` is pure by promise — `test/decomposition_test.dart` greps
/// its whole directory and asserts `dart:io` appears nowhere in it — and this
/// area's entire job is to run a process and read its exit code, so putting it
/// there would delete that guarantee for the sake of adjacency. `runner`
/// launches sessions and owns their streams; it has no opinion about whether
/// what came back was any good, and §2.4's whole argument is that the thing
/// producing the artifact must not be the thing judging it.
///
/// **What this library does not do.** It does not act on its own answer. It
/// tears nothing down, merges nothing, closes no node and authorizes nothing:
/// §6's *"a brief is not a human"* means a parent's judgement of a child can
/// never grant one of the four human-only gates. `bin/sprout.dart` is the
/// caller that decides what an acceptance is worth, and the worktree teardown
/// it offers still refuses whenever removing the directory would lose work.
///
/// Implementation lives under `lib/src/acceptance/`. See `docs/01-plan.md`
/// §2.4, §2.5, §5, §6 and §14.7.
library;

export 'package:sprout_protocol/values.dart'
    show
        acceptanceAcceptedKind,
        acceptanceKindPrefix,
        acceptanceRejectedKind,
        acceptanceUndecidableKind;

export 'src/acceptance/check.dart' show AcceptanceCheck, AcceptanceCounts;
export 'src/acceptance/condition_runner.dart'
    show
        ConditionCouldNotRun,
        ConditionRan,
        ConditionRun,
        ConditionRunner,
        ProcessConditions,
        conditionOutputTailChars;
export 'src/acceptance/outcome.dart'
    show
        AcceptanceOutcome,
        AcceptanceUndecidable,
        ChildAccepted,
        ChildRejected,
        ChildReturn,
        RejectionReason,
        UndecidableReason;
