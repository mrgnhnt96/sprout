/// The watchdog's verdict on the wire: what is stalled right now, what could
/// not be looked at, and the sweep's own sentence for why it was quiet.
///
/// A `part` of `frame.dart` because [ProtocolFrame] is sealed and a subtype
/// must share its library. See the note beside the `part` directive there.
part of 'frame.dart';

/// One node the watchdog currently considers contradicted.
///
/// **A level, not an event.** This describes what the *last sweep* concluded,
/// not something that happened. That is the whole reason the board can show a
/// node stop being stalled: the next [WatchdogFrame] carries the whole current
/// set, and a node that recovered is simply absent from it. Nothing has to
/// write a row, and no status anywhere is mutated — see the note on
/// `NodeStatus` in `values.dart`, which refuses a `stalled` member for exactly
/// this reason.
final class StalledNode {
  /// Records that [nodeId] is [liveness], because of [because].
  const StalledNode({
    required this.nodeId,
    required this.liveness,
    required this.because,
    required this.consecutiveRings,
    required this.silenced,
  });

  /// Decodes one entry of a `watchdog` frame's `stalled` list.
  factory StalledNode.fromJson(Map<String, Object?> json) => StalledNode(
    nodeId: _string(json, 'node_id'),
    liveness: _string(json, 'liveness'),
    because: _string(json, 'because'),
    consecutiveRings: _int(json, 'consecutive_rings'),
    silenced: _bool(json, 'silenced'),
  );

  /// The node the tree and the world disagree about.
  final String nodeId;

  /// Which contradiction it is, as the daemon spells it: `stalled` or
  /// `abandoned`.
  ///
  /// **A string, and not an enum, because this package has no dependencies.**
  /// `sproutd`'s `Liveness` enum lives beside a measurement that runs `ps` and
  /// stats files, in a package that reaches `dart:io` and `dart:ffi`;
  /// `sprout_protocol` is compiled for the browser and
  /// `sproutd/test/scaffold_test.dart` asserts it declares no dependencies at
  /// all (F-07). So the daemon's own `Liveness.wire` value is carried through
  /// verbatim, exactly as `SproutNode.status` carries `NodeStatus.wire`.
  ///
  /// A value this build does not recognise is still **shown**, not dropped: an
  /// unknown liveness on a node the daemon is contradicting is a node worth a
  /// human's eye, and a consumer that hid it would report a healthier tree
  /// than the daemon sees.
  final String liveness;

  /// The measurement's own sentence, carried through unedited.
  ///
  /// Unedited because a page a human cannot argue with is a page they learn to
  /// dismiss: `stalled` with a pid, a process start time and a frozen-for
  /// duration can be checked by hand in one `ps`.
  final String because;

  /// How many consecutive unproductive rings this node stands at.
  final int consecutiveRings;

  /// Whether the ring cap silenced this node's ring for this sweep.
  ///
  /// **A silenced node is still stalled**, which is why it is in this list at
  /// all. The cap governs how often a human is *rung at*; it must never make a
  /// stall disappear from the board, because a board that hid a node after
  /// three rings would be the "watchdog that stopped guarding, quietly" the
  /// cap's own documentation warns about.
  final bool silenced;

  /// This node as JSON.
  Map<String, Object?> toJson() => {
    'node_id': nodeId,
    'liveness': liveness,
    'because': because,
    'consecutive_rings': consecutiveRings,
    'silenced': silenced,
  };

  @override
  String toString() => 'StalledNode($nodeId: $liveness — $because)';
}

/// One node the watchdog could not measure at all.
///
/// Carried separately from [StalledNode] and never folded into it, because the
/// two hold opposite information: a stall is something the watchdog saw, and
/// this is something it did **not** see. A failed read is not a fact about the
/// world, so this is neither a ring nor a claim of health — and a board that
/// rendered it as either would be the blind watchdog reporting green.
final class UnmeasuredNode {
  /// Records that [nodeId] could not be looked at, and why.
  const UnmeasuredNode({required this.nodeId, required this.because});

  /// Decodes one entry of a `watchdog` frame's `blind` list.
  factory UnmeasuredNode.fromJson(Map<String, Object?> json) => UnmeasuredNode(
    nodeId: _string(json, 'node_id'),
    because: _string(json, 'because'),
  );

  /// The node that could not be looked at.
  final String nodeId;

  /// What went wrong, in the measurement's own words.
  final String because;

  /// This node as JSON.
  Map<String, Object?> toJson() => {'node_id': nodeId, 'because': because};

  @override
  String toString() => 'UnmeasuredNode($nodeId: $because)';
}

/// What one watchdog sweep concluded, delivered to every attached board.
///
/// **Why this is its own frame and not a field on [DeltaFrame].** A delta is a
/// batch of feed events, and the watchdog writes nothing to the feed — a sweep
/// is about the whole forest, and `SproutStore.append` attributes every event
/// to exactly one node, so there is no honest node id to file it under. Worse,
/// hanging the watchdog's verdict on a delta would deliver it only when the
/// tree emits events, and **a stalled tree emits nothing by definition**. The
/// one moment the board needs this is the one moment no delta is sent.
///
/// **Why a frame and not a second endpoint.** The board already holds one
/// long-lived socket whose liveness it reports; a second connection would be a
/// second thing that can die quietly, and nothing on screen would say which of
/// the two went away. One socket, one decoder, one heartbeat.
///
/// **Why the sealed hierarchy earns its keep here.** Adding this member is a
/// compile error in `LiveTree.apply`, in `App.describe` and in
/// `bin/sprout.dart`'s `renderFrame` — three consumers that had to make a
/// decision about it rather than let it fall through a default branch into
/// nothing.
///
/// **There is deliberately no `healthy` flag.** A consumer that could read one
/// boolean would read it, and it would say healthy for a sweep that could not
/// look at half the tree. What this frame carries instead is [why] — the
/// daemon's own sentence, which on a blind sweep reads *"not one of the 2
/// node(s) could be measured, so this sweep establishes nothing about any of
/// them"* — and the two lists a reader has to look at to disagree with it.
///
/// **And it carries nothing to act on.** No pid to signal, no handle, no
/// affordance. §5: *"Never auto-reclaim a stalled node"* — the real incident
/// behind that rule held four uncommitted files and a green test suite.
/// Surface it, page, never act.
final class WatchdogFrame extends ProtocolFrame {
  /// Creates the frame for one sweep.
  WatchdogFrame({
    required super.cursor,
    required DateTime sweptAt,
    required this.why,
    required this.nodesSwept,
    this.stalled = const [],
    this.blind = const [],
    this.failure,
  }) : sweptAt = sweptAt.toUtc();

  /// The `type` string.
  static const String wireType = 'watchdog';

  /// Decodes a `watchdog` object.
  factory WatchdogFrame.fromJson(Map<String, Object?> json) {
    final failure = json['failure'];
    if (failure != null && failure is! String) {
      throw ProtocolFormatException('watchdog "failure" is not a string');
    }
    return WatchdogFrame(
      cursor: cursorOf(json),
      sweptAt: instantOf(json, 'at'),
      why: _string(json, 'why'),
      nodesSwept: _int(json, 'nodes_swept'),
      stalled: [
        for (final entry in _list(json, 'stalled'))
          StalledNode.fromJson(_object(entry)),
      ],
      blind: [
        for (final entry in _list(json, 'blind'))
          UnmeasuredNode.fromJson(_object(entry)),
      ],
      failure: failure as String?,
    );
  }

  /// When the sweep finished. UTC.
  ///
  /// The board measures the watchdog's own age against this and never against
  /// the browser's clock, for the same reason every other age on the board is
  /// measured against a daemon instant: a skewed browser would show a watchdog
  /// that looks fresher, or staler, than it is, with nothing on screen
  /// admitting it.
  final DateTime sweptAt;

  /// The sweep's own sentence, always present and never empty.
  ///
  /// This is `SweepRecord.why` carried through unedited — the same string the
  /// NDJSON journal on disk holds for this sweep, so the board and the journal
  /// cannot come to describe one sweep two ways.
  final String why;

  /// How many nodes the measurement returned a verdict for.
  final int nodesSwept;

  /// Every node the watchdog currently considers contradicted.
  ///
  /// The **whole** current set, replaced each sweep rather than accumulated.
  final List<StalledNode> stalled;

  /// Every node the measurement could not look at.
  final List<UnmeasuredNode> blind;

  /// Why this sweep establishes nothing, when it establishes nothing.
  ///
  /// Non-null means the measurement threw, or the confirming sweep after the
  /// settle did. **A consumer must not read that as recovery**: a sweep that
  /// could not look has not observed a node getting better, and clearing the
  /// board's stall set on it would turn blindness into health. [conclusive]
  /// is the predicate to branch on.
  final String? failure;

  /// Whether this sweep observed enough to replace what the board is showing.
  ///
  /// False when [failure] is set. Named as a question about *evidence* rather
  /// than as `ok`, because there is no reading of "ok" that does not drift
  /// towards "the tree is fine".
  bool get conclusive => failure == null;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': wireType,
    'cursor': cursor.encode(),
    'at': sweptAt.toIso8601String(),
    'why': why,
    'nodes_swept': nodesSwept,
    'stalled': [for (final node in stalled) node.toJson()],
    'blind': [for (final node in blind) node.toJson()],
    if (failure != null) 'failure': failure,
  };
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw ProtocolFormatException('watchdog "$key" is not a string');
  }
  return value;
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw ProtocolFormatException('watchdog "$key" is not an integer');
  }
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw ProtocolFormatException('watchdog "$key" is not a boolean');
  }
  return value;
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) {
    throw ProtocolFormatException('watchdog "$key" is not a list');
  }
  return value;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) {
    throw ProtocolFormatException('expected a JSON object', '$value');
  }
  return {for (final entry in value.entries) '${entry.key}': entry.value};
}
