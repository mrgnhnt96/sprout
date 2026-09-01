/// The snapshot of tree state a containment decision is taken over.
library;

/// Dollars, as whole micro-dollars.
///
/// Every comparison against a ceiling is made on these integers, never on the
/// doubles. `0.1 + 0.2 > 0.3` is true in binary floating point, and a budget
/// gate that refuses a spawn sitting *exactly* on its ceiling — or permits one
/// a hair over — is wrong in a way no test written in dollars would surface.
/// Micro-dollars because that is the precision the control plane reports at:
/// `total_cost_usd: 0.025414` in
/// `docs/research/fixtures/phase0/streams/E.ndjson`.
int microUsd(double usd) => (usd * 1000000).round();

/// Renders [usd] for a human-readable refusal reason.
///
/// Two decimals when the figure is whole cents, four when it is not, because
/// per-node spend is routinely sub-cent and `$0.00` in a refusal reason reads
/// as a bug in the gate.
String formatUsd(double usd) {
  final wholeCents = (usd * 100).roundToDouble() / 100 == usd;
  return '\$${usd.toStringAsFixed(wholeCents ? 2 : 4)}';
}

/// One node's *own* spend, and whether it is still running.
///
/// [costUsd] excludes descendants on purpose. Rolling up is [SpendLedger]'s
/// job, not the caller's: "a child's cost counts against every ancestor's
/// budget" is the property that makes a runaway subtree visible at the root,
/// and a property enforced in the caller is a property that holds only some of
/// the time.
final class NodeSpend {
  /// Records one node's own spend.
  const NodeSpend({
    required this.id,
    required this.costUsd,
    this.parentId,
    this.isLive = false,
  });

  /// sprout's node id.
  final String id;

  /// The parent node, or null for a root.
  final String? parentId;

  /// Dollars attributed to this node alone.
  ///
  /// Per INV13 this comes from what the control plane reported for the node —
  /// the `usage` block on a `PostToolUse.tool_response` for an `Agent` call, or
  /// the **last** `result` frame, deduped by `message.id` — never from a
  /// heuristic and never from `isSidechain`. This object cannot tell where the
  /// number came from, which is exactly why that rule has to be honoured on the
  /// way in.
  final double costUsd;

  /// Whether the node's process is still running.
  ///
  /// Feeds the concurrency bound. This is sprout's own view of liveness, not a
  /// control-plane fact.
  final bool isLive;

  @override
  String toString() => 'NodeSpend($id, parent: $parentId, \$$costUsd)';
}

/// An immutable snapshot of a tree: depth, rolled-up spend, and live counts.
///
/// Derived once, at construction, from a single set of [NodeSpend] records, so
/// a decision cannot be taken over numbers that disagree with each other. There
/// is no way to hand the policy a depth that contradicts the parent chain or a
/// live count that contradicts the nodes.
final class SpendLedger {
  SpendLedger._(
    this._parents,
    this._depths,
    this._subtreeMicros,
    this._liveChildren,
    this.totalMicroUsd,
    this.liveNodes,
  );

  /// Builds a ledger from every node sprout currently knows about.
  ///
  /// Throws [ArgumentError] on a duplicate id or a parent cycle. Both mean the
  /// node graph is corrupt, and a corrupt graph must stop the run loudly rather
  /// than be quietly interpreted — a cycle read permissively would hand every
  /// node in it a finite depth and so hide an unbounded tree.
  factory SpendLedger.of(Iterable<NodeSpend> nodes) {
    final byId = <String, NodeSpend>{};
    for (final node in nodes) {
      if (byId.containsKey(node.id)) {
        throw ArgumentError.value(node.id, 'nodes', 'duplicate node id');
      }
      byId[node.id] = node;
    }

    final parents = <String, String?>{
      for (final node in byId.values)
        // A parent sprout has not recorded is not a link. The node becomes the
        // root of its own fragment, the same reading `TreeNode` takes in the
        // store: a child seen before its parent is reported, never dropped.
        node.id: byId.containsKey(node.parentId) ? node.parentId : null,
    };

    final depths = <String, int>{};
    for (final id in byId.keys) {
      _resolveDepth(id, parents, depths);
    }

    final subtreeMicros = <String, int>{};
    final liveChildren = <String, int>{};
    var totalMicros = 0;
    var liveNodes = 0;
    for (final node in byId.values) {
      final micros = microUsd(node.costUsd);
      totalMicros += micros;
      if (node.isLive) {
        liveNodes++;
        final parentId = parents[node.id];
        if (parentId != null) {
          liveChildren[parentId] = (liveChildren[parentId] ?? 0) + 1;
        }
      }
      // The roll-up: a node's own dollars land on the node itself and on every
      // ancestor above it. That is what makes an ancestor's ceiling bind on its
      // descendants' spending, so a runaway subtree is visible at the root and
      // not only at the leaf that is doing the spending.
      for (String? id = node.id; id != null; id = parents[id]) {
        subtreeMicros[id] = (subtreeMicros[id] ?? 0) + micros;
      }
    }

    return SpendLedger._(
      Map.unmodifiable(parents),
      Map.unmodifiable(depths),
      Map.unmodifiable(subtreeMicros),
      Map.unmodifiable(liveChildren),
      totalMicros,
      liveNodes,
    );
  }

  /// A tree with nothing in it yet — what the very first spawn is decided over.
  factory SpendLedger.empty() => SpendLedger.of(const <NodeSpend>[]);

  static void _resolveDepth(
    String id,
    Map<String, String?> parents,
    Map<String, int> depths,
  ) {
    final chain = <String>[];
    final seen = <String>{};
    String? cursor = id;
    while (cursor != null && !depths.containsKey(cursor)) {
      if (!seen.add(cursor)) {
        throw ArgumentError.value(id, 'nodes', 'parent cycle through $cursor');
      }
      chain.add(cursor);
      cursor = parents[cursor];
    }
    var depth = cursor == null ? -1 : depths[cursor]!;
    for (final node in chain.reversed) {
      depths[node] = ++depth;
    }
  }

  final Map<String, String?> _parents;
  final Map<String, int> _depths;
  final Map<String, int> _subtreeMicros;
  final Map<String, int> _liveChildren;

  /// Micro-dollars spent by the whole run.
  final int totalMicroUsd;

  /// How many nodes in the whole tree are still running.
  final int liveNodes;

  /// Whether [nodeId] is in this snapshot at all.
  bool contains(String nodeId) => _depths.containsKey(nodeId);

  /// How far [nodeId] sits from the root of its fragment, or null if unknown.
  int? depthOf(String nodeId) => _depths[nodeId];

  /// The chain from the root of [nodeId]'s fragment down to [nodeId] itself.
  ///
  /// Empty for an unknown id. This is the list of ceilings a new child under
  /// [nodeId] has to clear, because its cost counts against every one of them.
  List<String> ancestryOf(String nodeId) {
    if (!contains(nodeId)) return const <String>[];
    final chain = <String>[];
    for (String? id = nodeId; id != null; id = _parents[id]) {
      chain.add(id);
    }
    return chain.reversed.toList();
  }

  /// Dollars spent by [nodeId] and everything beneath it. 0 for an unknown id.
  double subtreeCostUsd(String nodeId) => subtreeMicroUsd(nodeId) / 1e6;

  /// Micro-dollars spent by [nodeId] and everything beneath it.
  int subtreeMicroUsd(String nodeId) => _subtreeMicros[nodeId] ?? 0;

  /// Dollars spent by the whole run.
  double get totalCostUsd => totalMicroUsd / 1e6;

  /// How many of [nodeId]'s direct children are still running.
  int liveChildrenOf(String nodeId) => _liveChildren[nodeId] ?? 0;

  @override
  String toString() =>
      'SpendLedger(${_depths.length} nodes, $liveNodes live, '
      '${formatUsd(totalCostUsd)})';
}
