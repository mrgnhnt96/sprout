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
      final snapshot = jsonDecode(await wire.next()) as Map<String, Object?>;
      expect(snapshot['type'], snapshotFrameType);
      expect(snapshot['nodes'], isEmpty);

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

    test('nothing notices a hang-up without a ping, and that is the leak', () {
      // The paired negative, and the reason the ping above matters. With no
      // ping the socket is never read while the connect handler is streaming,
      // so a client that hung up two seconds ago is indistinguishable from one
      // that is simply quiet — and the session, its 15s heartbeat and its
      // 250ms poll stay alive. This is what the generated route does TODAY,
      // because revali drops the ping the annotation asks for.
      return _withWire((wire) async {
        await wire.skipToReady();
        await wire.socket.close();
        // The same loop the test above tears down in, with the ping taken
        // away and nothing else changed: heartbeats keep being sent into a
        // socket whose peer left, and every one of them succeeds.
        for (var i = 0; i < 20; i++) {
          wire.heartbeats.add(null);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          wire.wakeups.hasListener,
          isTrue,
          reason:
              'FIXME(P2-05 finding): if this now fails, disconnects are being '
              'noticed and the per-client leak is gone — delete this test',
        );
        expect(wire.heartbeats.hasListener, isTrue);
      }, ping: null);
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

  group('the wire format', () {
    late _Wire wire;
    tearDown(() => wire.close());

    test('is NDJSON, one frame per message, with no envelope', () async {
      // `sprout watch --json` writes exactly these lines. A `{"data": …}`
      // wrapper — Revali's default for a Map return — would mean the two
      // surfaces need two decoders for one protocol.
      wire = await _serve();
      final first = await wire.next();
      expect(first, isNot(contains('"data":')));
      expect(jsonDecode(first), isA<Map<String, Object?>>());

      wire.heartbeats.add(null);
      final beat = await wire.next();
      expect(ProtocolFrame.decodeLine(beat).encodeLine(), beat);
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

    test('the snapshot frame is not a ProtocolFrame, and the rest are', () {
      // Paired, because "it decodes" and "it does not" are the two halves of
      // one finding: `lib/protocol.dart` has no `SnapshotFrame`, so a consumer
      // needs one branch before it can use one decoder. Named in
      // `snapshotFrameType`; the fix belongs in that library, not here.
      return _withWire((wire) async {
        wire.heartbeats.add(null);
        await _until(() => wire.received.length >= 3);
        expect(
          () => ProtocolFrame.decodeLine(wire.received.first),
          throwsA(isA<ProtocolFormatException>()),
        );
        for (final line in wire.received.skip(1)) {
          expect(() => ProtocolFrame.decodeLine(line), returnsNormally);
        }
      });
    });
  });

  group('the generated shape', () {
    // The route under test is hand-built above; this is what keeps it honest
    // against what `revali build` actually emits. The generated tree is
    // git-ignored, so a clean checkout skips the comparison — and the two
    // assertions that do not need it run either way.
    final generated = File('.revali/server/routes/__tree_route.dart');

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

    test('the handler returns a Stream, which is what keeps it open', () {
      final source = File('routes/controllers/tree_controller.dart')
          .readAsStringSync();
      expect(source, contains('Stream<StringContent> events('));
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
      // StringContent.toJson() is the raw String, which is what puts NDJSON on
      // the wire instead of a {"data": …} envelope.
      expect(source, contains("yield* result.map((e) => e.toJson())"));
      expect(source, contains("queryParameters['since']"));
    });

    test('and revali DROPS the ping the annotation asks for', () {
      // A pinned defect, not a preference. `WebSocketAnnotation.fromAnnotation`
      // (revali_construct 3.0.0) reads Duration's private `_duration` field,
      // which Dart 3.13.2 does not have — it declares the public
      // `inMicroseconds` — so the ping never reaches the route and the
      // generated socket has no disconnect detection at all. Nothing warns.
      final source = File('routes/controllers/tree_controller.dart')
          .readAsStringSync();
      expect(source, contains('ping: socketPingInterval'));
      if (!generated.existsSync()) {
        markTestSkipped('run `dart run revali build` to check the drop');
        return;
      }
      expect(
        generated.readAsStringSync(),
        isNot(contains('ping:')),
        reason:
            'if this now passes the ping through, revali has been fixed: drop '
            'this test and assert the ping is present instead',
      );
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

/// Serves one socket, runs [body] against it, and always tears it down.
Future<void> _withWire(
  Future<void> Function(_Wire wire) body, {
  Duration? ping = _testPing,
}) async {
  final wire = await _serve(ping: ping);
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
Future<_Wire> _serve({
  SproutStore? store,
  void Function(SproutStore store)? seed,
  Object? since,
  Duration? ping = _testPing,
  Duration timeout = const Duration(seconds: 10),
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

  Stream<String> handle(WebSocketContext context) => treeSocketFrames(
    store: db,
    instance: instance,
    since: context.request.queryParameters['since'] as String?,
    signals: signals,
  ).map((frame) => StringContent(jsonEncode(frame)).toJson());

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
                // Shortened from `socketPingInterval` so the disconnect test
                // is seconds rather than a minute, and passed straight to
                // `WebSocketRoute` because the annotation's ping is dropped by
                // revali (see the `generated shape` group). The ping is not a
                // test convenience: without one the session is never torn down
                // at all, because nothing reads the socket while the connect
                // handler is still streaming.
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

  final sinceValue = switch (since) {
    final String value => value,
    final String Function(SproutInstance) build => build(instance),
    _ => null,
  };
  final query = sinceValue == null
      ? ''
      : '?since=${Uri.encodeQueryComponent(sinceValue)}';
  final socket = await WebSocket.connect(
    'ws://127.0.0.1:${server.port}/api/tree/events$query',
  );

  return _Wire(
    server: server,
    socket: socket,
    store: db,
    ownsStore: owned,
    instance: instance,
    wakeups: wakeups,
    heartbeats: heartbeats,
    shutdown: shutdown,
    timeout: timeout,
  );
}

/// One connected client and everything the test needs to drive it.
final class _Wire {
  _Wire({
    required this.server,
    required this.socket,
    required this.store,
    required this.ownsStore,
    required this.instance,
    required this.wakeups,
    required this.heartbeats,
    required this.shutdown,
    required this.timeout,
  }) {
    _subscription = socket.listen(
      (message) {
        // Every message arrives as a BINARY frame, never text:
        // `HandleWebSocket.sendResponse` reads `response.body.read()`, which is
        // a `Stream<List<int>>` in `BodyImpl` whatever the payload type was,
        // and hands those chunks to `webSocket.add`. Asserted rather than
        // assumed, because a browser client has to set `binaryType` and decode
        // for itself — Phase 3 inherits this.
        expect(message, isA<List<int>>());
        received.add(utf8.decode(message as List<int>));
        _serve();
      },
      onDone: () {
        _closed = true;
        _serve();
      },
    );
  }

  final HttpServer server;
  final WebSocket socket;
  final SproutStore store;
  final bool ownsStore;
  final SproutInstance instance;
  final StreamController<void> wakeups;
  final StreamController<void> heartbeats;
  final Completer<String> shutdown;
  final Duration timeout;

  /// Every message the client has received, in order.
  final List<String> received = [];

  late final StreamSubscription<dynamic> _subscription;
  final List<Completer<String>> _waiting = [];
  int _taken = 0;
  bool _closed = false;
  bool _disposed = false;

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
