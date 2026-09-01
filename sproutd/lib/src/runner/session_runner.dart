/// Spawning one `claude -p` session and owning it until it ends.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessSignal;
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../policy.dart';
import '../../store.dart';
import '../../stream.dart';
import 'launcher.dart';
import 'projection.dart';
import 'raw_log.dart';

part 'outcome.dart';

/// The `--max-budget-usd` a root session is launched with under [policy].
///
/// The tighter of the two ceilings a root sits under: its own subtree's, and
/// whatever the run has left after what [ledger] has already spent. Never
/// negative — a run already past its ceiling is refused by the gate before
/// this is computed, so a negative here would be a bug, and clamping keeps the
/// flag parseable if one ever slips through.
double rootBudgetUsd(ContainmentPolicy policy, SpendLedger ledger) {
  final runRemaining = max(0.0, policy.runBudgetUsd - ledger.totalCostUsd);
  return min(policy.subtreeBudgetUsd, runRemaining);
}

/// Spawns `claude -p` sessions at depth 0, streams each one to disk and into
/// the store, and reports how it ended.
///
/// Phase 1 spawns exactly one root per call and no children: delegation is
/// Phase 4. The containment check runs anyway, before every launch, because
/// a cap added later is a cap that was absent when it mattered (INV14).
final class SessionRunner {
  /// Creates a runner writing to [store] and [logDirectory].
  ///
  /// [launcher] defaults to the real [ClaudeLauncher]; tests pass one that
  /// replays a fixture. [clock] and [mintNodeId] exist for the same reason.
  SessionRunner({
    required this.store,
    required this.gate,
    required this.logDirectory,
    this.launcher = const ClaudeLauncher(),
    this.executable = 'claude',
    DateTime Function()? clock,
    String Function()? mintNodeId,
  }) : _clock = clock ?? DateTime.now,
       _mintNodeId = mintNodeId ?? _defaultNodeId;

  /// Where nodes and events go.
  final SproutStore store;

  /// The containment policy, with its refusal tally.
  final ContainmentGate gate;

  /// Where raw logs go: `<logDirectory>/<nodeId>.ndjson` and `.stderr`.
  final String logDirectory;

  /// Starts processes.
  final SessionLauncher launcher;

  /// The `claude` binary to launch.
  final String executable;

  final DateTime Function() _clock;
  final String Function() _mintNodeId;

  static final Random _random = Random.secure();

  static String _defaultNodeId() {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final salt = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${stamp.toRadixString(36)}-$salt';
  }

  /// Runs [request] to completion: [launch], then wait for the process to end.
  Future<SessionOutcome> run(SessionRequest request, {SpendLedger? ledger}) {
    return launch(request, ledger: ledger).then(
      (start) => switch (start) {
        RefusedSession() => Future.value(start),
        LiveSession(:final done) => done,
      },
    );
  }

  /// Consults the gate and, if permitted, starts the process.
  ///
  /// Returns without waiting for the session to end: a [LiveSession] is
  /// observable while it runs, which is the whole point of sprout. The node
  /// row is written before the gate is asked, so a refusal is recorded against
  /// a node too — sprout's own refusals must be counted (INV14), and a count
  /// held only in memory dies with the daemon.
  ///
  /// [ledger] is the tree as it stands; it defaults to empty, which is what
  /// the first root of a run is decided over.
  ///
  /// Throws whatever the launcher throws if the process cannot be started —
  /// typically a `ProcessException` because `claude` is not on `PATH` — after
  /// recording a `runner.launch_failed` event.
  Future<SessionStart> launch(
    SessionRequest request, {
    SpendLedger? ledger,
  }) async {
    final nodeId = request.nodeId ?? _mintNodeId();
    final tree = ledger ?? SpendLedger.empty();
    final now = _clock();

    store.putNode(
      SproutNode(
        id: nodeId,
        project: request.project,
        status: NodeStatus.spawning,
        currentTask: request.task,
        since: now,
      ),
    );

    final decision = gate.admit(
      SpawnRequest(ledger: tree, estimatedCostUsd: request.estimatedCostUsd),
    );
    final SpawnPermit permit;
    switch (decision) {
      case SpawnRefusal():
        store.append(
          nodeId: nodeId,
          kind: 'runner.refused',
          payload: {
            'reason': decision.reason.wire,
            'explanation': decision.explanation,
            'refusals': gate.refusals.toWireMap(),
          },
          ts: now,
        );
        return RefusedSession(nodeId: nodeId, refusal: decision);
      case SpawnPermit():
        permit = decision;
    }

    final launch = SessionLaunch.claude(
      task: request.task,
      project: request.project,
      maxBudgetUsd: rootBudgetUsd(gate.policy, tree),
      executable: executable,
      environment: request.environment,
    );
    final rawLogPath = p.join(logDirectory, '$nodeId.ndjson');
    final stderrLogPath = p.join(logDirectory, '$nodeId.stderr');

    final SessionProcess process;
    try {
      process = await launcher.launch(launch);
    } on Object catch (error) {
      store.append(
        nodeId: nodeId,
        kind: 'runner.launch_failed',
        payload: {'error': error.toString(), 'launch': launch.toJson()},
        ts: _clock(),
      );
      rethrow;
    }

    store.append(
      nodeId: nodeId,
      kind: 'runner.spawned',
      payload: {
        'pid': process.pid,
        'launch': launch.toJson(),
        'max_budget_usd': launch.arguments.last,
        'permit': {
          'depth': permit.depth,
          'projected_subtree_cost_usd': permit.projectedSubtreeCostUsd,
          'projected_run_cost_usd': permit.projectedRunCostUsd,
        },
        'raw_log': rawLogPath,
        'stderr_log': stderrLogPath,
      },
      ts: _clock(),
    );

    final session = LiveSession._(
      nodeId: nodeId,
      launch: launch,
      process: process,
      rawLog: RawLog.open(rawLogPath),
      stderrLog: RawLog.open(stderrLogPath),
      projection: StoreProjection(
        store: store,
        rootId: nodeId,
        project: request.project,
        clock: _clock,
      ),
      clock: _clock,
    );
    unawaited(session._pump());
    return session;
  }
}

/// A session whose process is running. Observable while it runs.
final class LiveSession implements SessionStart {
  LiveSession._({
    required this.nodeId,
    required this.launch,
    required this._process,
    required this._rawLog,
    required this._stderrLog,
    required this._projection,
    required this._clock,
  });

  @override
  final String nodeId;

  /// What was launched.
  final SessionLaunch launch;

  final SessionProcess _process;
  final RawLog _rawLog;
  final RawLog _stderrLog;
  final StoreProjection _projection;
  final DateTime Function() _clock;
  final StreamParser _parser = StreamParser();
  final StreamController<StreamFrame> _frames =
      StreamController<StreamFrame>.broadcast();
  final Completer<EndedSession> _done = Completer<EndedSession>();

  /// The process id.
  int get pid => _process.pid;

  /// Where the raw stream is being written.
  String get rawLogPath => _rawLog.path;

  /// Where stderr is being written.
  String get stderrLogPath => _stderrLog.path;

  /// The folded view so far. Reads the same object [done] will report on.
  StreamTranscript get transcript => _projection.transcript;

  /// Every frame as it is parsed, after it has been logged and stored.
  Stream<StreamFrame> get frames => _frames.stream;

  /// Completes when the process has exited and its output is fully drained.
  ///
  /// Exit is the end of the *process*. It is not evidence that the work is
  /// complete — see [EndedSession.hasResult] and [EndedSession.incompleteTasks]
  /// for what the stream actually said (INV12).
  Future<EndedSession> get done => _done.future;

  /// Sends [signal] to the process.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);

  Future<void> _pump() async {
    try {
      final stderrDrained = _process.stderr.forEach(_stderrLog.write);

      // Decoded incrementally so a multi-byte character split across chunks
      // survives; `allowMalformed` so a byte the CLI should not have written
      // becomes U+FFFD rather than an exception that ends the run.
      final decoded = StringBuffer();
      final decoder = const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(StringConversionSink.fromStringSink(decoded));

      var started = false;
      await for (final chunk in _process.stdout) {
        // Disk first, then the parser, then the store: a frame the projection
        // cannot handle is still on disk in full.
        _rawLog.write(chunk);
        decoder.add(chunk);
        final text = decoded.toString();
        decoded.clear();
        for (final frame in _parser.addChunk(text)) {
          if (!started) {
            started = true;
            _markRoot(NodeStatus.working);
          }
          _observe(frame);
        }
      }
      decoder.close();
      for (final frame in _parser.addChunk(decoded.toString())) {
        _observe(frame);
      }
      // The killed-mid-write case: a trailing line with no newline. It comes
      // back as a MalformedFrame and is stored like any other; every frame
      // before it already stands.
      for (final frame in _parser.finish()) {
        _observe(frame);
      }

      final exitCode = await _process.exitCode;
      await stderrDrained;
      _rawLog.close();
      _stderrLog.close();

      final transcript = _projection.transcript;
      if (transcript.hasResult) _markRoot(NodeStatus.checkpointed);

      final ended = EndedSession._(
        nodeId: nodeId,
        exitCode: exitCode,
        transcript: transcript,
        rawLogPath: _rawLog.path,
        stderrLogPath: _stderrLog.path,
        duplicatesDropped: _parser.duplicatesDropped,
        framesWithoutUuid: _parser.framesWithoutUuid,
      );
      _projection.store.append(
        nodeId: nodeId,
        kind: 'runner.exited',
        payload: ended.toJson(),
        ts: _clock(),
      );
      _done.complete(ended);
    } on Object catch (error, stack) {
      _rawLog.close();
      _stderrLog.close();
      _done.completeError(error, stack);
    } finally {
      await _frames.close();
    }
  }

  void _observe(StreamFrame frame) {
    _projection.observe(frame);
    _frames.add(frame);
  }

  void _markRoot(NodeStatus status) {
    final store = _projection.store;
    final node = store.node(nodeId);
    if (node == null) return;
    store.putNode(node.copyWith(status: status));
  }
}
