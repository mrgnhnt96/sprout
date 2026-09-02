/// The board's state: one snapshot, and every delta since its cursor.
library;

import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_protocol/snapshot.dart';
import 'package:sprout_protocol/values.dart';

/// The event kind announcing a node for the first time.
///
/// **Written here a second time, and a test compares the two.** The producer's
/// spelling is `nodeObservedKind` in
/// `sproutd/lib/src/store/sprout_store.dart`, and this package cannot import it:
/// `package:sproutd` reaches `dart:io` and `dart:ffi` and so cannot be compiled
/// for the browser at all — that was finding F-07. Their real home is
/// `sprout_protocol`, beside the frames, and moving them there is the actual
/// repair; until then `test/kinds_test.dart` reads the producer's source and
/// fails if the strings drift. Two lists that must stay equal is the shape of
/// F-01, and what made F-01 a bug was not the duplication but that nothing
/// compared the two.
const String nodeObservedKind = 'runner.observed';

/// The event kind announcing that a node already in the feed changed.
///
/// See [nodeObservedKind] for why this string is written twice.
///
/// This is the kind the board actually depends on. In the Phase 0 `B.ndjson`
/// capture both subagents are announced with a **null** `current_task` and
/// given one several seconds later by this event, so a client that handled
/// creation and ignored updates would render two permanently blank tasks and
/// look entirely healthy doing it.
const String nodeUpdatedKind = 'runner.updated';

/// What a node's line says when the feed has mentioned it but never described
/// it.
///
/// Reached when an event arrives for a node id that was in neither the
/// snapshot nor a [nodeObservedKind] event. The node is **shown**, not
/// dropped: an id sprout is emitting events about is a real node, and a
/// consumer that hid it would report a smaller tree than exists — which is the
/// runaway this project exists to surface.
const String strangerText = 'not described on this stream';

/// The whole world as this client knows it.
///
/// **Snapshotted once, then advanced only by deltas.** Re-taking a snapshot to
/// stay current would paper over exactly the defects that made this possible:
/// F-01 made a cursor from one surface acceptable to the other, and F-02 made
/// subagent creation reach the feed so that deltas are *sufficient*. A UI that
/// re-snapshots proves neither.
///
/// Immutable. [apply] returns the next tree rather than mutating this one, so
/// a rendered board can never be half-updated.
final class LiveTree {
  /// Creates a tree in the given state. See [attaching] for the initial one.
  const LiveTree({
    required this.nodes,
    required this.resources,
    required this.strangers,
    this.cursor,
    this.takenAt,
    this.asOf,
    this.journalUnreadable,
    this.replayComplete = false,
    this.lastHeartbeat,
    this.ended,
    this.lastFrame,
    this.frames = 0,
    this.events = 0,
  });

  /// Nothing has arrived yet.
  ///
  /// Distinct from a snapshot of an empty store, and the distinction is the
  /// whole of INV8: [cursor] is null here and set there, so "not fetched" and
  /// "nothing in it" cannot render the same.
  static const LiveTree attaching = LiveTree(
    nodes: [],
    resources: [],
    strangers: {},
  );

  /// Where this client stands. Null until the first frame.
  final Cursor? cursor;

  /// When the snapshot was taken, or null before one arrives.
  final DateTime? takenAt;

  /// The most recent instant the **daemon** has reported.
  ///
  /// Every age on the board is measured against this and never against the
  /// browser's clock. Two reasons, and the second is the important one. A
  /// browser clock skewed against the daemon's would show ages that are wrong
  /// by the skew with nothing on screen admitting it. And because the daemon
  /// stamps a `heartbeat` every 15 seconds, ages advance while the stream is
  /// alive and **stop** when it dies — so a board that has gone stale says so
  /// by standing still, next to a heartbeat time that has stopped moving.
  ///
  /// Sources, all measured and none inferred: `snapshot.taken_at`,
  /// `heartbeat.at`, and each event's own `ts`. Null before any of them.
  final DateTime? asOf;

  /// Every node, parents before children.
  final List<SnapshotNode> nodes;

  /// Everything held right now, each with its holder.
  final List<HeldResource> resources;

  /// Node ids the feed has emitted events about that this client has never
  /// been told the shape of, and how many such events each has had.
  ///
  /// **Empty in normal operation now, and kept anyway.** It used to hold the
  /// root of every run: `SproutStore.putNode` wrote a row and no event, so a
  /// root created by `sprout run` after this client attached appeared in the
  /// feed only as `runner.spawned` — an event carrying a pid and a command
  /// line, not a node row. That was F-10, and `putNode` now announces the row
  /// it writes, so the root arrives here through [nodeObservedKind] exactly as
  /// the subagents always did.
  ///
  /// This path stays because the case it covers is real and is not the one
  /// F-10 fixed: an id sprout emits events about with no node row behind it is
  /// still a node, and a consumer that hid it would report a smaller tree than
  /// exists — which is the runaway this project exists to surface.
  final Map<String, int> strangers;

  /// Why the event feed could not be read, or null if it was read.
  ///
  /// The third field that survives any compression (`docs/01-plan.md` §7).
  /// Surfaced whenever it is set, never swallowed.
  final String? journalUnreadable;

  /// Whether the `ready` frame has arrived.
  ///
  /// **Set by [ReadyFrame] alone**, via [ProtocolFrame.marksEndOfReplay]. A
  /// `delta` that carried no events is a position update with nothing in it,
  /// not the end of replay, and a client that conflated them would either
  /// declare itself live mid-backlog or wait forever for a `ready` it decided
  /// it had already seen.
  final bool replayComplete;

  /// When the daemon last said it was alive, or null if it has not yet.
  ///
  /// *"A stream that has DIED looks the same"* as a sparse one. This is the
  /// second bit that tells them apart.
  final DateTime? lastHeartbeat;

  /// The `bye` that ended the stream, or null while it is open.
  ///
  /// A stream that simply stops did not end, it broke — so the board renders
  /// this reason when there is one, and says the connection dropped when there
  /// is not.
  final ByeFrame? ended;

  /// The most recent frame, whatever it was.
  final ProtocolFrame? lastFrame;

  /// How many frames have been applied.
  final int frames;

  /// How many events have been applied.
  final int events;

  /// Whether a snapshot has arrived at all.
  bool get isAttached => cursor != null;

  /// Whether the feed could not be read.
  bool get isJournalUnreadable => journalUnreadable != null;

  /// This tree with [frame] applied.
  ///
  /// Exhaustive over the sealed [ProtocolFrame], which is what makes adding a
  /// frame type a compile error here rather than a line falling through into
  /// nothing.
  ///
  /// Throws rather than repairing: [ProtocolFormatException] when an event's
  /// payload is not the shape its kind promises. A board that quietly ignored
  /// an event it could not read would show a stale tree and never say why,
  /// which is the failure the protocol's own decoder refuses for the same
  /// reason.
  LiveTree apply(ProtocolFrame frame) {
    switch (frame) {
      case SnapshotFrame(:final snapshot):
        return LiveTree(
          nodes: List.of(snapshot.nodes),
          resources: List.of(snapshot.resources),
          strangers: const {},
          cursor: snapshot.cursor,
          takenAt: snapshot.takenAt,
          asOf: snapshot.takenAt,
          journalUnreadable: snapshot.journalUnreadable,
          lastHeartbeat: lastHeartbeat,
          lastFrame: frame,
          frames: frames + 1,
          events: events,
        );
      case ReadyFrame():
        return _with(frame: frame, replayComplete: true);
      case HeartbeatFrame(:final sentAt):
        return _with(frame: frame, heartbeat: sentAt, instant: sentAt);
      case ByeFrame():
        return _with(frame: frame, bye: frame);
      case DeltaFrame(:final events):
        final next = List.of(nodes);
        final unknown = Map.of(strangers);
        var instant = asOf;
        for (final event in events) {
          _applyEvent(event, next, unknown);
          if (instant == null || event.ts.isAfter(instant)) instant = event.ts;
        }
        return LiveTree(
          nodes: next,
          resources: resources,
          strangers: unknown,
          cursor: frame.cursor,
          takenAt: takenAt,
          asOf: instant,
          journalUnreadable: journalUnreadable,
          replayComplete: replayComplete,
          lastHeartbeat: lastHeartbeat,
          ended: ended,
          lastFrame: frame,
          frames: frames + 1,
          events: this.events + events.length,
        );
    }
  }

  LiveTree _with({
    required ProtocolFrame frame,
    bool? replayComplete,
    DateTime? heartbeat,
    DateTime? instant,
    ByeFrame? bye,
  }) {
    final at = asOf;
    return LiveTree(
      nodes: nodes,
      resources: resources,
      strangers: strangers,
      cursor: frame.cursor,
      takenAt: takenAt,
      asOf: instant != null && (at == null || instant.isAfter(at))
          ? instant
          : at,
      journalUnreadable: journalUnreadable,
      replayComplete: replayComplete ?? this.replayComplete,
      lastHeartbeat: heartbeat ?? lastHeartbeat,
      ended: bye ?? ended,
      lastFrame: frame,
      frames: frames + 1,
      events: events,
    );
  }

  void _applyEvent(
    SproutEvent event,
    List<SnapshotNode> nodes,
    Map<String, int> strangers,
  ) {
    final at = nodes.indexWhere((n) => n.node.id == event.nodeId);
    switch (event.kind) {
      case nodeObservedKind:
        if (at >= 0) {
          // The projection appends this exactly once per node. A second one
          // means the feed disagrees with itself, and the honest reading is
          // that the node was re-created rather than that this is a no-op.
          nodes[at] = _observed(event, nodes);
          return;
        }
        _insert(nodes, _observed(event, nodes));
      case nodeUpdatedKind:
        if (at < 0) {
          strangers[event.nodeId] = (strangers[event.nodeId] ?? 0) + 1;
          return;
        }
        _update(nodes, at, event);
      default:
        // Every other kind — `frame.*`, `runner.spawned`, `runner.session`,
        // `runner.exited` — carries a Claude Code frame or a launch record,
        // not a node row. There is nothing in one to change a rendered field
        // with, and inventing a change from a launch's argv would be a guess.
        if (at < 0) {
          strangers[event.nodeId] = (strangers[event.nodeId] ?? 0) + 1;
        }
    }
  }

  SnapshotNode _observed(SproutEvent event, List<SnapshotNode> nodes) {
    final parentId = _stringOrNull(event, 'parent_id');
    final parent = parentId == null ? null : _find(nodes, parentId)?.depth;
    return SnapshotNode(
      node: SproutNode(
        id: event.nodeId,
        parentId: parentId,
        project: _string(event, 'project'),
        status: _status(event, _string(event, 'status')),
        currentTask: _stringOrNull(event, 'current_task'),
        // The event's own timestamp, which is a measurement and not an
        // estimate: the projection creates the row and appends this event in
        // the same call, so this instant IS when the node started. It differs
        // from the stored `since` by the microseconds between two `_clock()`
        // reads, because `runner.observed` does not carry `since` on the wire.
        since: event.ts,
      ),
      // The rule `SproutStore.tree`'s recursive CTE uses, applied only where
      // the store has not spoken: a child is one deeper than its parent, and a
      // node whose parent was never recorded is the root of its own fragment.
      depth: parent == null ? 0 : parent + 1,
      ownCostUsd: null,
      // Genuinely unknown, and said so rather than shown as zero: this event
      // carries no dollars, and an identity element reported as `$0.0000`
      // cannot be told from a measured nothing (INV7).
      spend: const SubtreeSpend(knownMicroUsd: 0, nodes: 1, unknownNodes: 1),
    );
  }

  /// Applies a `{from, to}` patch, and nothing it does not mention.
  ///
  /// The payload spells out only what moved, so an absent key means unchanged
  /// — never null. `since` is deliberately untouched: the producer keeps the
  /// original (`since: previous?.since ?? _clock()`), so resetting it here
  /// would make every status flip look like a fresh start.
  void _update(List<SnapshotNode> nodes, int at, SproutEvent event) {
    final current = nodes[at];
    final statusTo = _patch(event, 'status');
    final taskTo = _patch(event, 'current_task');
    final parentTo = _patch(event, 'parent_id');
    final hasParent = event.payload.containsKey('parent_id');
    final node = SproutNode(
      id: current.node.id,
      parentId: hasParent ? parentTo as String? : current.node.parentId,
      project: current.node.project,
      role: current.node.role,
      status: statusTo == null
          ? current.node.status
          : _status(event, statusTo as String),
      // `copyWith` cannot express "set this to null", and `current_task` moving
      // to null is a value the producer really emits, so the node is rebuilt.
      currentTask: event.payload.containsKey('current_task')
          ? taskTo as String?
          : current.node.currentTask,
      since: current.node.since,
      nextCheckin: current.node.nextCheckin,
    );
    final depth = hasParent
        ? (_find(nodes, node.parentId)?.depth ?? -1) + 1
        : current.depth;
    nodes[at] = SnapshotNode(
      node: node,
      depth: depth,
      ownCostUsd: current.ownCostUsd,
      spend: current.spend,
    );
    if (hasParent && depth != current.depth) {
      _reposition(nodes, at, depth - current.depth);
    }
  }

  /// Places [node] after everything already beneath its parent.
  ///
  /// Depth-first, parents before children — the order `SproutSnapshot`
  /// promises — so a node arriving by delta lands where a fresh snapshot would
  /// have put it. A node whose parent is unknown goes at the end as a fragment
  /// root, which is how the store reports one and is the shape a runaway takes.
  static void _insert(List<SnapshotNode> nodes, SnapshotNode node) {
    final parentId = node.node.parentId;
    var at = parentId == null
        ? -1
        : nodes.indexWhere((n) => n.node.id == parentId);
    if (at < 0) {
      nodes.add(node);
      _chargeAncestors(nodes, node);
      return;
    }
    final parentDepth = nodes[at].depth;
    at++;
    while (at < nodes.length && nodes[at].depth > parentDepth) {
      at++;
    }
    nodes.insert(at, node);
    _chargeAncestors(nodes, node);
  }

  /// Counts a new node into every ancestor's subtree totals.
  ///
  /// Exact, not a re-fold: the subtree gained one node and nothing is known
  /// about its dollars, so `nodes` and `unknownNodes` each rise by one and
  /// `knownMicroUsd` does not move. Leaving the ancestors alone would let a
  /// parent keep reporting `>=$0.24 (1 unknown)` while two unmeasured children
  /// hang beneath it, and an unknown count that is too low is a floor
  /// presented as if it were nearly a total (INV7).
  static void _chargeAncestors(List<SnapshotNode> nodes, SnapshotNode node) {
    var parentId = node.node.parentId;
    while (parentId != null) {
      final at = nodes.indexWhere((n) => n.node.id == parentId);
      if (at < 0) return;
      final ancestor = nodes[at];
      nodes[at] = SnapshotNode(
        node: ancestor.node,
        depth: ancestor.depth,
        ownCostUsd: ancestor.ownCostUsd,
        spend: SubtreeSpend(
          knownMicroUsd: ancestor.spend.knownMicroUsd,
          nodes: ancestor.spend.nodes + 1,
          unknownNodes: ancestor.spend.unknownNodes + 1,
        ),
      );
      parentId = ancestor.node.parentId;
    }
  }

  /// Moves a re-parented node and its descendants under their new parent.
  static void _reposition(List<SnapshotNode> nodes, int at, int shift) {
    final moved = nodes[at];
    var end = at + 1;
    while (end < nodes.length && nodes[end].depth > moved.depth - shift) {
      end++;
    }
    final block = [
      for (final node in nodes.sublist(at, end))
        node.node.id == moved.node.id
            ? node
            : SnapshotNode(
                node: node.node,
                depth: node.depth + shift,
                ownCostUsd: node.ownCostUsd,
                spend: node.spend,
              ),
    ];
    nodes.removeRange(at, end);
    final parentId = moved.node.parentId;
    var to = parentId == null
        ? -1
        : nodes.indexWhere((n) => n.node.id == parentId);
    if (to < 0) {
      nodes.addAll(block);
      return;
    }
    final parentDepth = nodes[to].depth;
    to++;
    while (to < nodes.length && nodes[to].depth > parentDepth) {
      to++;
    }
    nodes.insertAll(to, block);
  }

  static SnapshotNode? _find(List<SnapshotNode> nodes, String? id) {
    if (id == null) return null;
    for (final node in nodes) {
      if (node.node.id == id) return node;
    }
    return null;
  }

  static Object? _patch(SproutEvent event, String key) {
    final value = event.payload[key];
    if (value == null) return null;
    if (value is! Map || !value.containsKey('to')) {
      throw ProtocolFormatException(
        '${event.kind} "$key" is not a {from, to} patch',
        '$value',
      );
    }
    return value['to'];
  }

  static String _string(SproutEvent event, String key) {
    final value = event.payload[key];
    if (value is! String) {
      throw ProtocolFormatException(
        '${event.kind} "$key" is not a string',
        '$value',
      );
    }
    return value;
  }

  static String? _stringOrNull(SproutEvent event, String key) {
    final value = event.payload[key];
    if (value == null) return null;
    if (value is! String) {
      throw ProtocolFormatException(
        '${event.kind} "$key" is not a string',
        '$value',
      );
    }
    return value;
  }

  static NodeStatus _status(SproutEvent event, String wire) {
    try {
      return NodeStatus.fromWire(wire);
    } on ArgumentError {
      throw ProtocolFormatException('${event.kind} "status" is unknown', wire);
    }
  }

  @override
  String toString() =>
      'LiveTree(${cursor?.encode() ?? 'unattached'}, ${nodes.length} nodes, '
      '$frames frames)';
}
