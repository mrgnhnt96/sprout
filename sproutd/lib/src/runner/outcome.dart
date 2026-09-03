part of 'session_runner.dart';

/// What to run, where, and under whom.
final class SessionRequest {
  /// Describes one session: a root when [parentId] is null, a child when it
  /// is not.
  const SessionRequest({
    required this.task,
    required this.project,
    this.nodeId,
    this.parentId,
    this.estimatedCostUsd = 0,
    this.environment = const {},
  });

  /// The prompt handed to `claude -p`.
  final String task;

  /// Absolute path of the project the session works in.
  final String project;

  /// sprout's id for the node. Minted if null; tests pass one.
  final String? nodeId;

  /// The node this session is being spawned *under*, or null for a root.
  ///
  /// This is what makes the containment gate mean anything.
  /// `ContainmentPolicy.decide` computes the child's depth as
  /// `ledger.depthOf(parentId)! + 1` and charges its estimate against every
  /// ancestor's subtree ceiling, so with this null — as it was for every spawn
  /// before P4-02, because the field did not exist — every request is depth 0
  /// over an empty tree and every bound is cleared by construction.
  ///
  /// It is written onto the node row as well as handed to the gate, so the
  /// tree the *next* decision is taken over contains this spawn. A parent
  /// recorded only in the request would give the child a correct depth once
  /// and its own children a wrong one.
  ///
  /// **Must name a node the ledger already holds.** `SessionRunner.launch`
  /// throws `ArgumentError` otherwise, which is the same refusal-to-decide
  /// `ContainmentPolicy.decide` makes and for its reason: a parent of unknown
  /// depth might be at depth 7, and treating it as a fragment root would hand
  /// its child a fresh budget of three more levels.
  final String? parentId;

  /// What the session is expected to cost, for the budget check. See
  /// `SpawnRequest.estimatedCostUsd` for why 0 is the default.
  final double estimatedCostUsd;

  /// Variables added on top of the daemon's environment.
  final Map<String, String> environment;
}

/// The answer to [SessionRunner.launch]: a process, or a refusal.
sealed class SessionStart {
  /// sprout's id for the node, assigned either way.
  String get nodeId;
}

/// The answer to [SessionRunner.run]: how the session ended, or that it never
/// started.
sealed class SessionOutcome {
  /// sprout's id for the node, assigned either way.
  String get nodeId;
}

/// The gate said no. No process was started and nothing was spent.
///
/// The refusal is also in the store as a `runner.refused` event, and counted
/// on the gate's tally: this value is the caller's copy, not the record.
final class RefusedSession implements SessionStart, SessionOutcome {
  /// Records a refusal.
  const RefusedSession({required this.nodeId, required this.refusal});

  @override
  final String nodeId;

  /// Why, and which bound.
  final SpawnRefusal refusal;

  @override
  String toString() => 'RefusedSession($nodeId, ${refusal.reason.wire})';
}

/// The process has exited and every byte it wrote has been logged, parsed and
/// stored.
///
/// Read this for what the *stream* said, not for what the exit code implies.
/// A zero exit with [hasResult] false is a session that died before
/// answering; a non-zero exit after two results is a run that answered twice
/// and then was killed. Neither is "done" or "failed" on the exit code alone
/// (INV12).
final class EndedSession implements SessionOutcome {
  EndedSession._({
    required this.nodeId,
    required this.exitCode,
    required this.transcript,
    required this.rawLogPath,
    required this.stderrLogPath,
    required this.duplicatesDropped,
    required this.framesWithoutUuid,
  });

  @override
  final String nodeId;

  /// The process exit code. On POSIX a negative value is the signal number.
  final int exitCode;

  /// Everything the stream said, folded.
  final StreamTranscript transcript;

  /// The byte-faithful copy of stdout.
  final String rawLogPath;

  /// The byte-faithful copy of stderr.
  final String stderrLogPath;

  /// Frames the parser dropped as duplicate `uuid`s.
  final int duplicatesDropped;

  /// Frames the parser could not dedupe because they carried no `uuid`.
  final int framesWithoutUuid;

  /// The session id the CLI reported, if any frame carried one.
  String? get sessionId => transcript.sessionId;

  /// Every `result` frame, in order. A run can emit more than one.
  List<ResultFrame> get results => transcript.results;

  /// The **last** result — the cumulative one — or null if none arrived.
  ResultFrame? get result => transcript.result;

  /// Whether any `result` frame arrived before the process ended.
  bool get hasResult => transcript.hasResult;

  /// Cumulative dollars from the last result, or null if none arrived.
  double? get totalCostUsd => transcript.totalCostUsd;

  /// Usage per assistant message, deduplicated by `message.id` (INV13).
  Map<String, Usage> get usageByMessageId => transcript.usageByMessageId;

  /// Token total over [usageByMessageId].
  int get totalMessageTokens => transcript.totalMessageTokens;

  /// How many frames were parsed, malformed lines included.
  int get frameCount => transcript.frames.length;

  /// Lines that were not JSON objects, including a truncated final line.
  List<MalformedFrame> get malformed => transcript.malformed;

  /// Subagents whose last seen status was not `completed` when the process
  /// ended — the subtree that had not drained (INV12).
  List<TaskLifecycle> get incompleteTasks => transcript.tasks.incomplete;

  /// A summary for the `runner.exited` event.
  Map<String, Object?> toJson() => {
    'exit_code': exitCode,
    'session_id': sessionId,
    'has_result': hasResult,
    'result_count': results.length,
    'result_subtype': result?.subtype,
    'total_cost_usd': totalCostUsd,
    'message_tokens': totalMessageTokens,
    'frames': frameCount,
    'malformed': malformed.length,
    'duplicates_dropped': duplicatesDropped,
    'frames_without_uuid': framesWithoutUuid,
    'incomplete_tasks': incompleteTasks.length,
    'subagents': transcript.tree.spawnedSubagents.length,
    'raw_log': rawLogPath,
    'stderr_log': stderrLogPath,
  };

  @override
  String toString() =>
      'EndedSession($nodeId, exit $exitCode, '
      '${results.length} results, \$$totalCostUsd)';
}
