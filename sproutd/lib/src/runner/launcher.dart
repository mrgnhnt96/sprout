/// Starting the process, behind a seam the tests can replace.
library;

import 'dart:async';
import 'dart:io';

/// The exact `claude -p` invocation, every flag verified present in v2.1.252
/// (`docs/research/17-observed-schemas.md` §9).
///
/// `--max-turns` is deliberately absent: it is **not a CLI flag** in this
/// version, only the environment variable `CLAUDE_CODE_MAX_TURNS`, and passing
/// it would fail the launch. The budget is the one bound the CLI enforces
/// itself; the depth cap and concurrency bounds are sprout's, applied before
/// this list is ever built.
List<String> claudeArguments({
  required String task,
  required double maxBudgetUsd,
}) => [
  '-p',
  task,
  '--output-format',
  'stream-json',
  '--verbose',
  '--include-partial-messages',
  '--include-hook-events',
  '--forward-subagent-text',
  '--permission-mode',
  'acceptEdits',
  '--max-budget-usd',
  maxBudgetUsd.toString(),
];

/// Everything needed to start one session process. A value, so a test can
/// assert on exactly what would have been run without running it.
final class SessionLaunch {
  /// Describes a launch.
  const SessionLaunch({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.environment = const {},
  });

  /// The standard `claude -p` launch for [task] in [project].
  factory SessionLaunch.claude({
    required String task,
    required String project,
    required double maxBudgetUsd,
    String executable = 'claude',
    Map<String, String> environment = const {},
  }) => SessionLaunch(
    executable: executable,
    arguments: claudeArguments(task: task, maxBudgetUsd: maxBudgetUsd),
    workingDirectory: project,
    environment: environment,
  );

  /// The binary, resolved on `PATH` if not absolute.
  final String executable;

  /// The argument vector, without the executable.
  final List<String> arguments;

  /// The directory the session runs in — the project.
  final String workingDirectory;

  /// Variables added on top of the parent environment.
  final Map<String, String> environment;

  /// The launch as a JSON-shaped map, for the event feed.
  Map<String, Object?> toJson() => {
    'executable': executable,
    'arguments': arguments,
    'working_directory': workingDirectory,
    'environment': environment,
  };
}

/// A running session process, as much of it as the runner needs.
///
/// [stdout] is bytes, not lines: the runner splits lines itself so that a
/// process dying mid-line leaves a truncated last line rather than a lost one,
/// and so that the raw log on disk is byte-identical to what arrived.
abstract interface class SessionProcess {
  /// The operating-system process id.
  int get pid;

  /// The process's standard output, as it arrives.
  Stream<List<int>> get stdout;

  /// The process's standard error, as it arrives.
  Stream<List<int>> get stderr;

  /// Completes with the exit code once the process has ended.
  Future<int> get exitCode;

  /// Sends [signal]. Returns whether it was delivered.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

/// Starts a [SessionProcess] for a [SessionLaunch].
///
/// The seam that keeps the test suite free: [ClaudeLauncher] is the real one,
/// and a test hands the runner a launcher that replays a captured fixture
/// instead. Nothing in `runner_test.dart` invokes the `claude` binary except
/// the one integration test that is skipped by default.
abstract interface class SessionLauncher {
  /// Starts the process described by [launch].
  Future<SessionProcess> launch(SessionLaunch launch);
}

/// The real thing: `Process.start`, with stdin closed at once.
///
/// Closing stdin immediately is the `< /dev/null` of the documented
/// invocation. `claude -p` waits about three seconds for stdin and warns on
/// stderr when nothing arrives (`17` §10); an immediate EOF is what makes it
/// proceed at once, and it is paid on every spawn if forgotten. Streaming
/// input into a live session is Phase 7 and is not built here.
final class ClaudeLauncher implements SessionLauncher {
  /// Creates the launcher.
  const ClaudeLauncher();

  @override
  Future<SessionProcess> launch(SessionLaunch launch) async {
    final process = await Process.start(
      launch.executable,
      launch.arguments,
      workingDirectory: launch.workingDirectory,
      environment: launch.environment,
    );
    // A process that has already exited makes this a broken pipe; that is
    // reported through `exitCode`, not through the close.
    process.stdin.close().ignore();
    return _RealProcess(process);
  }
}

final class _RealProcess implements SessionProcess {
  _RealProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}
