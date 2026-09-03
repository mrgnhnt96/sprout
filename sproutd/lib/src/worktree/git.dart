/// Running `git`, behind a seam the tests can replace.
library;

import 'dart:convert';
import 'dart:io';

/// The exit code this library reports when `git` could not be run at all.
///
/// Negative on purpose: git's own exit codes are non-negative, so no real one
/// can be mistaken for this. It exists because *"a failed read is not a fact
/// about the world"* — a missing binary, a directory that vanished, a fork that
/// failed are all cases where sprout **could not look**, and the one answer that
/// must never be produced from them is "nothing there". Every caller in this
/// area routes a [GitResult] carrying this into a refusal to act.
const int gitCouldNotRun = -1;

/// What one `git` invocation did.
final class GitResult {
  /// Records a finished invocation.
  const GitResult({
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The argv git was given, without the executable. Kept so a caller can name
  /// the command in an explanation rather than describing it.
  final List<String> arguments;

  /// git's exit code, or [gitCouldNotRun] if it never ran.
  final int exitCode;

  /// Standard output, decoded as UTF-8.
  final String stdout;

  /// Standard error, decoded as UTF-8.
  final String stderr;

  /// Whether git ran and said yes.
  bool get ok => exitCode == 0;

  /// Whether git never ran. See [gitCouldNotRun].
  bool get couldNotRun => exitCode == gitCouldNotRun;

  /// The command and what it said, for an explanation a human can act on.
  String get label {
    final said = stderr.trim().isEmpty ? stdout.trim() : stderr.trim();
    return 'git ${arguments.join(' ')} exited $exitCode'
        '${said.isEmpty ? '' : ': ${said.split('\n').first}'}';
  }

  @override
  String toString() => 'GitResult($label)';
}

/// Runs `git`.
///
/// The seam. A test replaces it to assert the exact argv without touching a
/// repository — but the safety property this area promises is *git's* behaviour,
/// so the teardown tests prove themselves against a real `git init` repository
/// and a fake is only ever used to assert what was asked for (INV8).
abstract interface class GitRunner {
  /// Runs `git [arguments]` with [workingDirectory] as the cwd.
  ///
  /// Never throws for a git that failed or could not start: both come back as
  /// a [GitResult], because a thrown exception is the one shape a caller can
  /// accidentally treat as "clean" by catching it too broadly.
  Future<GitResult> run(
    List<String> arguments, {
    required String workingDirectory,
  });
}

/// The real thing: `Process.run`, with output decoded as UTF-8.
final class ProcessGit implements GitRunner {
  /// Creates the runner.
  const ProcessGit({this.executable = 'git'});

  /// The `git` binary to run.
  final String executable;

  @override
  Future<GitResult> run(
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        // `allowMalformed` so a filename that is not valid UTF-8 becomes
        // U+FFFD rather than an exception. A byte sequence git could print is
        // not a reason to stop being able to answer whether a tree is dirty.
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      return GitResult(
        arguments: arguments,
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on Object catch (error) {
      return GitResult(
        arguments: arguments,
        exitCode: gitCouldNotRun,
        stdout: '',
        stderr: '$error',
      );
    }
  }
}
