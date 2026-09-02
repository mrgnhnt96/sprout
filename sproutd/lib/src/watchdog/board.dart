/// The seam between the sweep and the human: every sweep, on the board.
library;

import 'dart:async';

import '../../protocol.dart';
import 'journal.dart';

/// Where the daemon's watchdog puts its sweeps so attached boards can see them.
///
/// **A [WatchdogJournal] and deliberately not a [WatchdogBell].** A bell fires
/// on a *ring*, which is an edge: it can say a node started being stalled and
/// has no way at all to say a node stopped. The board needs the opposite — the
/// whole current verdict, every sweep, so that a node which recovered is
/// simply absent from the next one. That is the same argument `NodeStatus`
/// makes from the other side by refusing a `stalled` member: liveness is
/// recomputed, never stored, so a recovered node stops being stalled with
/// nothing having written a row.
///
/// The bell is still rung, and still goes to a human — `sprout ui` gives the
/// watchdog a [WritingBell] on stderr. The two are different jobs: the bell
/// *pages*, this *surfaces*. §11 asks for both.
///
/// **Pair it with a [FileWatchdogJournal], never replace one.** This holds one
/// record in memory and it dies with the process, and a record that dies with
/// the process cannot tell anyone the process died. The file's own mtime is
/// the watchdog's pulse, readable with `ls -l` by something running none of
/// this code.
///
/// **It cannot act.** It holds a value and a broadcast stream; there is no pid
/// here, no handle, and nothing a subscriber could call. §5: *"Never
/// auto-reclaim a stalled node."*
final class WatchdogBoard implements WatchdogJournal {
  /// Creates an empty board.
  WatchdogBoard();

  /// The board the daemon's own watchdog writes to.
  ///
  /// **A process-wide singleton, because the two halves that need it are wired
  /// up by two different mechanisms in one process.** `bin/sprout.dart`
  /// constructs the [Watchdog] because it owns the daemon's lifetime; the
  /// controller receives its dependencies from revali's DI, which
  /// `MainApp.configureDependencies` populates out of `Platform.environment`
  /// and which `bin/sprout.dart` has no handle on — `createServer` calls
  /// `MainApp.new()` itself. One process, one watchdog, one board is the fact;
  /// this names it rather than passing an instance through a seam that does
  /// not exist.
  ///
  /// Tests never touch it: `treeSocketFrames` and `attachTreeSocket` take a
  /// board by parameter, exactly as they take `signals` and `now`.
  static final WatchdogBoard shared = WatchdogBoard();

  final StreamController<SweepRecord> _sweeps =
      StreamController<SweepRecord>.broadcast();

  SweepRecord? _last;

  /// The most recent sweep, or null if the watchdog has not swept yet.
  ///
  /// Null is a real answer and boards must render it as one: a daemon whose
  /// watchdog has not run and a daemon whose tree is fine are different things,
  /// and a board that showed them the same would be INV8 all over again.
  SweepRecord? get last => _last;

  /// Every sweep from now on. Broadcast: one board per attached client.
  Stream<SweepRecord> get sweeps => _sweeps.stream;

  @override
  Future<void> record(SweepRecord sweep) async {
    _last = sweep;
    if (!_sweeps.isClosed) _sweeps.add(sweep);
  }

  /// Stops publishing. Called when the daemon shuts down.
  Future<void> close() => _sweeps.close();
}

/// The last entry a watchdog loop writes: it is no longer running, and why.
///
/// **The single most important record this file produces.** A watchdog that
/// crashed and a tree that is quiet leave exactly the same trace — none — and
/// `docs/01-plan.md` §1 is about a run that *"sat inert for six hours with the
/// Stop gate, watchdog, and limit gate all reporting healthy"*. So when the
/// loop ends for any reason, the journal and the board are told, in the same
/// shape as every other sweep, with [SweepRecord.failure] set so that no
/// consumer can read it as a sweep that found nothing.
///
/// [error] is null for an orderly stop — the daemon is shutting down — and the
/// message for a crash. Both are recorded, because a watchdog that stopped
/// when nobody asked it to and one that stopped because the process is going
/// away are different facts and the board says which.
SweepRecord watchdogStoppedRecord({required DateTime at, String? error}) {
  return SweepRecord(
    at: at.toUtc(),
    took: Duration.zero,
    nodesSwept: 0,
    failure: error ?? 'the daemon is shutting down',
    why: error == null
        ? 'the watchdog has stopped because the daemon is shutting down. '
              'Nothing here says the tree is healthy: from now on nobody is '
              'looking'
        : 'THE WATCHDOG STOPPED and it was not asked to ($error). Nothing '
              'here says the tree is healthy — this is the thing that was '
              'meant to notice, having itself stopped',
  );
}

/// The [WatchdogFrame] for [sweep], as it goes out on the socket.
///
/// **The stall set is `rang` plus `silenced`, and that is the whole of it.** A
/// silenced node is still contradicted — the ring cap governs how often a
/// human is rung at, never whether a stall is shown — so dropping it here
/// would make a node vanish from the board on the sweep its third ring was
/// capped. Every other node the sweep touched is absent, which is how a
/// recovered node stops being stalled.
///
/// **Blindness is carried separately and is never folded in.** `SweepRecord`
/// has no `healthy` getter and neither does the frame; what travels instead is
/// [SweepRecord.why] unedited, which on a blind sweep already reads *"not one
/// of the 2 node(s) could be measured, so this sweep establishes nothing about
/// any of them"*. One sentence, written once, shown on the board and appended
/// to the NDJSON journal — so the two cannot come to describe one sweep two
/// ways.
///
/// [at] is where the socket stands in the event feed. A sweep is not a feed
/// position and does not advance one; the frame carries the last cursor its
/// socket emitted, so a consumer storing cursors as it goes can never be
/// carried past an event by a frame that contained none.
WatchdogFrame watchdogFrameFor(SweepRecord sweep, {required Cursor at}) {
  final stalled = <StalledNode>[
    for (final ring in sweep.rang)
      StalledNode(
        nodeId: ring.nodeId,
        liveness: ring.liveness.wire,
        because: ring.because,
        consecutiveRings: ring.consecutiveRings,
        silenced: false,
      ),
    for (final ruling in sweep.silenced)
      StalledNode(
        nodeId: ruling.nodeId,
        liveness: ruling.liveness.wire,
        because: ruling.because,
        consecutiveRings: ruling.consecutiveRings,
        silenced: true,
      ),
  ]..sort((a, b) => a.nodeId.compareTo(b.nodeId));

  return WatchdogFrame(
    cursor: at,
    sweptAt: sweep.at,
    why: sweep.why,
    nodesSwept: sweep.nodesSwept,
    stalled: stalled,
    blind: [
      for (final blindness in sweep.blind)
        UnmeasuredNode(nodeId: blindness.nodeId, because: blindness.because),
    ],
    failure: sweep.failure,
  );
}
