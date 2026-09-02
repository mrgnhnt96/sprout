/// Tests for the WebSocket transport: `snapshot` then `watch` over one
/// long-lived socket.
///
/// **These run against a real `HttpServer` and a real `WebSocket` client.**
/// That is the whole point. P1-06 shipped a socket that closed the instant it
/// opened, and every test it had still passed, because they called the
/// controller method directly and a `101` handshake looks identical either
/// way. So the assertions here are about what a client actually receives and
/// for how long: that frames keep arriving after a silence, that a heartbeat
/// lands with nothing else happening, that a `bye` really closes the socket,
/// and that hanging up really tears the session down.
///
/// The route is built here rather than taken from `.revali/server/`, which is
/// generated and git-ignored, so it cannot be imported by a test that has to
/// pass on a clean checkout. It mirrors what `revali build` emits verbatim —
/// `assertions on the generated shape` below reads the generated file when it
/// is present and fails if the two have drifted, and `docs`/the commit message
/// carry the run of the compiled binary, which is the only proof that covers
/// the annotation itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
// `dart:io`'s WebSocket is the client here; revali_router exports an
// annotation of the same name, so that one is hidden rather than aliased.
import 'package:revali_router/revali_router.dart' hide WebSocket;
import 'package:sproutd/protocol.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watch.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;
import '../routes/controllers/tree_controller.dart';

/// A cursor that is well formed and belongs to nobody in this test.
const String foreignCursor = 's1.deadbeefdeadbeef.3';

/// A value that is not a cursor at all.
const String malformedCursor = 'not-a-cursor';

/// The size of the chunk the transport cuts a frame into, in bytes.
///
/// Not a knob and not a guess: `dart:convert`'s `_Utf8Encoder` allocates
/// `_DEFAULT_BYTE_BUFFER_SIZE = 1024` (Dart SDK 3.13, `lib/convert/utf.dart`)
/// and flushes whenever it fills, and `StreamBodyData.read()` encodes the
/// socket's `Stream<String>` through exactly that. So a frame past this many
/// bytes reaches `webSocket.add` as more than one call and arrives as more
/// than one message — which is what `a frame larger than one chunk` builds a
/// frame to cross. `sprout_ui/lib/src/frame_reader.dart` spells the same
/// number for the same reason on the reading side.
const int daemonChunkBytes = 1024;

/// The ping the test sockets use, shortened from `socketPingInterval`.
///
/// It is what makes a disconnect observable at all, so a test that wants to
/// watch the teardown passes this and a test that wants to watch the leak
/// passes null.
const Duration _testPing = Duration(milliseconds: 250);

void main() {
  group('the socket', () {
    late _Wire wire;

    tearDown(() => wire.close());

    test('opens with a snapshot, says ready, and then stays open', () async {
      // The P1-06 regression, stated as an assertion. A send-only handler that
      // returned one `Map` closed the socket here, and nothing noticed.
      wire = await _serve();
      final line = await wire.next();
      final snapshot = jsonDecode(line) as Map<String, Object?>;
      expect(snapshot['type'], snapshotFrameType);
      expect(snapshot['nodes'], isEmpty);
      // Over a real socket, not a fake sender: the opening line goes through
      // the same decoder as every line after it (F-04).
      expect(ProtocolFrame.decodeLine(line), isA<SnapshotFrame>());

      final ready = ProtocolFrame.decodeLine(await wire.next());
      expect(ready, isA<ReadyFrame>());
      expect(ready.marksEndOfReplay, isTrue);

      // Still open, and still able to carry traffic — the second half is what
      // makes this more than a readyState read.
      expect(wire.socket.closeCode, isNull);
      wire.heartbeats.add(null);
      expect(
        ProtocolFrame.decodeLine(await wire.next()),
        isA<HeartbeatFrame>(),
      );
      expect(wire.socket.closeCode, isNull);
    });

    test('heartbeats while the tree is silent, and deltas when it is not', () {
      // INV8 both ways in one test: a beat with nothing happening is what
      // distinguishes a live stream from a dead one, and it is only meaningful
      // if a real event still produces a real delta on the same socket.
      return _withWire((wire) async {
        await wire.skipToReady();

        wire.heartbeats.add(null);
        final beat = ProtocolFrame.decodeLine(await wire.next());
        expect(beat, isA<HeartbeatFrame>());
        expect(beat.cursor.position, 0, reason: 'a beat moves no position');

        wire.store
          ..putNode(
            const SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
            ),
          )
          ..append(nodeId: 'a', kind: 'runner.spawned');
        wire.wakeups.add(null);

        final delta = ProtocolFrame.decodeLine(await wire.next());
        expect(delta, isA<DeltaFrame>());
        expect((delta as DeltaFrame).events.single.kind, 'runner.spawned');
      });
    });

    test('a wake-up with nothing new sends nothing at all', () {
      // The paired negative for the delta above. An empty `delta` would be a
      // position update carrying no position change; the next frame a consumer
      // sees must be the heartbeat, not a delta with an empty list in it.
      return _withWire((wire) async {
        await wire.skipToReady();
        wire.wakeups
          ..add(null)
          ..add(null);
        wire.heartbeats.add(null);
        expect(
          ProtocolFrame.decodeLine(await wire.next()),
          isA<HeartbeatFrame>(),
        );
      });
    });

    test('replays what happened after --since, then says ready', () async {
      wire = await _serve(
        seed: (store) {
          store.putNode(
            const SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
            ),
          );
          for (var i = 0; i < 3; i++) {
            store.append(nodeId: 'a', kind: 'runner.frame');
          }
        },
        since: (SproutInstance instance) => instance.cursorAt(1).encode(),
      );
      // snapshot, then the replay of seq 2 and 3, then ready. Strictly after
      // the cursor: the consumer already holds seq 1.
      expect(
        (jsonDecode(await wire.next()) as Map<String, Object?>)['type'],
        snapshotFrameType,
      );
      final delta = ProtocolFrame.decodeLine(await wire.next()) as DeltaFrame;
      expect(delta.events.map((e) => e.seq), [2, 3]);
      final ready = ProtocolFrame.decodeLine(await wire.next());
      expect(ready, isA<ReadyFrame>());
      expect(ready.cursor.position, 3);
    });
  });

  group('a refused --since', () {
    late _Wire wire;
    tearDown(() => wire.close());

    test('sends a bye and no snapshot at all', () async {
      wire = await _serve(since: foreignCursor);
      final bye = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
      expect(bye.reason, ByeReason.refused);
      expect(bye.detail, contains('take a fresh snapshot'));
      // The consumer asked to resume and was told it cannot. Answering with a
      // picture it did not ask for would make the socket and the CLI disagree
      // about what a refusal is.
      await wire.expectClosed();
      expect(wire.received.length, 1, reason: 'exactly one frame, the bye');
    });

    test('carries this daemon position, not the offered one', () async {
      wire = await _serve(
        since: foreignCursor,
        seed: (store) {
          store
            ..putNode(
              const SproutNode(
                id: 'a',
                project: '/p',
                status: NodeStatus.working,
              ),
            )
            ..append(nodeId: 'a', kind: 'runner.spawned');
        },
      );
      final bye = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
      expect(bye.cursor.instanceId, wire.instance.id);
      expect(bye.cursor.position, 1, reason: 'where THIS daemon stands');
      expect(bye.cursor.instanceId, isNot('deadbeefdeadbeef'));
    });

    test('says the same words the CLI says, byte for byte', () async {
      // A malformed cursor's refusal names no instance id, so the two surfaces
      // owe each other an exact string. Two surfaces disagreeing about a
      // refusal is a bug, and this is the cheapest place it would show.
      wire = await _serve(since: malformedCursor);
      final bye = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;

      final tmp = Directory.systemTemp.createTempSync('sprout_ws_cli');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final err = StringBuffer();
      final code = await cli.sprout(
        ['watch', '--since', malformedCursor, '--db', p.join(tmp.path, 's.db')],
        out: StringBuffer(),
        err: err,
        environment: const {},
      );

      expect(code, cli.exitCursorMalformed);
      expect(err.toString().trim(), 'sprout: refusing --since: ${bye.detail}');
    });

    test('refuses a malformed and a foreign cursor differently', () async {
      // The paired case: both are refusals, and collapsing them would tell a
      // reconnecting consumer its own cursor is corrupt when it is merely from
      // another daemon. Same socket, same code path, two different texts.
      wire = await _serve(since: malformedCursor);
      final malformed = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
      expect(malformed.detail, contains('not a sprout cursor'));
      expect(malformed.detail, isNot(contains('take a fresh snapshot')));
      await wire.close();

      wire = await _serve(since: foreignCursor);
      final foreign = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
      expect(foreign.detail, contains('take a fresh snapshot'));
      expect(foreign.detail, isNot(contains('not a sprout cursor')));
    });

    test('accepts a well-formed cursor this daemon minted', () async {
      // The positive half of the three refusal tests above: the gate is only
      // meaningful if it lets the right cursor through.
      wire = await _serve(
        seed: (store) {
          store
            ..putNode(
              const SproutNode(
                id: 'a',
                project: '/p',
                status: NodeStatus.working,
              ),
            )
            ..append(nodeId: 'a', kind: 'runner.spawned');
        },
        since: (SproutInstance instance) => instance.cursorAt(1).encode(),
      );
      expect(
        (jsonDecode(await wire.next()) as Map<String, Object?>)['type'],
        snapshotFrameType,
      );
      expect(ProtocolFrame.decodeLine(await wire.next()), isA<ReadyFrame>());
    });
  });

  group('the CLI and the daemon agree on an instance id', () {
    // Finding F-01, now asserted as the behaviour rather than as the defect.
    //
    // The daemon used to hand out `SproutInstance.current`, generated per
    // process, so a cursor a user copied out of `sprout snapshot` was refused
    // by this socket every single time and the join the whole protocol exists
    // to protect was broken between the two surfaces sprout ships. Both sides
    // now call one derivation, `SproutInstance.forFeed`, over the absolute
    // database path and the identity of the feed's first event.
    //
    // These two tests go through the real entry points on purpose —
    // `cli.instanceForStore` is what `sprout snapshot` mints with and
    // `daemonInstanceFor` (inside `_serve`) is what the socket serves with —
    // so they would still fail if one surface were quietly changed to compute
    // its own hash.
    late _Wire wire;
    tearDown(() => wire.close());

    test('so a cursor sprout snapshot minted is accepted by the socket', () {
      return _withStore((store, dbPath) async {
        store
          ..putNode(
            const SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
            ),
          )
          ..append(nodeId: 'a', kind: 'runner.spawned');
        final fromCli = cli.instanceForStore(store).cursorAt(1).encode();

        wire = await _serve(store: store, since: fromCli);
        // Accepted means a picture and a `ready`, not a `bye`. Asserting the
        // frames rather than just "not refused" is the difference between the
        // cursor being honoured and the refusal merely being worded
        // differently.
        expect(
          (jsonDecode(await wire.next()) as Map<String, Object?>)['type'],
          snapshotFrameType,
        );
        final ready = ProtocolFrame.decodeLine(await wire.next());
        expect(ready, isA<ReadyFrame>());
        expect(
          ready.cursor.instanceId,
          cli.instanceForStore(store).id,
          reason:
              'the daemon must hand back cursors in the same namespace '
              'the CLI mints in, or the next --since starts the loop again',
        );
      });
    });

    test('and a cursor from a different database is still refused', () {
      // The pair (INV8). Acceptance on its own cannot tell a working join from
      // a check that was deleted: this is the case that must still be refused,
      // and it is a *real* second database rather than a made-up id, so it
      // fails if the derivation ever collapses to something constant.
      return _withStore((store, dbPath) async {
        store
          ..putNode(
            const SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
            ),
          )
          ..append(nodeId: 'a', kind: 'runner.spawned');

        await _withStore((other, otherPath) async {
          other
            ..putNode(
              const SproutNode(
                id: 'a',
                project: '/p',
                status: NodeStatus.working,
              ),
            )
            ..append(nodeId: 'a', kind: 'runner.spawned');
          final elsewhere = cli.instanceForStore(other);
          expect(
            elsewhere.id,
            isNot(cli.instanceForStore(store).id),
            reason: 'two databases at two paths are two instances',
          );

          wire = await _serve(
            store: store,
            since: elsewhere.cursorAt(1).encode(),
          );
          final bye = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
          expect(bye.reason, ByeReason.refused);
          // Both ids named, which is what makes the refusal actionable.
          expect(bye.detail, contains(elsewhere.id));
          expect(bye.detail, contains(cli.instanceForStore(store).id));
          expect(bye.detail, contains('take a fresh snapshot'));
        });
      });
    });

    test('and the CLI accepts its own cursor', () {
      // The third leg: the test above is a statement about the *daemon* only
      // if the cursor was good to begin with.
      return _withStore((store, dbPath) async {
        store
          ..putNode(
            const SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
            ),
          )
          ..append(nodeId: 'a', kind: 'runner.spawned');
        final instance = cli.instanceForStore(store);
        expect(
          instance.accept(instance.cursorAt(1).encode()),
          isA<CursorAccepted>(),
        );
      });
    });
  });

  group('ending the stream', () {
    late _Wire wire;
    tearDown(() => wire.close());

    test('a bye really closes the socket, and nothing follows it', () async {
      wire = await _serve();
      await wire.skipToReady();

      wire.shutdown.complete('daemon going away');
      final bye = ProtocolFrame.decodeLine(await wire.next()) as ByeFrame;
      expect(bye.reason, ByeReason.shutdown);
      expect(bye.detail, 'daemon going away');

      // "A stream that simply stops did not end, it broke." A two-way socket
      // that fell through to listenToMessages() would sit open here, saying
      // nothing, which is exactly the state `bye` exists to rule out.
      await wire.expectClosed();
      expect(wire.received.last, bye.encodeLine());
    });

    test('the client hanging up tears the session and its timers down', () {
      // The leak that is invisible for a day. `treeSocketFrames` is
      // StreamController-driven rather than `async*` precisely so this is
      // deterministic (dart-lang/sdk#26686).
      return _withWire((wire) async {
        await wire.skipToReady();
        // The positive half: while a client is attached, the session really is
        // subscribed to both signals.
        expect(wire.wakeups.hasListener, isTrue);
        expect(wire.heartbeats.hasListener, isTrue);

        await wire.socket.close();

        // Two things are needed and the shape of the delay is both of them:
        // the *ping* is what discovers the peer is gone and sets `closeCode`,
        // and the next *send* is what sees that and unwinds the handler. So
        // the bound is one ping plus one heartbeat, and the test below is the
        // same loop with the ping taken away.
        await _until(() {
          wire.heartbeats.add(null);
          return !wire.wakeups.hasListener && !wire.heartbeats.hasListener;
        });
        expect(wire.wakeups.hasListener, isFalse);
        expect(wire.heartbeats.hasListener, isFalse);
      });
    });
  });

  group('the ping', () {
    // These three do not share the group above's `wire`: two of them attach a
    // client `dart:io` cannot be, and a group-level tearDown over a `late`
    // field that a test never assigns fails on whatever ran last instead.
    test('a client that answers the ping outlives twice the interval', () {
      // Finding F-06, stated as the behaviour rather than as the defect.
      //
      // `dart:io` closes a socket with 1001 when a ping goes unanswered, and
      // for a while *every* socket was closed that way whether the client
      // answered or not: the protocol subscription is paused until something
      // listens to the `WebSocket` (`websocket_impl.dart`:
      // `subscription.pause()`, resumed by `_controller.onListen`), and while
      // the connect handler streamed nothing ever did. A pong that is never
      // delivered cannot cancel the timer. Measured on the compiled binary at
      // a 15s ping: a client sending well-formed masked pongs was closed 1001
      // at +30.0s, identically to one that sent nothing.
      //
      // `_Wire` listens, and `dart:io` answers a ping as soon as anything
      // listens, so this client is the live peer. Six intervals is well past
      // the two that used to be fatal.
      return _withWire((wire) async {
        await wire.skipToReady();
        await Future<void>.delayed(_testPing * 6);

        expect(
          wire.socket.closeCode,
          isNull,
          reason:
              'F-06: the socket was closed at twice the ping interval even '
              'though the client answered every ping',
        );
        expect(wire.wakeups.hasListener, isTrue);
        // Not merely unclosed — still carrying traffic. A socket that is open
        // and no longer serviced is the failure this whole file exists for.
        wire.heartbeats.add(null);
        expect(
          ProtocolFrame.decodeLine(await wire.next()),
          isA<HeartbeatFrame>(),
        );
      });
    });

    test('a peer that never answers the ping is still reclaimed', () async {
      // The pair, and the half that must not be lost to fix the half above. A
      // silent client is the peer whose host vanished: the connection is still
      // ESTABLISHED, nothing is wrong with it at the TCP level, and no close
      // frame is ever coming. Only the ping notices.
      final bound = await _bind(ping: _testPing);
      final silent = await _silentClient(bound.server.port);
      addTearDown(() async {
        await silent.close();
        await bound.dispose();
      });

      await _until(() => bound.wakeups.hasListener);
      await _until(
        () => !bound.wakeups.hasListener && !bound.heartbeats.hasListener,
      );
      // The close frame is written on its way out and arrives a moment after
      // the session is dropped, so this waits rather than reads once.
      await _until(() => silent.sawGoingAway);
    });

    test('with no ping that same peer is never noticed, which is the point', () {
      // The negative control for the two above: it is what shows the ping is
      // doing the work rather than something else in the handler. A hang-up is
      // now seen by the read loop with or without a ping, so the control has to
      // be the peer that never hangs up — which is exactly the case the ping
      // was added for.
      return _withBound((bound) async {
        final silent = await _silentClient(bound.server.port);
        addTearDown(silent.close);
        await _until(() => bound.wakeups.hasListener);

        // Well past the two intervals the test above is reclaimed in, with
        // traffic flowing the whole time: every send into the abandoned peer
        // succeeds, because nothing is wrong with the connection.
        for (var i = 0; i < 20; i++) {
          bound.heartbeats.add(null);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          bound.wakeups.hasListener,
          isTrue,
          reason:
              'a route built with no ping must still leak: if this fails the '
              'reclaim above is being caused by something other than the '
              'ping, and that test no longer proves what it claims',
        );
        expect(bound.heartbeats.hasListener, isTrue);
        expect(silent.closed, isFalse);
      }, ping: null);
    });
  });

  group('the back channel', () {
    // Finding F-05, which was the same unread socket as F-06 seen from the
    // other side: `HandleWebSocket.execute()` awaits `runHandler(onConnect)`
    // to completion before it calls `listenToMessages()`, so on a socket whose
    // connect handler streamed forever no inbound message was ever serviced.
    // The connect handler now completes at once, so the read loop runs
    // alongside the push — and that is a fact about the transport, not a
    // steer: nothing in sproutd interprets a client message yet, which is
    // Phase 7's work.
    test('an inbound message is serviced while the server is pushing', () {
      return _withWire((wire) async {
        await wire.skipToReady();
        expect(wire.handlerCalls, 1, reason: 'the connect, and nothing else');

        wire.socket.add(utf8.encode('{"steer":"not yet"}'));
        await _until(
          () => wire.handlerCalls > 1,
          timeout: const Duration(seconds: 5),
        );

        // Serviced *while* pushing: the socket is still the one streaming.
        wire.heartbeats.add(null);
        expect(
          ProtocolFrame.decodeLine(await wire.next()),
          isA<HeartbeatFrame>(),
        );
      });
    });

    test('and it does not open a second snapshot-and-watch', () {
      // revali registers one closure as both `onConnect` and `onMessage`, so
      // without the session guard in `attachTreeSocket` every client message
      // would replay the whole protocol down the same socket.
      return _withWire((wire) async {
        await wire.skipToReady();
        wire.socket
          ..add(utf8.encode('{"steer":"one"}'))
          ..add(utf8.encode('{"steer":"two"}'));
        await _until(() => wire.handlerCalls >= 3);

        wire.heartbeats.add(null);
        expect(
          ProtocolFrame.decodeLine(await wire.next()),
          isA<HeartbeatFrame>(),
          reason: 'the next frame must be the beat, not a second snapshot',
        );
        expect(
          wire.received.where((line) => line.contains('"$snapshotFrameType"')),
          hasLength(1),
        );
        expect(
          wire.received.where((line) => line.contains('"ready"')),
          hasLength(1),
        );
      });
    });
  });

  group('the wire format', () {
    late _Wire wire;
    tearDown(() => wire.close());

    test('is NDJSON, one frame per LINE, with no envelope', () async {
      // `sprout watch --json` writes exactly these lines. A `{"data": …}`
      // wrapper — Revali's default for a Map return — would mean the two
      // surfaces need two decoders for one protocol.
      //
      // Per line and not per message: `_Wire` cuts at the newline the
      // transport now writes, and `a frame larger than one chunk` is what
      // proves the two are different things.
      wire = await _serve();
      final first = await wire.next();
      expect(first, isNot(contains('"data":')));
      expect(jsonDecode(first), isA<Map<String, Object?>>());

      wire.heartbeats.add(null);
      final beat = await wire.next();
      // `encodeLine()` carries no trailing newline and neither does a line
      // `_Wire` has cut, so the round trip is byte-for-byte. The delimiter
      // belongs to the transport, not to the encoder: putting it in
      // `encodeLine` would make `sprout watch --json` — which writes these
      // with `writeln` — emit a blank line between every frame.
      expect(ProtocolFrame.decodeLine(beat).encodeLine(), beat);
    });

    test('every frame ends with a newline, so a consumer can split', () async {
      // The delimiter itself, asserted at the byte level rather than inferred
      // from `_Wire` having produced frames. `pendingBytes` is what a client
      // is still holding: zero after a frame means the frame was terminated,
      // not merely started.
      wire = await _serve();
      await wire.skipToReady();
      wire.heartbeats.add(null);
      await wire.next();
      await _until(() => wire.pendingBytes == 0);
      expect(
        wire.pendingBytes,
        0,
        reason: 'a frame the transport finished leaves nothing buffered',
      );
    });

    test('a frame larger than one chunk still arrives whole', () async {
      // **The test that was missing, and its absence is why F-09 survived two
      // phases.** Every other frame these tests build is under a kilobyte, so
      // reading one message as one frame worked by luck.
      //
      // `dart:convert`'s utf8 encoder flushes a 1024-byte buffer, so a frame
      // past that is chopped into several WebSocket messages before it ever
      // reaches `webSocket.add`. The newline does not stop that and is not
      // supposed to: what it does is make the pieces reassemblable. So this
      // asserts BOTH halves — that the frame really was split (otherwise the
      // test proves nothing), and that splitting on `\n` recovered it whole,
      // byte for byte, including the frames on either side of it.
      const filler = 'lorem ipsum dolor sit amet — a payload that will not fit';
      final long = List.generate(80, (i) => '$i:$filler').join(' ');
      wire = await _serve(
        seed: (store) => store.putNode(
          SproutNode(
            id: 'big',
            project: '/p',
            status: NodeStatus.working,
            currentTask: long,
          ),
        ),
      );

      final snapshot = await wire.next();
      expect(
        snapshot.length,
        greaterThan(daemonChunkBytes),
        reason: 'the point of this test is a frame past one encoder buffer',
      );
      expect(
        wire.messages,
        greaterThan(1),
        reason: 'and it must really have been chopped, or nothing is proved',
      );
      expect(wire.largestMessage, lessThanOrEqualTo(daemonChunkBytes));

      // Recovered whole: the long task survives, and the frame round-trips.
      final frame = ProtocolFrame.decodeLine(snapshot) as SnapshotFrame;
      expect(frame.snapshot.nodes.single.node.currentTask, long);
      expect(frame.encodeLine(), snapshot);

      // And the stream did not lose its place: the frames after the big one
      // are still whole, which is what a missing delimiter would break.
      expect(ProtocolFrame.decodeLine(await wire.next()), isA<ReadyFrame>());
      wire.heartbeats.add(null);
      expect(
        ProtocolFrame.decodeLine(await wire.next()),
        isA<HeartbeatFrame>(),
      );
      expect(wire.pendingBytes, 0);
    });

    test('a splitter that swallows everything is not a reader', () {
      // The paired negative (INV8). Newline-splitting makes reassembly easy,
      // and the easy mistake is a reader that treats every line it cannot
      // parse as nothing at all — which renders an empty tree and looks
      // healthy. A complete line that is not a frame must still throw.
      expect(
        () => ProtocolFrame.decodeLine('{"type":"delta"'),
        throwsA(isA<Object>()),
        reason: 'truncated JSON is not an empty frame',
      );
      expect(
        () => ProtocolFrame.decodeLine('not json at all'),
        throwsA(isA<Object>()),
      );
      expect(
        () => ProtocolFrame.decodeLine('{"type":"nonsense"}'),
        throwsA(isA<ProtocolFormatException>()),
        reason: 'well-formed JSON that is not a frame is still a failure',
      );
    });

    test('carries the snapshot fields that must survive compression', () async {
      wire = await _serve(
        seed: (store) => store.putNode(
          const SproutNode(id: 'a', project: '/p', status: NodeStatus.working),
        ),
      );
      final snapshot = jsonDecode(await wire.next()) as Map<String, Object?>;
      // `journal_unreadable` is present and false rather than absent: a
      // snapshot that silently omitted what it could not read is the INV8
      // failure this phase exists to prevent.
      expect(snapshot.containsKey('journal_unreadable'), isTrue);
      expect(snapshot['journal_unreadable'], isNull);
      expect(snapshot.containsKey('resources'), isTrue);
      final node = (snapshot['nodes'] as List).single as Map<String, Object?>;
      // Absence is transmitted as null and never estimated; the CLI is what
      // renders it as NONE SCHEDULED and `since ?`.
      expect(node.containsKey('next_checkin'), isTrue);
      expect(node['next_checkin'], isNull);
      expect(node['since'], isNull);
    });

    test('the decoded picture carries the tree, not just the frame type', () {
      // The empty-store case above proves the frame decodes; this proves the
      // *contents* survive the wire, which is what a client actually renders.
      // A node held, a resource with its holder, and a spend nobody reported.
      return _withWire(
        seed: (store) => store.putNode(
          SproutNode(
            id: 'a',
            project: '/p',
            role: 'crawler',
            status: NodeStatus.working,
            currentTask: 'building the thing',
            since: DateTime.utc(2026, 3, 4, 4, 54),
          ),
        ),
        (wire) async {
          await _until(() => wire.received.isNotEmpty);
          final frame =
              ProtocolFrame.decodeLine(wire.received.first) as SnapshotFrame;
          final node = frame.snapshot.nodes.single;
          expect(node.node.id, 'a');
          expect(node.node.role, 'crawler');
          expect(node.node.status, NodeStatus.working);
          expect(node.node.currentTask, 'building the thing');
          expect(node.node.since, DateTime.utc(2026, 3, 4, 4, 54));
          expect(node.node.nextCheckin, isNull);
          // Nobody reported dollars, and that stays `spend ?` rather than
          // becoming `\$0.0000` on the way through the decoder.
          expect(node.spend.isUnknown, isTrue);
          expect(node.spend.label, 'spend ?');
          expect(node.spend.nodes, 1);
          // A working node holds its project directory, with its holder.
          expect(frame.snapshot.resources.single.name, '/p');
          expect(frame.snapshot.resources.single.holder, 'a');
          expect(frame.snapshot.isJournalUnreadable, isFalse);
          // And the picture re-encodes to the bytes it arrived as.
          expect(frame.encodeLine(), wire.received.first);
        },
      );
    });

    test('every line this socket sends is a ProtocolFrame, the first '
        'included', () {
      // F-04, stated as the assertion that closes it: one decoder for the
      // whole stream, with no branch on `type` before it can start. The first
      // line is the picture, and it decodes into the `SproutSnapshot`
      // `lib/snapshot.dart` owns rather than a map the consumer must pick
      // apart itself.
      return _withWire((wire) async {
        wire.heartbeats.add(null);
        await _until(() => wire.received.length >= 3);
        final opening = ProtocolFrame.decodeLine(wire.received.first);
        expect(opening, isA<SnapshotFrame>());
        expect((opening as SnapshotFrame).snapshot.nodes, isEmpty);
        // The picture's cursor is the frame's, so the deltas that follow
        // resume from where it was taken.
        expect(opening.cursor, opening.snapshot.cursor);
        // ...and it is emphatically not the end of replay: the `ready` after
        // it is.
        expect(opening.marksEndOfReplay, isFalse);
        for (final line in wire.received.skip(1)) {
          expect(() => ProtocolFrame.decodeLine(line), returnsNormally);
        }
        // The paired negative: a decoder that took anything would pass the
        // loop above without discriminating (INV8).
        expect(
          () => ProtocolFrame.decodeLine(
            '{"type":"nonsense","cursor":"s1.0123456789abcdef.9"}',
          ),
          throwsA(isA<ProtocolFormatException>()),
        );
      });
    });
  });

  group('the generated shape', () {
    // The route under test is hand-built above; this is what keeps it honest
    // against what `revali build` actually emits. The generated tree is
    // git-ignored, so a clean checkout skips the comparison — and the two
    // assertions that do not need it run either way.
    // `__api_tree_route.dart` and not `__tree_route.dart`: revali names the
    // file after the controller's path, and P3-03 moved `api` out of the app
    // prefix and into `@Controller(treeControllerPath)` so the UI could answer
    // at `/`. The rename matters here because a path that no longer exists
    // does not fail this group — it SKIPS it, and a drift check that quietly
    // stops running is worse than one that was never written.
    final generated = File('.revali/server/routes/__api_tree_route.dart');

    test('the controller asks for a two-way, connect-triggered socket', () {
      final source = File('routes/controllers/tree_controller.dart')
          .readAsStringSync();
      expect(
        source,
        contains('mode: WebSocketMode.twoWay'),
        reason:
            'revali 3.3.2 createWebSocketHandler registers onConnect only when '
            'triggerOnConnect is true or the mode cannot receive, so twoWay '
            'without it runs nothing on connect',
      );
      expect(source, contains('triggerOnConnect: true'));
      expect(
        source,
        isNot(contains('mode: WebSocketMode.sendOnly')),
        reason:
            'sendOnly makes execute() close the socket as soon as the connect '
            "stream completes — P1-06's defect",
      );
      expect(RegExp(r'^\s*@SSE\b', multiLine: true).hasMatch(source), isFalse);
    });

    test('the handler returns a Stream that is already done', () {
      // Both halves matter and they pull in opposite directions. The return
      // type has to be a `Stream` because that is what revali derives the
      // injected `AsyncWebSocketSender`'s type argument from and what keeps
      // the route a WebSocketRoute — and the stream has to be *empty*, because
      // `execute()` awaits `runHandler(onConnect)` before it calls
      // `listenToMessages()`, the only `webSocket.listen` in the package. A
      // handler that streams for the life of the session leaves the socket
      // unread for the life of the session, which is F-05 and F-06 both.
      final source = File('routes/controllers/tree_controller.dart')
          .readAsStringSync();
      expect(source, contains('Stream<StringContent> events('));
      expect(
        source,
        contains('const Stream<StringContent>.empty()'),
        reason:
            'F-06: if the connect handler streams again, nothing reads the '
            'socket, no pong is ever processed, and every client is closed '
            'with 1001 at twice the ping interval whether it answers or not',
      );
    });

    test('revali build agrees, when it has been run', () {
      if (!generated.existsSync()) {
        markTestSkipped(
          '.revali/ is git-ignored; run `dart run revali build` to check the '
          'generated shape against the route this file builds by hand',
        );
        return;
      }
      final source = generated.readAsStringSync();
      expect(source, contains('mode: WebSocketMode.twoWay'));
      expect(source, contains('onConnect:'));
      // The four parameters revali resolves by type. The sender's type
      // argument is the handler's whole return type and not its element type
      // (`_createAsyncWebSocketSender` reads `returnType.nonAsyncType`, which
      // strips `Future` and not `Stream`), so a signature written the obvious
      // way emits code that does not compile — this is what catches that.
      expect(source, contains('context.data,'));
      expect(source, contains("expectedType: 'CleanUp'"));
      expect(
        source,
        contains('AsyncWebSocketSenderImpl<Stream<StringContent>>'),
      );
      expect(source, contains('context.close,'));
      // StringContent.toJson() is the raw String, which is what puts NDJSON on
      // the wire instead of a {"data": …} envelope.
      expect(source, contains("yield* result.map((e) => e.toJson())"));
      expect(source, contains("queryParameters['since']"));
    });

    test('the ping the annotation asks for reaches the generated route', () {
      // The assertion F-03 is closed by, and the reason `PingDuration` exists.
      // revali_construct 3.0.0 reads the annotated ping as
      // `getField('_duration')` — the private name Duration stored its
      // microseconds under before the SDK made the value public — so a plain
      // `Duration` yields null, `create_child_route.dart:48` emits no `ping`
      // argument, and `revali build` succeeds with no warning at all. That
      // silence is the whole hazard: the socket is then never read and never
      // pinged, so no disconnect is ever noticed.
      //
      // This is a source-text assertion because that is where the failure
      // lives. Nothing about a running socket distinguishes "the ping is set"
      // from "the ping was dropped" until a client hangs up, which is exactly
      // how it shipped unnoticed.
      final source = File('routes/controllers/tree_controller.dart')
          .readAsStringSync();
      expect(source, contains('ping: socketPingInterval'));
      if (!generated.existsSync()) {
        markTestSkipped(
          'run `dart run revali build`: the drop this pins is invisible '
          'without the generated route to read',
        );
        return;
      }
      final emitted = generated.readAsStringSync();
      expect(
        emitted,
        contains('ping:'),
        reason:
            'revali emitted no ping at all — the annotation was accepted and '
            'discarded, which is F-03 exactly. Check that socketPingInterval '
            'is still a PingDuration and that PingDuration still declares the '
            '_duration field revali_construct reads.',
      );
      // Not merely present, but the interval actually asked for: revali emits
      // `Duration(microseconds: n)` from `ping.inMicroseconds`, so a ping that
      // arrived truncated or zeroed would satisfy `contains('ping:')` and
      // still never fire.
      expect(
        emitted,
        contains(
          'ping: Duration(microseconds: '
          '${socketPingInterval.inMicroseconds})',
        ),
        reason:
            'the generated ping must be socketPingInterval to the microsecond',
      );
    });

    test('the ping constant is an ordinary Duration to everything else', () {
      // `PingDuration` overrides `inMicroseconds` to return the private field
      // the generator reads, so the two copies of the value cannot drift: if
      // they ever did, the socket would be pinged at one interval while every
      // reader here reported another.
      expect(socketPingInterval, isA<Duration>());
      expect(socketPingInterval, const Duration(seconds: 15));
      expect(socketPingInterval.inMicroseconds, 15 * 1000 * 1000);
      expect(socketPingInterval.inSeconds, 15);
    });
  });
}

/// Polls [condition] until it holds, or fails the test after [timeout].
///
/// Used only where the thing being waited on is genuinely asynchronous plumbing
/// (a socket close travelling back through the router). The clock the protocol
/// runs on is injected, never slept on.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not hold within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Opens a file-backed store in a temp directory and hands both to [body].
///
/// File-backed rather than in-memory because the instance derivation
/// fingerprints the **absolute path** along with the feed, and an in-memory
/// store has no path to fingerprint — it reports a per-connection `memory:<n>`
/// instead, which two processes could never agree on.
Future<void> _withStore(
  Future<void> Function(SproutStore store, String path) body,
) async {
  final tmp = Directory.systemTemp.createTempSync('sprout_ws');
  final path = p.absolute(p.join(tmp.path, 'sprout.db'));
  final store = SproutStore.open(path: path);
  try {
    await body(store, path);
  } finally {
    store.close();
    tmp.deleteSync(recursive: true);
  }
}

/// Binds a server with no client, runs [body] against it, and tears it down.
Future<void> _withBound(
  Future<void> Function(_Bound bound) body, {
  Duration? ping = _testPing,
}) async {
  final bound = await _bind(ping: ping);
  try {
    await body(bound);
  } finally {
    await bound.dispose();
  }
}

/// Serves one socket, runs [body] against it, and always tears it down.
Future<void> _withWire(
  Future<void> Function(_Wire wire) body, {
  Duration? ping = _testPing,
  void Function(SproutStore store)? seed,
}) async {
  final wire = await _serve(ping: ping, seed: seed);
  try {
    await body(wire);
  } finally {
    await wire.close();
  }
}

/// Binds a real loopback server carrying the tree socket and connects to it.
///
/// The route is the one `revali build` emits for
/// `@WebSocket('events', mode: WebSocketMode.twoWay, triggerOnConnect: true)`
/// over a `Stream<StringContent>`: `WebSocketRoute` in `twoWay` mode with the
/// same closure registered as both `onConnect` and `onMessage`, each
/// `yield*`-ing the handler's stream mapped through `StringContent.toJson()`.
/// See the `generated shape` group.
Future<_Bound> _bind({
  SproutStore? store,
  void Function(SproutStore store)? seed,
  Duration? ping = _testPing,
}) async {
  final owned = store == null;
  final db = store ?? SproutStore.memory();
  seed?.call(db);

  // The daemon's own derivation, not a generated id: this is what makes the
  // socket under test the one the compiled daemon serves, and it is what the
  // `agree on an instance id` group joins against.
  final instance = daemonInstanceFor(db);
  final wakeups = StreamController<void>();
  final heartbeats = StreamController<void>();
  final shutdown = Completer<String>();
  final signals = WatchSignals(
    wakeups: wakeups.stream,
    heartbeats: heartbeats.stream,
    shutdown: shutdown.future,
  );

  // Mirrors the generated call verbatim, injected parameters included: revali
  // resolves `Data`, `CleanUp`, `AsyncWebSocketSender` and `CloseWebSocket`
  // off the context by type (`create_param_arg.dart`,
  // `create_web_socket_handler.dart`), and maps the handler's own stream
  // through `StringContent.toJson()` whether it carries anything or not — and
  // it now carries nothing, which is the whole of the F-06 fix.
  var calls = 0;
  Stream<String> handle(WebSocketContext context) {
    calls++;
    return attachTreeSocket(
      store: db,
      instance: instance,
      since: context.request.queryParameters['since'] as String?,
      signals: signals,
      data: context.data,
      cleanUp: context.data.get<CleanUp>()!,
      sender: AsyncWebSocketSenderImpl<Stream<StringContent>>(
        (data) => context.asyncSender.send(data.map((e) => e.toJson())),
      ),
      close: context.close,
    ).map((e) => e.toJson());
  }

  final router = Router(
    routes: [
      Route(
        'api',
        routes: [
          Route(
            'tree',
            routes: [
              WebSocketRoute(
                'events',
                mode: WebSocketMode.twoWay,
                // Shortened from `socketPingInterval` so the disconnect
                // test is seconds rather than a minute. The ping is not a test
                // convenience: without one the session is never torn down at
                // all, because nothing reads the socket while the connect
                // handler is still streaming. That the real annotation now
                // puts a ping here too is what the `generated shape` group
                // checks — this route is hand-built, so it cannot see it.
                ping: ping,
                handler: (context) async => WebSocketHandler(
                  onConnect: (context) async* {
                    yield* handle(context);
                  },
                  onMessage: (context) async* {
                    yield* handle(context);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  // 127.0.0.1 literally, never 'localhost': the generated `_bindServer` maps
  // exactly that string to InternetAddress.anyIPv6, which is every interface.
  final server = await HttpServer.bind('127.0.0.1', 0);
  unawaited(handleRouterRequests(server, router, router.close));

  return _Bound(
    server: server,
    store: db,
    ownsStore: owned,
    instance: instance,
    wakeups: wakeups,
    heartbeats: heartbeats,
    shutdown: shutdown,
    handlerCalls: () => calls,
  );
}

/// A bound server with no client attached to it.
///
/// Split out of [_serve] because the two ping tests need a client `dart:io`
/// cannot be: one that completes the handshake and then never answers a ping.
final class _Bound {
  _Bound({
    required this.server,
    required this.store,
    required this.ownsStore,
    required this.instance,
    required this.wakeups,
    required this.heartbeats,
    required this.shutdown,
    required this.handlerCalls,
  });

  final HttpServer server;
  final SproutStore store;
  final bool ownsStore;
  final SproutInstance instance;
  final StreamController<void> wakeups;
  final StreamController<void> heartbeats;
  final Completer<String> shutdown;

  /// How many times the route handler has been invoked on this server.
  ///
  /// revali registers one closure as both `onConnect` and `onMessage`, so this
  /// counts connects *and* inbound messages — which is what makes it able to
  /// say whether an inbound message was serviced at all (F-05) and whether a
  /// second one opened a second watch (it must not).
  final int Function() handlerCalls;

  /// Releases everything [_bind] created. Safe to call twice.
  Future<void> dispose() async {
    await server.close(force: true);
    // NOT awaited. A single-subscription `StreamController.close()` completes
    // only once a listener has taken the done event, and on the refusal path
    // the watch session never subscribes to either signal — so awaiting these
    // hangs forever, which surfaces as an unexplained tearDown timeout that
    // hides the assertion the test was actually making.
    unawaited(wakeups.close());
    unawaited(heartbeats.close());
    if (ownsStore) store.close();
  }
}

/// Binds a server and connects a real `dart:io` client to it.
Future<_Wire> _serve({
  SproutStore? store,
  void Function(SproutStore store)? seed,
  Object? since,
  Duration? ping = _testPing,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final bound = await _bind(store: store, seed: seed, ping: ping);

  final sinceValue = switch (since) {
    final String value => value,
    final String Function(SproutInstance) build => build(bound.instance),
    _ => null,
  };
  final query = sinceValue == null
      ? ''
      : '?since=${Uri.encodeQueryComponent(sinceValue)}';
  final socket = await WebSocket.connect(
    'ws://127.0.0.1:${bound.server.port}/api/tree/events$query',
  );

  return _Wire(bound: bound, socket: socket, timeout: timeout);
}

/// A client that completes the handshake by hand and then never answers a ping.
///
/// `dart:io`'s `WebSocket` answers a ping automatically as soon as anything
/// listens to it, which is the live peer the fix is *for* and the opposite of
/// what the reclaim test needs. This one reads every byte the server sends and
/// replies to none of it: the connection stays ESTABLISHED, nothing is wrong
/// with it at the TCP level, and only an unanswered ping can tell it apart
/// from a client that is simply quiet.
Future<_Silent> _silentClient(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final client = _Silent(socket);
  socket.write(
    'GET /api/tree/events HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: ${base64.encode(List<int>.generate(16, (i) => i))}\r\n'
    'Sec-WebSocket-Version: 13\r\n\r\n',
  );
  await socket.flush();
  await _until(() => client.handshook, timeout: const Duration(seconds: 5));
  return client;
}

/// The bytes a [_silentClient] has been sent, and nothing else.
final class _Silent {
  _Silent(this.socket) {
    socket.listen(_bytes.addAll, onDone: () => closed = true);
  }

  final Socket socket;
  final List<int> _bytes = [];

  /// True once the server has hung the connection up.
  bool closed = false;

  /// True once the 101 came back, so a later assertion is about the socket
  /// rather than about a handshake that never happened.
  bool get handshook =>
      utf8.decode(_bytes, allowMalformed: true).startsWith('HTTP/1.1 101');

  /// True once a close frame with code 1001 has arrived.
  ///
  /// Matched as raw bytes because there is no client library here: `0x88` is
  /// FIN + opcode 8, `0x02` is a two-byte unmasked payload — a code and no
  /// reason, which is what `dart:io` sends when a pong does not come back —
  /// and `0x03E9` is 1001, `goingAway`.
  bool get sawGoingAway {
    for (var i = 0; i + 3 < _bytes.length; i++) {
      if (_bytes[i] == 0x88 &&
          _bytes[i + 1] == 0x02 &&
          _bytes[i + 2] == 0x03 &&
          _bytes[i + 3] == 0xE9) {
        return true;
      }
    }
    return false;
  }

  Future<void> close() async {
    socket.destroy();
  }
}

/// One connected client and everything the test needs to drive it.
///
/// **It reassembles, because a real consumer has to.** This used to treat each
/// WebSocket message as one frame, and every test passed because every frame
/// these tests build is smaller than the 1024-byte chunk `dart:convert`'s utf8
/// encoder flushes at — which is exactly the blind spot that let finding F-09
/// live through two phases. It now does what a browser must: append every
/// message's bytes to one buffer and cut at each `\n`. So `received` holds
/// whole frames whatever the daemon's chunking did, and
/// `a frame larger than one chunk` below proves it on a payload big enough to
/// be split.
///
/// It buffers rather than decoding per message on purpose: a partial line at
/// the end of a message is normal and must wait, while a *complete* line that
/// is not JSON is a real protocol break — see
/// `a splitter that swallows everything is not a reader`.
final class _Wire {
  _Wire({required this.bound, required this.socket, required this.timeout}) {
    _subscription = socket.listen(
      (message) {
        // Every message arrives as a BINARY frame, never text:
        // `HandleWebSocket.sendResponse` reads `response.body.read()`, which is
        // a `Stream<List<int>>` in `BodyImpl` whatever the payload type was,
        // and hands those chunks to `webSocket.add`. Asserted rather than
        // assumed, because a browser client has to set `binaryType` and decode
        // for itself — Phase 3 inherits this.
        expect(message, isA<List<int>>());
        final bytes = message as List<int>;
        messages++;
        if (bytes.length > largestMessage) largestMessage = bytes.length;
        _feed(bytes);
        _serve();
      },
      onDone: () {
        _closed = true;
        _serve();
      },
    );
  }

  final _Bound bound;
  final WebSocket socket;
  final Duration timeout;

  HttpServer get server => bound.server;
  SproutStore get store => bound.store;
  SproutInstance get instance => bound.instance;
  StreamController<void> get wakeups => bound.wakeups;
  StreamController<void> get heartbeats => bound.heartbeats;
  Completer<String> get shutdown => bound.shutdown;

  /// See [_Bound.handlerCalls].
  int get handlerCalls => bound.handlerCalls();

  /// Every whole frame the client has read, in order, without its newline.
  ///
  /// Frames, not messages: see the note on this class. The delimiter is
  /// stripped so these compare equal to `ProtocolFrame.encodeLine()`, which is
  /// what the CLI writes and what every assertion here is phrased against.
  final List<String> received = [];

  /// How many WebSocket messages arrived, whatever they carried.
  ///
  /// Kept beside [received] because the two differing is the finding: a frame
  /// can span messages and small frames can share one.
  int messages = 0;

  /// The largest single message, in bytes. Never exceeds 1024 in practice.
  int largestMessage = 0;

  late final StreamSubscription<dynamic> _subscription;
  final List<Completer<String>> _waiting = [];
  final List<int> _buffer = [];
  int _taken = 0;
  bool _closed = false;
  bool _disposed = false;

  /// Bytes not yet followed by a newline — a frame still arriving.
  int get pendingBytes => _buffer.length;

  /// Buffers [bytes] and completes every whole line they finish.
  ///
  /// A line that is not a JSON object is thrown rather than skipped: a
  /// splitter that quietly drops what it cannot read reports a quiet tree,
  /// which is INV8 and the failure this protocol exists to remove.
  void _feed(List<int> bytes) {
    _buffer.addAll(bytes);
    var cut = _buffer.indexOf(0x0A);
    while (cut != -1) {
      final line = utf8.decode(_buffer.sublist(0, cut));
      _buffer.removeRange(0, cut + 1);
      if (line.isNotEmpty) {
        expect(
          jsonDecode(line),
          isA<Map<String, Object?>>(),
          reason: 'a delimited line must be one whole frame: $line',
        );
        received.add(line);
      }
      cut = _buffer.indexOf(0x0A);
    }
  }

  /// The next message, or a test failure if the socket closes or goes quiet.
  ///
  /// It never returns a placeholder: "the frame did not arrive" and "a frame
  /// arrived that says nothing" are different observations, and a helper that
  /// folded them together would let a dead socket pass.
  Future<String> next() {
    if (_taken < received.length) return Future.value(received[_taken++]);
    if (_closed) {
      return Future.error(
        StateError('the socket closed with no further frames'),
      );
    }
    final completer = Completer<String>();
    _waiting.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw StateError('no frame arrived within $timeout'),
    );
  }

  /// Reads through the opening snapshot and the `ready`.
  Future<void> skipToReady() async {
    expect(
      (jsonDecode(await next()) as Map<String, Object?>)['type'],
      snapshotFrameType,
    );
    expect(ProtocolFrame.decodeLine(await next()), isA<ReadyFrame>());
  }

  /// Waits for the server to actually close the socket.
  Future<void> expectClosed() async {
    await _until(() => _closed, timeout: timeout);
    expect(socket.closeCode, isNotNull);
  }

  void _serve() {
    while (_waiting.isNotEmpty && _taken < received.length) {
      _waiting.removeAt(0).complete(received[_taken++]);
    }
    if (_closed) {
      for (final completer in _waiting) {
        completer.completeError(
          StateError('the socket closed with no further frames'),
        );
      }
      _waiting.clear();
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    // Close the socket first and do NOT cancel the subscription: cancelling a
    // `dart:io` WebSocket's subscription and then awaiting `close()` leaves the
    // close future uncompleted when the server has already closed, and a
    // tearDown that hangs shows up as an unexplained test timeout that hides
    // whatever the test actually asserted.
    await socket.close();
    unawaited(_subscription.cancel());
    await bound.dispose();
  }
}
