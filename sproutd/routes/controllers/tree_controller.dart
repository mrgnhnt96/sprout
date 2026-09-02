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
/// **Not decoration — it is the only thing that ends a session.** While
/// `runHandler(onConnect)` is streaming, `HandleWebSocket.execute()` has not
/// reached `listenToMessages()`, so *nobody reads the socket*: an inbound
/// close frame is never processed, `closeCode` stays null, and
/// `webSocket.add` keeps succeeding into a peer that has gone. The ping is
/// timer-driven rather than read-driven, so it notices anyway: `dart:io`
/// closes the socket when a pong does not come back, which unwinds the
/// handler and cancels both signals with it. Without one, **every client that
/// hangs up leaks a watch session, its 15s heartbeat and its 250ms poll**, and
/// nothing ever reclaims them.
///
/// Measured out of process against the compiled binary, run from `/`, with a
/// client SIGKILLed so it sends a TCP FIN and no close frame: with no ping the
/// daemon still held the connection ESTABLISHED after 60s; with this ping it
/// closed the connection itself after 31s, one ping to discover the peer is
/// gone and one to time the missing pong out.
///
/// The type is the fix, and it is a workaround for a dependency bug rather
/// than a design: see [PingDuration].
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
  /// **Two-way, and triggered on connect.** revali 3.3.2's
  /// `createWebSocketHandler` registers `onConnect` only when
  /// `triggerOnConnect` is true *or* the mode cannot receive, so a plain
  /// `twoWay` socket would run nothing at all when a client attaches. And
  /// `WebSocketMode.sendOnly` — what P1-06 shipped — makes
  /// `HandleWebSocket.execute()` close the socket with 1000 the moment the
  /// connect handler's stream completes, which for a handler returning a
  /// single `Map` is immediately. Returning a `Stream` is what makes the
  /// socket long-lived; `twoWay` is what leaves Phase 7's back channel on the
  /// wire rather than off it.
  ///
  /// One caveat, measured rather than assumed, and it belongs to Phase 7:
  /// `execute()` awaits `runHandler(onConnect)` to completion *before*
  /// `listenToMessages()`, so while this stream is running no inbound client
  /// message is serviced. The mode is right and the channel is negotiated; a
  /// steer arriving on it needs a revali-side change, not a mode change here.
  @WebSocket.ping(
    ping: socketPingInterval,
    path: 'events',
    mode: WebSocketMode.twoWay,
    triggerOnConnect: true,
  )
  Stream<StringContent> events(@Query('since') String? since) =>
      treeSocketFrames(
        store: _store,
        instance: daemonInstanceFor(_store),
        since: since,
      ).map((frame) => StringContent(jsonEncode(frame)));
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
