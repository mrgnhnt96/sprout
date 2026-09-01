/// The on-disk copy of a session's stream, written before anything reads it.
library;

import 'dart:io';

/// An append-only file of exactly the bytes a process wrote.
///
/// One per session, and the ground truth for it: the store holds what the
/// parser *understood*, and the first time the parser is wrong this file is
/// the only record of what the CLI actually said. So it is written with the
/// raw bytes, before they are decoded, before they are parsed, and before the
/// store sees them — a frame the projection mishandles is still here in full.
///
/// Writes are synchronous and unbuffered. Each chunk is in the kernel before
/// the call returns, so `tail -f` on the file sees the run as it happens and a
/// crash of sprout itself loses nothing already received. There is no fsync:
/// the failure this guards against is sprout dying, not the machine.
final class RawLog {
  RawLog._(this.path, this._file);

  /// Creates (or truncates) the file at [path] and opens it for writing.
  factory RawLog.open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return RawLog._(path, file.openSync(mode: FileMode.writeOnly));
  }

  /// Where the log lives.
  final String path;

  final RandomAccessFile _file;
  int _bytesWritten = 0;
  bool _closed = false;

  /// How many bytes have been written so far.
  int get bytesWritten => _bytesWritten;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Appends [bytes] verbatim.
  void write(List<int> bytes) {
    if (_closed) throw StateError('raw log at $path is closed');
    _file.writeFromSync(bytes);
    _bytesWritten += bytes.length;
  }

  /// Releases the file handle. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _file.closeSync();
  }
}
