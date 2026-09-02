/// When the node's raw transcript was last written.
library;

import 'dart:io';

/// What a look at one transcript file found.
///
/// Missing and unreadable are separate for the same reason [ProcessGone] and
/// [ProcessUnreadable] are: a `stat` that failed is not a fact about the file.
sealed class TranscriptLook {
  const TranscriptLook();
}

/// The transcript exists and was last modified at [modifiedAt].
final class TranscriptWritten extends TranscriptLook {
  /// Records a transcript's mtime.
  const TranscriptWritten({required this.path, required this.modifiedAt});

  /// The file looked at.
  final String path;

  /// Its mtime, in UTC.
  final DateTime modifiedAt;

  @override
  String toString() => 'TranscriptWritten($path, $modifiedAt)';
}

/// The transcript is not there yet.
///
/// Normal for a few hundred milliseconds after a spawn, and normal forever for
/// a node that was refused before a process existed. The caller falls back to
/// the node's spawn time as the freshness reference rather than treating an
/// absent file as a frozen one.
final class TranscriptAbsent extends TranscriptLook {
  /// Records an absent transcript.
  const TranscriptAbsent(this.path);

  /// The file looked for.
  final String path;

  @override
  String toString() => 'TranscriptAbsent($path)';
}

/// The look failed. Not evidence that the file is absent or frozen.
final class TranscriptUnreadable extends TranscriptLook {
  /// Records a failed look and why.
  const TranscriptUnreadable(this.path, this.why);

  /// The file looked at.
  final String path;

  /// What went wrong.
  final String why;

  @override
  String toString() => 'TranscriptUnreadable($path, $why)';
}

/// Answers "when was this transcript last written?".
abstract interface class TranscriptIndex {
  /// Stats [path].
  Future<TranscriptLook> lastWrite(String path);
}

/// The real index: `FileStat` on the raw NDJSON log.
///
/// **The raw log, never the store.** `SessionRunner` writes every stream chunk
/// to `<logDirectory>/<nodeId>.ndjson` before it touches SQLite
/// (`session_runner.dart` `_pump`), so this file's mtime is the session's own
/// pulse. The store's mtime would only prove that *sprout* is alive, which is
/// the thing a watcher outside the session must not confuse with the session
/// working.
final class FileTranscripts implements TranscriptIndex {
  /// Creates the index.
  const FileTranscripts();

  @override
  Future<TranscriptLook> lastWrite(String path) async {
    final FileStat stat;
    try {
      stat = await FileStat.stat(path);
    } on Object catch (error) {
      return TranscriptUnreadable(path, 'could not stat: $error');
    }
    // `FileStat.stat` does not throw on a missing path; it reports notFound
    // with an epoch mtime. Returning that mtime would read as a transcript
    // frozen since 1970 — the exact shape of a failed read laundered into a
    // verdict.
    if (stat.type == FileSystemEntityType.notFound) {
      return TranscriptAbsent(path);
    }
    return TranscriptWritten(path: path, modifiedAt: stat.modified.toUtc());
  }
}
