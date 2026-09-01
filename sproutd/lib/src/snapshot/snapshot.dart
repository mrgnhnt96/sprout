import '../../protocol.dart';

import '../../store.dart';
import 'resource.dart';
import 'spend.dart';

/// One node as it stood at the snapshot's cursor.
final class SnapshotNode {
  /// Positions [node] at [depth] with its folded [spend].
  const SnapshotNode({
    required this.node,
    required this.depth,
    required this.spend,
    required this.ownCostUsd,
  });

  /// The node itself: id, parent, project, role, status, `current_task`,
  /// `since`, `next_checkin`.
  final SproutNode node;

  /// 0 for a root, 1 for its children, and so on — the depth
  /// `SproutStore.tree`'s recursive CTE assigned, not a second computation of
  /// it. A node whose parent was never recorded is the root of its own
  /// fragment and so has depth 0; it is reported, never dropped, because that
  /// is the shape a runaway takes.
  final int depth;

  /// This node's own dollars, or null if none were ever reported for it.
  ///
  /// Null is the ordinary case for a subagent — see [SubtreeSpend].
  final double? ownCostUsd;

  /// Dollars for this node and everything beneath it, with the count of what
  /// was not observed.
  final SubtreeSpend spend;

  /// This node as JSON.
  ///
  /// **Every key is always present**, with an explicit `null` where sprout has
  /// no value. An omitted key is the JSON spelling of a blank field, and a
  /// blank field reads as "fine" — the failure `NONE SCHEDULED` exists to
  /// prevent, one layer down.
  Map<String, Object?> toJson() => {
    'id': node.id,
    'parent_id': node.parentId,
    'depth': depth,
    'project': node.project,
    'role': node.role,
    'status': node.status.wire,
    'current_task': node.currentTask,
    'since': node.since?.toUtc().toIso8601String(),
    'next_checkin': node.nextCheckin?.toUtc().toIso8601String(),
    'own_cost_usd': ownCostUsd,
    'subtree_cost_usd': spend.costUsd,
    'subtree_cost_is_complete': spend.isComplete,
    'subtree_unknown_cost_nodes': spend.unknownNodes,
  };

  /// The one line this node prints, indented by [depth].
  ///
  /// `status · id · task · since HH:MMZ (age) · next HH:MMZ · $0.0000`, with
  /// [unknownValueText] and [noCheckinText] standing in wherever sprout has no
  /// value. The age is measured against [takenAt] — the instant the snapshot
  /// was taken — and is **never** estimated: a node with no `since` prints
  /// `since ?`, not `0`, not the process start time (`docs/01-plan.md` §7).
  String render(DateTime takenAt) {
    final task = node.currentTask;
    return [
      '  ' * depth + node.status.wire,
      node.id,
      task == null || task.trim().isEmpty
          ? unknownValueText
          : task.trim().replaceAll(RegExp(r'\s+'), ' '),
      'since ${_since(takenAt)}',
      'next ${node.nextCheckin == null ? noCheckinText : formatClock(node.nextCheckin!)}',
      spend.label,
    ].join(' · ');
  }

  String _since(DateTime takenAt) {
    final since = node.since;
    if (since == null) return unknownValueText;
    return '${formatClock(since)} (${formatAge(takenAt.difference(since))})';
  }

  @override
  String toString() => 'SnapshotNode(${node.id} @ $depth, ${spend.label})';
}

/// The whole world, in one call, at one cursor.
///
/// Everything here is true at [cursor], so a consumer can take this picture,
/// apply `watch --since <cursor>` deltas to it, and arrive at the present —
/// *"an event saying `leaf.closed` is not a picture, it is a delta against
/// one"* (`docs/01-plan.md` §7). How that consistency is obtained without a
/// transaction seam, and which direction it errs in, is in
/// `StoreSnapshotSource`'s own documentation.
final class SproutSnapshot {
  /// Assembles a snapshot. See `takeSnapshot`, which is how one is made.
  SproutSnapshot({
    required this.cursor,
    required this.takenAt,
    required List<SnapshotNode> nodes,
    required List<HeldResource> resources,
    this.journalUnreadable,
  }) : nodes = List.unmodifiable(nodes),
       resources = List.unmodifiable(resources);

  /// The position everything here is true at.
  ///
  /// A [Cursor], never a bare `seq`: it names the sproutd instance that
  /// produced it, so a consumer reconnecting to a *restarted* daemon is
  /// refused rather than silently resumed at a number that has come to mean
  /// something else (`lib/src/protocol/cursor.dart`).
  final Cursor cursor;

  /// When the snapshot was taken. UTC, measured, never inferred — every age
  /// rendered below is a difference against this instant.
  final DateTime takenAt;

  /// Every node, parents before children, depth-first, siblings by id.
  final List<SnapshotNode> nodes;

  /// Everything held right now, each entry with its holder.
  final List<HeldResource> resources;

  /// Why the event feed could not be read, or null if it was read.
  ///
  /// The third field that survives any compression (`docs/01-plan.md` §7). A
  /// snapshot that silently omitted what it could not read would be
  /// indistinguishable from one taken over an empty feed, and the consumer
  /// would have no way to tell "nothing has happened" from "I could not look"
  /// — INV8 exactly. When this is set, [cursor] is at position 0 and every
  /// [SubtreeSpend] is unknown, because a position read out of a feed that
  /// could not be read would be a guess.
  final String? journalUnreadable;

  /// Whether the event feed could not be read.
  bool get isJournalUnreadable => journalUnreadable != null;

  /// This snapshot as JSON. Every key always present.
  Map<String, Object?> toJson() => {
    'cursor': cursor.encode(),
    'taken_at': takenAt.toUtc().toIso8601String(),
    'journal_unreadable': journalUnreadable,
    'nodes': [for (final node in nodes) node.toJson()],
    'resources': [for (final resource in resources) resource.toJson()],
  };

  /// The human rendering: the cursor, one line per node, then the two fields
  /// that must survive even when there is nothing to say about them.
  ///
  /// It is never empty. An empty store renders [noNodesText] rather than
  /// nothing, held resources render [nothingHeldText] rather than vanishing,
  /// and a readable feed says so — because a report that prints nothing when
  /// all is well cannot be told from one that never ran.
  String render() => [
    'cursor ${cursor.encode()}',
    if (nodes.isEmpty) noNodesText,
    for (final node in nodes) node.render(takenAt),
    if (resources.isEmpty) nothingHeldText,
    for (final resource in resources) resource.label,
    journalUnreadable == null
        ? journalReadableText
        : '$journalUnreadableKey: $journalUnreadable',
  ].join('\n');

  @override
  String toString() =>
      'SproutSnapshot(${cursor.encode()}, ${nodes.length} nodes'
      '${isJournalUnreadable ? ', $journalUnreadableKey' : ''})';
}

/// What renders in place of the node lines when the store holds no nodes.
///
/// A snapshot of an empty store is a valid snapshot, not an error — and not
/// silence either.
const String noNodesText = 'no nodes';

/// The field name, on the wire and in the rendering.
const String journalUnreadableKey = 'journal_unreadable';

/// The other half of [journalUnreadableKey], printed when the feed *was* read.
///
/// The permissive half of a rail needs its own bit, or being satisfied looks
/// exactly like never having run (INV8).
const String journalReadableText = 'journal readable';

/// An instant as `HH:MMZ`.
///
/// UTC and marked as such. A bare `HH:MM` in an unnamed zone is a number two
/// readers will disagree about, and the plan's output budget has no room for a
/// full timestamp per node (`docs/01-plan.md` §8).
String formatClock(DateTime instant) {
  final utc = instant.toUtc();
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  return '$hour:${minute}Z';
}

/// A duration as `12m`, `3h04m` or `2d03h`.
///
/// A **negative** age — a `since` in the future, which happens when a clock
/// moves — renders [unknownValueText]. sprout can measure an age or it can
/// say it cannot; those are the only two options, and "0m" would be a guess
/// dressed as a measurement.
String formatAge(Duration age) {
  if (age.isNegative) return unknownValueText;
  if (age.inHours < 1) return '${age.inMinutes}m';
  if (age.inDays < 1) {
    return '${age.inHours}h${(age.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  return '${age.inDays}d${(age.inHours % 24).toString().padLeft(2, '0')}h';
}
