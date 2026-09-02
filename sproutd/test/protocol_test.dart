import 'dart:convert';

import 'package:sproutd/protocol.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:test/test.dart';

/// A well-formed instance id that is not the one under test.
const String otherInstanceId = 'ffffffffffffffff';

/// An event with the fields filled in, so each test states only what it is
/// about. Pure values: nothing here opens a database.
SproutEvent anEvent(int seq, {String kind = 'spawned'}) => SproutEvent(
  seq: seq,
  nodeId: 'node-$seq',
  ts: DateTime.utc(2026, 3, 4, 5, 6, 7),
  kind: kind,
  payload: {'depth': seq, 'note': 'e$seq'},
);

/// A snapshot with one node, one held resource and a readable feed.
///
/// Assembled directly rather than through `takeSnapshot`, because this file
/// tests the protocol and `takeSnapshot` reads a store. Pure values, as the
/// library doc promises: nothing here opens a database or asks the clock.
SproutSnapshot aSnapshot(
  Cursor cursor, {
  String? journalUnreadable,
  SubtreeSpend? spend,
}) => SproutSnapshot(
  cursor: cursor,
  takenAt: DateTime.utc(2026, 3, 4, 5, 6, 7),
  journalUnreadable: journalUnreadable,
  nodes: [
    SnapshotNode(
      node: SproutNode(
        id: 'root',
        project: '/tmp/p',
        status: NodeStatus.working,
        role: 'crawler',
        currentTask: 'building the thing',
        since: DateTime.utc(2026, 3, 4, 4, 54),
        nextCheckin: DateTime.utc(2026, 3, 4, 5, 21),
      ),
      depth: 0,
      ownCostUsd: 0.2415507,
      spend:
          spend ??
          const SubtreeSpend(knownMicroUsd: 241551, nodes: 3, unknownNodes: 2),
    ),
  ],
  resources: [HeldResource(name: '/tmp/p', holder: 'root')],
);

/// Encodes [frame] to one NDJSON line and reads it back.
ProtocolFrame roundTrip(ProtocolFrame frame) =>
    ProtocolFrame.decodeLine(frame.encodeLine());

void main() {
  late SproutInstance instance;

  setUp(() => instance = SproutInstance('0123456789abcdef'));

  group('instance id', () {
    test('two generated ids differ', () {
      // `generate` is what a test uses when it wants a namespace nobody else
      // can compute. If it returned a constant, the cursor's whole namespace
      // would be one value machine-wide and every foreign cursor would be
      // accepted.
      final ids = {for (var i = 0; i < 32; i++) SproutInstance.generate().id};
      expect(ids, hasLength(32));
      expect(ids.every(Cursor.isWellFormedInstanceId), isTrue);
    });

    test('derived from a feed, the same feed gives the same id', () {
      // This is finding F-01 stated as an assertion at the derivation itself.
      // The CLI and the daemon are different processes; they agree only
      // because two independent calls with the same inputs land on the same
      // id. `ws_test.dart` asserts the same property across the two real
      // surfaces; here it is the derivation alone.
      final first = anEvent(1);
      final id = SproutInstance.forFeed(
        databasePath: '/tmp/sprout.db',
        firstEvent: first,
      ).id;

      expect(
        SproutInstance.forFeed(
          databasePath: '/tmp/sprout.db',
          firstEvent: anEvent(1),
        ).id,
        id,
        reason:
            'a second process reading the same feed must derive the same '
            'id, or a cursor cannot cross between them',
      );
      expect(Cursor.isWellFormedInstanceId(id), isTrue);
    });

    test('the derivation is pinned, not merely self-consistent', () {
      // The pair the two tests around this one cannot be: both of those ask
      // whether the derivation agrees WITH ITSELF, and a hash that computed
      // something different on another platform would satisfy every one of
      // them from inside that platform.
      //
      // This matters now because `SproutInstance` is compiled twice. It moved
      // into `package:sprout_protocol` so the browser could decode the same
      // frames sproutd emits (finding F-07), and Dart's `int` is 64-bit on the
      // VM and a JavaScript double on the web. The FNV-1a offset basis alone
      // does not survive that — `0xcbf29ce484222325` is a compile error under
      // dart2js — and the wrapping multiply would disagree silently even if it
      // did. `_idFor` therefore uses BigInt, which is exact on both.
      //
      // A browser deriving a DIFFERENT id from the same feed would have every
      // cursor it offered refused as foreign: finding F-01's failure arriving
      // by a new road. This value is what the pre-split native-int
      // implementation computed for this input, so the split is asserted to
      // have changed nothing.
      expect(
        SproutInstance.forFeed(
          databasePath: '/tmp/sprout.db',
          firstEvent: SproutEvent(
            seq: 1,
            nodeId: 'node-a',
            ts: DateTime.utc(2026, 1, 2, 3, 4, 5),
            kind: 'spawned',
            payload: const {},
          ),
        ).id,
        _pinnedFeedId,
        reason:
            'the instance id derivation changed. Every cursor already in a '
            "consumer's hands is now refused as foreign",
      );
    });

    test('and changes when the feed or the file does', () {
      // The pair (INV8). "Agrees" is worthless without this: an id that were
      // constant would also agree, and would then accept a cursor at seq 412
      // taken against a database that has since been replaced.
      final id = SproutInstance.forFeed(
        databasePath: '/tmp/sprout.db',
        firstEvent: anEvent(1),
      ).id;

      // A different file at the same instant.
      expect(
        SproutInstance.forFeed(
          databasePath: '/tmp/other.db',
          firstEvent: anEvent(1),
        ).id,
        isNot(id),
      );
      // The same path, but the feed's first row is a different row — which is
      // what a database deleted and recreated at that path looks like.
      expect(
        SproutInstance.forFeed(
          databasePath: '/tmp/sprout.db',
          firstEvent: anEvent(1, kind: 'runner.spawned'),
        ).id,
        isNot(id),
      );
      // And an empty feed is its own fingerprint, so the id changes once the
      // first event lands. A cursor from an empty feed is at position 0 and
      // would have been safe to resume; this errs toward the refusal, which
      // names both ids, rather than toward a silent resume.
      expect(
        SproutInstance.forFeed(
          databasePath: '/tmp/sprout.db',
          firstEvent: null,
        ).id,
        isNot(id),
      );
    });

    test('refuses an id that is not a well-formed instance id', () {
      expect(() => SproutInstance('nope'), throwsArgumentError);
      expect(() => SproutInstance('0123456789ABCDEF'), throwsArgumentError);
      // Paired positive, through the same constructor.
      expect(SproutInstance('0123456789abcdef').id, '0123456789abcdef');
    });
  });

  group('cursor', () {
    test('round-trips through its encoded form', () {
      for (final position in [0, 1, 42, 9007199254740991]) {
        final cursor = instance.cursorAt(position);
        expect(Cursor.parse(cursor.encode()), cursor);
        expect(Cursor.parse(cursor.encode()).position, position);
        expect(Cursor.parse(cursor.encode()).instanceId, instance.id);
      }
    });

    test('is one token with nothing a shell or an argv would eat', () {
      final encoded = instance.cursorAt(7).encode();
      expect(encoded, 's1.0123456789abcdef.7');
      expect(encoded.split(' '), hasLength(1));
      expect(RegExp(r'^[0-9a-z.]+$').hasMatch(encoded), isTrue);
    });

    test('refuses a negative position rather than clamping it', () {
      expect(() => instance.cursorAt(-1), throwsArgumentError);
      // The pair: 0 is a real position — "before the first event" — and must
      // not be swept up by the same check.
      expect(instance.cursorAt(0).position, 0);
    });
  });

  group('--since', () {
    test('accepts a cursor this instance issued', () {
      final result = instance.accept(instance.cursorAt(412).encode());
      expect(result, isA<CursorAccepted>());
      expect((result as CursorAccepted).cursor.position, 412);
    });

    test('refuses a cursor from another instance, and names both ids', () {
      final foreign = Cursor(instanceId: otherInstanceId, position: 412);
      final result = instance.accept(foreign.encode());

      // Refused — not accepted. This is the case the instance namespace
      // exists for: a consumer reconnecting to a RESTARTED sproutd holds a
      // seq that now means something else, and 412 parses perfectly.
      expect(result, isA<CursorFromAnotherInstance>());
      final refusal = result as CursorFromAnotherInstance;
      expect(refusal.offeredInstanceId, otherInstanceId);
      expect(refusal.expectedInstanceId, instance.id);

      // And it SAYS so. A refusal that does not name both daemons leaves the
      // consumer unable to tell "your cursor is corrupt" from "you are talking
      // to a different sproutd", which have different remedies.
      expect(refusal.reason, contains(otherInstanceId));
      expect(refusal.reason, contains(instance.id));

      // The paired positive, through the same call: the identical position
      // from THIS instance is accepted, so the refusal is about the instance
      // id and not about 412.
      expect(
        instance.accept(instance.cursorAt(412).encode()),
        isA<CursorAccepted>(),
      );
    });

    test('refuses a malformed cursor DIFFERENTLY from a foreign one', () {
      final malformed = instance.accept('not-a-cursor');
      final foreign = instance.accept(
        Cursor(instanceId: otherInstanceId, position: 1).encode(),
      );

      // Both refuse — that much they share, and a caller may treat them alike
      // only insofar as neither resumes.
      expect(malformed, isA<CursorRefused>());
      expect(foreign, isA<CursorRefused>());

      // But they are distinguishable by type and by what they say. Conflating
      // them tells a consumer with a perfectly good cursor that its cursor is
      // garbage, and it will keep offering it.
      expect(malformed, isA<CursorMalformed>());
      expect(malformed, isNot(isA<CursorFromAnotherInstance>()));
      expect(foreign, isNot(isA<CursorMalformed>()));
      expect(
        (malformed as CursorRefused).reason,
        isNot((foreign as CursorRefused).reason),
      );
      expect(malformed.reason, isNot(contains(otherInstanceId)));
    });

    test('names what is wrong with each shape of malformed value', () {
      String reasonFor(String text) =>
          (instance.accept(text) as CursorMalformed).detail;

      expect(reasonFor(''), 'empty');
      expect(reasonFor('s1.0123456789abcdef'), contains('parts'));
      expect(reasonFor('s2.0123456789abcdef.1'), contains('version'));
      expect(reasonFor('s1.zzz.1'), contains('instance id'));
      expect(reasonFor('s1.0123456789abcdef.-1'), contains('position'));
      expect(reasonFor('s1.0123456789abcdef.x'), contains('position'));

      // The pair: every string above differs from the accepted one in exactly
      // the field its message names, and the accepted one is not refused.
      expect(instance.accept('s1.0123456789abcdef.1'), isA<CursorAccepted>());
    });
  });

  group('frames', () {
    test('snapshot round-trips, whole, through the one decoder', () {
      // F-04: the frame the socket *opens with* is decoded by
      // `ProtocolFrame.decodeLine` like every other line, and no consumer
      // branches on `type` before it can start.
      final frame = SnapshotFrame(snapshot: aSnapshot(instance.cursorAt(9)));
      final decoded = roundTrip(frame);
      expect(decoded, isA<SnapshotFrame>());
      expect(decoded.type, 'snapshot');
      expect(decoded.cursor, frame.cursor);

      // Whole, not merely present: every field a consumer renders survives.
      final picture = (decoded as SnapshotFrame).snapshot;
      expect(picture.takenAt, frame.snapshot.takenAt);
      expect(picture.takenAt.isUtc, isTrue);
      expect(picture.journalUnreadable, isNull);
      expect(picture.resources.single.name, '/tmp/p');
      expect(picture.resources.single.holder, 'root');

      final node = picture.nodes.single;
      expect(node.node.id, 'root');
      expect(node.node.role, 'crawler');
      expect(node.node.status, NodeStatus.working);
      expect(node.node.currentTask, 'building the thing');
      expect(node.node.parentId, isNull);
      expect(node.node.since, DateTime.utc(2026, 3, 4, 4, 54));
      expect(node.node.nextCheckin, DateTime.utc(2026, 3, 4, 5, 21));
      expect(node.depth, 0);
      expect(node.ownCostUsd, 0.2415507);

      // The spend is rebuilt exactly, `nodes` included. A decoder that had to
      // guess the size of the subtree would render a floor as if it were a
      // total, which is the one thing `SubtreeSpend.label` exists to prevent.
      expect(node.spend.knownMicroUsd, 241551);
      expect(node.spend.nodes, 3);
      expect(node.spend.unknownNodes, 2);
      expect(node.spend.isComplete, isFalse);
      expect(node.spend.label, frame.snapshot.nodes.single.spend.label);

      // Byte-for-byte, so the encoder and the decoder cannot drift apart.
      expect(decoded.encodeLine(), frame.encodeLine());
      // And the same bytes the socket already sends: `type` then the picture.
      expect((jsonDecode(frame.encodeLine()) as Map)['type'], 'snapshot');
      expect(jsonDecode(frame.encodeLine()), {
        'type': 'snapshot',
        ...frame.snapshot.toJson(),
      });
    });

    test('a snapshot with nothing in it round-trips as nothing, not as '
        'absence', () {
      // The empty picture and the unreadable one are different facts, and a
      // decoder that flattened either into the other is INV8 exactly.
      final cursor = instance.cursorAt(0);
      final empty = SnapshotFrame(
        snapshot: SproutSnapshot(
          cursor: cursor,
          takenAt: DateTime.utc(2026),
          nodes: const [],
          resources: const [],
        ),
      );
      final unreadable = SnapshotFrame(
        snapshot: SproutSnapshot(
          cursor: cursor,
          takenAt: DateTime.utc(2026),
          nodes: const [],
          resources: const [],
          journalUnreadable: 'database is locked',
        ),
      );
      expect((roundTrip(empty) as SnapshotFrame).snapshot.nodes, isEmpty);
      expect(
        (roundTrip(empty) as SnapshotFrame).snapshot.isJournalUnreadable,
        isFalse,
      );
      expect(
        (roundTrip(unreadable) as SnapshotFrame).snapshot.journalUnreadable,
        'database is locked',
      );
      expect(empty.encodeLine(), isNot(unreadable.encodeLine()));
    });

    test('an unknown subtree spend survives as unknown, never as zero', () {
      // `spend ?` and `$0.0000` are different answers and the wire has to keep
      // them apart: an identity element reported as "nothing there" is the
      // failure `SubtreeSpend` has three states for.
      final unknown = SnapshotFrame(
        snapshot: aSnapshot(
          instance.cursorAt(9),
          spend: const SubtreeSpend(
            knownMicroUsd: 0,
            nodes: 2,
            unknownNodes: 2,
          ),
        ),
      );
      final zero = SnapshotFrame(
        snapshot: aSnapshot(
          instance.cursorAt(9),
          spend: const SubtreeSpend(
            knownMicroUsd: 0,
            nodes: 2,
            unknownNodes: 1,
          ),
        ),
      );
      final decodedUnknown =
          (roundTrip(unknown) as SnapshotFrame).snapshot.nodes.single.spend;
      final decodedZero =
          (roundTrip(zero) as SnapshotFrame).snapshot.nodes.single.spend;
      expect(decodedUnknown.isUnknown, isTrue);
      expect(decodedUnknown.costUsd, isNull);
      expect(decodedUnknown.label, 'spend ?');
      expect(decodedZero.isUnknown, isFalse);
      expect(decodedZero.costUsd, 0);
      expect(decodedZero.label, r'>=$0.0000 (1 unknown)');
    });

    test('a malformed snapshot is refused, not half-decoded', () {
      // The picture is the thing every other frame is a delta against, so a
      // partially-read one is worse than none: the consumer would apply deltas
      // to a tree that was never on the wire.
      const good =
          '{"type":"snapshot","cursor":"s1.0123456789abcdef.9",'
          '"taken_at":"2026-03-04T05:06:07.000Z","journal_unreadable":null,'
          '"nodes":[],"resources":[]}';
      expect(ProtocolFrame.decodeLine(good), isA<SnapshotFrame>());
      for (final line in [
        // no cursor, and a cursor that is not one
        good.replaceFirst('"cursor":"s1.0123456789abcdef.9",', ''),
        good.replaceFirst('s1.0123456789abcdef.9', 'nonsense'),
        // no instant, and one that is not an instant
        good.replaceFirst('"taken_at":"2026-03-04T05:06:07.000Z",', ''),
        good.replaceFirst('2026-03-04T05:06:07.000Z', 'half past four'),
        // the two lists
        good.replaceFirst('"nodes":[],', ''),
        good.replaceFirst('"resources":[]', '"resources":7'),
        // A missing `journal_unreadable` would decode as a *readable* feed —
        // "I could not look" read as "nothing has happened", which is the
        // confusion the field exists to remove.
        good.replaceFirst('"journal_unreadable":null,', ''),
        // a node with a status nothing writes, and one missing its subtree size
        good.replaceFirst(
          '"nodes":[]',
          '"nodes":[{"id":"a","parent_id":null,'
              '"depth":0,"project":"/p","role":null,"status":"vibing",'
              '"current_task":null,"since":null,"next_checkin":null,'
              '"own_cost_usd":null,"subtree_cost_usd":null,'
              '"subtree_cost_is_complete":false,"subtree_unknown_cost_nodes":1,'
              '"subtree_nodes":1}]',
        ),
        good.replaceFirst(
          '"nodes":[]',
          '"nodes":[{"id":"a","parent_id":null,'
              '"depth":0,"project":"/p","role":null,"status":"working",'
              '"current_task":null,"since":null,"next_checkin":null,'
              '"own_cost_usd":null,"subtree_cost_usd":null,'
              '"subtree_cost_is_complete":false,'
              '"subtree_unknown_cost_nodes":1}]',
        ),
        // a resource with no holder: a lock with no named holder is not
        // information, and it is refused on the way in as on the way out.
        good.replaceFirst('"resources":[]', '"resources":[{"name":"/p"}]'),
        good.replaceFirst(
          '"resources":[]',
          '"resources":[{"name":"/p","holder":""}]',
        ),
      ]) {
        expect(
          () => ProtocolFrame.decodeLine(line),
          throwsA(isA<ProtocolFormatException>()),
          reason: line,
        );
      }
    });

    test('ready round-trips', () {
      final frame = ReadyFrame(cursor: instance.cursorAt(9));
      final decoded = roundTrip(frame);
      expect(decoded, isA<ReadyFrame>());
      expect(decoded.cursor, frame.cursor);
      expect(decoded.type, 'ready');
      expect(jsonDecode(frame.encodeLine()), {
        'type': 'ready',
        'cursor': 's1.0123456789abcdef.9',
      });
    });

    test('heartbeat round-trips, carrying the instant it was sent', () {
      final sentAt = DateTime.utc(2026, 3, 4, 5, 6, 7, 8);
      final frame = HeartbeatFrame(
        cursor: instance.cursorAt(9),
        sentAt: sentAt,
      );
      final decoded = roundTrip(frame) as HeartbeatFrame;
      expect(decoded.sentAt, sentAt);
      expect(decoded.cursor, frame.cursor);

      // The timestamp is the point of the frame, so two heartbeats at the same
      // cursor must still be distinguishable. Without it a buffered beat from
      // three minutes ago reads exactly like proof of life now, which is the
      // ambiguity the heartbeat was added to remove.
      final later = HeartbeatFrame(
        cursor: instance.cursorAt(9),
        sentAt: sentAt.add(const Duration(minutes: 3)),
      );
      expect(later.encodeLine(), isNot(frame.encodeLine()));

      // A local time is normalised rather than carried as-is: a consumer that
      // subtracts two instants must not be handed two different zones.
      final local = HeartbeatFrame(
        cursor: instance.cursorAt(9),
        sentAt: DateTime(2026, 3, 4, 5, 6, 7),
      );
      expect(local.sentAt.isUtc, isTrue);
    });

    test('a heartbeat with no instant is refused, not defaulted', () {
      expect(
        () => ProtocolFrame.decodeLine(
          '{"type":"heartbeat","cursor":"s1.0123456789abcdef.9"}',
        ),
        throwsA(isA<ProtocolFormatException>()),
      );
      // The pair: the same line with an instant decodes.
      expect(
        ProtocolFrame.decodeLine(
          '{"type":"heartbeat","cursor":"s1.0123456789abcdef.9",'
          '"at":"2026-03-04T05:06:07.000Z"}',
        ),
        isA<HeartbeatFrame>(),
      );
    });

    test('bye round-trips with and without a detail', () {
      final bare = ByeFrame(
        cursor: instance.cursorAt(9),
        reason: ByeReason.shutdown,
      );
      final decoded = roundTrip(bare) as ByeFrame;
      expect(decoded.reason, ByeReason.shutdown);
      expect(decoded.detail, isNull);
      expect(
        (jsonDecode(bare.encodeLine()) as Map).containsKey('detail'),
        isFalse,
      );

      final detailed = ByeFrame(
        cursor: instance.cursorAt(9),
        reason: ByeReason.error,
        detail: 'store became unreadable',
      );
      final decodedDetail = roundTrip(detailed) as ByeFrame;
      expect(decodedDetail.reason, ByeReason.error);
      expect(decodedDetail.detail, 'store became unreadable');
    });

    test('an unknown bye reason is refused, never read as an orderly end', () {
      expect(
        () => ProtocolFrame.decodeLine(
          '{"type":"bye","cursor":"s1.0123456789abcdef.9","reason":"whatever"}',
        ),
        throwsA(isA<ProtocolFormatException>()),
      );
      // The pair, on the same line with a reason this build knows.
      final ok = ProtocolFrame.decodeLine(
        '{"type":"bye","cursor":"s1.0123456789abcdef.9","reason":"shutdown"}',
      );
      expect((ok as ByeFrame).reason, ByeReason.shutdown);
    });

    test('bye for a refused cursor carries the refusal words and OUR position', () {
      final refusal = instance.accept(
        Cursor(instanceId: otherInstanceId, position: 412).encode(),
      ) as CursorRefused;
      final bye = ByeFrame.refusing(refusal, at: instance.cursorAt(77));

      expect(bye.reason, ByeReason.refused);
      expect(bye.detail, refusal.reason);
      // Not the consumer's meaningless 412: where THIS daemon stands, which is
      // what it needs in order to start again.
      expect(bye.cursor, instance.cursorAt(77));
      expect((roundTrip(bye) as ByeFrame).detail, refusal.reason);
    });

    test('delta round-trips its events, payloads and instants intact', () {
      final frame = DeltaFrame(
        cursor: instance.cursorAt(3),
        events: [
          anEvent(1),
          anEvent(2, kind: 'tool_use'),
          anEvent(3),
        ],
      );
      final decoded = roundTrip(frame) as DeltaFrame;
      expect(decoded.events, hasLength(3));
      expect(decoded.events.map((e) => e.seq), [1, 2, 3]);
      expect(decoded.events[1].kind, 'tool_use');
      expect(decoded.events[1].nodeId, 'node-2');
      expect(decoded.events[1].ts, DateTime.utc(2026, 3, 4, 5, 6, 7));
      expect(decoded.events[1].payload, {'depth': 2, 'note': 'e2'});
      expect(decoded.cursor, frame.cursor);
    });

    test('a delta whose cursor disagrees with its events is refused', () {
      // Ahead of its own contents: a consumer that stores this cursor skips
      // events 4..9 forever and nothing ever says so.
      expect(
        () => DeltaFrame(
          cursor: instance.cursorAt(9),
          events: [anEvent(1), anEvent(3)],
        ),
        throwsArgumentError,
      );
      // Out of order, and a repeated seq: both mean the batch was assembled
      // wrongly, and the feed's seq is monotonic and gapless by construction.
      expect(
        () => DeltaFrame(
          cursor: instance.cursorAt(3),
          events: [anEvent(3), anEvent(1)],
        ),
        throwsArgumentError,
      );
      expect(
        () => DeltaFrame(
          cursor: instance.cursorAt(3),
          events: [anEvent(3), anEvent(3)],
        ),
        throwsArgumentError,
      );
      // The pair, through the same constructor: the correct batch is built.
      expect(
        DeltaFrame(
          cursor: instance.cursorAt(3),
          events: [anEvent(1), anEvent(3)],
        ).events,
        hasLength(2),
      );
    });
  });

  group('ready is not an empty delta', () {
    test('they differ by type, by wire, and by marksEndOfReplay', () {
      final cursor = instance.cursorAt(9);
      final ready = ReadyFrame(cursor: cursor);
      final empty = DeltaFrame(cursor: cursor, events: const []);

      // Same cursor, same absence of events — the only thing separating them
      // is the frame type, and a consumer that branches on "did that carry any
      // events" waits for a `ready` it has already decided it saw, and shows a
      // blank screen forever.
      expect(ready.marksEndOfReplay, isTrue);
      expect(empty.marksEndOfReplay, isFalse);
      expect(ready.type, isNot(empty.type));
      expect(ready.encodeLine(), isNot(empty.encodeLine()));

      expect(roundTrip(ready), isA<ReadyFrame>());
      expect(roundTrip(empty), isA<DeltaFrame>());
      expect(roundTrip(ready), isNot(isA<DeltaFrame>()));
      expect(roundTrip(empty), isNot(isA<ReadyFrame>()));
      expect((roundTrip(empty) as DeltaFrame).events, isEmpty);
      expect(roundTrip(empty).marksEndOfReplay, isFalse);
    });

    test('marksEndOfReplay is true for ready ALONE, across every frame', () {
      // The paired negative for the assertion above. If `marksEndOfReplay`
      // were true everywhere, the empty-delta test would still pass on the
      // ready side; only checking the other three shows it discriminates.
      final cursor = instance.cursorAt(9);
      final frames = <ProtocolFrame>[
        ReadyFrame(cursor: cursor),
        HeartbeatFrame(cursor: cursor, sentAt: DateTime.utc(2026)),
        ByeFrame(cursor: cursor, reason: ByeReason.shutdown),
        DeltaFrame(cursor: cursor, events: const []),
        DeltaFrame(cursor: instance.cursorAt(1), events: [anEvent(1)]),
        // The fifth type. A snapshot is where replay *starts*: the backlog
        // after it may be thousands of events, and a consumer that went live
        // on the picture would show a tree it has not caught up to.
        SnapshotFrame(snapshot: aSnapshot(cursor)),
      ];
      expect(frames.where((f) => f.marksEndOfReplay).map((f) => f.type), [
        'ready',
      ]);
      // Every frame type this build has is in the list above. If a sixth is
      // added, this fails and the invariant is re-checked rather than assumed.
      expect(frames.map((f) => f.type).toSet(), {
        'ready',
        'heartbeat',
        'bye',
        'delta',
        'snapshot',
      });
    });
  });

  group('decoding refuses rather than degrades', () {
    test('an unknown frame type throws instead of being dropped', () {
      // `snapshot` used to be the example here, which is exactly what F-04
      // was: the frame the socket *opens with* read as unknown. It decodes
      // now, so the negative needs a type nothing emits — a decoder that
      // silently accepted anything would pass every positive test in this
      // file and still show a stale tree without saying why (INV8).
      for (final line in [
        '{"type":"nonsense","cursor":"s1.0123456789abcdef.9"}',
        '{"type":"snapshots","cursor":"s1.0123456789abcdef.9"}',
        '{"type":"","cursor":"s1.0123456789abcdef.9"}',
      ]) {
        expect(
          () => ProtocolFrame.decodeLine(line),
          throwsA(isA<ProtocolFormatException>()),
          reason: line,
        );
      }
      // The pair: a type this build does know decodes off the identical shape.
      expect(
        ProtocolFrame.decodeLine(
          '{"type":"ready","cursor":"s1.0123456789abcdef.9"}',
        ),
        isA<ReadyFrame>(),
      );
    });

    test('a frame with no type, no cursor, or a bad cursor throws', () {
      for (final line in [
        '{"cursor":"s1.0123456789abcdef.9"}',
        '{"type":"ready"}',
        '{"type":"ready","cursor":"nonsense"}',
        '{"type":"ready","cursor":7}',
        'not json at all',
        '[1,2,3]',
      ]) {
        expect(
          () => ProtocolFrame.decodeLine(line),
          throwsA(isA<ProtocolFormatException>()),
          reason: line,
        );
      }
      // The pair: the well-formed line these are each one field away from.
      expect(
        ProtocolFrame.decodeLine(
          '{"type":"ready","cursor":"s1.0123456789abcdef.9"}',
        ),
        isA<ReadyFrame>(),
      );
    });

    test('a frame cursor is read as-is, whatever instance it names', () {
      // A consumer LEARNS the instance id from the frames it is sent, so frame
      // decoding must not apply the `--since` check. If it did, a consumer
      // could not read the very first frame of a stream from a daemon it has
      // not met — and the id in that frame is exactly what tells it the daemon
      // restarted.
      final line = ReadyFrame(
        cursor: Cursor(instanceId: otherInstanceId, position: 5),
      ).encodeLine();
      expect(ProtocolFrame.decodeLine(line).cursor.instanceId, otherInstanceId);
      // And the pair: the same value offered on `--since` IS refused.
      expect(
        instance.accept(
          Cursor(instanceId: otherInstanceId, position: 5).encode(),
        ),
        isA<CursorFromAnotherInstance>(),
      );
    });

    test('a malformed event inside a delta throws', () {
      expect(
        () => ProtocolFrame.decodeLine(
          '{"type":"delta","cursor":"s1.0123456789abcdef.1",'
          '"events":[{"seq":"1","node_id":"n","ts":"2026-01-01T00:00:00Z",'
          '"kind":"k","payload":{}}]}',
        ),
        throwsA(isA<ProtocolFormatException>()),
      );
      // The pair: the same delta with an integer seq decodes.
      final ok = ProtocolFrame.decodeLine(
        '{"type":"delta","cursor":"s1.0123456789abcdef.1",'
        '"events":[{"seq":1,"node_id":"n","ts":"2026-01-01T00:00:00Z",'
        '"kind":"k","payload":{}}]}',
      );
      expect((ok as DeltaFrame).events.single.seq, 1);
    });
  });
}

/// What `_idFor` computes for the fixed input above.
///
/// Captured from the native-int implementation that predates the
/// `sprout_protocol` split, so this is a claim about continuity and not just
/// about the current code agreeing with itself.
const String _pinnedFeedId = 'af1a355b65886dd7';
