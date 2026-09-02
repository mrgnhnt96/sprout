/// The on-disk copy of every hook payload, written before the projection runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The file name the hook raw log takes when it sits beside the database.
///
/// Beside the store on purpose, next to `watchdog.ndjson`: one directory holds
/// everything a machine-wide sprout leaves behind, so `ls -l ~/.sprout` shows
/// whether hooks are arriving at all without anyone knowing this constant.
const String hookRawLogName = 'hooks.raw';

/// The marker every frame header starts with.
const String hookRawLogFrameMarker = 'sprout-hook';

/// The path of the raw log that belongs beside the database at [databasePath].
String hookRawLogPathFor(String databasePath) =>
    p.join(p.dirname(p.absolute(databasePath)), hookRawLogName);

/// Appends the bytes a hook was handed, verbatim, to the log at [path].
///
/// **This is the repair F-15 named first, and the order of operations is the
/// whole point.** (F-15 is closed by the commit that added this file; what it
/// did not cover is F-18.)
/// `HookProjection.observe` returns null and stores nothing for a record with
/// no `session_id` — every `MalformedHookPayload`, since input that is not JSON
/// has no fields at all — because `event.node_id` is `NOT NULL` with a foreign
/// key and there is no node such a record belongs to. Before this file, those
/// bytes were gone the instant the hook process exited. Now they are on disk
/// first, so a payload the store cannot take is a recovery problem rather than
/// an amnesia problem.
///
/// It is the same discipline `RawLog` gives the runner path — *the store is a
/// view of the run; the raw log is the run* — and the same reason it is written
/// **before** anything parses: a payload that makes the parser or the
/// projection throw is still here in full, and it is the only record of what
/// the CLI actually sent.
///
/// A sibling of `RawLog` rather than a use of it, for one structural reason:
/// `RawLog.open` truncates (`FileMode.writeOnly`) because it owns a session's
/// file for that session's lifetime. A hook is **one OS process per event**, so
/// this must append to a file other processes are also appending to, and it
/// must survive the file not existing yet on a cold machine.
///
/// ## The frame, and why it is not bare bytes
///
/// ```
/// sprout-hook <iso8601 utc> <byte count>
/// <exactly those bytes>
/// ```
///
/// The header exists because the record boundary cannot come from the content.
/// What arrives here is whatever was on a pipe: compact JSON in every one of
/// the 37 Phase 0 captures, but the failures this log exists for are precisely
/// the inputs that are not that — a truncated write, a pretty-printed payload,
/// a process that printed a stack trace. A newline-delimited log would frame
/// those wrong, and framing the malformed record wrong loses the one thing
/// worth keeping. The byte count makes every frame recoverable whatever is
/// inside it, and the bytes themselves are still written untouched.
///
/// ## Concurrency, which is measured rather than assumed
///
/// Several hook processes append here at once — a session running subagents in
/// parallel fires tool events from every node — and two things that look like
/// they handle that do not:
///
/// - **`lockSync()` does not wait.** Its default is `FileLock.exclusive`, which
///   is non-blocking: probed with twelve concurrent processes on macOS it threw
///   `FileSystemException: lock failed … errno = 35` in three of them. Only
///   `FileLock.blockingExclusive` waits.
/// - **`FileMode.writeOnlyAppend` does not append at write time.** The position
///   is fixed when the file is opened, not recomputed per write, so processes
///   that opened before an earlier one finished all write at the same offset
///   and overwrite each other. The same probe lost four of sixteen records
///   *with no error anywhere* — the worst shape a log can fail in. The seek to
///   the current length, taken inside the lock, is what makes the append real.
///
/// With both, sixteen concurrent processes wrote sixteen records in each of
/// three runs. The frame is also assembled and written in **one** call rather
/// than three, so nothing depends on writes not interleaving.
///
/// ## Failure is silent by design
///
/// Returns whether the append happened. It never throws: a hook process that
/// died because its log directory was read-only would break the session it was
/// observing, which is worse than losing the record. The caller reports the
/// miss on stderr and carries on to the projection — losing the durable copy
/// is not a reason to also lose the stored event.
bool appendHookRawLog(String path, List<int> bytes, {DateTime? ts}) {
  try {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final stamp = (ts ?? DateTime.now()).toUtc().toIso8601String();
    final frame = <int>[
      ...utf8.encode('$hookRawLogFrameMarker $stamp ${bytes.length}\n'),
      ...bytes,
      0x0a,
    ];
    final handle = file.openSync(mode: FileMode.writeOnlyAppend);
    try {
      handle.lockSync(FileLock.blockingExclusive);
      try {
        handle.setPositionSync(handle.lengthSync());
        handle.writeFromSync(frame);
        handle.flushSync();
      } finally {
        handle.unlockSync();
      }
    } finally {
      handle.closeSync();
    }
    return true;
  } on Object {
    // Deliberately every error, including the ones that are not IOException:
    // a path that is a directory, a permission failure, a full disk. See the
    // doc comment — this call site is inside a developer's own session.
    return false;
  }
}
