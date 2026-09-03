/// Running one declared success condition, behind a seam the tests can replace.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sproutd/decomposition.dart';

/// The longest run of a condition's output kept in an event payload.
///
/// A failing `dart test` prints thousands of lines and the feed is append-only
/// by schema trigger, so the whole of it would be in every database for ever.
/// The tail rather than the head: a test runner's verdict is at the end.
const int conditionOutputTailChars = 2000;

/// What one attempt to run a success condition did.
///
/// Sealed, and **"could not run" is an arm rather than an exit code**, on
/// `GitResult.couldNotRun`'s argument one library over: a missing executable,
/// a working directory that is gone and a fork that failed are all cases where
/// sprout could not look, and the one answer they must never produce is a
/// verdict about the work.
sealed class ConditionRun {
  const ConditionRun(this.condition);

  /// The condition that was attempted.
  final SuccessCondition condition;

  /// This attempt as part of an event payload.
  Map<String, Object?> toJson();

  /// One line naming the command and what happened.
  String get label;
}

/// The command ran and reported an exit code.
final class ConditionRan extends ConditionRun {
  /// Records a finished run.
  const ConditionRan({
    required SuccessCondition condition,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  }) : super(condition);

  /// What the command exited with. Zero is the only pass.
  final int exitCode;

  /// Everything it wrote to stdout, decoded as UTF-8.
  final String stdout;

  /// Everything it wrote to stderr, decoded as UTF-8.
  final String stderr;

  /// Whether the condition was satisfied.
  bool get passed => exitCode == 0;

  /// The last [conditionOutputTailChars] of what it said, stderr preferred.
  ///
  /// `GitResult.label`'s rule — a tool that failed usually says why on stderr,
  /// and falls back to stdout when it does not.
  String get said {
    final chosen = stderr.trim().isEmpty ? stdout.trim() : stderr.trim();
    return chosen.length <= conditionOutputTailChars
        ? chosen
        : chosen.substring(chosen.length - conditionOutputTailChars);
  }

  @override
  Map<String, Object?> toJson() => {
    'command': condition.command,
    'working_directory': ?condition.workingDirectory,
    'exit_code': exitCode,
    'output': said,
  };

  @override
  String get label =>
      '$condition exited $exitCode'
      '${said.isEmpty ? '' : ': ${said.split('\n').last}'}';

  @override
  String toString() => 'ConditionRan($label)';
}

/// sprout could not run it, and says so rather than answering.
///
/// Never produced from a non-zero exit code: this is the case where no exit
/// code exists at all.
final class ConditionCouldNotRun extends ConditionRun {
  /// Records a failed attempt.
  const ConditionCouldNotRun({
    required SuccessCondition condition,
    required this.why,
  }) : super(condition);

  /// One sentence naming the command and what went wrong, verbatim from the
  /// error where there is one. It reaches a human unmodified.
  final String why;

  @override
  Map<String, Object?> toJson() => {
    'command': condition.command,
    'working_directory': ?condition.workingDirectory,
    'could_not_run': why,
  };

  @override
  String get label => '$condition could not be run: $why';

  @override
  String toString() => 'ConditionCouldNotRun($label)';
}

/// Runs a [SuccessCondition].
///
/// The seam. A test replaces it to reach outcomes a real command would make
/// awkward to stage — but the check's own tests prove themselves against real
/// processes with real exit codes as well, because *"a test that only proves
/// your fake refuses proves nothing"* (INV8).
abstract interface class ConditionRunner {
  /// Runs [condition], resolving its working directory under [workspace].
  ///
  /// Never throws. Everything that goes wrong comes back as
  /// [ConditionCouldNotRun], because a thrown exception is the one shape a
  /// caller can accidentally treat as a pass by catching it too broadly.
  Future<ConditionRun> run(
    SuccessCondition condition, {
    required String workspace,
  });
}

/// The real thing: `Process.run` on the condition's own argv.
///
/// **No shell between the declaration and what executes.** A
/// [SuccessCondition] is an argv and a directory precisely so that it can be
/// handed to `Process.run` with nothing in between — an interpreter in that gap
/// is finding F-08 in a different costume, where the text a guard reads and the
/// text that runs are not the same text.
final class ProcessConditions implements ConditionRunner {
  /// Creates the runner.
  const ProcessConditions();

  @override
  Future<ConditionRun> run(
    SuccessCondition condition, {
    required String workspace,
  }) async {
    final directory = condition.workingDirectory == null
        ? workspace
        : '$workspace/${condition.workingDirectory}';
    try {
      final result = await Process.run(
        condition.command.first,
        condition.command.skip(1).toList(),
        workingDirectory: directory,
        // `allowMalformed` for the same reason `ProcessGit` gives: a byte
        // sequence a test runner printed is not a reason to lose the verdict.
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      return ConditionRan(
        condition: condition,
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on Object catch (error) {
      return ConditionCouldNotRun(condition: condition, why: '$error');
    }
  }
}
