import 'dart:convert';

import 'frame.dart';

/// Turns the NDJSON of `claude -p --output-format stream-json` into typed
/// frames.
///
/// Incremental by design: feed it whatever arrives, in whatever sized pieces,
/// and it holds a partial line until the newline that completes it. Call
/// [finish] when the pipe closes to flush whatever is left.
///
/// Three promises, in the order they matter:
///
/// - **It never throws on input.** Malformed lines become [MalformedFrame] and
///   unrecognised types become [UnknownFrame]; both keep their payload. The
///   stream is an unstable API (INV10) and the daemon that watches from outside
///   the session cannot be the thing that dies first.
/// - **It deduplicates by frame `uuid`.** Unique across all 344 frames of the
///   six phase-0 captures. A frame with no `uuid` is passed through rather than
///   dropped, and counted in [framesWithoutUuid], because a silent drop is the
///   failure INV8 warns about.
/// - **It is a pure function over bytes.** No process, no clock, no filesystem.
class StreamParser {
  /// Creates a parser with an empty dedupe set and an empty line buffer.
  StreamParser();

  final Set<String> _seenUuids = {};
  final StringBuffer _pending = StringBuffer();
  int _duplicatesDropped = 0;
  int _framesWithoutUuid = 0;

  /// Frames dropped because their `uuid` had already been seen.
  int get duplicatesDropped => _duplicatesDropped;

  /// Frames emitted despite carrying no `uuid`, and so not deduplicable.
  ///
  /// Zero across every phase-0 capture. A non-zero value means the envelope
  /// changed and dedupe is now partial — worth surfacing rather than inferring
  /// from a count that quietly stopped rising.
  int get framesWithoutUuid => _framesWithoutUuid;

  /// Whether a partial line is buffered, waiting for its newline.
  bool get hasPendingLine => _pending.isNotEmpty;

  /// Feeds [chunk], returning every frame it completed.
  ///
  /// A chunk may end mid-line, mid-token or mid-character-sequence; whatever is
  /// left over is held for the next call.
  List<StreamFrame> addChunk(String chunk) {
    final frames = <StreamFrame>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk.codeUnitAt(i) != 0x0a) continue;
      _pending.write(chunk.substring(start, i));
      start = i + 1;
      final frame = _consumePending();
      if (frame != null) frames.add(frame);
    }
    _pending.write(chunk.substring(start));
    return frames;
  }

  /// Flushes a trailing line that never got its newline.
  ///
  /// This is the killed-mid-write case: `claude` died with half a frame in the
  /// pipe, so the last line is truncated. It comes back as a [MalformedFrame]
  /// and every frame before it stands — the run's history is not invalidated by
  /// how it ended. Returns an empty list when the stream ended cleanly.
  List<StreamFrame> finish() {
    final frame = _consumePending();
    return frame == null ? const [] : [frame];
  }

  /// Parses a complete NDJSON document in one call.
  ///
  /// Equivalent to [addChunk] followed by [finish], and subject to the same
  /// dedupe set, so calling it twice on the same document yields nothing the
  /// second time.
  List<StreamFrame> parseAll(String ndjson) => [
    ...addChunk(ndjson),
    ...finish(),
  ];

  /// Parses one whole line, returning null for a blank line or a duplicate.
  ///
  /// Exposed for callers that already have line boundaries. It shares the
  /// dedupe set with [addChunk].
  StreamFrame? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      return MalformedFrame(line, error);
    }
    if (decoded is! Map<String, Object?>) {
      return MalformedFrame(
        line,
        'expected a JSON object, got ${decoded.runtimeType}',
      );
    }

    final frame = StreamFrame.fromJson(decoded);
    final uuid = frame.uuid;
    if (uuid == null) {
      _framesWithoutUuid++;
      return frame;
    }
    if (!_seenUuids.add(uuid)) {
      _duplicatesDropped++;
      return null;
    }
    return frame;
  }

  StreamFrame? _consumePending() {
    if (_pending.isEmpty) return null;
    final line = _pending.toString();
    _pending.clear();
    return parseLine(line);
  }
}

/// Parses a whole NDJSON document with a fresh parser.
///
/// The convenience form for a file on disk. Live streams want a [StreamParser]
/// of their own so the dedupe set outlives one chunk.
List<StreamFrame> parseStreamJson(String ndjson) =>
    StreamParser().parseAll(ndjson);
