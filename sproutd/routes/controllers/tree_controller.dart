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
/// **Not decoration, and — on this toolchain — not yet in effect.** While
/// `runHandler(onConnect)` is streaming, `HandleWebSocket.execute()` has not
/// reached `listenToMessages()`, so *nobody reads the socket*: an inbound
/// close frame is never processed, `closeCode` stays null, and
/// `webSocket.add` keeps succeeding into a peer that has gone. A ping is the
/// only thing that notices. Measured on a real loopback socket with the same
/// handler: with no ping the watch session was still subscribed to its signals
/// twelve seconds after the client hung up and would have stayed that way; at
/// `ping: 1s` it was torn down in 2219ms, at `500ms` in 1213ms.
///
/// The annotation below asks for it and **revali silently drops it**:
/// `WebSocketAnnotation.fromAnnotation` (revali_construct 3.0.0) reads
/// `Duration`'s private `_duration` field, which Dart 3.13.2 does not have —
/// `lib/core/duration.dart` declares the public `inMicroseconds` instead — so
/// the read yields null and `create_child_route.dart:48` emits no `ping`
/// argument. `revali build` succeeds with no warning. Passing the same
/// `Duration` straight to `WebSocketRoute(ping: …)` works, so only the
/// annotation path is broken.
///
/// The consequence, stated plainly because it is a Phase 3 blocker: **every
/// client that hangs up leaks a watch session and its two timers, and nothing
/// reclaims them.** `test/ws_test.dart` pins both halves — that the teardown
/// works when the transport reports the disconnect, and that nothing reports
/// it through the generated route today.
const Duration socketPingInterval = Duration(seconds: 15);

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
    instance: daemonInstance,
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
        instance: daemonInstance,
        since: since,
      ).map((frame) => StringContent(jsonEncode(frame)));
}

/// The instance this daemon hands out cursors from.
///
/// **This is a known defect, kept visible on purpose.** It is
/// `SproutInstance.current`, which is *generated per process*, so a cursor a
/// user took from `sprout snapshot` is refused by this socket as foreign every
/// single time — the two processes never agree on an id, and the join the
/// cursor exists to protect is therefore broken between the CLI and the
/// daemon.
///
/// The fix is not to compute an id here. `bin/sprout.dart`'s `instanceOf`
/// already derives a stable one from the absolute database path plus the
/// identity of the feed's first event, and forking a second derivation that
/// happens to agree today is the bug rather than the repair — two independent
/// hashes that must stay equal will drift. The honest fix is lifting that
/// derivation into `lib/protocol.dart` as `SproutInstance.forStore(...)` and
/// calling it from both `bin/` and here. That is a file this leaf does not
/// own, so it is reported rather than done, and `test/ws_test.dart` pins the
/// current behaviour — a CLI-minted cursor is refused, with the CLI's own
/// words — so the day it is fixed the test says so instead of staying quiet.
SproutInstance get daemonInstance => SproutInstance.current;

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
