/// Folding hook payloads into the store, one payload at a time.
library;

import 'package:sprout_protocol/values.dart';

import '../../store.dart';
import '../stream/prompt.dart';
import 'payload.dart';

/// The prefix on every node id this projection mints.
///
/// It is what keeps the hook path's ids out of the runner's namespace, which
/// is `<base36 stamp>-<hex salt>` for a root (`SessionRunner._defaultNodeId`)
/// and `<rootId>/<toolUseId>` for a subagent. Neither can begin with `hook/`,
/// so the two paths can write the same table without ever colliding — and,
/// for the same reason, without ever recognising each other. See the
/// double-vision finding in `docs/02-open-findings.md`.
const String hookNodeIdPrefix = 'hook/';

/// The `project` written for a payload that reported no `cwd`.
///
/// `node.project` is `NOT NULL`, so a row has to say something. This says
/// *nothing was reported* in a spelling that is not a path, so no consumer can
/// mistake it for one and try to open it. Every payload in the Phase 0 corpus
/// carries a `cwd`; this exists for the payload that does not.
const String unknownHookProject = '<unknown>';

/// The environment variable a hook process reads its session's pid from.
///
/// **Measured, twice, on this machine.** A settings file whose hook dumped
/// `env | grep '^CLAUDE'` and then ran `ps -o pid=,ppid=,command= -p
/// "$CLAUDE_PID"` was run against a real `claude -p` on CLI 2.1.258 and again
/// on 2.1.259. On every event that fired, `CLAUDE_PID` was present, identical
/// across events, equal to the pid of the `claude` process itself, and equal to
/// the hook shell's own `$PPID` — so it is the session, not the hook and not a
/// wrapper. `docs/research/17-observed-schemas.md` §9 claims this; the Phase 0
/// fixtures do not contain the `env.txt` files that would have proved it, so it
/// was re-measured rather than believed.
///
/// It is the only way this path can learn a pid at all. A hook payload carries
/// no process identifier of any kind.
const String claudePidEnvVariable = 'CLAUDE_PID';

/// The environment variable carrying the session id the hook process belongs
/// to.
///
/// Read only to **refuse**: if it is present and disagrees with the payload's
/// `session_id`, the environment belongs to a different session than the bytes
/// do, and [claudePidEnvVariable] would be the wrong process. Recording a wrong
/// pid is worse than recording none — none measures as `unmeasured`, and a
/// wrong one is a confident verdict about somebody else's process.
///
/// Absence is not a refusal. Every payload the tests replay arrives with no
/// environment at all, and so does any future caller that folds a payload in
/// from somewhere other than a live hook.
const String claudeSessionIdEnvVariable = 'CLAUDE_CODE_SESSION_ID';

/// Projects hook payloads into the store, one payload at a time.
///
/// The sibling of `StoreProjection`, which does the same job for the stream
/// path: same order of operations, same sentinel for an unclaimed child, same
/// rule that a node row is written before any event is attributed to it. Read
/// that class first — most of the decisions here were made there.
///
/// **Every fact this projection remembers, it remembers in the store.** There
/// is no in-memory cache of nodes, of pending joins, or of anything else, and
/// that is the load-bearing difference from `StoreProjection`. A hook is one
/// OS process per event (P8-03): the process folds a single payload and exits,
/// so an instance of this class never sees a second payload and a field on it
/// would be empty every time it mattered. Re-reading the row is not a
/// pessimisation here, it is the only correct source.
///
/// ## What one payload does
///
/// 1. The root row for the payload's `session_id` is created or updated.
/// 2. If a subagent emitted it, that subagent's row is created or updated.
/// 3. If it is a spawn `PostToolUse`, the **callee's** row is created or
///    re-parented onto the caller.
/// 4. The payload is appended as exactly one event, attributed to the node
///    that emitted it.
///
/// Steps 1–3 before step 4, always, and for the reason `SproutStore`'s schema
/// makes non-negotiable: `event.node_id` carries a foreign key, so an event
/// whose node row does not exist is *refused by SQLite* rather than silently
/// dropped. `putNode` appends `runner.observed` / `runner.updated` beside the
/// row itself, so nothing here hand-appends those (findings F-02 and F-10).
///
/// ## Both spawn orders happen, so both are handled
///
/// A `SubagentStart` names the child and says nothing about its parent; the
/// parent link arrives only on the spawning `PostToolUse`. In one capture the
/// two orders both occur — in `hooks/B/` the root's claim of its child lands
/// **4.3 seconds after** that child had already stopped, while the
/// grandchild's claim lands **1.7 milliseconds before** its `SubagentStart`.
/// So a child is created by whichever of the two arrives first, and the join
/// re-parents it if it arrives second. A node created by the join alone is
/// [NodeStatus.spawning] — asked for, not yet reported in — and a join that
/// arrives for a node that already exists moves its `parent_id` and touches
/// nothing else, so a child that has already finished is not walked backwards
/// into `spawning`.
///
/// Until the join arrives a subagent's `parent_id` is [unobservedParentId],
/// which names no node. `SproutStore.tree` then reports it as the root of its
/// own fragment — a detached node, which is what it honestly is — rather than
/// attaching it to the session root, which would be a guess and is wrong for
/// every grandchild.
///
/// ## What it will not do
///
/// **There is no dedupe.** A hook payload carries no unique id — unlike a
/// stream frame, which has `uuid` — so replaying the same payload twice
/// appends the event twice, and there is nothing here that could tell the
/// difference between a replay and two identical events that really happened.
/// The node graph is idempotent under replay because every write is an upsert
/// of a value derived from the payload; the feed is not, and cannot be made so
/// without a key the wire does not carry.
///
/// **Tool names never reach `current_task`.** `PreToolUse` and `PostToolUse`
/// are recorded as feed events and change no row. Every `current_task` move
/// appends a `runner.updated` that a board re-renders on, and two of those per
/// tool call is the flood `nodeUpdatedKind` exists to prevent.
///
/// ## The process record, which is what makes a foreign session measurable
///
/// Seeing a session and being able to *measure* it are different things.
/// `LivenessMeasure` finds a node's process through a spawn record — a `pid` to
/// probe beside a `raw_log` to time — and only `SessionRunner` writes one, so
/// before P8-04 every hook-observed node reported *"no spawn event for this
/// node, and no ending recorded"*, which is `abandoned`, which the watchdog
/// rings on. The session most likely to be silently stuck was the one the
/// watchdog could say least about.
///
/// So this projection also writes [observedProcessKind], carrying `pid` and
/// `raw_log` under exactly those names. What it writes them **from** differs by
/// depth, and the asymmetry is the whole care of this file:
///
/// - **A root** gets the real pair: `CLAUDE_PID` from the hook process's
///   environment, and the payload's `transcript_path`. That is a session a
///   human started in a terminal, now measurable exactly as a spawned one is.
/// - **A subagent** gets neither, on purpose. There is one OS process and one
///   `session_id` per `claude -p` however deep the tree goes (`17` §2), so
///   `CLAUDE_PID` inside a subagent's payload is the *root's* pid and recording
///   it would make every child inherit the root's liveness. And
///   `transcript_path` is always the root session's `.jsonl` even inside a
///   subagent (`17` §3), so timing it to decide whether a child is frozen would
///   report the parent's pulse as the child's. A record with neither field
///   measures as `unmeasured` with a `because` naming what could not be looked
///   at, which is the honest answer and does not ring.
///
/// **It is written once per node, not once per payload.** On the payload that
/// creates the node's row — which is the first sighting, and so covers hooks
/// installed halfway through a session — and again on that node's own
/// `SessionStart` or `SubagentStart`, which is where a *new* process for an id
/// sprout already knows announces itself. `LivenessMeasure` takes the newest,
/// so a resumed session measures against its current pid. Writing one per
/// payload would put a row in the feed for every tool call, which is the flood
/// `nodeUpdatedKind` exists to prevent, arriving by a different door.
final class HookProjection {
  /// Creates a projection over [store], stamping its writes from [clock].
  ///
  /// [environment] is the hook process's own environment, which is where
  /// [claudePidEnvVariable] lives — the only place a pid can be learned on this
  /// path. It defaults to empty rather than to `Platform.environment` so that
  /// nothing here reads ambient state a caller did not hand it: a test replaying
  /// fixtures must not pick up the pid of the process running the test, which
  /// would be a live pid attached to somebody else's session id.
  HookProjection({
    required this.store,
    required this._clock,
    this.environment = const {},
  });

  /// Where the payloads are written.
  final SproutStore store;

  /// The hook process's environment. See [claudePidEnvVariable].
  final Map<String, String> environment;

  final DateTime Function() _clock;

  /// sprout's node id for the root of session [sessionId].
  static String rootNodeId(String sessionId) => '$hookNodeIdPrefix$sessionId';

  /// sprout's node id for the subagent [agentId] inside session [sessionId].
  ///
  /// Both halves are needed. `session_id` is one value for the whole tree
  /// however deep it goes (`17` §2) so it cannot identify a node on its own,
  /// and `agent_id` is scoped to the session that minted it.
  static String subagentNodeId(String sessionId, String agentId) =>
      '${rootNodeId(sessionId)}/$agentId';

  /// The parent recorded for a subagent whose spawn has not been observed yet.
  ///
  /// Names no node, deliberately: a real subagent id is 17 hex characters, so
  /// nothing can ever be written at this id. See the class doc.
  static String unobservedParentId(String sessionId) =>
      '${rootNodeId(sessionId)}/unobserved-parent';

  /// Folds one hook record into the store.
  ///
  /// Returns the id of the node the event was attributed to, or **null when
  /// the record could not be attributed to any session** — which is every
  /// [MalformedHookPayload], because input that was not JSON has no
  /// `session_id`, and any payload that arrived without one.
  ///
  /// Null is a refusal to invent, not a drop: there is no node such a record
  /// belongs to, `event.node_id` is `NOT NULL` with a foreign key, and the
  /// only ways to store it anyway would be to attach it to an unrelated
  /// session or to mint a fake node that would then render on the board as an
  /// agent. The runner path does not face this — a `MalformedFrame` there is
  /// attributed to the root of the run sprout itself launched — and the
  /// asymmetry is recorded as a finding rather than papered over here.
  String? observe(HookRecord record) {
    if (record is! HookPayload) return null;
    final sessionId = record.sessionId;
    if (sessionId == null) return null;

    final rootId = rootNodeId(sessionId);
    final agentId = record.agentId;
    final emitterId = agentId == null
        ? rootId
        : subagentNodeId(sessionId, agentId);

    // Whether each row exists is read BEFORE the write that would create it,
    // because "this payload is the first sighting of the node" is exactly when
    // the process record has to be written and is unrecoverable afterwards.
    final rootIsNew = store.node(rootId) == null;
    _writeRoot(record, sessionId);
    if (rootIsNew ||
        (!record.isFromSubagent && record.eventName == 'SessionStart')) {
      _recordRootProcess(record, sessionId);
    }

    if (agentId != null) {
      final subagentIsNew = store.node(emitterId) == null;
      _writeSubagent(record, sessionId, agentId);
      if (subagentIsNew || record.eventName == 'SubagentStart') {
        _recordSubagentProcess(record, sessionId, agentId);
      }
    }

    final spawned = record.spawnedAgentId;
    if (spawned != null) {
      final calleeIsNew =
          store.node(subagentNodeId(sessionId, spawned)) == null;
      _writeJoin(record, sessionId, spawned, emitterId);
      // A node the join created has been asked for and has reported nothing.
      // It still needs a record saying its process cannot be named: without
      // one it reads as never started, which is `abandoned`, which rings — and
      // a child claimed a millisecond before its own `SubagentStart` is the
      // grandchild's order in `hooks/B/`, so this is the normal case and not
      // an edge.
      if (calleeIsNew) _recordSubagentProcess(record, sessionId, spawned);
    }

    store.append(
      nodeId: emitterId,
      kind: record.kind,
      payload: record.raw,
      ts: _clock(),
    );
    return emitterId;
  }

  /// Creates or updates the session's root row.
  ///
  /// Any payload at all is enough to know the session exists, so an unseen one
  /// becomes a [NodeStatus.working] root. The lifecycle transitions below are
  /// applied **only to a payload the root itself emitted**: a `Stop` carrying
  /// an `agent_id` would otherwise checkpoint the root because one of its
  /// children stopped. No such payload is in the corpus — `Stop` never carries
  /// an `agent_id` there and `SubagentStop` always does — so this is a guard
  /// against a shape that has not been observed, kept because the failure it
  /// prevents is silent and the check is one field.
  void _writeRoot(HookPayload payload, String sessionId) {
    final id = rootNodeId(sessionId);
    final previous = store.node(id);
    var status = previous?.status ?? NodeStatus.working;
    var task = previous?.currentTask;

    if (!payload.isFromSubagent) {
      switch (payload.eventName) {
        case 'UserPromptSubmit':
          status = NodeStatus.working;
          task = _humanPrompt(payload) ?? task;
        case 'Stop':
        case 'SessionEnd':
          // `checkpointed` is what the runner already writes for a finished
          // root, and it is the honest end of the vocabulary rather than a
          // perfect fit: `NodeStatus` has no "the process is gone" state. See
          // the finding — adding one is a protocol change with an append-only
          // feed behind it, not a line in this file.
          status = NodeStatus.checkpointed;
      }
    }

    store.putNode(
      SproutNode(
        id: id,
        project: payload.cwd ?? previous?.project ?? unknownHookProject,
        status: status,
        currentTask: task,
        since: previous?.since ?? _clock(),
      ),
      // The one fact the row does not hold, and the one a later leaf needs to
      // join this tree to the runner's: `runner.session` carries the same
      // `session_id` for a run sprout launched itself.
      announce: {'session_id': sessionId},
      ts: _clock(),
    );
  }

  /// Records the OS process behind a session sprout did not launch.
  ///
  /// The pair a liveness measurement needs, under the two names it already
  /// reads: `pid` from [claudePidEnvVariable] and `raw_log` from the payload's
  /// `transcript_path`. Both may be missing, and a record that is missing one
  /// is still worth writing — it is what makes the node `unmeasured` with a
  /// reason instead of `abandoned` with none.
  ///
  /// **Nothing is inferred when the pid is not there.** The hook process's
  /// parent really is the session, so `getppid()` would work in the common case
  /// and would be wrong the moment anything wraps the hook — and a wrong pid is
  /// a confident verdict about a stranger's process, where a missing one is an
  /// honest `unmeasured`.
  void _recordRootProcess(HookPayload payload, String sessionId) {
    final pid = _sessionPid(sessionId);
    final rawLog = payload.transcriptPath;
    final missing = [
      if (pid == null)
        'no $claudePidEnvVariable in the hook process environment, so the '
            "session's own process could not be identified",
      if (rawLog == null)
        'the payload carried no transcript_path, so there is no transcript to '
            'time',
    ];

    store.append(
      nodeId: rootNodeId(sessionId),
      kind: observedProcessKind,
      payload: {
        'pid': ?pid,
        'raw_log': ?rawLog,
        'session_id': sessionId,
        'observed_from': payload.eventName,
        if (missing.isNotEmpty) 'why': missing.join('; '),
      },
      ts: _clock(),
    );
  }

  /// Records that a hook-observed subagent's process cannot be named.
  ///
  /// **It carries no `pid` and no `raw_log`, and that is the entire point.**
  /// Both fields are available in the payload and both would be the *root's*:
  /// there is one process per `claude -p` (`17` §2), and `transcript_path` is
  /// the root session's `.jsonl` even inside a subagent (`17` §3). Writing
  /// either would give a child its parent's liveness — a wedged subagent under
  /// a busy root would read as healthy, and every subagent of a dead session
  /// would page separately about the one process that died.
  ///
  /// So this row exists only to say *what could not be looked at*, in a
  /// sentence that reaches the human verbatim through the verdict's `because`.
  /// A node with no record at all would read as never started, which is
  /// `abandoned`, which rings — about a subagent that is very likely working
  /// perfectly well inside a session somebody is watching.
  ///
  /// The subagent's own transcript exists, at
  /// `…/<session-id>/subagents/agent-<agent_id>.jsonl`, and both `SubagentStop`
  /// captures in `hooks/B/` carry exactly that path — so it *could* be derived
  /// for a running subagent. It deliberately is not; see the finding in
  /// `docs/02-open-findings.md`, which records why deriving it is unsafe under
  /// the measurement as it stands today.
  void _recordSubagentProcess(
    HookPayload payload,
    String sessionId,
    String agentId,
  ) {
    store.append(
      nodeId: subagentNodeId(sessionId, agentId),
      kind: observedProcessKind,
      payload: {
        'session_id': sessionId,
        'agent_id': agentId,
        'observed_from': payload.eventName,
        // Kept as evidence, under a name no measurement reads. `pid` would be
        // probed; this is here so a human debugging the feed can see which
        // session's process this subagent was running inside.
        'session_pid': ?_sessionPid(sessionId),
        'why':
            'a hook-observed subagent has no process of its own — one OS '
            'process and one session_id per claude -p, however deep the tree '
            "goes — and its own transcript is not in the payload, because "
            "transcript_path is always the root session's and "
            'agent_transcript_path arrives only on SubagentStop',
      },
      ts: _clock(),
    );
  }

  /// The session's own pid, or null when it could not be established.
  ///
  /// Two ways it comes back null, and both are the honest answer rather than a
  /// fallback: [claudePidEnvVariable] is absent or is not a number, or
  /// [claudeSessionIdEnvVariable] is present and names a *different* session
  /// than the payload does — in which case the environment and the bytes are
  /// about two different processes and the pid belongs to neither this node nor
  /// this projection.
  int? _sessionPid(String sessionId) {
    final envSession = environment[claudeSessionIdEnvVariable];
    if (envSession != null && envSession != sessionId) return null;
    final raw = environment[claudePidEnvVariable];
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }

  /// The prompt text of a `UserPromptSubmit`, or null when a machine wrote it.
  ///
  /// **The brief's table says "`current_task` = the prompt" and this narrows
  /// it, because the fixtures do.** When a background node finishes, its
  /// result is delivered to the *root* as a fresh `UserPromptSubmit` whose
  /// prompt is a `<task-notification>` block — byte for byte the shape of a
  /// person starting a new task
  /// (`hooks/B/1788281001.678994-UserPromptSubmit.stdin.json`). `17` §6 is
  /// explicit that sprout "must not let a `UserPromptSubmit` gate treat it as
  /// a new task", and writing that block into `current_task` is exactly that:
  /// the board would show B's root working on its own grandchild's answer
  /// instead of on the task it was given.
  ///
  /// The status still moves to `working`, which is true — the root really did
  /// resume, and a `Stop` follows two seconds later in the same capture. Only
  /// the *task* is left alone.
  ///
  /// This is the classification `UserPromptSubmitPayload` exists for, reused
  /// rather than restated (F-14).
  static String? _humanPrompt(HookPayload payload) {
    final prompt = UserPromptSubmitPayload(payload.raw);
    return prompt.isMachineTraffic ? null : prompt.prompt;
  }

  /// Creates or updates the row for the subagent that emitted [payload].
  ///
  /// `parent_id` is preserved when the row already has one and set to the
  /// sentinel when it does not: this method never learns a parent, because a
  /// payload from inside a subagent says nothing about who spawned it. Only
  /// [_writeJoin] can claim a child.
  void _writeSubagent(HookPayload payload, String sessionId, String agentId) {
    final id = subagentNodeId(sessionId, agentId);
    final previous = store.node(id);
    var status = previous?.status ?? NodeStatus.working;
    var task = previous?.currentTask;

    switch (payload.eventName) {
      case 'SubagentStart':
        status = NodeStatus.working;
        task = payload.agentType ?? task;
      case 'SubagentStop':
        status = NodeStatus.checkpointed;
    }

    store.putNode(
      SproutNode(
        id: id,
        parentId: previous?.parentId ?? unobservedParentId(sessionId),
        project: payload.cwd ?? previous?.project ?? unknownHookProject,
        status: status,
        currentTask: task,
        since: previous?.since ?? _clock(),
      ),
      announce: {'session_id': sessionId, 'agent_id': agentId},
      ts: _clock(),
    );
  }

  /// Claims the node [payload]'s spawn call created, as a child of [callerId].
  ///
  /// This is the only place a parent link is ever written, and it is the whole
  /// reason the hook path can rebuild a tree: `tool_response.agentId` is the
  /// **callee**, the payload's own `agent_id` is the **caller**, and its
  /// absence means the caller is the root.
  ///
  /// A node that does not exist yet is created [NodeStatus.spawning] — the
  /// join arrived before the child's own `SubagentStart`, which is the
  /// grandchild's order in `hooks/B/`. A node that does exist keeps its status,
  /// its task and its `since`, and moves only its parent; that is the root's
  /// order in the same capture, where the claim lands after the child has
  /// already stopped and must not resurrect it.
  void _writeJoin(
    HookPayload payload,
    String sessionId,
    String spawnedAgentId,
    String callerId,
  ) {
    final id = subagentNodeId(sessionId, spawnedAgentId);
    final previous = store.node(id);
    store.putNode(
      SproutNode(
        id: id,
        parentId: callerId,
        project: payload.cwd ?? previous?.project ?? unknownHookProject,
        status: previous?.status ?? NodeStatus.spawning,
        currentTask: previous?.currentTask,
        since: previous?.since ?? _clock(),
      ),
      announce: {
        'session_id': sessionId,
        'agent_id': spawnedAgentId,
        // The `toolu_…` id of the spawning call. It is the child's
        // `parent_tool_use_id` on the stream path, so it is the second half of
        // the join a later leaf would need to recognise this tree as one the
        // runner is also watching (`17` §2).
        'tool_use_id': payload.toolUseId,
      },
      ts: _clock(),
    );
  }
}
