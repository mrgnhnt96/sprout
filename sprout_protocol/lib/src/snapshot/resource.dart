import '../values/node.dart';

/// Something a node is holding, together with **who** is holding it.
///
/// One of the three fields that survive any compression (`docs/01-plan.md`
/// §7). The holder is not optional and is not allowed to be empty, because a
/// lock with no named holder is not information: it tells a reader that
/// something is blocked and nothing about what to do next, which is the same
/// as telling them nothing while looking like it told them something.
final class HeldResource {
  /// Records that [holder] is holding [name].
  ///
  /// Throws [ArgumentError] on an empty [name] or [holder] rather than
  /// rendering a half-line. The refusal is the enforcement; the paragraph
  /// above is not (INV1).
  HeldResource({required this.name, required this.holder}) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must name the resource');
    }
    if (holder.isEmpty) {
      throw ArgumentError.value(holder, 'holder', 'must name the holder');
    }
  }

  /// What is held. A project directory today; see [heldResourcesOf].
  final String name;

  /// The id of the node holding it.
  final String holder;

  /// This entry as JSON.
  Map<String, Object?> toJson() => {'name': name, 'holder': holder};

  /// Reads back what [toJson] wrote.
  ///
  /// Throws [FormatException] on a missing or non-string field, and the
  /// constructor's own [ArgumentError] still stands behind it: an entry that
  /// arrives holder-less is refused on the way in exactly as it is refused on
  /// the way out, because a lock with no named holder is not information
  /// whichever side of the wire assembled it.
  factory HeldResource.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final holder = json['holder'];
    if (name is! String || holder is! String) {
      throw FormatException('resource needs "name" and "holder"', '$json');
    }
    return HeldResource(name: name, holder: holder);
  }

  /// The one-line rendering.
  String get label => 'holds $name · $holder';

  @override
  bool operator ==(Object other) =>
      other is HeldResource && other.name == name && other.holder == holder;

  @override
  int get hashCode => Object.hash(name, holder);

  @override
  String toString() => 'HeldResource($name held by $holder)';
}

/// What renders when nothing is held.
///
/// Printed rather than omitted. A section that disappears when it is empty
/// cannot be told apart from a section the renderer forgot, which is INV8 in
/// the smallest possible form.
const String nothingHeldText = 'holds nothing';

/// The resources [nodes] are holding right now.
///
/// **Derived, and only from what sprout actually records.** There is no lock
/// table in the schema (`sproutd/lib/src/store/schema.dart` has `node` and `event` and
/// nothing else), and there will not be one before Phase 4 gives children
/// their own worktrees. The one single-consumer resource sprout can observe
/// today is the directory a live node is working in: `node.project`, held by
/// the node, for as long as the node is [NodeStatus.spawning] or
/// [NodeStatus.working].
///
/// Two nodes in one project produce two entries with the same [name], which is
/// the contention showing through rather than a duplicate to collapse.
List<HeldResource> heldResourcesOf(Iterable<SproutNode> nodes) {
  final held = [
    for (final node in nodes)
      if (isHoldingStatus(node.status))
        HeldResource(name: node.project, holder: node.id),
  ];
  held.sort((a, b) {
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.holder.compareTo(b.holder);
  });
  return List.unmodifiable(held);
}

/// Whether a node in [status] still occupies its project directory.
///
/// The three ending states and `parked` do not: the process is gone, or the
/// developer stopped it. Neither does [NodeStatus.unlaunched], where the
/// process was never started at all — that was P4-09, and it is what stops a
/// spawn the containment gate refused from announcing a worktree sprout tore
/// down seconds earlier, and from counting against the concurrency bound for
/// ever. Liveness proper — live / stalled / abandoned — is a pid beside a
/// transcript mtime and is Phase 6's; this is the coarser fact the store
/// already holds, and it is deliberately not called liveness.
///
/// **This list is deliberately not widened.** It names the two statuses that
/// hold, so a status added later holds nothing until someone says otherwise
/// here, on purpose.
bool isHoldingStatus(NodeStatus status) =>
    status == NodeStatus.spawning || status == NodeStatus.working;
