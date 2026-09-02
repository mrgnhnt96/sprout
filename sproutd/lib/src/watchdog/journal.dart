/// Where every sweep is written down — the ones that rang and the ones that
/// did not.
library;

import 'dart:convert';
import 'dart:io';

import '../../liveness.dart';
import 'contradiction.dart';
import 'ring_ledger.dart';

/// One node the watchdog rang about.
final class Ring {
  /// Records a ring and the evidence behind it.
  const Ring({
    required this.nodeId,
    required this.liveness,
    required this.because,
    required this.consecutiveRings,
    required this.at,
    this.pid,
    this.frozenFor,
  });

  /// Builds a ring from the ledger's ruling and the contradiction it ruled on.
  factory Ring.from(
    Contradiction contradiction,
    RingRuling ruling, {
    required DateTime at,
  }) {
    return Ring(
      nodeId: contradiction.nodeId,
      liveness: contradiction.liveness,
      because: contradiction.because,
      consecutiveRings: ruling.consecutiveRings,
      at: at,
      pid: contradiction.verdict.pid,
      frozenFor: contradiction.verdict.frozenFor,
    );
  }

  /// The node the tree and the world disagree about.
  final String nodeId;

  /// [Liveness.stalled] or [Liveness.abandoned].
  final Liveness liveness;

  /// The measurement's sentence, carried through unedited.
  ///
  /// Unedited on purpose: a page a human cannot argue with is a page they
  /// learn to dismiss. `stalled` with a pid, a process start time and a
  /// frozen-for duration can be checked by hand in one `ps`.
  final String because;

  /// Which consecutive ring this is, against the ledger's cap.
  final int consecutiveRings;

  /// When it rang. UTC.
  final DateTime at;

  /// The pid the node recorded, when it recorded one.
  final int? pid;

  /// How long the node's freshness reference has stood still.
  final Duration? frozenFor;

  /// The ring as one line of NDJSON.
  Map<String, Object?> toJson() => {
    'node_id': nodeId,
    'liveness': liveness.wire,
    'because': because,
    'consecutive_rings': consecutiveRings,
    'at': at.toIso8601String(),
    if (pid != null) 'pid': pid,
    if (frozenFor != null) 'frozen_for_sec': frozenFor!.inSeconds,
  };

  @override
  String toString() => 'Ring($nodeId: ${liveness.wire} — $because)';
}

/// Everything one sweep saw and everything it decided.
///
/// **This exists because a silent watchdog is ambiguous.** `docs/01-plan.md`
/// §11 requires *"every quiet exit logged with a `why`"*, and the reason is
/// INV8 turned on the watchdog itself: a watchdog that is quiet because the
/// tree is healthy and one that is quiet because it crashed at 03:00 look
/// exactly the same from outside, and the second is the failure this project
/// was built to catch. A sweep that ran and found nothing has to be
/// distinguishable from a sweep that never ran, and the only way to do that is
/// for the quiet sweep to leave something behind.
///
/// **There is deliberately no `healthy` getter.** A caller that could read one
/// boolean off a sweep would read it, and it would say "healthy" for a sweep
/// that could not look at half the tree. [blind] is listed separately and
/// named in [why] for the same reason.
final class SweepRecord {
  /// Records one completed sweep.
  const SweepRecord({
    required this.at,
    required this.took,
    required this.nodesSwept,
    required this.why,
    this.rang = const [],
    this.silenced = const [],
    this.blind = const [],
    this.settledClear = const [],
    this.failure,
  });

  /// When the sweep finished. UTC.
  final DateTime at;

  /// How long it took, settle included.
  final Duration took;

  /// How many nodes the measurement returned a verdict for.
  ///
  /// Zero with a null [failure] means an empty tree, which is a real and quiet
  /// answer. Zero with a [failure] means the sweep could not be taken at all —
  /// which is why the two are separate fields rather than one count a reader
  /// has to interpret.
  final int nodesSwept;

  /// One sentence saying what this sweep did and, when it was quiet, why.
  ///
  /// Never empty. Every construction path in `Watchdog` supplies one.
  final String why;

  /// The nodes that rang.
  final List<Ring> rang;

  /// The contradictions that did **not** ring because they are at the cap.
  final List<RingRuling> silenced;

  /// The nodes the measurement could not look at.
  ///
  /// Not rung, and not counted healthy. See [Blindness].
  final List<Blindness> blind;

  /// Node ids that contradicted before the settle and no longer did after it.
  ///
  /// These are the mid-write catches the settle exists for, and they are
  /// listed rather than dropped so that a settle doing nothing and a settle
  /// doing its job are told apart in the journal.
  final List<String> settledClear;

  /// Why the sweep could not be taken at all, when it could not.
  ///
  /// A sweep that threw is [nodesSwept] zero and rings nothing — a
  /// measurement that failed is not evidence about any node.
  final String? failure;

  /// Whether this sweep rang about anything.
  bool get quiet => rang.isEmpty;

  /// The sweep as one line of NDJSON.
  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'took_ms': took.inMilliseconds,
    'nodes_swept': nodesSwept,
    'why': why,
    'rang': [for (final ring in rang) ring.toJson()],
    'silenced': [
      for (final ruling in silenced)
        {
          'node_id': ruling.nodeId,
          'consecutive_rings': ruling.consecutiveRings,
          'why': ruling.why,
        },
    ],
    'blind': [
      for (final blindness in blind)
        {'node_id': blindness.nodeId, 'why': blindness.because},
    ],
    'settled_clear': settledClear,
    if (failure != null) 'failure': failure,
  };

  @override
  String toString() =>
      'SweepRecord(${at.toIso8601String()}, $nodesSwept nodes — $why)';
}

/// Where sweeps are written down.
///
/// An interface so P6-03 can put the same records somewhere a human sees them
/// without this leaf deciding what that surface is.
abstract interface class WatchdogJournal {
  /// Writes [sweep] down. Must not throw: a journal that cannot be written is
  /// a problem to report, never a reason to end the loop.
  Future<void> record(SweepRecord sweep);
}

/// The durable journal: one line of NDJSON per sweep, appended.
///
/// **A file rather than the event feed**, for two reasons that are about this
/// record specifically:
///
/// - A sweep is about the whole forest, and `SproutStore.append` attributes
///   every event to exactly one node. There is no honest node id to file a
///   tree-wide observation under.
/// - A sweep every interval, forever, would be the largest single producer in
///   a feed that Phase 2's `watch --since` replays to every consumer.
///
/// It carries a second signal for free: **the file's own mtime is the
/// watchdog's pulse.** A quiet journal whose mtime is minutes old says the
/// tree is quiet; a quiet journal whose mtime is hours old says the watchdog
/// itself stopped. That is the distinction §11 asks for, and it is readable
/// with `ls -l` by something that is not running any of this code.
final class FileWatchdogJournal implements WatchdogJournal {
  /// Appends to [path], creating it and its parent directory on first write.
  FileWatchdogJournal(this.path);

  /// The NDJSON file written to.
  final String path;

  /// What went wrong on the last failed write, or null.
  ///
  /// Surfaced rather than thrown, so a full disk degrades the record instead
  /// of ending the loop that is the only thing watching the tree.
  String? lastWriteError;

  @override
  Future<void> record(SweepRecord sweep) async {
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(sweep.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      lastWriteError = null;
    } on Object catch (error) {
      lastWriteError = 'could not append to $path: $error';
    }
  }
}

/// A journal that keeps the last [keep] sweeps in memory.
///
/// For tests, and for P6-03: the board needs the most recent sweeps without
/// re-reading a growing file. Pair it with a [FileWatchdogJournal] through
/// [FanOutJournal] rather than replacing one with the other — memory alone is
/// not durable, and a record that dies with the process cannot tell anyone the
/// process died.
final class MemoryWatchdogJournal implements WatchdogJournal {
  /// Keeps the most recent [keep] sweeps.
  MemoryWatchdogJournal({this.keep = 64}) : assert(keep > 0, 'keep at least 1');

  /// How many sweeps are retained.
  final int keep;

  final List<SweepRecord> _sweeps = [];

  /// The retained sweeps, oldest first.
  List<SweepRecord> get sweeps => List.unmodifiable(_sweeps);

  /// The most recent sweep, or null if none has been recorded.
  SweepRecord? get last => _sweeps.isEmpty ? null : _sweeps.last;

  @override
  Future<void> record(SweepRecord sweep) async {
    _sweeps.add(sweep);
    if (_sweeps.length > keep) _sweeps.removeRange(0, _sweeps.length - keep);
  }
}

/// Writes each sweep to several journals.
final class FanOutJournal implements WatchdogJournal {
  /// Records to each of [journals], in order.
  const FanOutJournal(this.journals);

  /// The journals written to.
  final List<WatchdogJournal> journals;

  @override
  Future<void> record(SweepRecord sweep) async {
    for (final journal in journals) {
      await journal.record(sweep);
    }
  }
}
