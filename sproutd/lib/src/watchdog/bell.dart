/// Where a ring goes. Surface it, page, never act.
library;

import 'dart:io';

import 'journal.dart';

/// The thing that gets a human's attention when a node contradicts.
///
/// **A sink, and only ever a sink.** `docs/01-plan.md` §5: *"Never
/// auto-reclaim a stalled node"* — the real incident behind that rule held
/// four uncommitted files and a green test suite. So the widest thing this
/// interface may ever do is tell someone. It takes no return value a caller
/// could branch on, because a bell that could say "handled, go clean it up"
/// is the first half of the thing that must never exist.
///
/// It has no default implementation on [Watchdog]. A watchdog is constructed
/// with a bell named out loud, because a no-op default is exactly the shape of
/// a watchdog that is installed, green, and connected to nobody.
abstract interface class WatchdogBell {
  /// Surfaces [ring]. Must not throw; a bell that fails is reported by the
  /// loop, never a reason to stop sweeping.
  Future<void> ring(Ring ring);
}

/// A bell that writes one line per ring to an [IOSink].
///
/// The default is stderr, which is where an unattended daemon's operator is
/// already looking. P6-03 replaces this with the board.
final class WritingBell implements WatchdogBell {
  /// Rings onto [sink], defaulting to stderr.
  WritingBell([IOSink? sink]) : sink = sink ?? stderr;

  /// Where the lines go.
  final IOSink sink;

  @override
  Future<void> ring(Ring ring) async {
    sink.writeln(
      'sprout watchdog: ${ring.nodeId} is ${ring.liveness.wire} '
      '(ring ${ring.consecutiveRings}) — ${ring.because}',
    );
  }
}

/// A bell that keeps every ring, for tests and for a board that polls.
final class RecordingBell implements WatchdogBell {
  /// Creates an empty bell.
  RecordingBell();

  final List<Ring> _rings = [];

  /// Every ring raised, oldest first.
  List<Ring> get rings => List.unmodifiable(_rings);

  @override
  Future<void> ring(Ring ring) async => _rings.add(ring);
}

/// Rings several bells.
final class FanOutBell implements WatchdogBell {
  /// Rings each of [bells], in order.
  const FanOutBell(this.bells);

  /// The bells rung.
  final List<WatchdogBell> bells;

  @override
  Future<void> ring(Ring ring) async {
    for (final bell in bells) {
      await bell.ring(ring);
    }
  }
}
