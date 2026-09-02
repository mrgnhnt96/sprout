/// The loop: settle, measure, decide, ring or say why not.
library;

import 'dart:async';

import '../../liveness.dart';
import '../../store.dart';
import 'bell.dart';
import 'contradiction.dart';
import 'journal.dart';
import 'ring_ledger.dart';

/// How often the tree is swept.
///
/// Thirty seconds, matching `.game_loop/config.json`'s `watchdog.idle_sec` —
/// the cadence this project already runs its own sessions under. It is cheap:
/// a sweep is one `ps` per node plus one `stat` per node, and it rings only on
/// a contradiction, so a shorter interval buys nothing that
/// [watchdogFrozenAfter] does not already gate.
const Duration defaultSweepInterval = Duration(seconds: 30);

/// How long the watchdog waits before believing a contradiction.
///
/// Five seconds, matching `.game_loop/config.json`'s `watchdog.settle_sec`.
/// §11 asks the watchdog to *"settle before measuring"*, and the hazard is
/// concrete: a transcript being appended to *right now* can read as frozen if
/// the sweep catches it between the mtime and the read. See
/// [Watchdog.sweepOnce] for what settling actually does, which is take a
/// second measurement rather than merely sleep.
const Duration defaultSettleFor = Duration(seconds: 5);

/// How long a transcript may stand still before the watchdog calls it frozen.
///
/// **The watchdog's own knob, declared here rather than borrowed.** P6-01 says
/// of its `defaultFrozenAfter` that it is *"a knob, not a finding"* — nothing
/// in the plan, the research, or the Phase 0 captures fixes a number. This
/// leaf inherits the absence of evidence along with the number, so it declares
/// its own constant, at the same five minutes, and says plainly that it has no
/// more support than P6-01's did. It is longer than a slow tool call — a test
/// suite or a build holds a session silent for minutes — and shorter than a
/// person's patience.
///
/// It is spelled out here instead of re-exported so that changing what the
/// *watchdog* believes is frozen never silently changes what a `sprout`
/// command reporting liveness believes, or the reverse.
const Duration watchdogFrozenAfter = Duration(minutes: 5);

/// The watchdog: sweeps the tree from outside it, rings on a contradiction,
/// and writes down every sweep that did not.
///
/// **Outside the sessions — the whole premise.** `docs/01-plan.md` §1: *"A real
/// run sat inert for six hours with the Stop gate, watchdog, and limit gate all
/// reporting healthy. A stuck session cannot notice it is stuck."* Nothing in
/// this class asks a watched process for anything. It reads the store's node
/// graph, runs `ps` against recorded pids, and stats transcript files. A
/// session that has wedged, deadlocked, or been SIGSTOPped changes none of
/// that, which is exactly the point.
///
/// **Contradiction-triggered, not timer-triggered.** The interval decides when
/// to *look*; only a [Contradiction] decides whether to ring. See
/// [ringingVerdicts] for the definition, written to be disagreed with.
///
/// **It never acts.** No kill, no signal, no reclaim, no auto-reclaim of a
/// stalled node, here or anywhere under `lib/src/watchdog/`;
/// `test/watchdog_test.dart` asserts that of the source, exactly as P6-01's
/// test does of `lib/src/liveness/`. §5: the real incident behind that rule
/// held four uncommitted files and a green test suite. Surface it, page, never
/// act.
final class Watchdog {
  /// Creates a watchdog over [store].
  ///
  /// [bell] and [journal] are required and have no defaults: a watchdog whose
  /// rings go nowhere, or whose quiet sweeps leave nothing behind, is the
  /// failure this class exists to prevent, and it must not be reachable by
  /// omission.
  ///
  /// [processes] and [transcripts] default to the real `ps` and the real
  /// filesystem; a test passes stubs, including a broken probe, to drive the
  /// blind case. [clock] and [sleep] exist so a test can drive the loop
  /// without waiting out an interval.
  Watchdog({
    required SproutStore store,
    required this.bell,
    required this.journal,
    ProcessProbe processes = const PsProcessProbe(),
    TranscriptIndex transcripts = const FileTranscripts(),
    this.frozenAfter = watchdogFrozenAfter,
    this.interval = defaultSweepInterval,
    this.settleFor = defaultSettleFor,
    int ringCap = defaultRingCap,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : ledger = RingLedger(cap: ringCap),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? _realSleep,
       measure = LivenessMeasure(
         store: store,
         processes: processes,
         transcripts: transcripts,
         // The loop owns the value it passes, rather than accepting P6-01's.
         frozenAfter: frozenAfter,
         clock: clock,
       );

  /// The measurement P6-01 shipped, constructed with this loop's knobs.
  final LivenessMeasure measure;

  /// Where a ring goes.
  final WatchdogBell bell;

  /// Where every sweep is written down, rung or quiet.
  final WatchdogJournal journal;

  /// The cap and its reset.
  final RingLedger ledger;

  /// How long a transcript may stand still before it counts as frozen.
  final Duration frozenAfter;

  /// How often [run] sweeps.
  final Duration interval;

  /// How long a contradiction must survive before it is believed.
  final Duration settleFor;

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  bool _running = false;
  Completer<void>? _stopped;
  Completer<void>? _wake;

  /// Whether [run] is currently looping.
  bool get isRunning => _running;

  /// Takes one sweep and returns what it decided.
  ///
  /// Public because a sweep on demand is a real thing to want — P6-03's board
  /// refreshing, a test driving the loop without waiting out an [interval] —
  /// and because a loop whose single iteration cannot be called is a loop that
  /// can only be tested by waiting.
  ///
  /// The order, and why each step is where it is:
  ///
  /// 1. **Measure the whole forest.** [LivenessMeasure.sweep] answers for
  ///    every node, deliberately: *"a silently short sweep and a small tree
  ///    look the same, and the node missing from a short sweep is exactly the
  ///    runaway."*
  /// 2. **If nothing contradicts, stop here** — no settle, no second sweep. The
  ///    healthy path costs one sweep.
  /// 3. **Settle, then measure again.** Settling is not a bare sleep: a sleep
  ///    on its own cannot tell a frozen transcript from one caught mid-write,
  ///    because both look identical to the single reading that already
  ///    happened. Taking a *second* reading after the wait can, and does — a
  ///    node whose transcript grew during the wait clears, and is recorded in
  ///    [SweepRecord.settledClear] rather than dropped, so a settle that is
  ///    doing nothing is distinguishable from one that is earning its place.
  /// 4. **Rule each surviving contradiction through the ledger**, which rings
  ///    or reports the cap.
  /// 5. **Reset every node that advanced**, including the ones that cleared
  ///    during the settle.
  /// 6. **Write the sweep down with a `why`, always** — including, and
  ///    especially, when it rang about nothing.
  Future<SweepRecord> sweepOnce() async {
    final startedAt = _clock().toUtc();

    final Map<String, LivenessVerdict> first;
    try {
      first = await measure.sweep();
    } on Object catch (error) {
      // A measurement that failed is not evidence about any node, so nothing
      // rings and nothing is marked as having progressed either. The ring
      // counts stand exactly where they were.
      return _write(
        SweepRecord(
          at: _clock().toUtc(),
          took: _clock().toUtc().difference(startedAt),
          nodesSwept: 0,
          failure: '$error',
          why:
              'no sweep was taken: the measurement threw ($error). Nothing '
              'rang, and nothing here says the tree is healthy — this is a '
              'sweep that could not look, not a sweep that found nothing',
        ),
      );
    }

    final contradictions = _contradictionsIn(first);
    final blind = _blindnessIn(first);

    if (contradictions.isEmpty) {
      final resets = _markProgress(
        first.keys,
        contradicted: const {},
        blind: {for (final blindness in blind) blindness.nodeId},
      );
      return _write(
        SweepRecord(
          at: _clock().toUtc(),
          took: _clock().toUtc().difference(startedAt),
          nodesSwept: first.length,
          blind: blind,
          why: _quietWhy(
            swept: first.length,
            blind: blind,
            resets: resets,
            settledClear: const [],
          ),
        ),
      );
    }

    // Something contradicts. Settle, then look again before believing it.
    await _sleep(settleFor);

    final Map<String, LivenessVerdict> second;
    try {
      second = await measure.sweep();
    } on Object catch (error) {
      return _write(
        SweepRecord(
          at: _clock().toUtc(),
          took: _clock().toUtc().difference(startedAt),
          nodesSwept: first.length,
          blind: blind,
          failure: '$error',
          why:
              '${contradictions.length} node(s) contradicted, but the '
              'confirming sweep after the ${_secs(settleFor)} settle threw '
              '($error). Nothing rang: one unconfirmed reading is not a '
              'contradiction',
        ),
      );
    }

    final confirmed = _contradictionsIn(second);
    final confirmedIds = confirmed.map((c) => c.nodeId).toSet();
    final settledClear = [
      for (final contradiction in contradictions)
        if (!confirmedIds.contains(contradiction.nodeId)) contradiction.nodeId,
    ]..sort();

    final rang = <Ring>[];
    final silenced = <RingRuling>[];
    for (final contradiction in confirmed) {
      final ruling = ledger.rule(contradiction);
      if (!ruling.rings) {
        silenced.add(ruling);
        continue;
      }
      final ring = Ring.from(contradiction, ruling, at: _clock().toUtc());
      rang.add(ring);
      await bell.ring(ring);
    }

    final stillBlind = _blindnessIn(second);
    final resets = _markProgress(
      second.keys,
      contradicted: confirmedIds,
      blind: {for (final blindness in stillBlind) blindness.nodeId},
    );

    final rung = rang.map((r) => '${r.nodeId} ${r.liveness.wire}').join(', ');
    return _write(
      SweepRecord(
        at: _clock().toUtc(),
        took: _clock().toUtc().difference(startedAt),
        nodesSwept: second.length,
        rang: rang,
        silenced: silenced,
        blind: stillBlind,
        settledClear: settledClear,
        why: rang.isEmpty
            ? _quietWhy(
                swept: second.length,
                blind: stillBlind,
                resets: resets,
                settledClear: settledClear,
                silenced: silenced,
              )
            : 'rang for ${rang.length} of ${second.length} node(s): $rung'
                  '${silenced.isEmpty ? '' : '; ${silenced.length} more at the ring cap and silenced'}'
                  '${stillBlind.isEmpty ? '' : '; ${stillBlind.length} unmeasured, not rung and not counted healthy'}',
      ),
    );
  }

  /// Sweeps every [interval] until [stop] is called.
  ///
  /// Sweeps immediately rather than waiting out the first interval: a watchdog
  /// started against an already-stalled tree should not be quiet for half a
  /// minute first.
  ///
  /// Returns when the loop has stopped. A sweep never throws — every failure
  /// path inside [sweepOnce] ends in a journal entry — so the loop cannot be
  /// ended by the thing it is watching.
  Future<void> run() async {
    if (_running) {
      throw StateError('this watchdog is already running');
    }
    _running = true;
    final stopped = _stopped = Completer<void>();
    try {
      while (_running) {
        await sweepOnce();
        if (!_running) break;
        // Raced against [stop] rather than simply awaited. A bare
        // `await _sleep(interval)` makes `stop()` wait out the whole interval
        // before the loop can notice it, which on the shipped thirty seconds
        // reads as a hung shutdown and on a longer one is a deadlock.
        final wake = _wake = Completer<void>();
        await Future.any([_sleep(interval), wake.future]);
        _wake = null;
      }
    } finally {
      _running = false;
      _stopped = null;
      _wake = null;
      if (!stopped.isCompleted) stopped.complete();
    }
  }

  /// Asks [run] to stop and returns when it has.
  ///
  /// The current sweep finishes first. Interrupting a sweep would leave the
  /// journal without the entry for it, and an unexplained gap in the journal
  /// is the one thing this loop is built not to produce.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    await _stopped?.future;
  }

  List<Contradiction> _contradictionsIn(Map<String, LivenessVerdict> sweep) {
    final found = [
      for (final verdict in sweep.values)
        if (ringingVerdicts.contains(verdict.liveness)) Contradiction(verdict),
    ];
    found.sort((a, b) => a.nodeId.compareTo(b.nodeId));
    return found;
  }

  List<Blindness> _blindnessIn(Map<String, LivenessVerdict> sweep) {
    final found = [
      for (final verdict in sweep.values)
        if (verdict.liveness == Liveness.unmeasured) Blindness(verdict),
    ];
    found.sort((a, b) => a.nodeId.compareTo(b.nodeId));
    return found;
  }

  /// Clears the ring count of every node that is not currently contradicted.
  ///
  /// A blind node is **not** progress and is not cleared here: "I could not
  /// look" must not reset a count that a real contradiction earned, or a probe
  /// that fails every other sweep would keep a genuinely stalled node ringing
  /// forever with the cap never reached.
  List<String> _markProgress(
    Iterable<String> nodeIds, {
    required Set<String> contradicted,
    required Set<String> blind,
  }) {
    final reset = <String>[];
    for (final nodeId in nodeIds) {
      if (contradicted.contains(nodeId)) continue;
      if (blind.contains(nodeId)) continue;
      if (ledger.progressed(nodeId) > 0) reset.add(nodeId);
    }
    reset.sort();
    return reset;
  }

  String _quietWhy({
    required int swept,
    required List<Blindness> blind,
    required List<String> resets,
    required List<String> settledClear,
    List<RingRuling> silenced = const [],
  }) {
    final parts = <String>[];
    if (settledClear.isNotEmpty) {
      parts.add(
        '${settledClear.length} node(s) contradicted and cleared during the '
        '${_secs(settleFor)} settle (${settledClear.join(', ')}), so the '
        'reading was caught mid-write rather than frozen',
      );
    }
    if (silenced.isNotEmpty) {
      parts.add(
        '${silenced.length} node(s) still contradicted but are at the ring '
        'cap of ${ledger.cap} (${silenced.map((s) => s.nodeId).join(', ')}) — '
        'silenced until each advances, not silenced for good',
      );
    }
    if (resets.isNotEmpty) {
      parts.add(
        '${resets.length} node(s) advanced, so their ring counts reset '
        '(${resets.join(', ')})',
      );
    }
    if (parts.isEmpty) {
      // Counted against the nodes that could actually be LOOKED at, never
      // against the whole tree. "All 3 nodes measured live" for a sweep whose
      // probe failed on all three is the blind watchdog reporting green, and
      // it is a sentence, not a bug in a boolean — which is why the sentence
      // is built from the same two numbers the record carries.
      final measured = swept - blind.length;
      parts.add(switch ((swept, measured)) {
        (0, _) => 'the tree is empty, so there was nothing to contradict',
        (_, 0) =>
          'not one of the $swept node(s) could be measured, so this sweep '
              'establishes nothing about any of them',
        _ =>
          'the $measured node(s) that could be measured were live or '
              'ended — no contradiction between what the tree records and '
              'what was observed',
      });
    }
    if (blind.isNotEmpty) {
      final which = blind.map((b) => b.nodeId).join(', ');
      parts.add(
        swept == blind.length
            ? 'the blind node(s) are $which — not rung, because a failed look '
                  'contradicts nothing, and NOT counted healthy'
            : '${blind.length} of $swept node(s) could not be measured '
                  '($which) — not rung, because a failed look contradicts '
                  'nothing, and NOT counted healthy',
      );
    }
    return 'no ring: ${parts.join('; ')}';
  }

  Future<SweepRecord> _write(SweepRecord sweep) async {
    await journal.record(sweep);
    return sweep;
  }

  static String _secs(Duration d) => '${d.inMilliseconds / 1000}s';

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);
}
