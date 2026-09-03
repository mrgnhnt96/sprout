import 'package:sprout_protocol/snapshot.dart';

import '../../policy.dart';
import '../../protocol.dart';
import '../../runner.dart';
import '../../store.dart';
import 'source.dart';

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
/// [instance] is required and has no default. A [SnapshotSource] is not
/// enough to derive one from — only a caller holding the store knows the
/// database path and the feed's first event — and the default that used to be
/// here, `SproutInstance.current`, was finding F-01: a per-process id meant
/// `sprout snapshot`'s cursor was refused by the daemon's socket every time.
/// A default that is still wrong is still the bug, so callers now name the
/// instance (`SproutInstance.forFeed`) rather than inherit one. [now] is the
/// clock, injectable so a test can assert on a rendered age instead of racing
/// one.
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
  required SproutInstance instance,
  DateTime Function()? now,
}) {
  final takenAt = (now ?? DateTime.now)().toUtc();

  final read = _read(source);
  final feed = read.feed;
  final tree = read.tree;
  final ownCostUsd = read.ownCostUsd;
  final ledger = read.ledger;
  final subtreeCounts = _countSubtrees(tree, ownCostUsd.keys.toSet());

  return SproutSnapshot(
    cursor: instance.cursorAt(feed.position),
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

/// The tree as the store recorded it, ready for a containment decision, with
/// what could **not** be observed stated rather than folded in.
///
/// [ledger] is the same object `takeSnapshot` prints from, built by the same
/// read, so the numbers `ContainmentGate` decides on and the numbers the UI
/// shows cannot drift into two answers.
///
/// **The spend in it is a floor, and that is structural.** All six Phase 0
/// captures carry `parent_tool_use_id: null` on every `result` frame, so
/// `total_cost_usd` reaches the feed only for the node that owns the stream —
/// a subagent's own dollars are not in the stream at all (INV7, INV13, and the
/// `SubtreeSpend` note this repeats). A node nobody reported a figure for
/// contributes 0 to [SpendLedger], because a ledger sums dollars and has no
/// third state to sum; [unknownCostNodes] is where that omission is kept
/// visible, and it is the caller's job to keep it visible too.
///
/// What that costs the budget bound is one-sided and worth stating plainly: a
/// **refusal** on budget is sound — the observed spend really did breach the
/// ceiling, and the unobserved part could only make it worse. A **permit** is
/// not proof of being under budget, only proof that what was observed is under
/// it. The depth cap and the concurrency bounds carry no such caveat: depth
/// comes from `node.parent_id` and liveness from `node.status`, both of which
/// the store holds for every node it knows about.
final class ObservedLedger {
  /// Records a ledger read off a store.
  const ObservedLedger({
    required this.ledger,
    required this.nodes,
    required this.unknownCostNodes,
    this.journalUnreadable,
  });

  /// The tree, with depths, rolled-up spend and live counts.
  final SpendLedger ledger;

  /// How many nodes the store holds.
  final int nodes;

  /// How many of [nodes] reported no dollar figure, so contribute 0 to a sum
  /// that is therefore a floor.
  final int unknownCostNodes;

  /// Why the event feed could not be read, or null if it was read.
  ///
  /// When this is set **nothing at all** is known about spend — every node is
  /// unknown — and the ledger still carries honest depths and live counts,
  /// because those come from the node graph. A caller that would enforce a
  /// dollar ceiling must not treat this as "nothing spent"; that is the INV8
  /// failure, a failed read reported as a fact about the world.
  final String? journalUnreadable;

  /// Whether every node in the ledger reported its own dollars.
  bool get isSpendComplete =>
      journalUnreadable == null && unknownCostNodes == 0;

  /// One line saying what the dollar figures in here are worth, for a log or a
  /// terminal. Never silent, because a budget check whose caveat is silence
  /// cannot be told from one that had nothing to caveat (INV8).
  String get spendLabel {
    if (journalUnreadable case final reason?) {
      return 'spend $unknownValueText over $nodes nodes '
          '($journalUnreadableKey: $reason)';
    }
    final amount = '\$${ledger.totalCostUsd.toStringAsFixed(4)}';
    return isSpendComplete
        ? '$amount over $nodes nodes'
        : '>=$amount over $nodes nodes ($unknownCostNodes unknown)';
  }

  @override
  String toString() => 'ObservedLedger($spendLabel)';
}

/// Reads [source] into the ledger a containment decision is taken over.
///
/// The seam `ContainmentGate` was missing. `SpendLedger.of` takes values and
/// `SpawnRequest` takes a ledger, but until this existed the only caller with
/// a store in its hand — `SessionRunner.launch` — had nothing to build one
/// from, so it fell back to `SpendLedger.empty()` on every launch and the
/// depth cap, the subtree budget and the concurrency bounds were each decided
/// over a tree with nothing in it. A gate that always says yes is
/// indistinguishable from a gate that is not there (INV8).
///
/// Never throws for an unreadable **feed**, for [takeSnapshot]'s reason: the
/// failure is reported on [ObservedLedger.journalUnreadable] rather than
/// folded into a number. A failure to read the **node graph** does propagate —
/// a ledger that could not read the graph is not a degraded ledger, it is not
/// a ledger, and deciding a spawn over it would be deciding over nothing.
ObservedLedger readLedger(SnapshotSource source) {
  final read = _read(source);
  return ObservedLedger(
    ledger: read.ledger,
    nodes: read.tree.length,
    unknownCostNodes: [
      for (final entry in read.tree)
        if (!read.ownCostUsd.containsKey(entry.node.id)) entry,
    ].length,
    journalUnreadable: read.feed.unreadable,
  );
}

/// One read of the store: the feed, the graph, and the ledger over both.
final class _Read {
  const _Read({
    required this.feed,
    required this.tree,
    required this.ownCostUsd,
    required this.ledger,
  });

  final _Feed feed;
  final List<TreeNode> tree;
  final Map<String, double> ownCostUsd;
  final SpendLedger ledger;
}

/// The feed first, then the graph. The order is load-bearing and the argument
/// for it is on `StoreSnapshotSource`.
///
/// One function so that [takeSnapshot] and [readLedger] cannot come to hold
/// two different ideas of what the tree is — the picture a developer reads and
/// the ledger a spawn is refused against are the same read.
_Read _read(SnapshotSource source) {
  final feed = _readFeed(source);
  final tree = source.tree();
  final ownCostUsd = _ownCostsFrom(feed.events);
  return _Read(
    feed: feed,
    tree: tree,
    ownCostUsd: ownCostUsd,
    ledger: SpendLedger.of([
      for (final entry in tree)
        NodeSpend(
          id: entry.node.id,
          parentId: entry.node.parentId,
          // A node nobody reported a figure for contributes nothing to the
          // sum, and is counted as unknown by every caller of this. The two
          // are not the same statement and only the second one survives into
          // what is printed or decided on.
          costUsd: ownCostUsd[entry.node.id] ?? 0,
          isLive: isHoldingStatus(entry.node.status),
        ),
    ]),
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
