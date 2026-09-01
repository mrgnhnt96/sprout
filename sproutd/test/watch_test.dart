/// Tests for `watch --since <cursor>` in `lib/watch.dart`.
///
/// Time is fake throughout. The session owns no clock and no timer — the
/// heartbeat and the wake-up arrive as injected streams and the instant comes
/// from an injected function — so every assertion below is about a *sequence*
/// of frames rather than about how long something took. Nothing here sleeps.
library;

import 'dart:async';

import 'package:sproutd/protocol.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watch.dart';
import 'package:test/test.dart';

/// The instance every asserted cursor in this file belongs to.
const String testInstanceId = '0123456789abcdef';

/// A well-formed id that is *not* the one under test — the other sproutd.
const String otherInstanceId = 'ffffffffffffffff';

/// The instant the fake clock reports unless a test advances it.
final DateTime beat0 = DateTime.utc(2026, 9, 1, 14, 15);

/// A [WatchSource] whose feed throws, and one that can be broken mid-stream.
///
/// This is the seam [WatchSource] exists for: an unreadable feed cannot be
/// provoked through `SproutStore`'s public API, and "the stream broke" is the
/// branch that matters most on a long-lived connection.
final class BreakableSource implements WatchSource {
  BreakableSource(this.store);

  final SproutStore store;

  /// Set true to make every subsequent read fail.
  bool broken = false;

  /// Set true to make only [feedPosition] fail.
  bool positionBroken = false;

  int reads = 0;

  @override
  int feedPosition() {
    if (broken || positionBroken) throw const FeedGone('feed head is gone');
    return store.cursor;
  }

  @override
  List<SproutEvent> eventsAfter(int position, {int? limit}) {
    reads += 1;
    if (broken) throw const FeedGone('payload could not be read');
    return store.eventsSince(position, limit: limit);
  }
}

/// Stands in for `dart:io`'s `FileSystemException`, so the test needs no io
/// import for one message.
final class FeedGone implements Exception {
  const FeedGone(this.message);
  final String message;
  @override
  String toString() => 'FeedGone: $message';
}

/// Drives one session's signals by hand: nothing ticks unless a test says so.
final class Driver {
  final wakeups = StreamController<void>();
  final heartbeats = StreamController<void>();
  final shutdown = Completer<String>();

  WatchSignals get signals => WatchSignals(
    wakeups: wakeups.stream,
    heartbeats: heartbeats.stream,
    shutdown: shutdown.future,
  );

  void wake() => wakeups.add(null);
  void beat() => heartbeats.add(null);
  void stop(String detail) => shutdown.complete(detail);

  /// Closes the signal controllers. Deliberately **not** awaited: closing a
  /// single-subscription controller that nobody ever listened to returns a
  /// future that completes only when a listener takes the done event, so
  /// awaiting one is a hang, not a cleanup. A refused `--since` never
  /// subscribes to its signals, which is exactly that case.
  void dispose() {
    wakeups.close();
    heartbeats.close();
  }
}

/// Appends [count] events and returns their seqs.
///
/// The node rows come first because `event.node_id` carries a real foreign
/// key: an event names a node sprout created a moment earlier, so a feed of
/// events about nothing is refused by the schema itself.
List<int> appendEvents(
  SproutStore store,
  int count, {
  String kind = 'spawned',
}) {
  return [
    for (var i = 0; i < count; i++) appendEvent(store, 'node-$i', kind: kind),
  ];
}

/// Appends one event about [nodeId], creating the node row if it is new.
int appendEvent(SproutStore store, String nodeId, {String kind = 'spawned'}) {
  if (store.node(nodeId) == null) {
    store.putNode(
      SproutNode(id: nodeId, project: '/w/root', status: NodeStatus.working),
    );
  }
  return store.append(nodeId: nodeId, kind: kind, payload: {'node': nodeId});
}

/// Every event carried by the `delta` frames in [frames], in order.
List<SproutEvent> deltaEvents(List<ProtocolFrame> frames) => [
  for (final frame in frames)
    if (frame is DeltaFrame) ...frame.events,
];

/// The frame types in order, as strings, so a test asserts a *sequence*.
List<String> typesOf(List<ProtocolFrame> frames) => [
  for (final frame in frames) frame.type,
];

void main() {
  late SproutStore store;
  late SproutInstance instance;
  late Driver driver;
  late DateTime clock;
  final drivers = <Driver>[];

  /// A fresh set of signals, disposed with the test. Each session needs its
  /// own: the signal streams are single-subscription, so two sessions sharing
  /// one driver is a listener conflict rather than a shared clock.
  Driver newDriver() {
    final created = Driver();
    drivers.add(created);
    return created;
  }

  setUp(() {
    store = SproutStore.memory();
    instance = SproutInstance(testInstanceId);
    drivers.clear();
    driver = newDriver();
    clock = beat0;
  });

  tearDown(() {
    for (final created in drivers) {
      created.dispose();
    }
    store.close();
  });

  /// Starts a session over [source] (the store by default) and collects its
  /// frames as they arrive.
  ({List<ProtocolFrame> frames, StreamSubscription<ProtocolFrame> sub})
  watching({
    String? since,
    WatchSource? source,
    int batchSize = 500,
    Driver? via,
  }) {
    final frames = <ProtocolFrame>[];
    final sub = watchFrames(
      source: source ?? StoreWatchSource(store),
      signals: (via ?? driver).signals,
      since: since,
      instance: instance,
      now: () => clock,
      batchSize: batchSize,
    ).listen(frames.add);
    return (frames: frames, sub: sub);
  }

  /// Lets every already-scheduled microtask and event run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('replay', () {
    test('from a cursor mid-feed yields exactly the events after it', () async {
      final seqs = appendEvents(store, 6);
      final session = watching(since: instance.cursorAt(seqs[2]).encode());
      await settle();

      // No duplicate: the event AT the cursor is not resent, because the
      // consumer already holds it.
      final replayed = deltaEvents(session.frames).map((e) => e.seq).toList();
      expect(replayed, [seqs[3], seqs[4], seqs[5]]);

      // And no gap: the replay picks up at the very next seq, so applying it
      // to a snapshot taken at that cursor loses nothing in between.
      expect(replayed.first, seqs[2] + 1);
      expect(session.frames.last, isA<ReadyFrame>());
      expect(session.frames.last.cursor, instance.cursorAt(seqs.last));

      await session.sub.cancel();
    });

    test('every delta ends at its own last event seq', () async {
      final seqs = appendEvents(store, 5);
      final session = watching(
        since: instance.cursorAt(0).encode(),
        batchSize: 2,
      );
      await settle();

      final deltas = session.frames.whereType<DeltaFrame>().toList();
      // Batched: three frames, not one enormous line.
      expect(deltas, hasLength(3));
      for (final delta in deltas) {
        expect(delta.cursor.position, delta.events.last.seq);
      }
      // Concatenated, the batches are the whole feed with no gap and no
      // repeat — the property a consumer's position depends on.
      expect(deltaEvents(session.frames).map((e) => e.seq), seqs);

      await session.sub.cancel();
    });

    test('replays nothing, and still says ready, on an empty feed', () async {
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();

      // The blank-screen case. `ready` arrives with no delta before it...
      expect(typesOf(session.frames), ['ready']);
      expect(session.frames.single.marksEndOfReplay, isTrue);
      // ...and emphatically NOT as a delta carrying zero events, which is a
      // different statement a consumer must not read as the end of replay.
      expect(session.frames.whereType<DeltaFrame>(), isEmpty);

      await session.sub.cancel();
    });

    test('without --since it starts at the head and replays nothing', () async {
      appendEvents(store, 3);
      final session = watching();
      await settle();

      // The paired positive for the test above: the same empty prefix, but
      // for a different reason — there IS a backlog, and it is deliberately
      // skipped because the consumer asked to start now.
      expect(typesOf(session.frames), ['ready']);
      expect(session.frames.single.cursor, instance.cursorAt(3));

      final fresh = appendEvent(store, 'n', kind: 'spawned');
      driver.wake();
      await settle();
      expect(deltaEvents(session.frames).map((e) => e.seq), [fresh]);

      await session.sub.cancel();
    });
  });

  group('ready', () {
    test('arrives after the replay and before any live delta', () async {
      final seqs = appendEvents(store, 2);
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();
      expect(typesOf(session.frames), ['delta', 'ready']);

      final live = appendEvent(store, 'n', kind: 'result');
      driver.wake();
      driver.beat();
      await settle();

      // The whole sequence, in order: backlog, ready, then live traffic. A
      // consumer switching to "live" on the ready frame is switching at the
      // right point.
      expect(typesOf(session.frames), ['delta', 'ready', 'delta', 'heartbeat']);
      expect(deltaEvents(session.frames).map((e) => e.seq), [...seqs, live]);

      // Exactly one ready, ever: it is the end of replay, not a periodic
      // reassurance.
      expect(session.frames.where((f) => f.marksEndOfReplay), hasLength(1));

      await session.sub.cancel();
    });

    test('is never preceded by a heartbeat, however early one ticks', () async {
      appendEvents(store, 400);
      final session = watching(
        since: instance.cursorAt(0).encode(),
        batchSize: 1,
      );
      driver.beat();
      driver.beat();
      await settle();

      final types = typesOf(session.frames);
      final ready = types.indexOf('ready');
      expect(ready, greaterThan(0));
      expect(types.take(ready), everyElement('delta'));
      // The pair: the beats were not swallowed, they were ordered after the
      // ready. A test that only asserted "no heartbeat before ready" would
      // pass just as well if heartbeats never worked at all.
      expect(types.skip(ready + 1), ['heartbeat', 'heartbeat']);

      await session.sub.cancel();
    });
  });

  group('heartbeat', () {
    test('fires on a stream where nothing at all is happening', () async {
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();
      expect(typesOf(session.frames), ['ready']);

      // Not one event appended, not one wake-up. This is the case that
      // distinguishes a dead stream from a quiet one, and the case a test
      // forgets to cover.
      clock = beat0.add(const Duration(seconds: 15));
      driver.beat();
      await settle();
      clock = beat0.add(const Duration(seconds: 30));
      driver.beat();
      await settle();

      final beats = session.frames.whereType<HeartbeatFrame>().toList();
      expect(beats, hasLength(2));
      // Each carries the CURRENT cursor and its own instant, so a consumer
      // computes staleness from a measured time and never estimates one.
      expect(beats.map((b) => b.cursor), everyElement(instance.cursorAt(0)));
      expect(beats.map((b) => b.sentAt), [
        beat0.add(const Duration(seconds: 15)),
        beat0.add(const Duration(seconds: 30)),
      ]);

      await session.sub.cancel();
    });

    test('is not starved by a busy stream, and tracks its cursor', () async {
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();

      // The paired positive of the idle case: traffic must not push the beat
      // out. A heartbeat that a busy tree can starve is not a liveness
      // signal, so this asserts one lands BETWEEN the deltas.
      final first = appendEvent(store, 'a', kind: 'spawned');
      driver.wake();
      await settle();
      driver.beat();
      await settle();
      final second = appendEvent(store, 'b', kind: 'spawned');
      driver.wake();
      await settle();
      driver.beat();
      await settle();

      expect(typesOf(session.frames), [
        'ready',
        'delta',
        'heartbeat',
        'delta',
        'heartbeat',
      ]);
      final beats = session.frames.whereType<HeartbeatFrame>().toList();
      expect(beats.map((b) => b.cursor.position), [first, second]);

      await session.sub.cancel();
    });

    test('a wake-up with no new events emits no frame at all', () async {
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();
      driver.wake();
      driver.wake();
      await settle();

      // No empty delta: a position update carrying nothing would be a frame a
      // consumer could mistake for the end of something.
      expect(typesOf(session.frames), ['ready']);

      // The pair, through the same wake-up path: with an event to send, it
      // does emit.
      appendEvent(store, 'n', kind: 'spawned');
      driver.wake();
      await settle();
      expect(typesOf(session.frames), ['ready', 'delta']);

      await session.sub.cancel();
    });
  });

  group('bye', () {
    test('carries a reason on orderly shutdown, and ends the stream', () async {
      final session = watching(since: instance.cursorAt(0).encode());
      final done = session.sub.asFuture<void>();
      final seq = appendEvent(store, 'n', kind: 'spawned');
      driver.wake();
      await settle();

      driver.stop('sproutd is going away');
      await done;

      final bye = session.frames.last as ByeFrame;
      expect(bye.reason, ByeReason.shutdown);
      expect(bye.detail, 'sproutd is going away');
      // At this daemon's position, so a consumer knows where it stood when it
      // stopped.
      expect(bye.cursor, instance.cursorAt(seq));
      expect(typesOf(session.frames), ['ready', 'delta', 'bye']);
    });

    test(
      'a consumer that cancels gets none — that is the case bye covers',
      () async {
        final session = watching(since: instance.cursorAt(0).encode());
        await settle();
        await session.sub.cancel();
        await settle();

        // The pair for the test above. Nothing sproutd can do makes a
        // consumer-side disconnect look orderly, which is precisely why the
        // producer-side end says so explicitly.
        expect(session.frames.whereType<ByeFrame>(), isEmpty);
      },
    );

    test('says error, not shutdown, when the feed breaks mid-stream', () async {
      final source = BreakableSource(store);
      appendEvents(store, 2);
      final session = watching(
        since: instance.cursorAt(0).encode(),
        source: source,
      );
      final done = session.sub.asFuture<void>();
      await settle();
      expect(typesOf(session.frames), ['delta', 'ready']);

      source.broken = true;
      driver.wake();
      await done;

      final bye = session.frames.last as ByeFrame;
      // Not `shutdown`: a broken stream calls for a reconnect and an orderly
      // one does not, and a consumer cannot tell them apart from the bytes.
      expect(bye.reason, ByeReason.error);
      expect(bye.detail, contains('could not be read'));
      expect(bye.cursor, instance.cursorAt(2));
    });

    test('says error when the feed head cannot be read at all', () async {
      final source = BreakableSource(store)..positionBroken = true;
      final session = watching(source: source);
      final done = session.sub.asFuture<void>();
      await done;

      // No `--since`, so the head is the only thing that could position the
      // stream. It could not be read, and the frame says so rather than
      // reporting an empty feed — "I could not look" and "there is nothing
      // there" are one observation to a consumer that gets 0 for both.
      final bye = session.frames.single as ByeFrame;
      expect(bye.reason, ByeReason.error);
      expect(bye.cursor.position, 0);
      expect(session.frames.whereType<ReadyFrame>(), isEmpty);
    });
  });

  group('--since', () {
    test('refuses a cursor from another sproutd, naming both ids', () async {
      appendEvents(store, 3);
      final foreign = Cursor(instanceId: otherInstanceId, position: 2);
      final session = watching(since: foreign.encode());
      final done = session.sub.asFuture<void>();
      await done;

      // One frame, and it is a refusal: no replay, no ready. Resuming at seq 2
      // of a DIFFERENT daemon's feed is the silent corruption the instance
      // namespace exists to prevent.
      expect(typesOf(session.frames), ['bye']);
      final bye = session.frames.single as ByeFrame;
      expect(bye.reason, ByeReason.refused);
      expect(bye.detail, contains(otherInstanceId));
      expect(bye.detail, contains(testInstanceId));
      // The bye carries THIS daemon's position, which is what the consumer
      // needs in order to start again.
      expect(bye.cursor, instance.cursorAt(3));
    });

    test('accepts the same position from this instance', () async {
      final seqs = appendEvents(store, 3);
      // The paired positive: identical position, identical feed, and the only
      // difference is whose instance the cursor names.
      final session = watching(since: instance.cursorAt(seqs[1]).encode());
      await settle();

      expect(typesOf(session.frames), ['delta', 'ready']);
      expect(deltaEvents(session.frames).map((e) => e.seq), [seqs[2]]);

      await session.sub.cancel();
    });

    test('refuses a malformed cursor differently from a foreign one', () async {
      final malformed = watching(since: 'not-a-cursor');
      await malformed.sub.asFuture<void>();
      final foreignSession = watching(
        since: Cursor(instanceId: otherInstanceId, position: 1).encode(),
        via: newDriver(),
      );
      await foreignSession.sub.asFuture<void>();

      final a = malformed.frames.single as ByeFrame;
      final b = foreignSession.frames.single as ByeFrame;

      // Both refuse, and both say `refused` — but the words differ, because
      // the remedies differ: one consumer holds a corrupt string, the other
      // holds a perfectly good cursor for a daemon that is not this one.
      expect(a.reason, ByeReason.refused);
      expect(b.reason, ByeReason.refused);
      expect(a.detail, isNot(b.detail));
      expect(a.detail, contains('not a sprout cursor'));
      expect(a.detail, isNot(contains(otherInstanceId)));
      expect(b.detail, contains('belongs to sproutd instance'));
    });

    test('refuses a cursor whose version this build does not speak', () async {
      final session = watching(since: 's2.$testInstanceId.4');
      await session.sub.asFuture<void>();

      // A future cursor shape is malformed HERE, not silently read as a v1
      // cursor with a strange instance id.
      final bye = session.frames.single as ByeFrame;
      expect(bye.reason, ByeReason.refused);
      expect(bye.detail, contains('unknown cursor version'));
    });
  });

  group('the cursor belongs to the consumer', () {
    test('watching twice from one cursor replays the same events', () async {
      final seqs = appendEvents(store, 4);
      final since = instance.cursorAt(seqs[1]).encode();

      final first = watching(since: since, via: newDriver());
      await settle();
      await first.sub.cancel();

      final second = watching(since: since, via: newDriver());
      await settle();
      await second.sub.cancel();

      // Having sent a frame is not proof the consumer took it. sproutd records
      // no read position, so the second attach is fed exactly what the first
      // one was — which is what makes a consumer that crashed mid-apply
      // recoverable.
      expect(
        deltaEvents(second.frames).map((e) => e.seq),
        deltaEvents(first.frames).map((e) => e.seq),
      );
      expect(deltaEvents(second.frames).map((e) => e.seq), [seqs[2], seqs[3]]);
    });

    test('a session writes nothing to the store', () async {
      final seqs = appendEvents(store, 3);
      final session = watching(since: instance.cursorAt(0).encode());
      await settle();
      driver.beat();
      driver.wake();
      await settle();
      driver.stop('done');
      await session.sub.asFuture<void>();

      // The paired positive is the feed itself: the events written before the
      // watch are all still there, unchanged, and no row was added by the act
      // of reading them.
      expect(store.cursor, seqs.last);
      expect(store.eventsSince(0).map((e) => e.seq), seqs);
    });
  });

  group('the wire', () {
    test('every frame of a session survives an NDJSON round trip', () async {
      appendEvents(store, 2);
      final session = watching(since: instance.cursorAt(0).encode());
      final done = session.sub.asFuture<void>();
      await settle();
      driver.beat();
      await settle();
      driver.stop('bye now');
      await done;

      final lines = session.frames.map((f) => f.encodeLine()).toList();
      expect(lines, everyElement(isNot(contains('\n'))));
      final decoded = lines.map(ProtocolFrame.decodeLine).toList();
      expect(typesOf(decoded), typesOf(session.frames));
      expect(decoded.map((f) => f.cursor), session.frames.map((f) => f.cursor));
      expect(
        deltaEvents(decoded).map((e) => e.seq),
        deltaEvents(session.frames).map((e) => e.seq),
      );
    });
  });
}
