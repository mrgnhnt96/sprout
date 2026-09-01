import 'dart:math';

import 'cursor.dart';

/// One running sproutd process, as far as the wire is concerned.
///
/// The id is generated at process start and never changes while that process
/// lives. It exists for exactly one reason: so that a cursor handed to a
/// consumer can be checked against the daemon that is asked to resume from it.
/// A restarted daemon is a *different* instance even against the same database
/// file, which is the honest answer — the file may have been replaced, and a
/// seq that survives is not something sproutd can verify from outside.
///
/// [current] is what `snapshot` and `watch` both read, so the two agree
/// without either being told: the id has to be one fact per process, and a
/// value passed down two call paths is two facts that can drift.
class SproutInstance {
  /// Wraps an id that already exists — the seam the tests use.
  ///
  /// Throws [ArgumentError] on anything that is not a well-formed id, so an
  /// instance can never hand out a cursor it would later refuse to parse.
  SproutInstance(this.id) {
    if (!Cursor.isWellFormedInstanceId(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'must be ${Cursor.instanceIdLength} lowercase hex characters',
      );
    }
  }

  /// Generates a fresh id.
  ///
  /// 64 bits from [Random.secure]. Not a security boundary — the id is public
  /// and appears in every frame — but a collision would silently accept a
  /// foreign cursor, which is the one outcome this whole type exists to
  /// prevent, so the cheap strong source is used rather than a timestamp or a
  /// pid. A pid in particular is reused by the OS within a day.
  factory SproutInstance.generate() {
    final random = Random.secure();
    final buffer = StringBuffer();
    while (buffer.length < Cursor.instanceIdLength) {
      buffer.write(random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'));
    }
    return SproutInstance(
      buffer.toString().substring(0, Cursor.instanceIdLength),
    );
  }

  /// This process's instance, generated on first use and stable thereafter.
  static SproutInstance get current => _current ??= SproutInstance.generate();

  static SproutInstance? _current;

  /// The id that appears in every cursor this process emits.
  final String id;

  /// A cursor at [position] in this instance's feed.
  Cursor cursorAt(int position) => Cursor(instanceId: id, position: position);

  /// Decides what to do with a `--since` value a consumer handed back.
  ///
  /// Returns one of three outcomes and never conflates them: [CursorAccepted],
  /// [CursorFromAnotherInstance] — well formed, wrong daemon, refusable with
  /// both ids named — and [CursorMalformed]. The middle case is why a cursor
  /// carries an instance at all: without it, a consumer reconnecting to a
  /// restarted sproutd is resumed at a seq that now means something else, and
  /// nothing anywhere reports a problem.
  CursorParse accept(String text) {
    final cursor = Cursor.tryParse(text);
    if (cursor == null) {
      return CursorMalformed(text: text, detail: _malformedDetail(text));
    }
    if (cursor.instanceId != id) {
      return CursorFromAnotherInstance(
        text: text,
        offered: cursor,
        expectedInstanceId: id,
      );
    }
    return CursorAccepted(cursor);
  }

  @override
  String toString() => 'SproutInstance($id)';

  /// Names the first thing wrong with [text], so the message is about the
  /// value rather than about the concept.
  static String _malformedDetail(String text) {
    if (text.isEmpty) return 'empty';
    final parts = text.split('.');
    if (parts.length != 3) {
      return 'expected ${Cursor.version}.<instance>.<seq>, got '
          '${parts.length} dot-separated ${parts.length == 1 ? "part" : "parts"}';
    }
    if (parts[0] != Cursor.version) {
      return 'unknown cursor version "${parts[0]}", this build speaks '
          '${Cursor.version}';
    }
    if (!Cursor.isWellFormedInstanceId(parts[1])) {
      return 'instance id "${parts[1]}" is not '
          '${Cursor.instanceIdLength} lowercase hex characters';
    }
    return 'position "${parts[2]}" is not a non-negative integer';
  }
}
