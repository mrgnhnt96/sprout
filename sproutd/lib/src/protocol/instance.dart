import 'dart:convert';
import 'dart:math';

import '../../store.dart';
import 'cursor.dart';

/// The instance a cursor belongs to, as far as the wire is concerned.
///
/// The id exists for exactly one reason: so that a cursor handed to a consumer
/// can be checked against the producer it is later offered back to. A cursor
/// at seq 412 taken against a database that has since been replaced must be
/// **refused**, rather than silently resumed at a 412 that now means something
/// else.
///
/// **What is namespaced is the feed, not the process.** [SproutInstance.forFeed]
/// derives the id from the thing that actually owns the seq space — this event
/// feed, in this file — so that every process reading the same database agrees
/// without being told, and the CLI's `sprout snapshot` and the daemon's socket
/// join on one cursor. A per-process id cannot deliver that: `sprout snapshot`
/// and `sprout watch` are two processes, and the daemon is a third.
///
/// There is deliberately **no process-global instance**. sproutd carried one
/// (`SproutInstance.current`, generated per process) and it was the whole of
/// finding F-01: the daemon read it, the CLI could not, and every cursor a
/// user copied between the two surfaces was refused as foreign. A default that
/// is available is a default that gets used, so the field is gone rather than
/// documented as wrong — `takeSnapshot` and `watchFrames` now require an
/// instance instead of inventing one.
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

  /// The instance that owns the seq space of one event feed.
  ///
  /// **The one derivation in this package, called by every surface.** The CLI
  /// (`bin/sprout.dart`) and the daemon (`routes/controllers/tree_controller.dart`)
  /// both come here; forking a second hash that happens to agree today is the
  /// bug rather than the repair, because two derivations that must stay equal
  /// will drift.
  ///
  /// The id is a hash of [databasePath] — absolute, because a relative path
  /// would make the id depend on a process's working directory and two
  /// consumers of one database would then refuse each other's cursors —
  /// together with the identity of [firstEvent], the feed's *first* row. The
  /// feed is append-only, so that row never changes while the feed is the same
  /// feed, and it is a different row the moment the file is replaced. That is
  /// what keeps the property the instance id exists for: a database deleted
  /// and recreated at the same path is still correctly refused. Deriving the
  /// id from the path alone would lose exactly that.
  ///
  /// Pass `null` for [firstEvent] when the feed is empty. An empty feed
  /// fingerprints as empty and so **changes id once the first event lands** —
  /// a cursor taken from it is at position 0 and would have been safe to
  /// resume, so this errs toward a refusal, which names both ids and says to
  /// take a fresh snapshot, rather than toward a silent resume. That is the
  /// direction the protocol errs in everywhere else too. The consequence for a
  /// long-lived daemon is worth stating plainly: a client that attaches to an
  /// empty tree and reconnects after the first event is refused once. Which is
  /// also why callers derive this per call rather than caching it at startup —
  /// a cached id would leave the daemon disagreeing with the CLI for as long
  /// as the daemon happened to be up.
  factory SproutInstance.forFeed({
    required String databasePath,
    required SproutEvent? firstEvent,
  }) {
    final feed = firstEvent == null
        ? 'empty'
        : '${firstEvent.seq} ${firstEvent.ts.toUtc().toIso8601String()}'
              ' ${firstEvent.nodeId} ${firstEvent.kind}';
    return SproutInstance(_idFor('$databasePath $feed'));
  }

  /// Generates a fresh id.
  ///
  /// 64 bits from [Random.secure]. Not a security boundary — the id is public
  /// and appears in every frame — but a collision would silently accept a
  /// foreign cursor, which is the one outcome this whole type exists to
  /// prevent, so the cheap strong source is used rather than a timestamp or a
  /// pid. A pid in particular is reused by the OS within a day.
  ///
  /// This is **not** how a serving instance gets its id — that is
  /// [SproutInstance.forFeed], which every reader of the same feed can arrive
  /// at independently. A generated id is a namespace nobody else can compute,
  /// which is what a test wants when it needs a cursor that belongs to
  /// somebody else.
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

  /// The id that appears in every cursor this instance emits.
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

  /// A 16-lowercase-hex-character id for [text]: FNV-1a, 64 bits, big-endian.
  ///
  /// Written out rather than taken from `package:crypto`, which this package
  /// does not depend on and which only the leaf that owns `pubspec.yaml` may
  /// add. Not a security boundary — this class says as much, the id is public
  /// and rides in every frame — and the input is a path plus a row that
  /// already exists, so there is nothing here to be preimage-resistant about.
  static String _idFor(String text) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(text)) {
      hash = (hash ^ byte) * 0x100000001b3;
    }
    final high = (hash >> 32) & 0xffffffff;
    final low = hash & 0xffffffff;
    return high.toRadixString(16).padLeft(8, '0') +
        low.toRadixString(16).padLeft(8, '0');
  }

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
