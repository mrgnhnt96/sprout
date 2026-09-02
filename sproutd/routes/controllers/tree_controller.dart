/// The observation protocol on the wire: one long-lived WebSocket that opens
/// with a `snapshot` and then behaves exactly as `sprout watch --since`.
///
/// This is Phase 2's transport (`docs/01-plan.md` §11). It says over a socket
/// the same things `bin/sprout.dart` says on a terminal, in the same order and
/// with the same words, because two surfaces that disagree about the protocol
/// are a bug in the protocol rather than a difference in taste. In particular
/// a `--since` cursor from another sproutd is refused here with the text
/// `CursorFromAnotherInstance.reason` produces, and the frame that carries the
/// refusal is the one `ByeFrame.refusing` builds — there is no second refusal
/// message anywhere in this package.
///
/// `@WebSocket` and never `@SSE`: Revali's SSE emits `application/octet-stream`
/// with `content-disposition: attachment` and no `data:` framing, and a
/// content-type override inside the handler is ignored, so a browser
/// `EventSource` cannot consume it (`docs/research/05-dart-stack.md`).
///
/// Only `revali_router` is imported. `revali_server` is not a package in
/// revali 3.x but a construct built into `revali` itself, and the published
/// package of that name cannot co-resolve with `revali_router 5.1.1`. The
/// annotations arrive through `revali_router`'s re-export of
/// `revali_annotations`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:revali_router/revali_router.dart';
import 'package:sproutd/protocol.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watch.dart';

/// The `type` the opening frame carries.
///
/// A snapshot is not a [ProtocolFrame]: `lib/protocol.dart` has `ready`,
/// `heartbeat`, `bye` and `delta` and no `snapshot`, so
/// `ProtocolFrame.fromJson` **throws `unknown frame type`** on this one. A
/// consumer of this socket therefore branches on `type == snapshotFrameType`
/// first and decodes everything else with `ProtocolFrame.decodeLine`.
///
/// That split is a real seam and it is named here rather than smoothed over:
/// adding a `SnapshotFrame` to `lib/protocol.dart` would let a consumer use
/// one decoder for the whole stream, and it belongs in that library rather
/// than in a controller. See `test/ws_test.dart`, which asserts both halves —
/// that every other frame this socket sends round-trips through
/// `ProtocolFrame.decodeLine`, and that this one does not.
const String snapshotFrameType = 'snapshot';

/// The close reason used when the stream said everything it had to say.
///
/// The socket is closed from inside the handler by throwing
/// [CloseWebSocketException], which `HandleWebSocket.runHandler` catches and
/// turns into a real close frame (`revali_router 5.1.1`,
/// `lib/src/router/handle_web_socket.dart`). Without it a two-way socket falls
/// through to `listenToMessages()` and sits open *after* it has said `bye`,
/// which is precisely the "a stream that simply stops did not end, it broke"
/// ambiguity `bye` exists to remove.
const String socketClosedReasonPrefix = 'sprout: ';

/// How often the socket asks its peer whether it is still there.
///
/// **It reclaims the peer that vanished without hanging up.** A client that
/// closes its connection is now noticed by the read loop
/// `HandleWebSocket.listenToMessages()` runs — see [TreeController.events]
/// for why that loop is reachable at all — but a peer whose host disappeared
/// leaves the connection ESTABLISHED with nothing ever arriving on it, and
/// only an unanswered ping tells that apart from a client that is merely
/// quiet. `dart:io` closes such a socket with 1001 after two intervals, which
/// unwinds the handler and cancels both signals with it. Without the ping
/// **that client leaks a watch session, its 15s heartbeat and its 250ms
/// poll** and nothing ever reclaims them; `test/ws_test.dart` pins both the
/// leak and the reclaim.
///
/// **A pong has to be able to cancel it, and for a while none could.**
/// `dart:io` pauses the socket's protocol subscription the moment it is
/// created and resumes it only when something listens to the `WebSocket`
/// (`websocket_impl.dart`: `subscription.pause()`, and
/// `_controller.onListen = subscription.resume`). A pong that is never
/// delivered cannot reset the timer, so while the connect handler streamed —
/// the one thing that keeps `listenToMessages()` out of reach — *every*
/// socket was closed at twice this interval whether or not the client
/// answered. That was finding F-06. Measured out of process against the
/// compiled binary run from `/`, two clients in one run: before, a client
/// sending well-formed masked pongs was closed 1001 at +30.0s exactly like a
/// silent one; after, it is still carrying frames at +45.0s while the silent
/// one is still closed at +30.0s.
///
/// The type is the fix for a different dependency bug, and it is a workaround
/// rather than a design: see [PingDuration].
const PingDuration socketPingInterval = PingDuration(seconds: 15);

/// A [Duration] that survives `revali build`.
///
/// This type exists for one reason: to be found by a code generator that is
/// looking for a field the SDK renamed. `WebSocketAnnotation.fromAnnotation`
/// (`revali_construct 3.0.0`, `lib/models/web_socket_annotation.dart:29`)
/// reads the annotated ping as `pingRaw.getField('_duration')` — the private
/// name `Duration` stored its microseconds under before the SDK made the
/// value public. That is the *only* read path in the factory; there is no
/// fallback to `inMicroseconds`. So a plain `Duration` yields null and the
/// ping is dropped.
///
/// A subclass that declares `_duration` itself gives that read something to
/// find, and the analyzer resolves a field against the object's own class
/// before walking to `(super)`. Nothing about the runtime changes: revali
/// re-materialises the value as a plain `Duration(microseconds: …)` when it
/// emits the route (`revali 3.3.2`,
/// `lib/server/makers/creators/create_child_route.dart:48`), so what reaches
/// `WebSocketRoute` is an ordinary `Duration` and this class never appears in
/// the generated server at all.
///
/// **This is a workaround for a bug in a dependency, not a modelling
/// decision.** The upstream fix is two lines in that factory — read
/// `inMicroseconds` first and keep `_duration` as a fallback, so the
/// annotation resolves on either SDK — and it was verified here by building
/// against a patched `revali_construct` with a plain `Duration`. When a
/// revali carrying that fix is pinned in `pubspec.yaml`, delete this class
/// and make [socketPingInterval] a plain `Duration` again. `test/ws_test.dart`
/// asserts the ping reaches the generated route, so that deletion is checked
/// rather than remembered.
final class PingDuration extends Duration {
  /// A ping of [seconds], stored twice on purpose.
  ///
  /// `super` sets the SDK's `inMicroseconds`, which is what every consumer
  /// reads at runtime, and [_duration] is the same number under the name the
  /// generator asks for. [inMicroseconds] is overridden to return [_duration]
  /// so the two cannot drift apart and the field is not dead weight.
  const PingDuration({required super.seconds})
    : _duration = seconds * Duration.microsecondsPerSecond;

  /// The microseconds, under the name `revali_construct` reads.
  final int _duration;

  @override
  int get inMicroseconds => _duration;
}

/// Serves the tree: a snapshot over HTTP, and snapshot-then-watch over a
/// socket.
@Controller('tree')
class TreeController {
  /// Takes the store from DI. Constructed once at startup, not per request
  /// (`.revali/server/definitions/__routes.dart` holds one instance).
  const TreeController(this._store);

  final SproutStore _store;

  /// `GET /api/tree` — the whole world at one cursor.
  ///
  /// The same `takeSnapshot` the socket's opening frame uses, so the two
  /// surfaces cannot drift into two different pictures. Revali wraps a map
  /// return in `{"data": …}`, so the body is `{"data": {"cursor": …}}`.
  @Get()
  Map<String, Object?> snapshot() => takeSnapshot(
    StoreSnapshotSource(_store),
    instance: daemonInstanceFor(_store),
  ).toJson();

  /// `ws://…/api/tree/events[?since=<cursor>]` — the long-lived socket.
  ///
  /// **Two-way, triggered on connect, and it returns a stream that is already
  /// done.** The empty stream is the load-bearing part of this method and it
  /// is not an oversight. `HandleWebSocket.execute()` awaits
  /// `runHandler(onConnect)` to completion *before* it calls
  /// `listenToMessages()`, and `listenToMessages()` is the only place in
  /// `revali_router 5.1.1` that ever listens to the `WebSocket`. A connect
  /// handler that streams for the life of the session therefore leaves the
  /// socket unread for the life of the session — which is what F-05 and F-06
  /// both were, one unread socket seen from two sides. Completing at once
  /// lets the read loop start; the frames go out through [AsyncWebSocketSender]
  /// instead, which `HandleWebSocket` wires to the same `sendResponse` the
  /// yielded ones went through, so nothing about the wire format changes.
  ///
  /// `triggerOnConnect` is still required: revali 3.3.2's
  /// `createWebSocketHandler` registers `onConnect` only when it is true *or*
  /// the mode cannot receive, so a plain `twoWay` socket would run nothing at
  /// all when a client attaches. `WebSocketMode.sendOnly` — what P1-06
  /// shipped — is still wrong for a second reason now: it makes `execute()`
  /// skip `listenToMessages()` entirely and close with 1000.
  ///
  /// The injected parameters are all resolved by `revali`'s generator from
  /// their types (`create_param_arg.dart`, `create_web_socket_handler.dart`):
  /// [sender] pushes frames, [close] ends the socket after the `bye`,
  /// [cleanUp] drops the watch session when the request context closes, and
  /// [data] is what makes an `onMessage` re-entry a no-op — revali registers
  /// this same method as both callbacks, so without the guard every inbound
  /// client message would open a second snapshot-and-watch on one socket.
  /// Reading those messages is Phase 7's steer; what changes here is that the
  /// channel carrying them is serviced at all.
  @WebSocket.ping(
    ping: socketPingInterval,
    path: 'events',
    mode: WebSocketMode.twoWay,
    triggerOnConnect: true,
  )
  Stream<StringContent> events(
    @Query('since') String? since,
    Data data,
    CleanUp cleanUp,
    AsyncWebSocketSender<Stream<StringContent>> sender,
    CloseWebSocket close,
  ) => attachTreeSocket(
    store: _store,
    instance: daemonInstanceFor(_store),
    since: since,
    data: data,
    cleanUp: cleanUp,
    sender: sender,
    close: close,
  );
}

/// The instance this daemon hands out cursors from.
///
/// **The same id `sprout snapshot` mints against the same database**, because
/// this is the same call: the derivation is `SproutInstance.forFeed` in
/// `lib/protocol.dart` and no id is computed here. That is the point rather
/// than a tidiness — an id computed here would be a second hash that has to
/// stay equal to the CLI's, and two hashes that must agree is the bug rather
/// than the repair. This function is plumbing; `bin/sprout.dart`'s
/// `instanceForStore` is the identical one line.
///
/// It used to be `SproutInstance.current`, generated per process, and that was
/// finding F-01: a cursor a user copied out of `sprout snapshot` was refused
/// by this socket as foreign every single time, so the join the whole protocol
/// exists to protect was broken between the two surfaces sprout ships.
/// `test/ws_test.dart` now asserts the acceptance, paired with a cursor from a
/// genuinely different database that is still refused.
///
/// Derived per call, never cached at startup. While the feed is empty the id
/// is the empty-feed one and it changes when the first event lands; a daemon
/// that captured it at boot would disagree with the CLI for as long as it
/// stayed up, which is the failure this whole change removes.
SproutInstance daemonInstanceFor(SproutStore store) => SproutInstance.forFeed(
  databasePath: store.databasePath,
  firstEvent: store.firstEvent,
);

/// The opening frame: a whole snapshot, tagged so a consumer can tell it from
/// the [ProtocolFrame]s that follow.
Map<String, Object?> snapshotFrameJson(SproutSnapshot snapshot) => {
  'type': snapshotFrameType,
  ...snapshot.toJson(),
};

/// The socket's frames: a `snapshot`, then `watch --since` in full.
///
/// In order: one [snapshotFrameJson], then the replay of everything after
/// [since], one `ready`, then live `delta`s, a `heartbeat` on a fixed interval
/// whether or not the tree is busy, and a `bye` with a reason. Every one of
/// those exists because a producer that has stopped working and a quiet one
/// emit the same bytes — none (INV8) — and the argument for each is on
/// `lib/watch.dart`.
///
/// **A refused `--since` sends no snapshot.** The stream is then exactly one
/// `bye`, the same as `sprout watch --since <foreign>` on a terminal: the
/// consumer asked to resume and was told it cannot, and answering a refusal
/// with a picture it did not ask for would make the two surfaces disagree
/// about what a refusal *is*. The refusal frame itself is built by
/// `watchFrames`, which is the only place in this package that builds one.
///
/// **Not `async*`.** A consumer that hangs up on an idle tree would not finish
/// cancelling an `async*` generator suspended over its signals until those
/// signals next ticked (dart-lang/sdk#26686), leaving the watch session and
/// its heartbeat timer alive — invisible per disconnect, fatal after a day up.
/// Here cancellation is a subscription cancel, so the teardown is immediate
/// and `test/ws_test.dart` can assert it rather than assume it.
///
/// The stream ends by *throwing* [CloseWebSocketException] rather than simply
/// completing, so the socket is really closed after the `bye`. See
/// [socketClosedReasonPrefix].
///
/// [signals] is injected only by tests, which drive fake time instead of
/// sleeping; production takes [WatchSignals.live].
Stream<Map<String, Object?>> treeSocketFrames({
  required SproutStore store,
  required SproutInstance instance,
  String? since,
  WatchSignals? signals,
  DateTime Function()? now,
}) {
  late final StreamController<Map<String, Object?>> out;
  StreamSubscription<ProtocolFrame>? watching;

  void start() {
    // The gate is asked here only to decide whether a picture is owed, never
    // to phrase a refusal: `watchFrames` emits the one `bye` a refused
    // consumer gets, carrying the refusal's own words and this daemon's
    // position.
    final refused = since != null && instance.accept(since) is CursorRefused;
    if (!refused) {
      try {
        out.add(
          snapshotFrameJson(
            takeSnapshot(
              StoreSnapshotSource(store),
              instance: instance,
              now: now,
            ),
          ),
        );
      } on Object catch (error) {
        // A snapshot that cannot be taken is not a degraded snapshot, so the
        // consumer is told the stream broke and where this daemon stood —
        // not handed an exception it has no cursor to recover from. A feed
        // that cannot be read is *not* this branch: `takeSnapshot` reports
        // that inside the picture as `journal_unreadable`, which is the whole
        // point of the field.
        out
          ..add(
            ByeFrame(
              cursor: instance.cursorAt(0),
              reason: ByeReason.error,
              detail: 'the snapshot could not be taken: $error',
            ).toJson(),
          )
          ..addError(
            const CloseWebSocketException(
              1000,
              '${socketClosedReasonPrefix}error',
            ),
          );
        unawaited(out.close());
        return;
      }
    }

    var closeReason = '${socketClosedReasonPrefix}done';
    watching =
        watchFrames(
          source: StoreWatchSource(store),
          signals: signals ?? WatchSignals.live(),
          since: since,
          instance: instance,
          now: now,
        ).listen(
          (frame) {
            if (frame case ByeFrame(:final reason)) {
              closeReason = '$socketClosedReasonPrefix${reason.wire}';
            }
            out.add(frame.toJson());
          },
          onDone: () {
            out.addError(CloseWebSocketException(1000, closeReason));
            unawaited(out.close());
          },
        );
  }

  out = StreamController<Map<String, Object?>>(
    onListen: start,
    onCancel: () async {
      // Reached both when the client hangs up and when the handler breaks out
      // of its `await for` after a failed send. Dropping the watch session
      // here is what drops its heartbeat and poll timers.
      final subscription = watching;
      watching = null;
      await subscription?.cancel();
    },
  );
  return out.stream;
}

/// Starts the socket's frames on [sender] and returns a stream that is already
/// done.
///
/// The two halves are deliberate. The **returned stream** is what
/// `HandleWebSocket.runHandler(onConnect)` awaits, and it completes at once so
/// that `execute()` reaches `listenToMessages()` — the only `webSocket.listen`
/// in `revali_router 5.1.1`, and therefore the only thing that un-pauses
/// `dart:io`'s protocol subscription so an inbound **pong** is processed at
/// all. The **frames** go out through [sender], which reaches the same
/// `HandleWebSocket.sendResponse` a yielded frame did.
///
/// Order is preserved across the two: `sendResponse` queues on one
/// `SequentialExecutor`, and each `send` reaches that queue after the same
/// single microtask hop, so sends are enqueued in the order they were made.
/// `test/ws_test.dart` asserts the resulting frame order over a real socket
/// rather than leaving that to reasoning.
///
/// [data] carries the session for the life of the socket, which is what makes
/// a second call — revali registers this handler as `onMessage` too — return
/// an empty stream instead of opening a second watch. [cleanUp] runs when the
/// request context closes, which is after `execute()` has returned and the
/// socket is really gone.
///
/// [signals] and [now] are injected only by tests, exactly as in
/// [treeSocketFrames].
Stream<StringContent> attachTreeSocket({
  required SproutStore store,
  required SproutInstance instance,
  required Data data,
  required CleanUp cleanUp,
  required AsyncWebSocketSender<Stream<StringContent>> sender,
  required CloseWebSocket close,
  String? since,
  WatchSignals? signals,
  DateTime Function()? now,
}) {
  // An inbound message, not a new connection. Answering it with a second
  // snapshot-and-watch on the same socket is the failure this guards.
  if (data.has<TreeSocketSession>()) {
    return const Stream<StringContent>.empty();
  }

  final session = TreeSocketSession(sender: sender, close: close);
  data.add<TreeSocketSession>(session);
  cleanUp.add(session.stop);
  session.pump(
    treeSocketFrames(
      store: store,
      instance: instance,
      since: since,
      signals: signals,
      now: now,
    ),
  );

  return const Stream<StringContent>.empty();
}

/// One attached client: the subscription that produces its frames, and the
/// close that ends it.
///
/// Held in the request's [Data] so the socket has exactly one of these however
/// many times revali invokes the handler, and cancelled from the request's
/// [CleanUp] so the watch session, its heartbeat and its poll go away with the
/// connection rather than outliving it.
final class TreeSocketSession {
  /// Pushes through [sender] and ends through [close].
  TreeSocketSession({required this.sender, required this.close});

  /// Where a frame goes, one single-element stream at a time.
  ///
  /// The type argument is the handler's whole return type rather than its
  /// element type, because that is what `revali` derives it from
  /// (`create_web_socket_handler.dart`'s `_createAsyncWebSocketSender` reads
  /// `returnType.nonAsyncType`, which strips `Future` and not `Stream`). The
  /// generated adapter maps it through `StringContent.toJson()` exactly as it
  /// maps a yielded frame, so `revali_router` sees a `Stream<String>`,
  /// `StreamBodyData.read()` encodes it with `utf8.encoder` — one output
  /// chunk per element — and one frame is still one WebSocket message. The
  /// wire format is asserted in `test/ws_test.dart`, not assumed here.
  final AsyncWebSocketSender<Stream<StringContent>> sender;

  /// How the socket is ended once the stream has said its last word.
  final CloseWebSocket close;

  StreamSubscription<Map<String, Object?>>? _frames;
  bool _closed = false;

  /// Subscribes to [frames] and sends each one.
  ///
  /// [treeSocketFrames] ends by *erroring* with a [CloseWebSocketException]
  /// carrying the code and the reason, which is how the close survives now
  /// that `runHandler` is no longer the thing catching it. The `bye` that
  /// precedes it is already enqueued when this runs: the send was made from
  /// the previous `onData`, and a stream controller schedules the next event
  /// only after that callback returns, so `HandleWebSocket.close` finds a
  /// `sending` future to await rather than closing over the top of it.
  void pump(Stream<Map<String, Object?>> frames) {
    _frames = frames.listen(
      (frame) => sender.send(Stream.value(StringContent(jsonEncode(frame)))),
      onError: (Object error, StackTrace stackTrace) {
        if (error case CloseWebSocketException(:final code, :final reason)) {
          _end(code, reason);
        } else {
          _end(1011, '${socketClosedReasonPrefix}error');
        }
      },
      onDone: () => _end(1000, '${socketClosedReasonPrefix}done'),
    );
  }

  /// Cancels the frames, and with them the watch session and both its timers.
  void stop() {
    final subscription = _frames;
    _frames = null;
    unawaited(subscription?.cancel());
  }

  void _end(int code, String reason) {
    // `onError` is followed by `onDone`, and both mean "closed"; the second
    // one must not close a socket a later client already owns.
    if (_closed) return;
    _closed = true;
    // `CloseWebSocket.close` is declared `void` on the interface even though
    // `CloseWebSocketImpl` returns a future, so there is nothing to await:
    // `HandleWebSocket.close` awaits the in-flight send itself.
    close.close(code, reason);
  }
}
