/// The ring cap, and the reset that is the half which makes it safe.
library;

import 'contradiction.dart';

/// How many consecutive unproductive rings one node gets before it is
/// silenced.
///
/// Three, matching `.game_loop/config.json`'s `watchdog.ring_cap` — the value
/// this project already runs its own sessions under, so it is a number with
/// use behind it rather than a fresh guess. Like every other knob here it is a
/// constructor argument.
const int defaultRingCap = 3;

/// What the ledger decided about one contradiction.
enum RingOutcome {
  /// Ring it. This is a contradiction that has not been rung to its cap.
  rang,

  /// Do not ring: this node has already rung [RingLedger.cap] times in a row
  /// with nothing changing. It stays silent until it advances.
  silenced,
}

/// The ledger's answer for one node this sweep.
final class RingRuling {
  /// Records a decision and the sentence behind it.
  const RingRuling({
    required this.nodeId,
    required this.outcome,
    required this.consecutiveRings,
    required this.why,
  });

  /// The node ruled on.
  final String nodeId;

  /// Ring, or stay silent.
  final RingOutcome outcome;

  /// How many consecutive unproductive rings this node now stands at.
  final int consecutiveRings;

  /// Why, in one sentence a human can read off a log line.
  final String why;

  /// Whether this ruling rings.
  bool get rings => outcome == RingOutcome.rang;

  @override
  String toString() => 'RingRuling($nodeId: ${outcome.name} — $why)';
}

/// Per-node memory of what has already been rung about, and whether it helped.
///
/// **The cap is on CONSECUTIVE UNPRODUCTIVE rings, not on rings.** `01-plan.md`
/// §11 asks for exactly that, and the two failures it sits between are both
/// real:
///
/// - A watchdog that rings forever about one stuck node is muted by the person
///   it is ringing at, and then it guards nothing at all.
/// - A watchdog that stops permanently after N rings has *also* stopped
///   guarding — quietly, which is worse, because from the outside it looks
///   identical to a healthy tree.
///
/// The reset is what separates the two, so it is the part to get right: the
/// moment a node advances, its count goes back to zero and it can ring again.
///
/// **Per node, never tree-wide.** A single tree-wide counter would let one
/// genuinely stuck node spend the whole tree's ring budget and silence the
/// watchdog for every other node — which is a global mute wearing a cap's
/// clothing.
///
/// **A ledger decides, it never acts.** Nothing here kills, signals or
/// reclaims anything; `test/watchdog_test.dart` asserts that of every file
/// under `lib/src/watchdog/`.
final class RingLedger {
  /// Creates an empty ledger with a cap of [cap] consecutive rings.
  RingLedger({this.cap = defaultRingCap})
    : assert(cap > 0, 'a cap of zero silences the watchdog permanently');

  /// How many consecutive unproductive rings a node gets.
  final int cap;

  final Map<String, _NodeRings> _byNode = {};

  /// How many consecutive unproductive rings [nodeId] currently stands at.
  int ringsFor(String nodeId) => _byNode[nodeId]?.rings ?? 0;

  /// Whether [nodeId] is currently silenced by the cap.
  bool isSilenced(String nodeId) => ringsFor(nodeId) >= cap;

  /// The node ids the ledger is currently holding a count for.
  Iterable<String> get tracked => _byNode.keys;

  /// Records that [nodeId] advanced, and returns the count that was cleared.
  ///
  /// Called for every node a sweep found *not* contradicted — live, ended, or
  /// a contradiction that cleared while the watchdog was settling. Returns 0
  /// when there was nothing to clear, so a caller can log the resets that
  /// actually happened rather than one line per healthy node per sweep.
  int progressed(String nodeId) {
    final cleared = _byNode.remove(nodeId)?.rings ?? 0;
    return cleared;
  }

  /// Decides whether [contradiction] rings now.
  ///
  /// Two ways the count resets, and both are here rather than split across
  /// callers so that neither can be forgotten:
  ///
  /// 1. Through [progressed], when the node stops contradicting at all.
  /// 2. Here, when the node is *still* contradicted but its
  ///    [Contradiction.mark] has moved since the last ring. A stalled node
  ///    that wrote something and then froze again is a new stall, not the
  ///    continuation of the one already rung about — the previous ring
  ///    produced an advance, so it was productive.
  ///
  /// A node with no mark at all (typically [Liveness.abandoned], which has no
  /// live process and so no freshness to move) can only reset through the
  /// first path. That is correct and not a gap: an abandoned node advancing is
  /// precisely a node that stopped being abandoned.
  RingRuling rule(Contradiction contradiction) {
    final nodeId = contradiction.nodeId;
    final state = _byNode.putIfAbsent(nodeId, _NodeRings.new);
    final mark = contradiction.mark;

    var resetBecause = '';
    if (state.rings > 0 && mark != null && state.mark != null) {
      if (mark.isAfter(state.mark!)) {
        resetBecause =
            'the node advanced since its last ring (${state.mark} → $mark), '
            'so those ${state.rings} ring(s) were productive and the count '
            'reset; ';
        state.rings = 0;
      }
    }

    if (state.rings >= cap) {
      return RingRuling(
        nodeId: nodeId,
        outcome: RingOutcome.silenced,
        consecutiveRings: state.rings,
        why:
            'still ${contradiction.liveness.wire}, and $nodeId has rung '
            '${state.rings} consecutive times with nothing changing, which is '
            'the cap of $cap — silenced until this node advances, not '
            'silenced for good',
      );
    }

    state.rings += 1;
    state.mark = mark;
    return RingRuling(
      nodeId: nodeId,
      outcome: RingOutcome.rang,
      consecutiveRings: state.rings,
      why:
          '$resetBecause${contradiction.liveness.wire}: '
          '${contradiction.because} (ring ${state.rings} of $cap)',
    );
  }
}

/// One node's ring count and the mark it was last rung at.
final class _NodeRings {
  int rings = 0;
  DateTime? mark;
}
