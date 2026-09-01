import 'frame.dart';

/// One node of the reconstructed agent tree: the root session, or a subagent.
class AgentNode {
  AgentNode._(this.id) : isRoot = id == null;

  /// The `toolu_…` id of the spawn call that created this node, and the value
  /// this node reports as its own `parent_tool_use_id` on every frame it emits.
  ///
  /// Null **only** for the root, which was not spawned by anything.
  final String? id;

  /// Whether this is the root session.
  final bool isRoot;

  /// The parent's [id], or null when the parent is the root.
  ///
  /// Meaningful only once [parentObserved] is true. Null is not "no parent":
  /// the root is the node whose own [id] is null, so a null [parentId] on a
  /// non-root node means "child of the root".
  String? parentId;

  /// Whether a spawn was actually seen for this node.
  ///
  /// False on the root, and false on a node that has only ever been seen
  /// *emitting* frames — which happens when the assistant frame that spawned it
  /// was not in the slice being parsed. Such a node is an orphan, and
  /// [SessionTree] refuses to guess its parent rather than attaching it to the
  /// root, because a runaway subtree hanging off nothing is exactly the shape
  /// sprout exists to surface.
  bool parentObserved = false;

  /// The node's `agent_id`-namespace id, from `system/task_started`.
  String? taskId;

  /// Depth **as the control plane reported it**, from
  /// `system/task_started.spawn_depth`. Observed `1` for a root's child.
  ///
  /// Distinct from [SessionTree.depthOf], which derives depth from the
  /// reconstructed edges. Keeping both lets one check the other.
  int? spawnDepth;

  /// The node's one-line description.
  String? description;

  /// The subagent type, e.g. `general-purpose`.
  String? subagentType;

  /// Whether the node was launched in the background.
  bool? isBackgrounded;

  /// How many frames this node emitted.
  int framesEmitted = 0;

  /// Whether the spawn that would have created this node was **refused**.
  ///
  /// A refused spawn still leaves an `Agent` `tool_use` block in the stream
  /// with a real `toolu_…` id, so it is indistinguishable from a node that
  /// started — that is what `fixtures/phase0/streams/E.ndjson` is: one
  /// `tool_use` block, `subagent_stats.spawned == 0`, and the only record of
  /// the refusal in `result.permission_denials`.
  ///
  /// **Which means this is not known until a `result` frame arrives.** Until
  /// then a refused spawn looks live, and [SessionTree.spawnedSubagents] will
  /// overcount by one. Sprout must count the refusals it issues itself anyway
  /// (INV14); this is the stream's own confirmation, not a substitute.
  bool spawnDenied = false;

  final List<String> _childIds = [];

  /// The ids of this node's children, in the order their spawns were observed.
  List<String> get childIds => List.unmodifiable(_childIds);

  @override
  String toString() =>
      'AgentNode(${isRoot ? 'root' : id}, '
      '${_childIds.length} children, $framesEmitted frames)';
}

/// The agent tree, rebuilt from a single stream.
///
/// This was Phase 0's second question and the answer was yes: one stream is
/// enough, given `--forward-subagent-text`. The whole reconstruction is one
/// rule, and getting it wrong is the most likely way to misread the control
/// plane, because the field that carries it is named as if it were something
/// else:
///
/// > An `assistant` frame with `parent_tool_use_id = P` carrying a `tool_use`
/// > block `{name: "Agent", id: C}` means **node `P` is the parent of node
/// > `C`**. `P = null` is the root.
///
/// `parent_tool_use_id` identifies **the agent that emitted the frame**, not a
/// per-frame parent pointer. Read it the other way and every subagent looks
/// like a child of its own first tool call.
///
/// Verified against `fixtures/phase0/streams/B.ndjson`, a depth-2 tree:
/// root → `toolu_013C…` → `toolu_01HL…`.
class SessionTree {
  /// Creates a tree containing only the root.
  SessionTree() {
    _nodes[null] = AgentNode._(null);
  }

  /// Builds a tree from [frames] in one call.
  factory SessionTree.from(Iterable<StreamFrame> frames) {
    final tree = SessionTree();
    for (final frame in frames) {
      tree.observe(frame);
    }
    return tree;
  }

  final Map<String?, AgentNode> _nodes = {};

  /// The root session. Always present, even for an empty stream.
  AgentNode get root => _nodes[null]!;

  /// Every node, root included.
  Iterable<AgentNode> get nodes => _nodes.values;

  /// Every node except the root, **including spawns that were refused**.
  Iterable<AgentNode> get subagents => _nodes.values.where((n) => !n.isRoot);

  /// Nodes whose spawn a gate refused. See [AgentNode.spawnDenied].
  Iterable<AgentNode> get deniedSpawns => subagents.where((n) => n.spawnDenied);

  /// Nodes that actually came into existence.
  ///
  /// Should agree with `result.subagent_stats.spawned` once the run's last
  /// result has been folded in; if it ever does not, one of the two is wrong
  /// and that is worth noticing rather than averaging.
  Iterable<AgentNode> get spawnedSubagents =>
      subagents.where((n) => !n.spawnDenied);

  /// The node with [id], or null if no frame has mentioned it.
  AgentNode? node(String? id) => _nodes[id];

  /// The children of [id], where null means the root.
  List<AgentNode> childrenOf(String? id) => [
    for (final childId in _nodes[id]?.childIds ?? const <String>[])
      ?_nodes[childId],
  ];

  /// Nodes that have emitted frames but whose spawn was never seen.
  ///
  /// Not attached to the root as a fallback. An orphan means the parse is
  /// missing the frame that would place it, and saying so is worth more than a
  /// tree that is silently wrong (INV8).
  List<AgentNode> get orphans => [
    for (final n in subagents)
      if (!n.parentObserved) n,
  ];

  /// Depth from the root, which is 0 — or null when [id] is unknown or an
  /// orphan whose parent was never observed.
  ///
  /// **Derived from the reconstructed edges**, unlike [AgentNode.spawnDepth],
  /// which is what the control plane reported. Where both exist they should
  /// agree; if they ever stop agreeing, the reconstruction rule has drifted and
  /// that is worth failing over rather than picking a winner.
  int? depthOf(String? id) {
    var node = _nodes[id];
    if (node == null) return null;
    var depth = 0;
    // Bounded by the node count so a cycle in control-plane data — which this
    // parser has no way to rule out — cannot hang the daemon.
    for (var steps = 0; steps <= _nodes.length; steps++) {
      if (node!.isRoot) return depth;
      if (!node.parentObserved) return null;
      node = _nodes[node.parentId];
      if (node == null) return null;
      depth++;
    }
    return null;
  }

  /// Folds one frame into the tree. Order-independent: a node may be seen
  /// emitting before the frame that spawned it is read, or the reverse.
  void observe(StreamFrame frame) {
    if (frame case final EmittedFrame emitted) {
      final emitter = _ensure(emitted.parentToolUseId);
      emitter.framesEmitted++;
      emitter.subagentType ??= emitted.subagentType;
      emitter.description ??= emitted.taskDescription;
    }
    switch (frame) {
      case AssistantFrame(:final spawns, :final parentToolUseId):
        for (final spawn in spawns) {
          final childId = spawn.id;
          if (childId == null) continue;
          _link(parentId: parentToolUseId, childId: childId);
        }
      case TaskStartedFrame(
        :final toolUseId,
        :final taskId,
        :final spawnDepth,
        :final description,
        :final subagentType,
        :final isBackgrounded,
      ):
        if (toolUseId == null) return;
        final node = _ensure(toolUseId);
        node.taskId = taskId;
        node.spawnDepth = spawnDepth;
        node.description = description ?? node.description;
        node.subagentType = subagentType ?? node.subagentType;
        node.isBackgrounded = isBackgrounded;
      case TaskFrame(:final toolUseId, :final taskId):
        if (toolUseId == null) return;
        _ensure(toolUseId).taskId ??= taskId;
      case ResultFrame(:final spawnDenials):
        for (final denial in spawnDenials) {
          final deniedId = denial.toolUseId;
          if (deniedId != null) _ensure(deniedId).spawnDenied = true;
        }
      case _:
        return;
    }
  }

  AgentNode _ensure(String? id) =>
      _nodes.putIfAbsent(id, () => AgentNode._(id));

  void _link({required String? parentId, required String childId}) {
    final parent = _ensure(parentId);
    final child = _ensure(childId);
    if (!child.parentObserved) {
      child.parentId = parentId;
      child.parentObserved = true;
    }
    if (!parent._childIds.contains(childId)) parent._childIds.add(childId);
  }

  /// An indented rendering, root first. For diagnostics and test failures.
  String render() {
    final out = StringBuffer();
    void write(AgentNode node, int indent) {
      out
        ..write('  ' * indent)
        ..write(node.isRoot ? 'root' : node.id)
        ..write(node.spawnDenied ? ' [refused]' : '')
        ..write(node.description == null ? '' : ' — ${node.description}')
        ..writeln();
      for (final child in childrenOf(node.id)) {
        write(child, indent + 1);
      }
    }

    write(root, 0);
    for (final orphan in orphans) {
      out.writeln('orphan: ${orphan.id}');
    }
    return out.toString();
  }
}
