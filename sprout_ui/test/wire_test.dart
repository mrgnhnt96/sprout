/// What the socket actually delivers, and what it takes to read it.
///
/// Every byte here was captured off `ws://127.0.0.1/api/tree/events` from the
/// **compiled** daemon run from `/`, while the **compiled** CLI seeded the
/// database by replaying `docs/research/fixtures/phase0/streams/B.ndjson`
/// through a stand-in for `claude`. The capture client decoded nothing: it
/// wrote each message's bytes to `live_wire.bin` and each message's length to
/// `live_wire.sizes`, so the boundaries are the daemon's and not a test's.
library;

import 'dart:convert';

import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_ui/src/frame_reader.dart';
import 'package:test/test.dart';

import 'wire_fixture.dart';

void main() {
  group('the live capture', () {
    final wire = WireFixture.read('live_wire');

    test('is a real capture: 112 messages, none over a chunk', () {
      // The claim the rest of this file rests on, asserted rather than
      // described. A capture whose messages happened to be small would let the
      // reassembler pass without ever being needed.
      expect(wire.messages.length, 112);
      expect(wire.bytes.length, 86144);
      expect(wire.messages.map((m) => m.length).reduce(max), daemonChunkBytes);
      expect(
        wire.messages.where((m) => m.length == daemonChunkBytes).length,
        63,
        reason:
            'the daemon chops at exactly $daemonChunkBytes bytes because '
            "dart:convert's utf8 encoder flushes a 1024-byte buffer",
      );
    });

    test('ONE MESSAGE IS NOT ONE FRAME — that way loses 39 of 49', () {
      // The failure this reader exists to prevent, measured on the same bytes.
      //
      // A client that fed each WebSocket message to `ProtocolFrame.decodeLine`
      // — which is what `sproutd/test/ws_test.dart` does, and what the note on
      // `TreeController.events` says is safe — reads 10 of the 112 messages
      // and throws on the other 102. What survives is the small stuff: the
      // empty opening snapshot, `ready`, the three heartbeats, and the five
      // deltas that happened to fit in a chunk. **39 of the 49 frames are
      // lost, including every delta that carries a subagent.** The payload of
      // a `frame.assistant` event is a whole Claude Code frame, so a busy
      // node's deltas are exactly the ones over a kilobyte. The board would
      // show the empty tree it opened with, forever, looking healthy.
      var decoded = 0;
      var failed = 0;
      for (final message in wire.messages) {
        try {
          ProtocolFrame.decodeLine(utf8.decode(message, allowMalformed: true));
          decoded++;
        } on Object {
          failed++;
        }
      }
      expect(decoded, 10, reason: 'only the frames under a chunk survive');
      expect(failed, 102);
    });

    test('reassembled, it is 49 whole frames', () {
      final frames = wire.frames();
      expect(frames.length, 49);
      expect(frames.whereType<SnapshotFrame>().length, 1);
      expect(frames.whereType<ReadyFrame>().length, 1);
      expect(frames.whereType<HeartbeatFrame>().length, 3);
      expect(frames.whereType<DeltaFrame>().length, 44);
      expect(frames.whereType<ByeFrame>(), isEmpty);
    });

    test('and it does not matter where the chunks fall', () {
      // The message boundaries are one arbitrary split of a byte stream, so a
      // reader that only works on the daemon's split is a reader that works by
      // luck. Re-fed one byte at a time — every boundary, including inside a
      // string literal and inside a multi-byte character — it produces exactly
      // the same frames.
      final reader = FrameReader();
      final oneAtATime = <ProtocolFrame>[];
      for (final byte in wire.bytes) {
        oneAtATime.addAll(reader.add([byte]));
      }
      expect(
        oneAtATime.map((f) => f.encodeLine()),
        wire.frames().map((f) => f.encodeLine()),
      );
      expect(reader.pendingBytes, 0, reason: 'nothing left half-read');
      expect(reader.isMidFrame, isFalse);
    });

    test('the capture really contains multi-byte characters', () {
      // Without this the byte-boundary test above proves less than it looks
      // like it does: splitting ASCII at every byte cannot expose a UTF-8
      // boundary bug. `B.ndjson` carries em dashes and arrows through the
      // frames it replays.
      expect(wire.bytes.any((b) => b > 0x7F), isTrue);
    });
  });

  group('the reader refuses what it cannot frame', () {
    test('a byte that cannot start a frame throws rather than buffering', () {
      // Silence is the failure mode this whole project is about. A reader that
      // accumulated an unparseable stream forever would look exactly like a
      // tree in which nothing is happening.
      expect(
        () => FrameReader().add(utf8.encode('not json')),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a brace inside a string does not end a frame', () {
      final reader = FrameReader();
      final frames = reader.add(
        utf8.encode(
          '{"type":"bye","cursor":"s1.aaaaaaaaaaaaaaaa.1",'
          '"reason":"error","detail":"a } and a \\" inside a string"}',
        ),
      );
      expect(frames, hasLength(1));
      expect((frames.single as ByeFrame).detail, contains('} and a "'));
    });

    test(
      'whitespace between frames is skipped, so NDJSON would still work',
      () {
        // The transport sends no delimiter today. If it ever sends one — which
        // is what `docs/02-open-findings.md` recommends — this keeps reading.
        final reader = FrameReader();
        const line = '{"type":"ready","cursor":"s1.aaaaaaaaaaaaaaaa.1"}';
        expect(reader.add(utf8.encode('$line\n$line\n')), hasLength(2));
        expect(reader.pendingBytes, 0);
      },
    );

    test('a well-framed object that is not a frame still throws', () {
      // Framing and decoding are separate failures and must stay separate:
      // "the stream is not frames" and "this frame is from another build" have
      // different remedies.
      expect(
        () => FrameReader().add(utf8.encode('{"type":"nonsense"}')),
        throwsA(isA<ProtocolFormatException>()),
      );
    });
  });
}

/// The larger of two lengths. `dart:math` is not imported for one comparison.
int max(int a, int b) => a > b ? a : b;
