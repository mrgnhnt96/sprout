/// Reading a captured socket back exactly as the daemon sent it.
///
/// Two files per capture, and the second one is the point:
///
/// - `<name>.bin` — every byte, concatenated, in order.
/// - `<name>.sizes` — one WebSocket message length per line.
///
/// A fixture that stored only the bytes would let a reader be tested against
/// boundaries the daemon never produces. The daemon chops a frame at 1024
/// bytes and sends each piece as its own message — it still does, F-09 changed
/// only what is *between* the frames — so where the boundaries fall is the
/// whole hazard.
///
/// The captures were taken by a client that decoded nothing: it wrote what
/// arrived, from a daemon predating F-09's fix, so there is no delimiter
/// anywhere in these bytes. See `wire_test.dart` for why they are kept that
/// way. Reproducing one is five commands, in `sprout_ui/README.md`.
library;

import 'dart:io';

import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_ui/src/frame_reader.dart';

/// One captured attachment to `/api/tree/events`.
final class WireFixture {
  /// Holds the captured bytes and the boundaries they arrived on.
  WireFixture({required this.bytes, required this.messages});

  /// Loads `test/fixtures/<name>.bin` and `<name>.sizes`.
  ///
  /// Refuses a fixture whose two halves disagree rather than trusting either:
  /// a truncated `.bin` would otherwise produce fewer frames and pass most of
  /// what is asserted about it.
  factory WireFixture.read(String name) {
    final bytes = File('test/fixtures/$name.bin').readAsBytesSync();
    final sizes = File('test/fixtures/$name.sizes')
        .readAsLinesSync()
        .where((line) => line.isNotEmpty)
        .map(int.parse)
        .toList();
    final total = sizes.fold<int>(0, (sum, size) => sum + size);
    if (total != bytes.length) {
      // Thrown rather than asserted: this runs while tests are being declared,
      // where `expect` has no test to fail, and a fixture whose halves
      // disagree must stop the file rather than quietly shorten it.
      throw StateError(
        '$name.sizes adds up to $total but $name.bin is ${bytes.length} bytes',
      );
    }
    final messages = <List<int>>[];
    var at = 0;
    for (final size in sizes) {
      messages.add(bytes.sublist(at, at + size));
      at += size;
    }
    return WireFixture(bytes: bytes, messages: messages);
  }

  /// Every byte, in order.
  final List<int> bytes;

  /// The bytes split at the message boundaries the daemon actually used.
  final List<List<int>> messages;

  /// The frames, read the way the browser reads them.
  List<ProtocolFrame> frames() {
    final reader = FrameReader();
    final frames = <ProtocolFrame>[];
    for (final message in messages) {
      frames.addAll(reader.add(message));
    }
    if (reader.pendingBytes != 0) {
      throw StateError('the capture ends mid-frame, so it is truncated');
    }
    return frames;
  }
}
