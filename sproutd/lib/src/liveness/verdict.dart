/// The three liveness verdicts of `docs/01-plan.md` §5, and the evidence.
library;

/// What a liveness measurement concluded about one node.
///
/// **Three of these are §5's verdicts** — [live], [stalled], [abandoned]. The
/// other two are deliberately *not* verdicts, and exist so that a measurement
/// never has to launder something it did not observe into one that is:
///
/// - [ended] — the node reached one of §5's honest endings, so there is no
///   liveness question to answer about it.
/// - [unmeasured] — the measurement could not look. A failed read is not a
///   fact about the world, and folding it into [abandoned] would page a human
///   about a healthy node every time `ps` was missing.
///
/// This is **not** a [NodeStatus]. Liveness is derived now, from a pid beside a
/// transcript mtime, and a node that recovers must stop being stalled without
/// anything having to write a row. See the note on `NodeStatus` in
/// `package:sprout_protocol/values.dart`, which says the same thing from the
/// other side.
enum Liveness {
  /// The process is genuinely working, or it is waiting on a descendant that
  /// is.
  ///
  /// The second half is the whole point, and it is the gap sprout exists to
  /// close. `.game_loop`'s watchdog fires on a contradiction — mandate bound,
  /// work outstanding, transcript not grown in `idle_sec` — with no probe for
  /// *waiting on a child* (`docs/research/07-local-harnesses.md` §100; this
  /// repo's `.game_loop/config.json` carries `idle_sec/settle_sec/ring_cap`
  /// and no `waiting_probe`). So a fanned-out orchestrator blocked on its
  /// children reads as asleep. A watchdog that pages every time an
  /// orchestrator waits is switched off within a day, and then it guards
  /// nothing.
  live('live'),

  /// Pid alive and start-time-verified, transcript frozen past the threshold,
  /// and nothing in the subtree advancing.
  ///
  /// **Surface it, page, never act.** §5: *"Never auto-reclaim a stalled
  /// node"* — the real incident behind that rule held four uncommitted files
  /// and a green test suite. Nothing in this library can kill a process, and
  /// `liveness_test.dart` asserts that of the source.
  stalled('stalled'),

  /// No live process for the node, and no honest ending recorded.
  abandoned('abandoned'),

  /// The node reached checkpoint, arm, clear or park. Not a liveness question.
  ///
  /// Process *exit* is not an ending: `runner.dart` refuses to infer completion
  /// from it (INV12), so a node whose process died still `working` is
  /// [abandoned], not [ended].
  ended('ended'),

  /// The measurement could not look, and says so instead of guessing.
  unmeasured('unmeasured');

  const Liveness(this.wire);

  /// The string a consumer reads off the wire.
  ///
  /// Written out rather than derived from [name] for the same reason
  /// `NodeStatus.wire` is: renaming a Dart identifier must not silently rewrite
  /// what a browser switches on.
  final String wire;

  /// Whether this is one of §5's three verdicts, as opposed to [ended] or
  /// [unmeasured].
  bool get isVerdict => this == live || this == stalled || this == abandoned;

  /// Whether a human should be shown this at all.
  ///
  /// **Renamed from `pages` by P6-03, settling F-13, and the rename is the
  /// whole fix.** P6-01 shipped this as `pages` returning true for
  /// [unmeasured], arguing that *"'I could not tell' about a node sprout
  /// believes is running is a fact worth a human's attention, and treating it
  /// as quiet is how a blind watchdog reports green."* P6-02's `ringingVerdicts`
  /// then excluded [unmeasured], because the watchdog rings on a
  /// *contradiction* and the absence of an observation contradicts nothing.
  ///
  /// Both were right, about **different questions**, and the bug was that two
  /// declarations answering different questions were named as though they
  /// answered one. `ringingVerdicts` means *rings a stall alarm*; this means
  /// *belongs on the board*. Narrowing this one to match would have thrown
  /// away P6-01's argument, which is correct — so the name moved instead and
  /// the set did not.
  ///
  /// The board honours it: a `watchdog` frame carries the contradictions in
  /// `stalled` and the blind nodes in `blind`, which together are exactly the
  /// verdicts this returns true for, and `test/watchdog_test.dart` pins that
  /// correspondence. The two lists stay separate on the wire precisely because
  /// they are not the same fact — one is what was seen, the other is what was
  /// not.
  bool get worthSurfacing =>
      this == stalled || this == abandoned || this == unmeasured;
}

/// One node's liveness, with everything the conclusion was drawn from.
///
/// The evidence fields are carried rather than logged and dropped because a
/// verdict a human is paged with has to be arguable: `stalled` with a pid, a
/// process start time and a frozen-for duration can be checked by hand in one
/// `ps`, and `stalled` on its own cannot.
final class LivenessVerdict {
  /// Creates a verdict. Prefer the named constructors.
  const LivenessVerdict({
    required this.nodeId,
    required this.liveness,
    required this.because,
    this.pid,
    this.processStartedAt,
    this.spawnedAt,
    this.lastWrite,
    this.frozenFor,
    this.waitingOn,
  });

  /// The node this is about.
  final String nodeId;

  /// The conclusion.
  final Liveness liveness;

  /// One sentence naming what was observed, for a human reading a page.
  final String because;

  /// The pid the node recorded, when it recorded one.
  final int? pid;

  /// When the process holding [pid] actually started, per `ps`. UTC.
  ///
  /// Null when no process was found, or when it could not be read.
  final DateTime? processStartedAt;

  /// When the node's `runner.spawned` event was appended. UTC.
  final DateTime? spawnedAt;

  /// The freshness reference: the transcript's mtime, or [spawnedAt] when the
  /// transcript has not been written yet. UTC.
  final DateTime? lastWrite;

  /// How long [lastWrite] has been in the past.
  final Duration? frozenFor;

  /// The advancing descendant that made a frozen node [Liveness.live].
  final String? waitingOn;

  @override
  String toString() => 'LivenessVerdict($nodeId: ${liveness.wire} — $because)';
}
