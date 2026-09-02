/// Folding a session's frames into the store, one frame at a time.
library;

import 'package:sprout_protocol/values.dart';

import '../../store.dart';
import '../../stream.dart';

/// The prefix on every event kind that is a frame the CLI emitted, as opposed
/// to something the runner itself recorded (`runner.*`).
const String frameKindPrefix = 'frame.';

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
      kind: runnerSessionKind,
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
      // `putNode` appends the event itself, beside the row it describes, so a
      // row cannot be written without the feed learning of it — see
      // [nodeObservedKind]. `_same` above only spares the write; suppressing
      // the no-op *event* is the store's job and not repeated here.
      //
      // `tool_use_id` is the one fact about a subagent the row does not hold:
      // the node id encodes it, but only a consumer that knows how ids are
      // minted could recover it, and that is not something the wire should
      // make a reader guess.
      store.putNode(next, announce: {'tool_use_id': toolUseId}, ts: _clock());
      _subagents[id] = next;
    }
  }

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
