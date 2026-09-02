/// The `sprout` command line — and, since P4-01, the daemon as well.
///
/// Four verbs:
///
/// ```
/// sprout run "<task>"
/// sprout snapshot [--json]
/// sprout watch [--since <cursor>] [--json]
/// sprout ui
/// ```
///
/// **This file is the whole product.** `dart compile exe bin/sprout.dart`
/// produces one executable that is both the CLI and the daemon, which is what
/// `README.md` and `docs/01-plan.md` §13 have claimed since Phase 0 — before
/// P4-01 there were two, and seeing the board meant compiling
/// `.revali/server/server.dart` separately and running it yourself with
/// `SPROUT_DB` and `SPROUT_PORT` set by hand. [UiCommand] explains what that
/// cost and why `.revali/` is now committed.
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
import 'package:sproutd/watchdog.dart';

// The generated Revali entrypoint, and the app it builds `MainApp` from.
//
// Relative, and outside `bin/`, exactly as the generated file itself reaches
// `../../routes/`. `.revali/server/server.dart` is written by
// `dart run revali build`; nothing in it is hand-edited, and `createServer`
// is the one thing this file calls out of it.
import '../.revali/server/server.dart' as daemon;
import '../routes/main_app.dart' as app;

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

/// `sprout ui` could not take the port, so it started nothing.
///
/// Almost always a daemon that is already up, which is the case worth its own
/// code: the remedy is "open the URL you already have", not "retry", and a
/// script that got [exitSessionFailed] would have no way to tell those apart.
///
/// The verb refuses rather than picking a free port. A URL the user did not
/// ask for is a URL their browser tab is not pointed at, and the second
/// daemon would be invisible except in whichever terminal printed it.
const int exitPortInUse = 7;

/// Bad arguments. `EX_USAGE` from sysexits.h.
const int exitUsage = 64;

/// The environment variable naming the watchdog's NDJSON journal.
///
/// Unset means the file sits beside the database — one directory holds
/// everything a run leaves behind, and the journal's own mtime is the
/// watchdog's pulse, so it wants to be somewhere a person will look with
/// `ls -l` rather than somewhere only this code knows about.
const String watchdogLogEnvVariable = 'SPROUT_WATCHDOG_LOG';

/// The file name used when [watchdogLogEnvVariable] is unset.
const String watchdogLogName = 'watchdog.ndjson';

/// The environment variable overriding the sweep interval, in milliseconds.
const String watchdogSweepEnvVariable = 'SPROUT_WATCHDOG_SWEEP_MS';

/// The environment variable overriding the freeze threshold, in milliseconds.
const String watchdogFrozenEnvVariable = 'SPROUT_WATCHDOG_FROZEN_MS';

/// The environment variable overriding the settle wait, in milliseconds.
const String watchdogSettleEnvVariable = 'SPROUT_WATCHDOG_SETTLE_MS';

/// The journal path [environment] asks for, or one beside [database].
String watchdogLogPathFor(Map<String, String> environment, String database) {
  final value = environment[watchdogLogEnvVariable];
  if (value != null && value.isNotEmpty) return p.absolute(value);
  return p.join(p.dirname(database), watchdogLogName);
}

/// The duration [environment] asks for under [key], or [fallback].
///
/// **These are knobs, and the defaults are not findings.** `watchdogFrozenAfter`
/// says so of itself: nothing in the plan, the research or the Phase 0 captures
/// fixes five minutes, and the sweep interval and settle are borrowed from
/// `.game_loop/config.json` rather than measured. They are overridable because
/// a person watching a demo should not have to wait out a threshold that has
/// no evidence behind it, and because a tree of thirty-second tasks and a tree
/// of hour-long ones do not want the same numbers.
///
/// A value that is set but not a positive integer throws rather than falling
/// back, for the reason `daemonPortFrom` does: someone set it on purpose, and
/// quietly running on a different number than they asked for is worse than
/// refusing to start.
Duration watchdogDurationFrom(
  Map<String, String> environment,
  String key,
  Duration fallback,
) {
  final value = environment[key];
  if (value == null || value.isEmpty) return fallback;
  final ms = int.tryParse(value);
  if (ms == null || ms <= 0) {
    throw FormatException(
      '\$$key must be a positive number of milliseconds',
      value,
    );
  }
  return Duration(milliseconds: ms);
}

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
        )
        // No `environment:`, and that is the point of the comment on
        // [UiCommand.run]: this verb starts a server that reads the process's
        // own environment, so an injected map would make it print a URL and a
        // database the server it just started does not use.
        ..addCommand(UiCommand(out: stdoutSink, err: stderrSink));
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

/// `sprout ui` — start the daemon in the foreground and print its URL.
///
/// The whole leaf is P4-01: seeing the board used to mean compiling two
/// artifacts and running the second one yourself with `SPROUT_DB` and
/// `SPROUT_PORT` set. It is now one command with no arguments.
///
/// **It is deliberately not a service manager.** No backgrounding, no PID
/// file, no restart, no `sprout stop`. A foreground process that prints where
/// it is listening and dies on Ctrl-C is the whole verb; anything that
/// outlives the terminal is a different decision and should be made on
/// purpose.
///
/// ## Why this makes sprout one binary
///
/// Importing `.revali/server/server.dart` is what collapses the artifact count
/// from two to one, and it costs a build-order coupling: three test files
/// import `bin/sprout.dart`, so a tree with no `.revali/` would now fail to
/// analyze *and* fail to compile its tests, not merely skip a check. That is
/// why `.revali/` is committed as of P4-01 and `.gitignore` says so. It is the
/// same trade P3-03 made for `lib/src/ui/assets.g.dart`: generated source is
/// committed when something that must build on a clean checkout names it.
///
/// It is a smaller trade than it looks. The generated tree is 501 lines across
/// seven files, it holds no absolute or machine-specific paths, and
/// `revali build` re-emits it byte for byte — so a stale `.revali/` is now a
/// visible diff rather than a local surprise, and the two `the generated
/// shape` groups in `test/ui_test.dart` and `test/ws_test.dart` no longer skip
/// themselves on a fresh checkout.
final class UiCommand extends Command<int> {
  /// Creates the verb.
  UiCommand({required this.out, required this.err});

  /// Where the URL goes.
  final StringSink out;

  /// Where errors go.
  final StringSink err;

  @override
  String get name => 'ui';

  @override
  String get description =>
      'Start the daemon and print the URL the board is at. Runs in the '
      'foreground until Ctrl-C.';

  @override
  String get invocation => 'sprout ui';

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      usageException(
        'sprout ui takes no arguments; set \$${app.daemonPortEnvVariable} or '
        '\$$databaseEnvVariable to change the port or the database',
      );
    }

    // `Platform.environment` and not an injected map, on purpose. The server
    // started below builds `MainApp` and its DI out of the process's own
    // environment (`.revali/server/server.dart` calls `MainApp.new()`, and
    // `MainApp` reads `Platform.environment` in its constructor and again in
    // `configureDependencies`). A verb that resolved the port and the database
    // from anywhere else would print two facts about a server that does not
    // hold them, which is worse than not printing them.
    final environment = Platform.environment;

    final int port;
    try {
      port = app.daemonPortFrom(environment);
    } on FormatException catch (error) {
      err.writeln('sprout: ${error.message} (got "${error.source}")');
      return exitUsage;
    }

    // Bound here rather than left to the generated `_bindServer`, for the one
    // reason that `createServer` takes a `providedServer` at all: a port
    // already in use reaches that code as `print('Failed to bind server')` on
    // *stdout* followed by `exit(1)`, which is neither a sprout message nor a
    // code a caller can act on. Binding first makes the refusal ours, and
    // makes it race-free — there is no window between a probe and the real
    // bind, because this *is* the real bind.
    final HttpServer server;
    try {
      server = await HttpServer.bind(app.daemonHost, port);
    } on SocketException catch (error) {
      err
        ..writeln(
          'sprout: cannot listen on ${app.daemonHost}:$port — '
          '${error.osError?.message ?? error.message}.',
        )
        ..writeln(
          'sprout: a daemon is probably already up. Open '
          '${_url(app.daemonHost, port)} , or set '
          '\$${app.daemonPortEnvVariable} to another port.',
        );
      return exitPortInUse;
    }

    // The database the DI will open, resolved through the daemon's own two
    // functions rather than through this file's `resolveDatabasePath`. The two
    // agree today; calling the daemon's is what keeps them agreeing.
    final String database;
    try {
      database = p.absolute(
        app.databasePathFrom(environment) ?? SproutStore.defaultDatabasePath(),
      );
    } on StateError catch (error) {
      await server.close(force: true);
      err.writeln('sprout: ${error.message}');
      return exitStoreUnreadable;
    }

    await daemon.createServer(server);

    // The watchdog's own store handle, opened here and not taken from the
    // daemon's DI. Two connections to one WAL database, which is the same
    // arrangement `sprout run` and `sprout ui` already have and is why the
    // store opens in WAL at all. The alternative — reaching into revali's DI
    // from out here — is not available: `createServer` constructs `MainApp`
    // itself, and the container it fills is not handed back.
    final SproutStore store;
    try {
      store = SproutStore.open(path: database);
    } on Object catch (error) {
      await server.close(force: true);
      err.writeln('sprout: the store at $database could not be opened: $error');
      return exitStoreUnreadable;
    }

    final Watchdog watchdog;
    final FanOutJournal journal;
    final String log;
    try {
      log = watchdogLogPathFor(environment, database);
      journal = FanOutJournal([
        // Durable first, and the board second. The file's mtime is the
        // watchdog's pulse — readable with `ls -l` by something running none
        // of this code — and the board dies with the process, so a record that
        // existed only in memory could never tell anyone the process died.
        FileWatchdogJournal(log),
        WatchdogBoard.shared,
      ]);
      watchdog = Watchdog(
        store: store,
        // The page, on stderr, in the daemon's own terminal. Distinct from the
        // board, which is the surface: §11 asks for both, and a ring that only
        // ever reached a browser tab nobody had open would not be a page.
        bell: WritingBell(),
        journal: journal,
        interval: watchdogDurationFrom(
          environment,
          watchdogSweepEnvVariable,
          defaultSweepInterval,
        ),
        frozenAfter: watchdogDurationFrom(
          environment,
          watchdogFrozenEnvVariable,
          watchdogFrozenAfter,
        ),
        settleFor: watchdogDurationFrom(
          environment,
          watchdogSettleEnvVariable,
          defaultSettleFor,
        ),
      );
    } on FormatException catch (error) {
      store.close();
      await server.close(force: true);
      err.writeln('sprout: ${error.message} (got "${error.source}")');
      return exitUsage;
    }

    // Read off the bound socket, not off `port`. They are the same number
    // here, and printing the socket's own is what keeps that true if it ever
    // stops being.
    out
      ..writeln(_url(server.address.address, server.port))
      ..writeln('db  $database')
      ..writeln(
        'watchdog  sweep ${_secs(watchdog.interval)} · '
        'frozen after ${_secs(watchdog.frozenAfter)} · '
        'settle ${_secs(watchdog.settleFor)} → $log',
      )
      ..writeln('Ctrl-C to stop.');

    var askedToStop = false;

    // **Started here, not in `MainApp.onServerStarted`.** The watchdog's
    // lifetime is the daemon's, and this method is the only thing that owns
    // the daemon's lifetime: it binds the socket, it closes it, and it is
    // where a Ctrl-C arrives. `onServerStarted` would also fire under
    // `revali dev`, giving a hot-reloading dev server a second watchdog on the
    // same tree with no way to stop it.
    //
    // **Unawaited, and its ending is reported rather than swallowed.**
    // `run()` is documented never to throw from a sweep — every failure path
    // inside `sweepOnce` ends in a journal entry — but "documented not to" is
    // not "cannot", and a watchdog that died is exactly the failure this whole
    // phase exists to catch. So both endings are handled and neither takes the
    // UI down: a throw is caught here, printed, and written to the journal and
    // the board as a sweep with a `failure`; and a `run()` that simply returns
    // without being asked to is treated the same way, because a loop that
    // stopped quietly is the worse of the two. The daemon keeps serving — a
    // board with a dead watchdog that says so is more useful than no board.
    unawaited(
      watchdog
          .run()
          .then<void>((_) async {
            if (askedToStop) return;
            err.writeln(
              'sprout: THE WATCHDOG STOPPED without being asked to. Nothing '
              'is watching the tree; the board and $log say so.',
            );
            await journal.record(watchdogStoppedRecord(at: DateTime.now()));
          })
          .catchError((Object error) async {
            err.writeln('sprout: THE WATCHDOG CRASHED — $error');
            await journal.record(
              watchdogStoppedRecord(at: DateTime.now(), error: '$error'),
            );
          }),
    );

    final code = await _serveUntilInterrupted(server);

    // Stopped with the server, and in this order: the loop first, so no sweep
    // is half-written, then the record saying nobody is looking any more, then
    // the board, then the file. `stop()` lets the current sweep finish —
    // interrupting one would leave the journal without its entry, and an
    // unexplained gap is the one thing this loop is built not to produce.
    askedToStop = true;
    await watchdog.stop();
    await journal.record(watchdogStoppedRecord(at: DateTime.now()));
    await WatchdogBoard.shared.close();
    store.close();
    return code;
  }

  static String _secs(Duration d) {
    final seconds = d.inMilliseconds / 1000;
    return seconds == seconds.roundToDouble()
        ? '${seconds.round()}s'
        : '${seconds}s';
  }

  /// Holds the process open on [server] and returns when Ctrl-C closes it.
  ///
  /// The signal is watched here rather than left to revali's own
  /// `listenForShutdown`, because the generated server installs that handler
  /// only when it bound the socket itself — `providedServer == null` — and
  /// this verb hands it one. Ctrl-C would otherwise kill the process by
  /// default disposition with the store's WAL still open.
  Future<int> _serveUntilInterrupted(HttpServer server) async {
    final stopped = Completer<int>();
    final interrupts = ProcessSignal.sigint.watch().listen((_) async {
      if (stopped.isCompleted) return;
      out.writeln('sprout: stopping.');
      await server.close(force: true);
      if (!stopped.isCompleted) stopped.complete(exitOk);
    });
    try {
      return await stopped.future;
    } finally {
      await interrupts.cancel();
    }
  }

  /// The URL a browser is meant to open.
  ///
  /// `127.0.0.1` and never `localhost`: the daemon binds the literal loopback
  /// address (`main_app.dart` explains why at length — `'localhost'` makes the
  /// generated `_bindServer` bind every interface), and a printed hostname
  /// that resolves elsewhere would be a URL the daemon is not on.
  String _url(String host, int port) => 'http://$host:$port/';
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
  // `watch` never receives one — `watchFrames` does not emit a picture — but
  // the socket in `routes/` opens with one, and the sealed switch is what
  // makes that a compile error here rather than a frame nobody renders. The
  // snapshot's own `render()` is reused so a picture reads identically
  // whichever surface printed it.
  SnapshotFrame(:final snapshot) =>
    'snapshot | ${frame.cursor.encode()}\n${snapshot.render()}',
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
  // `watch` never receives one either — the watchdog runs in the daemon and
  // this verb reads the store directly. It is rendered anyway, and rendered in
  // full: the sweep's own `why` is the sentence, never a summary of it, and a
  // consumer pointed at the socket with `--json` gets the same words the board
  // does. Note there is no "watchdog ok" line for a quiet sweep — the `why`
  // says what was actually established, which on a blind sweep is nothing.
  WatchdogFrame(:final why, :final stalled, :final blind, :final failure) => [
    'watchdog | ${frame.cursor.encode()} | ${stalled.length} stalled, '
        '${blind.length} unmeasured of ${frame.nodesSwept} | $why',
    if (failure != null) '  could not look: $failure',
    for (final node in stalled)
      '  ${node.silenced ? 'STALL (silenced)' : 'STALL'} | ${node.nodeId} | '
          '${node.liveness} | ring ${node.consecutiveRings} | ${node.because}',
    for (final node in blind) '  BLIND | ${node.nodeId} | ${node.because}',
  ].join('\n'),
};
