/// Where a node is in the lifecycle of `docs/01-plan.md` §5.
///
/// These are sprout's own states, not control-plane facts, so INV10 does not
/// apply: nothing here is read off a Claude Code frame. The names track §5's
/// spawn → work → three honest endings, plus the one human-only exit.
///
/// **Liveness is deliberately absent.** §5 is explicit that live / stalled /
/// abandoned is *derived* from a pid beside a transcript mtime, and that a
/// stalled node is never auto-reclaimed. Storing it as a status would turn a
/// derivation that must be recomputed into a stale fact on disk.
enum NodeStatus {
  /// The process has been asked for but has not reported in yet.
  spawning('spawning'),

  /// Running, with a bound mandate.
  working('working'),

  /// Handed back with progress and no question. The default ending.
  checkpointed('checkpointed'),

  /// Escalated — the one question §6 lets a node ask.
  armed('armed'),

  /// Genuinely done, with proof.
  cleared('cleared'),

  /// The developer called a break. Never the agent's judgement.
  parked('parked');

  const NodeStatus(this.wire);

  /// The string persisted in `node.status`.
  ///
  /// Written out rather than derived from [name] so that renaming a Dart
  /// identifier cannot silently rewrite what is already on disk.
  final String wire;

  /// Parses a value read back out of the database.
  ///
  /// Throws [ArgumentError] on an unknown value rather than falling back to a
  /// default: every string in the column was written by this file, so an
  /// unrecognised one means a schema drifted, and a silent default would hide
  /// exactly that.
  static NodeStatus fromWire(String value) {
    for (final status in NodeStatus.values) {
      if (status.wire == value) return status;
    }
    throw ArgumentError.value(value, 'value', 'not a known node status');
  }
}

/// One node of the task graph: a single agent session sprout owns.
class SproutNode {
  /// Creates a node.
  const SproutNode({
    required this.id,
    required this.project,
    required this.status,
    this.parentId,
    this.role,
    this.currentTask,
    this.since,
    this.nextCheckin,
  });

  /// Stable identifier. sprout's own id, not the session id, so that a node
  /// exists before the session that fills it has reported one.
  final String id;

  /// The parent node, or null for a root.
  ///
  /// Not a foreign key. See the note on `SproutStore.tree`: a child observed
  /// before its parent must still be recorded, because that is the shape of
  /// the runaway sprout exists to surface.
  final String? parentId;

  /// Absolute path of the project the node works in.
  final String project;

  /// The seat the node was spawned into, if roles are configured.
  final String? role;

  /// Lifecycle state.
  final NodeStatus status;

  /// One line: what the node says it is doing right now.
  final String? currentTask;

  /// When the node entered [currentTask]. UTC.
  final DateTime? since;

  /// When the node is next expected to report. UTC.
  final DateTime? nextCheckin;

  /// Returns a copy with the given fields replaced.
  SproutNode copyWith({
    String? project,
    String? role,
    NodeStatus? status,
    String? currentTask,
    DateTime? since,
    DateTime? nextCheckin,
  }) {
    return SproutNode(
      id: id,
      parentId: parentId,
      project: project ?? this.project,
      role: role ?? this.role,
      status: status ?? this.status,
      currentTask: currentTask ?? this.currentTask,
      since: since ?? this.since,
      nextCheckin: nextCheckin ?? this.nextCheckin,
    );
  }

  @override
  String toString() => 'SproutNode($id, parent: $parentId, ${status.wire})';
}

/// A [SproutNode] together with its distance from the root of its tree.
class TreeNode {
  /// Creates a positioned node.
  const TreeNode({required this.node, required this.depth});

  /// The node itself.
  final SproutNode node;

  /// 0 for a root, 1 for its children, and so on.
  ///
  /// A node whose parent is missing is a root of its own fragment and so has
  /// depth 0 — it is reported, not dropped.
  final int depth;

  @override
  String toString() => 'TreeNode(${node.id} @ $depth)';
}
