import '../../policy.dart';
import '../../protocol.dart';
import '../../runner.dart';
import '../../store.dart';
import 'resource.dart';
import 'snapshot.dart';
import 'source.dart';
import 'spend.dart';

/// The event kind a dollar figure arrives on.
///
/// `frame.result` — a `result` frame, projected by `StoreProjection.kindOf`.
/// The prefix is imported from `lib/runner.dart` rather than spelled out, so
/// that the writer and this reader cannot drift into two ideas of what is in
/// the `kind` column.
final String resultEventKind = '${frameKindPrefix}result';

/// The field on a `result` frame that carries dollars.
///
/// Observed, not documented: it is present on the `result` frame of every one
/// of the six Phase 0 captures in
/// `docs/research/fixtures/phase0/streams/`, and `ResultFrame.totalCostUsd`
/// reads the same key (INV10).
const String totalCostUsdField = 'total_cost_usd';

/// Takes the whole world in one call, at one cursor.
///
/// [instance] defaults to [SproutInstance.current], so a `snapshot` and a
/// `watch` in the same process hand out cursors from the same namespace
/// without either being told which. [now] is the clock, injectable so a test
/// can assert on a rendered age instead of racing one.
///
/// This never throws for an unreadable **feed**: that outcome is reported in
/// the snapshot as [SproutSnapshot.journalUnreadable], because a caller who
/// gets an exception has no picture at all, and a caller who gets a picture
/// with a silent hole in it is worse off still. It does let a failure to read
/// the **node graph** propagate — `SproutStore.tree` throws `TreeIntegrityError`
/// on a `parent_id` cycle, and a snapshot that could not read the graph is not
/// a degraded snapshot, it is not a snapshot.
SproutSnapshot takeSnapshot(
  SnapshotSource source, {
  SproutInstance? instance,
  DateTime Function()? now,
}) {
  final id = instance ?? SproutInstance.current;
  final takenAt = (now ?? DateTime.now)().toUtc();

  // The feed first, then the graph. The order is load-bearing and the argument
  // for it is on `StoreSnapshotSource`.
  final feed = _readFeed(source);
  final tree = source.tree();

  final ownCostUsd = _ownCostsFrom(feed.events);
  final ledger = SpendLedger.of([
    for (final entry in tree)
      NodeSpend(
        id: entry.node.id,
        parentId: entry.node.parentId,
        // A node nobody reported a figure for contributes nothing to the sum,
        // and is counted as unknown below. The two are not the same statement
        // and only the second one survives into what is printed.
        costUsd: ownCostUsd[entry.node.id] ?? 0,
        isLive: isHoldingStatus(entry.node.status),
      ),
  ]);
  final subtreeCounts = _countSubtrees(tree, ownCostUsd.keys.toSet());

  return SproutSnapshot(
    cursor: id.cursorAt(feed.position),
    takenAt: takenAt,
    nodes: [
      for (final entry in _depthFirst(tree))
        SnapshotNode(
          node: entry.node,
          depth: entry.depth,
          ownCostUsd: ownCostUsd[entry.node.id],
          spend: SubtreeSpend(
            knownMicroUsd: ledger.subtreeMicroUsd(entry.node.id),
            nodes: subtreeCounts[entry.node.id]?.total ?? 1,
            unknownNodes: subtreeCounts[entry.node.id]?.unknown ?? 1,
          ),
        ),
    ],
    resources: heldResourcesOf([for (final entry in tree) entry.node]),
    journalUnreadable: feed.unreadable,
  );
}

/// The feed at one position, or the reason it could not be read.
final class _Feed {
  const _Feed({required this.position, required this.events, this.unreadable});

  /// A feed that could not be read: no position, no events, and a reason.
  ///
  /// The position is 0 rather than whatever was read before the failure. Any
  /// other number would be a claim about a feed nobody managed to read, and a
  /// consumer resuming from it would skip whatever it named.
  factory _Feed.unreadableBecause(Object error) =>
      _Feed(position: 0, events: const [], unreadable: '$error');

  final int position;
  final List<SproutEvent> events;
  final String? unreadable;
}

_Feed _readFeed(SnapshotSource source) {
  try {
    final position = source.feedPosition();
    return _Feed(position: position, events: source.eventsUpTo(position));
  } on Object catch (error) {
    return _Feed.unreadableBecause(error);
  }
}

/// Each node's own dollars, folded out of the feed.
///
/// The **last** `result` for a node wins, because `total_cost_usd` is
/// cumulative across the results of one run and not per turn: `B.ndjson` runs
/// `0.2316953` → `0.2415507`, and taking the first understates it (INV12 —
/// more than one `result` frame is the normal case, not an edge one).
///
/// A node with no `result` is simply absent from the map. It is not zero.
Map<String, double> _ownCostsFrom(List<SproutEvent> events) {
  final costs = <String, double>{};
  for (final event in events) {
    if (event.kind != resultEventKind) continue;
    final cost = event.payload[totalCostUsdField];
    if (cost is num) costs[event.nodeId] = cost.toDouble();
  }
  return costs;
}

/// How many nodes each subtree holds, and how many of them reported no cost.
final class _SubtreeCount {
  int total = 0;
  int unknown = 0;
}

/// Rolls the counts up the parent chain, the same way `SpendLedger` rolls the
/// dollars: a node's own fact lands on itself and on every ancestor.
///
/// A `parent_id` naming a node that is not in [tree] is not a link — the node
/// is the root of its own fragment, which is the reading `SproutStore.tree`
/// and `SpendLedger` both already take.
Map<String, _SubtreeCount> _countSubtrees(
  List<TreeNode> tree,
  Set<String> known,
) {
  final parents = _parentsOf(tree);
  final counts = <String, _SubtreeCount>{};
  for (final entry in tree) {
    final isUnknown = !known.contains(entry.node.id);
    for (String? id = entry.node.id; id != null; id = parents[id]) {
      final count = counts.putIfAbsent(id, _SubtreeCount.new)..total += 1;
      if (isUnknown) count.unknown += 1;
    }
  }
  return counts;
}

Map<String, String?> _parentsOf(List<TreeNode> tree) {
  final ids = {for (final entry in tree) entry.node.id};
  return {
    for (final entry in tree)
      entry.node.id: ids.contains(entry.node.parentId)
          ? entry.node.parentId
          : null,
  };
}

/// Reorders the forest depth-first, siblings by id.
///
/// `SproutStore.tree` returns depth-major order, which lists every depth-1
/// node before any depth-2 one — correct, and unreadable as a tree once it is
/// indented. Only the order changes here: the depths are the CTE's, and every
/// node it returned comes out exactly once, including the fragment roots.
List<TreeNode> _depthFirst(List<TreeNode> tree) {
  final children = <String?, List<TreeNode>>{};
  final parents = _parentsOf(tree);
  for (final entry in tree) {
    children.putIfAbsent(parents[entry.node.id], () => []).add(entry);
  }
  for (final siblings in children.values) {
    siblings.sort((a, b) => a.node.id.compareTo(b.node.id));
  }

  final ordered = <TreeNode>[];
  void visit(TreeNode entry) {
    ordered.add(entry);
    for (final child in children[entry.node.id] ?? const <TreeNode>[]) {
      visit(child);
    }
  }

  for (final root in children[null] ?? const <TreeNode>[]) {
    visit(root);
  }
  if (ordered.length != tree.length) {
    // Unreachable while `SproutStore.tree` is doing its job — it already
    // refuses a graph that is not a forest. Checked anyway, because the cost
    // of being wrong is a snapshot that is quietly missing nodes, and a short
    // list is indistinguishable from a small tree.
    throw StateError(
      'reordering lost nodes: ${tree.length} in, ${ordered.length} out',
    );
  }
  return ordered;
}
