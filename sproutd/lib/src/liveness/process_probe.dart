/// Is this pid alive, and *when did its process actually start?*
library;

import 'dart:io';

/// What a look at one pid found.
///
/// Three cases rather than a nullable answer, because "no such process" and
/// "I could not run `ps`" must never share a consequence. A probe that folds
/// the second into the first reports every node abandoned the moment `ps`
/// goes missing, which is the shape of a watchdog that pages about a healthy
/// tree.
sealed class ProcessLook {
  const ProcessLook();
}

/// A process with this pid exists, and started at [startedAt].
final class ProcessRunning extends ProcessLook {
  /// Records a live process.
  const ProcessRunning({required this.pid, required this.startedAt});

  /// The pid asked about.
  final int pid;

  /// When the process was created, in UTC.
  ///
  /// **Second resolution, and no finer.** macOS `ps -o lstart=` prints
  /// `Wed Sep  2 14:09:09 2026` — verified by running it, not read off a man
  /// page. A start time inside the same second as the node's spawn therefore
  /// cannot be ordered against it, which is why `startTimeTolerance` in
  /// `measure.dart` exists instead of a strict comparison.
  final DateTime startedAt;

  @override
  String toString() => 'ProcessRunning($pid, started $startedAt)';
}

/// No process holds this pid.
final class ProcessGone extends ProcessLook {
  /// Records an absent process.
  const ProcessGone(this.pid);

  /// The pid asked about.
  final int pid;

  @override
  String toString() => 'ProcessGone($pid)';
}

/// The look failed. This is **not** evidence that the process is gone.
final class ProcessUnreadable extends ProcessLook {
  /// Records a failed look and why it failed.
  const ProcessUnreadable(this.pid, this.why);

  /// The pid asked about.
  final int pid;

  /// What went wrong, in words that can be put in front of a human.
  final String why;

  @override
  String toString() => 'ProcessUnreadable($pid, $why)';
}

/// Answers [inspect] for a pid. Faked in tests that must not spawn.
///
/// The demonstrable tests for this leaf drive [PsProcessProbe] against real
/// processes; this interface exists so a unit test can also drive an
/// impossible start time, not so the suite can avoid ever running `ps`.
abstract interface class ProcessProbe {
  /// Looks up [pid].
  Future<ProcessLook> inspect(int pid);
}

/// The real probe: `ps -o lstart= -p <pid>`.
///
/// `ps` rather than `kill -0` because a live pid is not the question. Pids are
/// reused by the OS within a day, so `docs/01-plan.md` §11 requires
/// "newest-wins with a **start-time-verified** pid": the start time is the only
/// thing that distinguishes our process from a later one wearing its number.
///
/// `LC_ALL=C` is set on the child so the month name and field order are the
/// ones this parser was written against, whatever the developer's locale is.
final class PsProcessProbe implements ProcessProbe {
  /// Creates a probe. [executable] exists so a test can point at a stub.
  const PsProcessProbe({this.executable = 'ps'});

  /// The `ps` to run.
  final String executable;

  @override
  Future<ProcessLook> inspect(int pid) async {
    if (pid <= 0) {
      return ProcessUnreadable(pid, 'pid $pid is not a process id');
    }
    final ProcessResult result;
    try {
      result = await Process.run(
        executable,
        ['-o', 'lstart=', '-p', '$pid'],
        environment: const {'LC_ALL': 'C'},
      );
    } on Object catch (error) {
      return ProcessUnreadable(pid, 'could not run $executable: $error');
    }

    final out = (result.stdout as String).trim();
    final err = (result.stderr as String).trim();

    if (result.exitCode != 0) {
      // `ps` exits 1 both for "no such process" and for a usage error. The
      // first is silent on both streams; the second says something on stderr.
      // Guessing between them is exactly the confusion this class refuses, so
      // anything that spoke is unreadable rather than gone.
      if (out.isEmpty && err.isEmpty) return ProcessGone(pid);
      return ProcessUnreadable(
        pid,
        '$executable exited ${result.exitCode}: ${err.isEmpty ? out : err}',
      );
    }
    if (out.isEmpty) {
      return ProcessUnreadable(pid, '$executable exited 0 but printed nothing');
    }

    final started = parseLstart(out);
    if (started == null) {
      return ProcessUnreadable(pid, 'could not parse an lstart from "$out"');
    }
    return ProcessRunning(pid: pid, startedAt: started);
  }

  /// Parses one `lstart` field — `Wed Sep  2 14:09:09 2026` — to UTC.
  ///
  /// `ps` prints **local** time with no offset, so the value is built as a
  /// local `DateTime` and then converted. Returns null rather than throwing on
  /// anything it does not recognise: the caller turns that into
  /// [ProcessUnreadable], and a parse failure must not be able to end a
  /// watchdog sweep.
  ///
  /// Stated limit: during a daylight-saving fall-back the printed hour is
  /// ambiguous and this resolves it however `DateTime` does. One hour a year,
  /// and the consequence is a start time an hour out — which shows up against
  /// the start-time tolerance rather than passing silently.
  static DateTime? parseLstart(String text) {
    final match = _lstart.firstMatch(text.trim());
    if (match == null) return null;
    final month = _months[match.group(1)!];
    if (month == null) return null;
    return DateTime(
      int.parse(match.group(6)!),
      month,
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
    ).toUtc();
  }

  static final RegExp _lstart = RegExp(
    r'^[A-Za-z]{3} +([A-Za-z]{3}) +(\d{1,2}) +'
    r'(\d{1,2}):(\d{2}):(\d{2}) +(\d{4})$',
  );

  static const Map<String, int> _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
}
