/// What a subtree has been *observed* to spend, and how much of it was not.
///
/// Three states, not two, and the third is the point. A subtree can be:
///
/// - **unknown** — no node in it reported a dollar figure. [costUsd] is null.
///   Emphatically not `$0.00`: an identity element is reported as *could not
///   tell*, never as *nothing there* (`docs/01-plan.md` §9).
/// - **partial** — some nodes reported and some did not. [costUsd] is a floor,
///   and [unknownNodes] says how many nodes are missing from it, so a caller
///   cannot print it as a total by accident.
/// - **complete** — every node in the subtree reported.
///
/// Partial is the *normal* state for a tree with subagents, and that is an
/// observation rather than a guess: across all six Phase 0 captures
/// (`docs/research/fixtures/phase0/streams/{A,B,C,C2,D,E}.ndjson`) every
/// `result` frame carries `parent_tool_use_id: null` — including `B.ndjson`,
/// which is the depth-2 nested-subagent capture. `total_cost_usd` exists only
/// on the root's results. A subagent's own dollars are not in the stream at
/// all, so sprout does not have them, and saying so is the only honest answer
/// (INV10, INV13).
final class SubtreeSpend {
  /// Records a fold over one subtree.
  const SubtreeSpend({
    required this.knownMicroUsd,
    required this.nodes,
    required this.unknownNodes,
  });

  /// Micro-dollars summed over the nodes that did report.
  ///
  /// Micro-dollars because that is what `SpendLedger` sums in, and for the
  /// reason it gives: `0.1 + 0.2 > 0.3` in binary floating point, so money is
  /// added as integers.
  final int knownMicroUsd;

  /// How many nodes are in this subtree, counting the node itself.
  final int nodes;

  /// How many of [nodes] reported no dollar figure.
  final int unknownNodes;

  /// How many of [nodes] did report one.
  int get knownNodes => nodes - unknownNodes;

  /// Whether nothing at all is known about this subtree's spend.
  bool get isUnknown => knownNodes == 0;

  /// Whether every node in the subtree reported.
  bool get isComplete => unknownNodes == 0;

  /// Dollars observed, or null when [isUnknown].
  ///
  /// When [isComplete] is false this is a **floor**, not a total. Render it
  /// through [label], which cannot lose that qualifier.
  double? get costUsd => isUnknown ? null : knownMicroUsd / 1e6;

  /// The one-line rendering, which never prints a floor as if it were a total.
  ///
  /// `spend ?` · `$0.2416` · `>=$0.2416 (2 unknown)`.
  String get label {
    final cost = costUsd;
    if (cost == null) return 'spend $unknownValueText';
    final amount = '\$${cost.toStringAsFixed(4)}';
    return isComplete ? amount : '>=$amount ($unknownNodes unknown)';
  }

  @override
  String toString() => 'SubtreeSpend($label over $nodes nodes)';
}

/// What a field prints when sprout does not know its value.
///
/// One character, and never a zero, a blank or a guess. `since ?` is the
/// plan's own wording (`docs/01-plan.md` §7 — *never estimate an age*), and
/// the same token is used everywhere else a value is genuinely absent so that
/// "sprout does not know" reads the same in every column.
const String unknownValueText = '?';

/// What `next check-in` prints when there is none.
///
/// Deliberately loud and deliberately not empty: *absence must never look like
/// presence*, and a blank column reads as "fine" (`docs/01-plan.md` §7).
const String noCheckinText = 'NONE SCHEDULED';
