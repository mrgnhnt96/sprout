/// Deciding live / stalled / abandoned over the whole node graph at once.
library;

import 'package:sprout_protocol/values.dart';

import '../../store.dart';
import 'process_probe.dart';
import 'transcript.dart';
import 'verdict.dart';

/// How long a transcript may stand still before the node counts as frozen.
///
/// **A knob, not a finding.** Nothing in `docs/01-plan.md`, the research under
/// `docs/research/`, or the Phase 0 captures fixes a number here, and this one
/// is stated as a knob rather than dressed up as evidence — the same way
/// `defaultMaxLiveChildren` is in `policy.dart`. It is set longer than a slow
/// tool call (a test suite or a build can hold a session silent for minutes)
/// and shorter than a person's patience. P6-02's watchdog loop passes its own.
const Duration defaultFrozenAfter = Duration(minutes: 5);

/// How far a process's start time may precede the node's recorded spawn and
/// still be believed.
///
/// A legitimate process *always* starts before its own `runner.spawned` event:
/// `SessionRunner.launch` appends that event after `launcher.launch` returns
/// (`session_runner.dart` lines 160–187). On top of that, macOS `ps -o lstart=`
/// reports whole seconds, so it can only ever round a start time *down*. Both
/// errors point the same way, and this absorbs them.
///
/// It is deliberately **not** symmetric. A process that started *after* the
/// node recorded its pid is the recycled-pid case, and no tolerance forgives
/// it — see [LivenessMeasure.startTimeTolerance].
///
/// **The rule transfers to [observedProcessKind] unchanged, and the reasoning
/// is worth having written down because the next reader will wonder.** That
/// record is written from a hook payload, and a `claude` process is already
/// running by the time its own `SessionStart` hook fires — the hook is a child
/// the session starts and waits for, and the pid it reports is the session's
/// own (`CLAUDE_PID` is the hook shell's parent, measured). So on this path
/// too the process predates the record of it, by more than on the runner path
/// rather than less: sprout may only learn of a session hours after it began,
/// when the hooks are installed mid-run. A start time *later* than the record
/// still means the same thing it means for a spawn — at the moment sprout
/// wrote the pid down, that pid was the session's, so a process wearing it
/// that began afterwards is a different process.
const Duration defaultStartTimeTolerance = Duration(seconds: 2);

/// The event kinds that carry a node's `pid` and `raw_log`.
///
/// **Two ways in, one measurement.** [runnerSpawnedKind] is written by
/// `SessionRunner` for a process sprout launched; [observedProcessKind] is
/// written by `HookProjection` for a session sprout only ever saw through a
/// hook. What the two mean about *provenance* is different, and that is why
/// they are separate kinds — but what they mean about *liveness* is identical,
/// a pid to probe beside a transcript to time, so everything below reads them
/// through one path.
///
/// Forking that path was the alternative and it is the thing to avoid: two
/// copies of the recycled-pid rule, the freeze threshold and the subtree rescue
/// would agree on the day they were written and drift afterwards, which is
/// F-01's shape. A set here costs one `contains`.
const Set<String> spawnRecordKinds = {runnerSpawnedKind, observedProcessKind};

/// The statuses that are honest endings, so not a liveness question.
///
/// `docs/01-plan.md` §5's three — checkpoint, arm, clear — plus `park`, the
/// human-only fourth. **Process exit is not on this list.** `runner.dart`
/// refuses to infer completion from exit (INV12), so a node whose process died
/// while still `working` is [Liveness.abandoned], which is the point.
const Set<NodeStatus> endedStatuses = {
  NodeStatus.checkpointed,
  NodeStatus.armed,
  NodeStatus.cleared,
  NodeStatus.parked,
};

// The three `runner.*` kinds this library reads — [runnerSpawnedKind],
// [runnerRefusedKind] and [runnerLaunchFailedKind] — were once declared here
// as well as at the runner's call sites, which was two derivations of one
// string and so F-01's shape. They are imported from
// `package:sprout_protocol/values.dart` now, where the runner writes them
// from: producer and reader read one declaration, and a rename is a compile
// error rather than something a test has to notice. That was F-12.
// `lib/liveness.dart` re-exports them, so nothing that imported them from
// here had to move.

/// Measures `docs/01-plan.md` §5's three liveness verdicts over a store.
///
/// **The whole forest at once, on purpose.** A node frozen because it is
/// blocked on a child that *is* making progress is live, and that cannot be
/// decided from the node alone — so [sweep] reads the tree, measures every
/// node's own pulse, and only then resolves each verdict against its subtree.
/// Measuring one node in isolation is how a watchdog pages every time an
/// orchestrator waits, and a watchdog that does that is switched off.
///
/// **Nothing here acts.** There is no kill, no signal, no reclaim, and there
/// must never be one: §5 says *"Never auto-reclaim a stalled node"* because the
/// real incident behind the rule held four uncommitted files and a green test
/// suite. Surface it, page, never act.
final class LivenessMeasure {
  /// Creates a measurement over [store].
  ///
  /// [processes] and [transcripts] default to the real `ps` and the real
  /// filesystem. [clock] exists so a test can age a transcript without waiting
  /// out [frozenAfter].
  LivenessMeasure({
    required this.store,
    this.processes = const PsProcessProbe(),
    this.transcripts = const FileTranscripts(),
    this.frozenAfter = defaultFrozenAfter,
    this.startTimeTolerance = defaultStartTimeTolerance,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where the node graph and the event feed are read from.
  final SproutStore store;

  /// Answers whether a pid is alive and when it started.
  final ProcessProbe processes;

  /// Answers when a node's raw transcript was last written.
  final TranscriptIndex transcripts;

  /// How long a transcript may stand still before the node counts as frozen.
  final Duration frozenAfter;

  /// How far a process start time may precede the recorded spawn.
  ///
  /// One-sided. A start time *later* than the spawn by any margin at all means
  /// the pid was recycled and the process wearing it is not ours.
  final Duration startTimeTolerance;

  final DateTime Function() _clock;

  /// Every node in the graph, with its verdict. Parents and children alike.
  ///
  /// Throws [TreeIntegrityError] if `parent_id` forms a cycle, rather than
  /// reporting on a subset — a silently short sweep and a small tree look the
  /// same, and the node missing from a short sweep is exactly the runaway.
  Future<Map<String, LivenessVerdict>> sweep() async {
    final tree = store.tree();
    final now = _clock().toUtc();

    final readings = <String, _Reading>{};
    for (final positioned in tree) {
      readings[positioned.node.id] = await _read(positioned.node, now);
    }

    // `tree()` has already proved the graph is a forest, so the walk below
    // terminates without a visited set.
    final childrenOf = <String, List<String>>{};
    for (final positioned in tree) {
      final parent = positioned.node.parentId;
      if (parent == null) continue;
      (childrenOf[parent] ??= <String>[]).add(positioned.node.id);
    }

    return {
      for (final positioned in tree)
        positioned.node.id: _resolve(positioned.node.id, readings, childrenOf),
    };
  }

  /// One node's verdict, or null when no node has that id.
  ///
  /// Measures the whole forest to answer it: the waiting case needs the
  /// subtree, and the subtree needs the tree. Callers with more than one node
  /// to ask about should call [sweep] once instead.
  Future<LivenessVerdict?> verdictFor(String nodeId) async =>
      (await sweep())[nodeId];

  /// Takes one node's own pulse, with no reference to its subtree.
  Future<_Reading> _read(SproutNode node, DateTime now) async {
    if (endedStatuses.contains(node.status)) {
      return _Reading(
        _Pulse.ended,
        because: 'the node ended: ${node.status.wire}',
      );
    }

    final spawn = _newestSpawn(node.id);
    if (spawn == null) {
      return _Reading(_Pulse.neverStarted, because: _whyNotStarted(node.id));
    }

    final pid = spawn.pid;
    if (pid == null) {
      // A record that names no process. The node was observed — something
      // wrote this event about it — but there is nothing to probe, so this is
      // a failed look and not a finding about the world. [Liveness.unmeasured]
      // is what that is, and the alternative is the one thing this path must
      // never do: page a human about a healthy subagent of a session they are
      // sitting in front of.
      return _Reading(
        _Pulse.unreadable,
        because:
            'the ${spawn.kind} event for this node names no pid, so there is '
            'no process to look at${spawn._note}',
        spawnedAt: spawn.at,
      );
    }

    final look = await processes.inspect(pid);
    switch (look) {
      case ProcessUnreadable(:final why):
        return _Reading(
          _Pulse.unreadable,
          because: 'could not look at pid $pid: $why',
          pid: pid,
          spawnedAt: spawn.at,
        );
      case ProcessGone():
        return _Reading(
          _Pulse.gone,
          because: 'no process holds pid $pid, and the node recorded no ending',
          pid: pid,
          spawnedAt: spawn.at,
        );
      case ProcessRunning(:final startedAt):
        if (startedAt.isAfter(spawn.at.add(startTimeTolerance))) {
          return _Reading(
            _Pulse.recycled,
            because:
                'pid $pid is alive but its process started at '
                '$startedAt, after this node recorded it at ${spawn.at}, so '
                'the pid was reused and that process is not ours',
            pid: pid,
            processStartedAt: startedAt,
            spawnedAt: spawn.at,
          );
        }
        return _pulseFromTranscript(spawn, pid, startedAt, now);
    }
  }

  Future<_Reading> _pulseFromTranscript(
    _Spawn spawn,
    int pid,
    DateTime startedAt,
    DateTime now,
  ) async {
    if (spawn.rawLog == null) {
      return _Reading(
        _Pulse.unreadable,
        because:
            'the ${spawn.kind} event for pid $pid carries no raw_log path, '
            'so there is no transcript to time${spawn._note}',
        pid: pid,
        processStartedAt: startedAt,
        spawnedAt: spawn.at,
      );
    }

    final look = await transcripts.lastWrite(spawn.rawLog!);
    final DateTime reference;
    final String what;
    switch (look) {
      case TranscriptUnreadable(:final path, :final why):
        return _Reading(
          _Pulse.unreadable,
          because: 'could not stat the transcript $path: $why',
          pid: pid,
          processStartedAt: startedAt,
          spawnedAt: spawn.at,
        );
      case TranscriptAbsent():
        // Not frozen — never written. The spawn is the only honest reference,
        // so a node that has produced nothing yet is young rather than stuck,
        // and becomes stalled on the same threshold as everyone else.
        reference = spawn.at;
        what = 'the transcript has not been written yet, and the node spawned';
      case TranscriptWritten(:final modifiedAt):
        // A transcript whose mtime predates the spawn belongs to an earlier
        // run of the same node id. Newest-wins (§11): the spawn still bounds
        // how long this process can have been silent.
        reference = modifiedAt.isAfter(spawn.at) ? modifiedAt : spawn.at;
        what = modifiedAt.isAfter(spawn.at)
            ? 'the transcript last grew'
            : 'the transcript predates this spawn, which was';
    }

    final frozenFor = now.difference(reference);
    final pulse = frozenFor < frozenAfter ? _Pulse.advancing : _Pulse.frozen;
    return _Reading(
      pulse,
      because:
          'pid $pid is alive and started at $startedAt; $what '
          '${_ago(frozenFor)} (threshold ${_ago(frozenAfter)})',
      pid: pid,
      processStartedAt: startedAt,
      spawnedAt: spawn.at,
      lastWrite: reference,
      frozenFor: frozenFor,
    );
  }

  /// Turns one node's pulse into a verdict, consulting its subtree only when
  /// the node is alive but frozen.
  ///
  /// The rescue is deliberately narrow. A node whose own process is gone is
  /// not *waiting* on anything, so an advancing descendant does not save it —
  /// that would hide a dead orchestrator behind a busy child.
  LivenessVerdict _resolve(
    String nodeId,
    Map<String, _Reading> readings,
    Map<String, List<String>> childrenOf,
  ) {
    final reading = readings[nodeId]!;
    LivenessVerdict as(
      Liveness liveness, {
      String? because,
      String? waitingOn,
    }) {
      return LivenessVerdict(
        nodeId: nodeId,
        liveness: liveness,
        because: because ?? reading.because,
        pid: reading.pid,
        processStartedAt: reading.processStartedAt,
        spawnedAt: reading.spawnedAt,
        lastWrite: reading.lastWrite,
        frozenFor: reading.frozenFor,
        waitingOn: waitingOn,
      );
    }

    switch (reading.pulse) {
      case _Pulse.ended:
        return as(Liveness.ended);
      case _Pulse.unreadable:
        return as(Liveness.unmeasured);
      case _Pulse.advancing:
        return as(Liveness.live);
      case _Pulse.gone:
      case _Pulse.recycled:
      case _Pulse.neverStarted:
        return as(Liveness.abandoned);
      case _Pulse.frozen:
        final advancing = _advancingDescendant(nodeId, readings, childrenOf);
        if (advancing == null) return as(Liveness.stalled);
        return as(
          Liveness.live,
          because:
              '${reading.because} — but descendant $advancing is advancing, '
              'so this node is waiting, not stalled',
          waitingOn: advancing,
        );
    }
  }

  /// The id of some descendant whose own transcript is still growing, or null.
  ///
  /// Transitive on purpose: an orchestrator waiting on a middle node that is
  /// itself waiting on a working leaf is live, and only the leaf is advancing.
  /// An *ended* descendant never counts — a subtree that has finished while
  /// the parent stays frozen is precisely the case that must page.
  String? _advancingDescendant(
    String nodeId,
    Map<String, _Reading> readings,
    Map<String, List<String>> childrenOf,
  ) {
    for (final childId in childrenOf[nodeId] ?? const <String>[]) {
      if (readings[childId]?.pulse == _Pulse.advancing) return childId;
      final deeper = _advancingDescendant(childId, readings, childrenOf);
      if (deeper != null) return deeper;
    }
    return null;
  }

  /// The newest spawn record for [nodeId], or null if it never started.
  ///
  /// Newest wins (§11). A node id that was launched twice has two spawn
  /// events, and the older one's pid is the one most likely to have been
  /// recycled — believing it is how a watchdog reports on a process that
  /// stopped existing hours ago.
  ///
  /// Any kind in [spawnRecordKinds] counts, and the kind that won is carried
  /// on the result so that every sentence below names the event a human can
  /// actually go and look at. Newest-wins is across the whole set rather than
  /// per kind on purpose: a session sprout launched *and* has hooks installed
  /// for produces both, and the two describe one process — taking the newer is
  /// the same rule as taking the newer of two launches.
  ///
  /// **A record with no `pid` is kept, not skipped.** It is the honest shape
  /// for a node whose process sprout cannot name — a hook-observed subagent,
  /// which has no process of its own — and skipping it would report the node
  /// as never having started, which is [Liveness.abandoned] and pages. A
  /// `runner.spawned` always carries one, so nothing on that path changes.
  _Spawn? _newestSpawn(String nodeId) {
    _Spawn? newest;
    for (final event in store.eventsSince(0, nodeId: nodeId)) {
      if (!spawnRecordKinds.contains(event.kind)) continue;
      final pid = event.payload['pid'];
      final rawLog = event.payload['raw_log'];
      final why = event.payload['why'];
      newest = _Spawn(
        kind: event.kind,
        pid: pid is int ? pid : null,
        at: event.ts,
        rawLog: rawLog is String ? rawLog : null,
        why: why is String ? why : null,
      );
    }
    return newest;
  }

  /// Why a node has no spawn event, said in the feed's own words when it can.
  String _whyNotStarted(String nodeId) {
    for (final event in store.eventsSince(0, nodeId: nodeId).reversed) {
      if (event.kind == runnerRefusedKind) {
        return 'no process was ever started: the containment gate refused the '
            'launch (${event.payload['explanation'] ?? event.payload['reason']})';
      }
      if (event.kind == runnerLaunchFailedKind) {
        return 'no process was ever started: the launch failed '
            '(${event.payload['error']})';
      }
    }
    return 'no ${spawnRecordKinds.join(' or ')} event for this node, and no '
        'ending recorded';
  }

  static String _ago(Duration d) {
    if (d.inSeconds.abs() < 90) return '${d.inSeconds}s ago';
    if (d.inMinutes.abs() < 90) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

/// The newest process record for a node, from either of [spawnRecordKinds].
final class _Spawn {
  const _Spawn({
    required this.kind,
    required this.pid,
    required this.at,
    required this.rawLog,
    required this.why,
  });

  /// Which of [spawnRecordKinds] this came from, so a `because` can name the
  /// event a human would go and read.
  final String kind;

  /// The process to probe, or null when the record could not name one.
  final int? pid;

  final DateTime at;
  final String? rawLog;

  /// The producer's own sentence about what it could not establish, when it
  /// wrote one. Carried into the verdict rather than restated here: the
  /// producer knows why, and this file would have to guess.
  final String? why;

  /// The producer's sentence, ready to append to a measurement's own.
  String get _note => why == null ? '' : ': $why';
}

/// A node's own pulse, before its subtree is consulted.
enum _Pulse {
  advancing,
  frozen,
  gone,
  recycled,
  neverStarted,
  ended,
  unreadable,
}

/// One node's pulse plus the evidence for it.
final class _Reading {
  const _Reading(
    this.pulse, {
    required this.because,
    this.pid,
    this.processStartedAt,
    this.spawnedAt,
    this.lastWrite,
    this.frozenFor,
  });

  final _Pulse pulse;
  final String because;
  final int? pid;
  final DateTime? processStartedAt;
  final DateTime? spawnedAt;
  final DateTime? lastWrite;
  final Duration? frozenFor;
}
