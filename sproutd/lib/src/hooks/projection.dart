/// Folding hook payloads into the store, one payload at a time.
library;

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
final class HookProjection {
  /// Creates a projection over [store], stamping its writes from [clock].
  HookProjection({required this.store, required this._clock});

  /// Where the payloads are written.
  final SproutStore store;

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

    _writeRoot(record, sessionId);
    if (agentId != null) _writeSubagent(record, sessionId, agentId);
    final spawned = record.spawnedAgentId;
    if (spawned != null) _writeJoin(record, sessionId, spawned, emitterId);

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
