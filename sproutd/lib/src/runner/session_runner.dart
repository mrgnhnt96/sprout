/// Spawning one `claude -p` session and owning it until it ends.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessSignal;
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sprout_protocol/values.dart';

import '../../policy.dart';
import '../../store.dart';
import '../../stream.dart';
import 'launcher.dart';
import 'projection.dart';
import 'raw_log.dart';

part 'outcome.dart';

/// The `--max-budget-usd` a session under [parentId] is launched with.
///
/// The tightest ceiling the new node sits under: whatever the run has left
/// after what [ledger] has already spent, and — for every ancestor above it —
/// whatever that ancestor's subtree ceiling has left. A root has no ancestors,
/// so it gets the tighter of the subtree ceiling and the run's remainder,
/// which is what this computed before P4-02 gave a spawn a parent.
///
/// The ancestor half is the part that only exists once spawns are parented,
/// and leaving it out would have been a hole this leaf opened: a child handed
/// the full subtree ceiling could spend it again beneath a parent that had
/// already spent most of it, and `--max-budget-usd` would have permitted
/// exactly the runaway the ceiling exists to bound.
///
/// **This is an upper bound on what is left, not a measurement of it.** The
/// spend it subtracts is a floor whenever a node in the tree reported no
/// dollar figure — see `ObservedLedger`, and INV7 — so the remainder it
/// returns can only be too generous, never too tight.
///
/// Never negative: a run or a subtree already past its ceiling is refused by
/// the gate before this is computed, so a negative here would be a bug, and
/// clamping keeps the flag parseable if one ever slips through.
double spawnBudgetUsd(
  ContainmentPolicy policy,
  SpendLedger ledger, {
  String? parentId,
}) {
  var remaining = max(0.0, policy.runBudgetUsd - ledger.totalCostUsd);
  remaining = min(policy.subtreeBudgetUsd, remaining);
  if (parentId == null) return remaining;
  for (final ancestorId in ledger.ancestryOf(parentId)) {
    final ancestorRemaining = max(
      0.0,
      policy.subtreeBudgetUsd - ledger.subtreeCostUsd(ancestorId),
    );
    remaining = min(remaining, ancestorRemaining);
  }
  return remaining;
}

final Random _idRandom = Random.secure();

/// Mints a node id: a millisecond timestamp in base 36, then 32 random bits.
///
/// Public because a caller sometimes has to know the id **before** the launch.
/// `sprout run --worktree` is the case that made it so: the worktree's path is
/// derived from the node id and goes into `SessionRequest.project`, which is
/// written onto the node row — and `SproutStore.putNode` deliberately does not
/// emit a patch for `project`, so a row created with one project and corrected
/// afterwards would correct only the database and never the feed. Minting here
/// and passing `SessionRequest.nodeId` is what keeps the row right the first
/// time.
///
/// Sortable by the timestamp and unique by the salt, in that order, so ids
/// group by run in any listing that sorts them while two spawned in the same
/// millisecond still differ.
String newNodeId() {
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final salt = _idRandom.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '${stamp.toRadixString(36)}-$salt';
}

/// Spawns `claude -p` sessions, streams each one to disk and into the store,
/// and reports how it ended.
///
/// One session per call, at whatever depth its `SessionRequest.parentId` puts
/// it. Before P4-02 that was always depth 0 over an empty ledger, so the
/// containment check ran on every launch and could not refuse any of them; it
/// ran anyway, because a cap added later is a cap that was absent when it
/// mattered (INV14). Deciding a *tree* of them — decomposition, waves, a
/// worktree per child — is still the rest of Phase 4.
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

  static const String Function() _defaultNodeId = newNodeId;

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
  /// [ledger] is the tree as it stands, and it is what every bound is judged
  /// against: `readLedger` in `lib/snapshot.dart` builds one from a store. It
  /// defaults to empty, which is what the very first root of a run is decided
  /// over and **only** that — an empty ledger clears the depth cap, the
  /// budgets and the concurrency bounds by construction, so passing none for a
  /// spawn that has a tree above it is a gate that cannot say no (INV8).
  ///
  /// Throws [ArgumentError] before writing anything if
  /// [SessionRequest.parentId] names a node [ledger] does not hold. See that
  /// field, and `ContainmentPolicy.decide`, for why that is not a refusal.
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
    final parentId = request.parentId;
    // `ContainmentPolicy.decide` makes this same check and throws rather than
    // refusing, deliberately: an unknown parent has an unknown depth, so no
    // spawn beneath it can be bounded at all, and treating it as a fragment
    // root would hand a node that might be at depth 7 a fresh three levels.
    // It is repeated *here* only to move it earlier than the node write below
    // — a launch that nobody could decide must leave no node behind, and it is
    // not a refusal, so there is no reason to count it under.
    if (parentId != null && !tree.contains(parentId)) {
      throw ArgumentError.value(
        parentId,
        'request.parentId',
        'not in the ledger, so its depth is unknown and no spawn beneath it '
            'can be bounded',
      );
    }
    final now = _clock();

    // `putNode` announces the row on the feed in the same call, so this is
    // also where the root introduces itself to a consumer that attached before
    // the run existed. It happens before the gate is asked, so even a refusal
    // is reported against a node the feed has described.
    store.putNode(
      SproutNode(
        id: nodeId,
        // Written onto the row, not only handed to the gate: the next
        // decision is taken over a ledger read back out of the store, so a
        // parent that lived only in the request would give this child a
        // correct depth and its own children a wrong one.
        parentId: parentId,
        project: request.project,
        status: NodeStatus.spawning,
        currentTask: request.task,
        since: now,
      ),
      ts: now,
    );

    final decision = gate.admit(
      SpawnRequest(
        ledger: tree,
        parentId: parentId,
        estimatedCostUsd: request.estimatedCostUsd,
      ),
    );
    final SpawnPermit permit;
    switch (decision) {
      case SpawnRefusal():
        store.append(
          nodeId: nodeId,
          kind: runnerRefusedKind,
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
      maxBudgetUsd: spawnBudgetUsd(gate.policy, tree, parentId: parentId),
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
        kind: runnerLaunchFailedKind,
        payload: {'error': error.toString(), 'launch': launch.toJson()},
        ts: _clock(),
      );
      rethrow;
    }

    store.append(
      nodeId: nodeId,
      kind: runnerSpawnedKind,
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
        kind: runnerExitedKind,
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

  /// Moves the root to [status], and lets the feed say so.
  ///
  /// The transition has to reach the feed as well as the row: a consumer built
  /// from deltas alone would otherwise show the root stuck on the status it
  /// launched with for the whole run. `putNode` appends the `runner.updated`
  /// itself, and appends nothing when the status did not actually move.
  void _markRoot(NodeStatus status) {
    final store = _projection.store;
    final node = store.node(nodeId);
    if (node == null) return;
    store.putNode(node.copyWith(status: status), ts: _clock());
  }
}
