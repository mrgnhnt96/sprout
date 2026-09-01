/// The `sprout` command line.
///
/// One verb in Phase 1:
///
/// ```
/// sprout run "<task>"
/// ```
///
/// which spawns exactly one `claude -p` session at depth 0 through
/// `package:sproutd/runner.dart` and streams its events to disk and into the
/// store. It spawns nothing else: delegation is Phase 4, and the runner it
/// calls has no path that starts a child.
///
/// The CLI writes the same SQLite file the daemon reads (WAL mode, so both
/// can be open at once), and it honours the same `SPROUT_DB` variable.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sproutd/policy.dart';
import 'package:sproutd/runner.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/stream.dart';

/// Everything went as the stream said it would: the process exited 0 and a
/// `result` frame arrived.
const int exitOk = 0;

/// The process ended, but not cleanly: a non-zero exit, or no `result` frame
/// before it went away. See `EndedSession` for why neither alone is "done".
const int exitSessionFailed = 1;

/// The containment gate refused the spawn. No process was started.
const int exitRefused = 2;

/// The process could not be started at all — usually `claude` not on `PATH`.
const int exitLaunchFailed = 3;

/// Bad arguments. `EX_USAGE` from sysexits.h.
const int exitUsage = 64;

/// The environment variable naming the SQLite file. Shared with the daemon.
const String databaseEnvVariable = 'SPROUT_DB';

/// The `--budget-usd` a run gets when none is given.
///
/// A knob, not a finding: nothing in the plan fixes a default. It is low so
/// that a first `sprout run` cannot cost more than a coffee, and it becomes
/// the `--max-budget-usd` the CLI itself enforces.
const double defaultBudgetUsd = 1.0;

Future<void> main(List<String> arguments) async {
  exitCode = await sprout(arguments);
}

/// Runs the CLI over [arguments] and returns the exit code.
///
/// [out] and [err] default to the process's; a test passes buffers.
/// [environment] defaults to the process's and supplies `SPROUT_DB`.
Future<int> sprout(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final runner =
      CommandRunner<int>(
        'sprout',
        'Orchestrates recursive Claude Code sessions and watches them from '
            'outside.',
      )..addCommand(
        RunCommand(
          out: stdoutSink,
          err: stderrSink,
          environment: environment ?? Platform.environment,
        ),
      );
  try {
    return await runner.run(arguments) ?? exitOk;
  } on UsageException catch (error) {
    stderrSink.writeln(error);
    return exitUsage;
  }
}

/// `sprout run "<task>"`.
final class RunCommand extends Command<int> {
  /// Creates the verb.
  RunCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser
      ..addOption(
        'project',
        abbr: 'C',
        help: 'The project directory the session works in.',
        defaultsTo: Directory.current.path,
      )
      ..addOption(
        'db',
        help:
            'The SQLite file. Defaults to \$$databaseEnvVariable, then '
            '~/.sprout/sprout.db.',
      )
      ..addOption(
        'logs',
        help:
            'Where raw session logs go, one <node>.ndjson and <node>.stderr '
            'each. Defaults to a sessions/ directory beside the database.',
      )
      ..addOption(
        'budget-usd',
        help:
            'The dollar ceiling for the session, passed to claude as '
            '--max-budget-usd and checked by sprout before the launch.',
        defaultsTo: defaultBudgetUsd.toString(),
      )
      ..addOption(
        'claude',
        help: 'The claude executable to launch.',
        defaultsTo: 'claude',
      );
  }

  /// Where progress goes.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  /// The environment, for `SPROUT_DB`.
  final Map<String, String> environment;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Spawn one claude -p session at depth 0 and stream its events to disk.';

  @override
  String get invocation => 'sprout run [options] "<task>"';

  @override
  Future<int> run() async {
    final results = argResults!;
    final task = results.rest.join(' ').trim();
    if (task.isEmpty) {
      usageException('A task is required: sprout run "<task>"');
    }
    final budget = double.tryParse(results['budget-usd'] as String);
    if (budget == null || budget <= 0) {
      usageException('--budget-usd must be a positive number of dollars');
    }

    final project = p.absolute(results['project'] as String);
    if (!Directory(project).existsSync()) {
      usageException('--project does not exist: $project');
    }

    final envDb = environment[databaseEnvVariable];
    final dbPath = p.absolute(
      results['db'] as String? ??
          (envDb != null && envDb.isNotEmpty
              ? envDb
              : SproutStore.defaultDatabasePath(home: environment['HOME'])),
    );
    final logDirectory = p.absolute(
      results['logs'] as String? ?? p.join(p.dirname(dbPath), 'sessions'),
    );

    final store = SproutStore.open(path: dbPath);
    try {
      return await _run(
        store: store,
        task: task,
        project: project,
        budgetUsd: budget,
        logDirectory: logDirectory,
        executable: results['claude'] as String,
      );
    } finally {
      store.close();
    }
  }

  Future<int> _run({
    required SproutStore store,
    required String task,
    required String project,
    required double budgetUsd,
    required String logDirectory,
    required String executable,
  }) async {
    // One session, so one ceiling: the subtree and the run are the same
    // thing at depth 0 with no children.
    final gate = ContainmentGate(
      ContainmentPolicy(subtreeBudgetUsd: budgetUsd, runBudgetUsd: budgetUsd),
    );
    final runner = SessionRunner(
      store: store,
      gate: gate,
      logDirectory: logDirectory,
      executable: executable,
    );

    final SessionStart start;
    try {
      start = await runner.launch(SessionRequest(task: task, project: project));
    } on ProcessException catch (error) {
      err.writeln('sprout: could not start $executable: ${error.message}');
      return exitLaunchFailed;
    }

    switch (start) {
      case RefusedSession(:final nodeId, :final refusal):
        err
          ..writeln('sprout: refused (${refusal.reason.wire}), node $nodeId')
          ..writeln(refusal.explanation);
        return exitRefused;
      case LiveSession():
        return _watch(start);
    }
  }

  /// Prints the session as it runs, forwarding Ctrl-C to the process so an
  /// interrupted `sprout run` does not leave a `claude` behind, still
  /// spending.
  Future<int> _watch(LiveSession session) async {
    out
      ..writeln('node ${session.nodeId}  pid ${session.pid}')
      ..writeln('log  ${session.rawLogPath}');

    final interrupts = ProcessSignal.sigint.watch().listen((_) {
      err.writeln('sprout: interrupted, stopping ${session.pid}');
      session.kill();
    });
    final frames = session.frames.listen(_printFrame);
    try {
      final ended = await session.done;
      await frames.asFuture<void>().catchError((_) {});
      return _report(ended);
    } finally {
      await frames.cancel();
      await interrupts.cancel();
    }
  }

  void _printFrame(StreamFrame frame) {
    switch (frame) {
      case SystemInitFrame(:final model, :final sessionId):
        out.writeln('session $sessionId  model $model');
      case AssistantFrame(:final message):
        final text = message.text.trim();
        if (text.isNotEmpty) out.writeln(text);
      case MalformedFrame():
        err.writeln('sprout: malformed line in stream, kept in the raw log');
      default:
        break;
    }
  }

  int _report(EndedSession ended) {
    final cost = ended.totalCostUsd;
    out.writeln(
      'exit ${ended.exitCode}  '
      'result ${ended.result?.subtype ?? 'none'}  '
      'cost ${cost == null ? 'unknown' : '\$${cost.toStringAsFixed(4)}'}  '
      'frames ${ended.frameCount}',
    );
    if (!ended.hasResult) {
      err.writeln(
        'sprout: the session ended without a result frame; '
        'see ${ended.stderrLogPath}',
      );
      return exitSessionFailed;
    }
    return ended.exitCode == 0 ? exitOk : exitSessionFailed;
  }
}
