/// Turning what the socket actually delivers into whole [ProtocolFrame]s.
library;

import 'dart:convert';

import 'package:sprout_protocol/protocol.dart';

/// How large a chunk the daemon's encoder emits, in bytes.
///
/// Not a knob and not a guess: `dart:convert`'s `_Utf8Encoder` allocates
/// `_DEFAULT_BYTE_BUFFER_SIZE = 1024` (Dart SDK 3.13, `lib/convert/utf.dart`)
/// and flushes whenever it fills, so `utf8.encoder.bind(Stream<String>)` emits
/// 1024-byte chunks whatever the strings were. `revali_router`'s
/// `HandleWebSocket.sendResponse` hands each of those chunks to
/// `webSocket.add`, and `dart:io` sends one message per call. It is recorded
/// here so the fixture in `test/fixtures/` is legible: a capture in which no
/// message exceeds this number, and 63 of 112 are exactly it, is that
/// mechanism and not a coincidence.
const int daemonChunkBytes = 1024;

/// Thrown when the byte stream cannot be a sequence of frames at all.
///
/// Distinct from [ProtocolFormatException], which means one frame was
/// unreadable. This means the *framing* is wrong — a byte where an object
/// should start — and no amount of further buffering will fix it.
class WireFormatException implements Exception {
  /// Creates the error.
  const WireFormatException(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'WireFormatException: $message';
}

/// Reassembles the socket's byte stream into whole frames.
///
/// **One WebSocket message is not one frame, and assuming it is decodes
/// nothing.** Measured against the compiled daemon run from `/`: a 45-second
/// attach that saw a real `sprout run` delivered 112 messages, 63 of them
/// exactly [daemonChunkBytes] long and none longer, carrying 49 frames. Every
/// `delta` in that capture was over a kilobyte — the payload of a
/// `frame.assistant` event is a whole Claude Code frame — so a client that fed
/// each message to [ProtocolFrame.decodeLine] would have thrown on all 44 of
/// them and rendered the empty snapshot it opened with, forever.
///
/// `sproutd/test/ws_test.dart` reads one message as one frame and passes,
/// because every frame those tests produce is smaller than a chunk. The
/// assumption has simply never been tested against a real payload; see
/// `docs/02-open-findings.md`.
///
/// **There is no delimiter to split on.** The transport sends
/// `jsonEncode(frame)` with no trailing newline
/// (`routes/controllers/tree_controller.dart`), so the stream is JSON objects
/// concatenated end to end. This scans for the end of each one by tracking
/// brace depth outside string literals — at the *byte* level, which is exact
/// rather than approximate: `{`, `}`, `"` and `\` are ASCII, and every byte of
/// a multi-byte UTF-8 sequence has its high bit set, so a character can never
/// be mistaken for a delimiter. That also means a chunk boundary landing in
/// the middle of a character costs nothing, because nothing is decoded until a
/// whole object is in hand.
///
/// It never silently swallows. A byte that cannot begin an object throws
/// [WireFormatException] rather than being buffered until the end of time,
/// because a client that quietly accumulates forever looks exactly like a
/// quiet tree — which is INV8, the failure this whole protocol exists to
/// remove.
class FrameReader {
  final List<int> _buffer = [];

  /// Where the scan has reached inside [_buffer], so a chunk is never rescanned.
  int _scanned = 0;

  /// Brace depth of the object being assembled; 0 between objects.
  int _depth = 0;

  /// Whether the scan is inside a JSON string literal.
  bool _inString = false;

  /// Whether the previous byte was a backslash inside a string literal.
  bool _escaped = false;

  static const int _openBrace = 0x7B; // {
  static const int _closeBrace = 0x7D; // }
  static const int _quote = 0x22; // "
  static const int _backslash = 0x5C; // \
  static const int _space = 0x20;
  static const int _tab = 0x09;
  static const int _newline = 0x0A;
  static const int _carriageReturn = 0x0D;

  /// How many bytes of a frame have arrived without the frame being complete.
  ///
  /// Exposed so a consumer can say "a frame is in flight" rather than leaving
  /// a half-delivered snapshot indistinguishable from a stalled stream.
  int get pendingBytes => _buffer.length;

  /// Whether a frame is currently half-arrived.
  bool get isMidFrame => _depth > 0;

  /// Feeds one WebSocket message in and returns every frame it completed.
  ///
  /// Usually empty (a chunk in the middle of a large frame) or one element.
  /// A small frame that arrives in the same message as the tail of a large one
  /// would yield two, which is why the return is a list rather than a nullable
  /// frame.
  List<ProtocolFrame> add(List<int> chunk) {
    final frames = <ProtocolFrame>[];
    _buffer.addAll(chunk);
    while (_scanned < _buffer.length) {
      final byte = _buffer[_scanned];
      _scanned++;
      if (_depth == 0) {
        if (_isWhitespace(byte)) {
          // Skipped rather than rejected. The transport sends no delimiter
          // today; if it ever sends NDJSON properly this keeps working.
          _buffer.removeRange(0, _scanned);
          _scanned = 0;
          continue;
        }
        if (byte != _openBrace) {
          throw WireFormatException(
            'a frame must start with "{", not byte 0x'
            '${byte.toRadixString(16).padLeft(2, '0')}',
          );
        }
        _depth = 1;
        continue;
      }
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (byte == _backslash) {
          _escaped = true;
        } else if (byte == _quote) {
          _inString = false;
        }
        continue;
      }
      switch (byte) {
        case _quote:
          _inString = true;
        case _openBrace:
          _depth++;
        case _closeBrace:
          _depth--;
          if (_depth == 0) {
            frames.add(
              ProtocolFrame.decodeLine(
                utf8.decode(_buffer.sublist(0, _scanned)),
              ),
            );
            _buffer.removeRange(0, _scanned);
            _scanned = 0;
          }
      }
    }
    return frames;
  }

  static bool _isWhitespace(int byte) =>
      byte == _space ||
      byte == _newline ||
      byte == _carriageReturn ||
      byte == _tab;
}
