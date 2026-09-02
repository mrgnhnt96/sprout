/// Folding a session's frames into the store, one frame at a time.
library;

import '../../store.dart';
import '../../stream.dart';

/// The prefix on every event kind that is a frame the CLI emitted, as opposed
/// to something the runner itself recorded (`runner.*`).
const String frameKindPrefix = 'frame.';

/// The event appended when a subagent node is recorded for the first time.
///
/// The runner does not launch a subagent — Claude Code does — so there is no
/// `runner.spawned` for one. This is its counterpart: it is attributed to the
/// subagent's own id, exactly as `runner.spawned` is attributed to the root's,
/// and it is what lets a consumer holding a snapshot plus every delta since
/// learn that the node exists without taking a fresh snapshot.
const String subagentObservedKind = 'runner.observed';

/// The event appended when a subagent node already in the feed changes.
///
/// A subagent's `status` and `current_task` both move while it runs, and a
/// feed that announced the node once and then went quiet would leave a live
/// tree showing a node frozen on its first label. Separate from
/// [subagentObservedKind] so that a change is never mistaken for a second
/// creation of the same node.
const String subagentUpdatedKind = 'runner.updated';

/// Projects one session's stream into the store as it arrives.
///
/// Every frame becomes one event, attributed to the node that emitted it — the
/// root, or the subagent named by `parent_tool_use_id` — and every subagent the
/// tree observes becomes a node row under the root, together with an event
/// announcing it. The store is a *view* of the run; the raw log is the run.
/// The two are written in that order, so an exception here can never cost the
/// frame that caused it.
///
/// A node's event is appended *before* the first frame attributed to that
/// node: `observe` syncs the subagents and only then appends the frame. That
/// order is what keeps a consumer from ever reading an event against a node it
/// has not been told about.
///
/// What the events carry is the frame verbatim, in a `payload` column. The
/// kinds are open strings (`frame.assistant`, `frame.system.init`,
/// `frame.result`, `frame.malformed`, …) rather than an enum, for the reason
/// `SproutEvent.kind` gives: closing the set would force a migration every
/// time a new frame type is captured.
final class StoreProjection {
  /// Creates a projection for the run rooted at [rootId], which must already
  /// be a node in [store] — every event needs a node to hang off.
  StoreProjection({
    required this.store,
    required this.rootId,
    required this.project,
    required this._clock,
  });

  /// Where the run is written.
  final SproutStore store;

  /// sprout's id for the root session's node.
  final String rootId;

  /// The project the root runs in, inherited by every subagent node.
  final String project;

  final DateTime Function() _clock;

  /// The folded view of everything observed so far.
  final StreamTranscript transcript = StreamTranscript();

  final Map<String, SproutNode> _subagents = {};
  bool _sessionRecorded = false;

  /// The parent recorded for a subagent whose spawn was never observed.
  ///
  /// A node that emits frames before — or without — the assistant frame that
  /// spawned it is an orphan, and `SessionTree` refuses to guess its parent.
  /// This id names no node, so `SproutStore.tree` reports the orphan as a root
  /// of its own fragment rather than dropping it or attaching it to the root,
  /// which is the shape a runaway takes and the thing sprout exists to show.
  String get unobservedParentId => '$rootId/unobserved-parent';

  /// sprout's node id for the subagent spawned by tool call [toolUseId].
  String subagentNodeId(String toolUseId) => '$rootId/$toolUseId';

  /// Folds [frame] into the transcript, syncs any node it introduced or
  /// changed, and appends it to the feed.
  void observe(StreamFrame frame) {
    transcript.observe(frame);
    _syncSubagents();
    _recordSessionOnce();
    store.append(
      nodeId: _emitterOf(frame),
      kind: kindOf(frame),
      payload: payloadOf(frame),
      ts: _clock(),
    );
  }

  /// The event kind for [frame]: `frame.<type>`, with `.<subtype>` appended
  /// for `system` frames, and `frame.malformed` for a line that was not JSON.
  static String kindOf(StreamFrame frame) => switch (frame) {
    MalformedFrame() => '${frameKindPrefix}malformed',
    SystemFrame(:final subtype?) => '${frameKindPrefix}system.$subtype',
    _ => '$frameKindPrefix${frame.type ?? 'untyped'}',
  };

  /// The event payload for [frame]: the frame verbatim, or for a malformed
  /// line the text and the error, since there is no object to store.
  static Map<String, Object?> payloadOf(StreamFrame frame) => switch (frame) {
    MalformedFrame(:final line, :final error) => {
      'line': line,
      'error': error.toString(),
    },
    _ => frame.raw,
  };

  String _emitterOf(StreamFrame frame) {
    if (frame case EmittedFrame(:final parentToolUseId?)) {
      return subagentNodeId(parentToolUseId);
    }
    return rootId;
  }

  /// Records `runner.session` once, on the first `system/init` — the frame
  /// that carries the model and CLI version alongside the session id. A hook
  /// frame can arrive before it (`A.ndjson` opens with `hook_started`), and a
  /// record taken then would have every field but the id empty.
  void _recordSessionOnce() {
    if (_sessionRecorded || transcript.inits.isEmpty) return;
    _sessionRecorded = true;
    final init = transcript.inits.first;
    store.append(
      nodeId: rootId,
      kind: 'runner.session',
      payload: {
        'session_id': init.sessionId ?? transcript.sessionId,
        'model': init.model,
        'claude_code_version': init.claudeCodeVersion,
        'cwd': init.cwd,
        'permission_mode': init.permissionMode,
      },
      ts: _clock(),
    );
  }

  void _syncSubagents() {
    for (final agent in transcript.tree.subagents) {
      final toolUseId = agent.id;
      if (toolUseId == null) continue;
      final id = subagentNodeId(toolUseId);
      final previous = _subagents[id];
      final next = SproutNode(
        id: id,
        parentId: !agent.parentObserved
            ? unobservedParentId
            : agent.parentId == null
            ? rootId
            : subagentNodeId(agent.parentId!),
        project: project,
        status: _statusOf(toolUseId),
        currentTask: agent.description,
        since: previous?.since ?? _clock(),
      );
      if (previous != null && _same(previous, next)) continue;
      store.putNode(next);
      // The event is appended here, beside the row it describes, so that a
      // row can never be written without the feed learning of it. `_same`
      // above is what keeps this from firing once per frame: an update event
      // is appended only when a field a consumer renders actually moved.
      store.append(
        nodeId: id,
        kind: previous == null ? subagentObservedKind : subagentUpdatedKind,
        payload: previous == null
            ? _observedPayload(toolUseId, next)
            : _updatedPayload(toolUseId, previous, next),
        ts: _clock(),
      );
      _subagents[id] = next;
    }
  }

  /// The whole node, so a consumer can build the row from this event alone
  /// rather than having to re-`snapshot` to learn the fields.
  static Map<String, Object?> _observedPayload(
    String toolUseId,
    SproutNode node,
  ) => {
    'tool_use_id': toolUseId,
    'parent_id': node.parentId,
    'project': node.project,
    'status': node.status.wire,
    'current_task': node.currentTask,
  };

  /// Only what moved, each as `{from, to}`.
  ///
  /// A consumer that has applied the [subagentObservedKind] event already
  /// holds the rest, and spelling out the unchanged fields would make a
  /// status flip indistinguishable from a re-creation in the feed.
  static Map<String, Object?> _updatedPayload(
    String toolUseId,
    SproutNode previous,
    SproutNode next,
  ) => {
    'tool_use_id': toolUseId,
    if (previous.parentId != next.parentId)
      'parent_id': {'from': previous.parentId, 'to': next.parentId},
    if (previous.status != next.status)
      'status': {'from': previous.status.wire, 'to': next.status.wire},
    if (previous.currentTask != next.currentTask)
      'current_task': {'from': previous.currentTask, 'to': next.currentTask},
  };

  NodeStatus _statusOf(String toolUseId) {
    for (final task in transcript.tasks.tasks.values) {
      if (task.toolUseId == toolUseId && task.isCompleted) {
        return NodeStatus.checkpointed;
      }
    }
    return NodeStatus.working;
  }

  static bool _same(SproutNode a, SproutNode b) =>
      a.parentId == b.parentId &&
      a.status == b.status &&
      a.currentTask == b.currentTask;
}
