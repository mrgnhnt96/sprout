/// The `sprout` command line.
///
/// Three verbs:
///
/// ```
/// sprout run "<task>"
/// sprout snapshot [--json]
/// sprout watch [--since <cursor>] [--json]
/// ```
///
/// `run` spawns exactly one `claude -p` session at depth 0 through
/// `package:sproutd/runner.dart` and streams its events to disk and into the
/// store. It spawns nothing else: delegation is Phase 4, and the runner it
/// calls has no path that starts a child.
///
/// `snapshot` and `watch` are Phase 2's observation protocol, taken whole from
/// showrunner (`docs/01-plan.md` §7, §11): a snapshot is the whole world at one
/// cursor, and `watch --since <cursor>` is the deltas against it. **CLI
/// consumer first** — this file is the consumer that proves the protocol joins
/// end to end, which is the one thing unit tests on either side cannot check.
///
/// Both read the store directly rather than through the daemon, because there
/// is no daemon in the loop yet. That costs nothing on the wire: the cursor's
/// instance id is a fingerprint of the event feed rather than of a process
/// (`SproutInstance.forFeed`), so a cursor this CLI mints is the same cursor
/// the daemon's socket mints against the same database, and the two surfaces
/// join.
///
/// The CLI writes the same SQLite file the daemon reads (WAL mode, so both
/// can be open at once), and it honours the same `SPROUT_DB` variable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sproutd/policy.dart';
import 'package:sproutd/protocol.dart';
import 'package:sproutd/runner.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/stream.dart';
import 'package:sproutd/watch.dart';

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

/// `watch --since` was handed a well-formed cursor belonging to a **different**
/// sproutd instance, and it was refused.
///
/// Distinct from [exitCursorMalformed] on purpose, and the two must never
/// share a code or a message. The consumer's cursor is not corrupt — it is
/// simply meaningless here, because seq 412 in another daemon's feed is not
/// seq 412 in this one. The remedy is a fresh `sprout snapshot`, not a retry
/// with a repaired string, and a script that cannot tell the two apart will
/// pick the wrong one.
const int exitCursorForeign = 4;

/// `watch --since` was handed something that is not a cursor at all.
///
/// The remedy here *is* to fix the value — a truncated copy-paste, a shell
/// that ate a character, a cursor from a future build. See [exitCursorForeign]
/// for why this is a separate code.
const int exitCursorMalformed = 5;

/// The store could not be read: the file is not a database, the schema is from
/// a build this one does not understand, or the path cannot be opened.
///
/// This is the *store*, not the feed. A feed that cannot be read while the
/// store can is reported inside the snapshot as `journal_unreadable` and exits
/// [exitOk], because that snapshot is still a picture and saying so in it is
/// the whole point (`docs/01-plan.md` §7). A store that will not open yields no
/// picture at all, and that is this code.
const int exitStoreUnreadable = 6;

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
  final env = environment ?? Platform.environment;
  final runner =
      CommandRunner<int>(
          'sprout',
          'Orchestrates recursive Claude Code sessions and watches them from '
              'outside.',
        )
        ..addCommand(
          RunCommand(out: stdoutSink, err: stderrSink, environment: env),
        )
        ..addCommand(
          SnapshotCommand(out: stdoutSink, err: stderrSink, environment: env),
        )
        ..addCommand(
          WatchCommand(out: stdoutSink, err: stderrSink, environment: env),
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

    final dbPath = resolveDatabasePath(
      option: results['db'] as String?,
      environment: environment,
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

/// The `--db` option's text, shared by every verb that opens the store.
const String databaseOptionHelp =
    'The SQLite file. Defaults to \$$databaseEnvVariable, then '
    '~/.sprout/sprout.db.';

/// Resolves the database path the same way for every verb.
///
/// `--db`, then `$SPROUT_DB` (empty treated as unset, because an exported-but-
/// blank variable is how a shell says nothing rather than how it says ""),
/// then `~/.sprout/sprout.db`. Absolute, because the path is what gets opened
/// and what error messages name. `SproutStore.databasePath` absolutises again
/// rather than trusting this, since the instance id is derived from it and a
/// relative value there would make a cursor depend on the working directory.
String resolveDatabasePath({
  required String? option,
  required Map<String, String> environment,
}) {
  final envDb = environment[databaseEnvVariable];
  return p.absolute(
    option ??
        (envDb != null && envDb.isNotEmpty
            ? envDb
            : SproutStore.defaultDatabasePath(home: environment['HOME'])),
  );
}

/// The instance this CLI hands out cursors from.
///
/// Plumbing, not a derivation: the rule lives in [SproutInstance.forFeed] and
/// this only hands it the two facts the store already knows. The daemon's
/// `daemonInstanceFor` is the same one line for the same reason —
/// `sprout snapshot`, `sprout watch` and the daemon's socket are three
/// processes that must arrive at one id, and they do it by calling one
/// derivation rather than by keeping two in step.
///
/// Derived per call rather than held: while the feed is empty the id is the
/// empty-feed one, and it changes when the first event lands. A CLI process
/// that cached it would drift from a daemon that did not.
SproutInstance instanceForStore(SproutStore store) => SproutInstance.forFeed(
  databasePath: store.databasePath,
  firstEvent: store.firstEvent,
);

/// `sprout snapshot [--json]` — the whole world, one call, one cursor.
final class SnapshotCommand extends Command<int> {
  /// Creates the verb.
  SnapshotCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser
      ..addOption('db', help: databaseOptionHelp)
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit one JSON object instead of the human tree.',
      );
  }

  /// Where the snapshot goes.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  /// The environment, for `SPROUT_DB`.
  final Map<String, String> environment;

  @override
  String get name => 'snapshot';

  @override
  String get description =>
      'Print the whole tree at one cursor: task, since, next check-in and '
      'cumulative subtree spend per node.';

  @override
  String get invocation => 'sprout snapshot [--json]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final dbPath = resolveDatabasePath(
      option: results['db'] as String?,
      environment: environment,
    );

    final SproutStore store;
    try {
      store = SproutStore.open(path: dbPath);
    } on Object catch (error) {
      err.writeln('sprout: cannot read the store at $dbPath: $error');
      return exitStoreUnreadable;
    }

    try {
      final snapshot = takeSnapshot(
        StoreSnapshotSource(store),
        instance: instanceForStore(store),
      );
      out.writeln(
        results['json'] as bool
            ? jsonEncode(snapshot.toJson())
            : snapshot.render(),
      );
      // A feed that could not be read is reported *in* the snapshot rather
      // than as a failure: the picture is still a picture, and the field is
      // how the consumer is told what is missing from it. See
      // [exitStoreUnreadable].
      return exitOk;
    } finally {
      store.close();
    }
  }
}

/// `sprout watch [--since <cursor>] [--json]` — deltas against a snapshot.
final class WatchCommand extends Command<int> {
  /// Creates the verb.
  WatchCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser
      ..addOption('db', help: databaseOptionHelp)
      ..addOption(
        'since',
        help:
            'Resume from a cursor a snapshot handed out. Omitted means start '
            'at the head: no replay, an immediate ready, then live deltas.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit one JSON frame per line instead of the human rendering.',
      )
      ..addFlag(
        'replay-only',
        negatable: false,
        help:
            'Stop at the ready frame, once the backlog is drained, instead of '
            'staying attached for live deltas.',
      )
      ..addOption(
        'heartbeat-ms',
        help:
            'Milliseconds between heartbeats. They are emitted whether or not '
            'the tree is busy, because a dead stream and a quiet one are '
            'otherwise the same bytes.',
        defaultsTo: defaultHeartbeatInterval.inMilliseconds.toString(),
      );
  }

  /// Where frames go.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  /// The environment, for `SPROUT_DB`.
  final Map<String, String> environment;

  @override
  String get name => 'watch';

  @override
  String get description =>
      'Stream deltas against a snapshot: replay, one ready, then live deltas, '
      'heartbeats and a bye.';

  @override
  String get invocation => 'sprout watch [--since <cursor>] [--json]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final heartbeatMs = int.tryParse(results['heartbeat-ms'] as String);
    if (heartbeatMs == null || heartbeatMs <= 0) {
      usageException('--heartbeat-ms must be a positive number of ms');
    }
    final dbPath = resolveDatabasePath(
      option: results['db'] as String?,
      environment: environment,
    );

    final SproutStore store;
    try {
      store = SproutStore.open(path: dbPath);
    } on Object catch (error) {
      err.writeln('sprout: cannot read the store at $dbPath: $error');
      return exitStoreUnreadable;
    }

    try {
      return await _watch(
        store: store,
        instance: instanceForStore(store),
        since: results['since'] as String?,
        asJson: results['json'] as bool,
        replayOnly: results['replay-only'] as bool,
        heartbeat: Duration(milliseconds: heartbeatMs),
      );
    } finally {
      store.close();
    }
  }

  /// Runs the stream to its end and returns the exit code.
  ///
  /// The `--since` value is offered to the instance *here* as well as inside
  /// [watchFrames], and the two do different jobs. [watchFrames] turns a
  /// refusal into the one `bye` frame the consumer is owed, which is the
  /// protocol's answer; this switch turns the same refusal into an exit code,
  /// which is the shell's. Sniffing the reason out of the bye's detail text
  /// would collapse [exitCursorForeign] and [exitCursorMalformed] into
  /// whichever wording survived a rename.
  Future<int> _watch({
    required SproutStore store,
    required SproutInstance instance,
    required String? since,
    required bool asJson,
    required bool replayOnly,
    required Duration heartbeat,
  }) async {
    var code = exitOk;
    if (since != null) {
      switch (instance.accept(since)) {
        case CursorAccepted():
          break;
        case CursorFromAnotherInstance(:final reason):
          err.writeln('sprout: refusing --since: $reason');
          code = exitCursorForeign;
        case CursorMalformed(:final reason):
          err.writeln('sprout: refusing --since: $reason');
          code = exitCursorMalformed;
      }
    }

    final shutdown = Completer<String>();
    final frames = watchFrames(
      source: StoreWatchSource(store),
      signals: WatchSignals.live(
        heartbeatInterval: heartbeat,
        shutdown: shutdown.future,
      ),
      since: since,
      instance: instance,
    );

    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    late final StreamSubscription<ProtocolFrame> subscription;
    subscription = frames.listen((frame) {
      out.writeln(asJson ? frame.encodeLine() : renderFrame(frame));
      if (frame case ByeFrame(reason: ByeReason.error, :final detail)) {
        err.writeln('sprout: the stream broke: ${detail ?? 'no detail'}');
        if (code == exitOk) code = exitStoreUnreadable;
      }
      // Branch on `marksEndOfReplay`, never on "did that delta carry zero
      // events". A delta with no events is a position update; only `ready`
      // says the backlog is drained, and a consumer that conflated them
      // would sit on a blank screen waiting for a frame it decided it had
      // already seen.
      if (replayOnly && frame.marksEndOfReplay) {
        unawaited(subscription.cancel().whenComplete(finish));
      }
    }, onDone: finish);

    // Ctrl-C is the ordinary way a `watch` ends, and it ends it *through the
    // protocol*: the shutdown future completes, the session emits a `bye`
    // saying so, and only then does the stream close. A consumer that was
    // killed mid-frame and one that was told the daemon is going away must
    // not look the same.
    final interrupts = ProcessSignal.sigint.watch().listen((_) {
      if (!shutdown.isCompleted) shutdown.complete('interrupted');
    });

    try {
      await done.future;
    } finally {
      await subscription.cancel();
      await interrupts.cancel();
    }
    return code;
  }
}

/// One frame, rendered for a human.
///
/// Every frame type prints something. A `heartbeat` in particular is shown
/// rather than swallowed: a consumer that hides them puts back exactly the
/// ambiguity the heartbeat exists to remove, since a stream with nothing to
/// say and a stream that has died then look identical again (INV8). Same for
/// a `delta` that carries no events — the type permits one, and a line saying
/// so is honest where silence is not.
String renderFrame(ProtocolFrame frame) => switch (frame) {
  ReadyFrame() => 'ready | ${frame.cursor.encode()} | end of replay',
  HeartbeatFrame(:final sentAt) =>
    'heartbeat | ${frame.cursor.encode()} | ${sentAt.toIso8601String()}',
  ByeFrame(:final reason, :final detail) => [
    'bye | ${reason.wire} | ${frame.cursor.encode()}',
    ?detail,
  ].join(' | '),
  DeltaFrame(:final events) when events.isEmpty =>
    'delta | ${frame.cursor.encode()} | no events',
  DeltaFrame(:final events) => [
    for (final event in events)
      'delta | #${event.seq} | ${event.nodeId} | ${event.kind}',
  ].join('\n'),
};
