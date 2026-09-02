/// The browser end of `ws://…/api/tree/events`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:sprout_protocol/protocol.dart';
import 'package:universal_web/web.dart';

import 'frame_reader.dart';

/// The socket's path on the daemon, unchanged since Phase 2.
///
/// `api` is part of `TreeController`'s own path rather than an app prefix —
/// `AppConfig.prefix` wraps every controller route, so a prefixed app could
/// not answer at `/` and serve this page at all (P3-03). The URL did not move.
const String eventsPath = '/api/tree/events';

/// The socket URL for the page's own origin.
///
/// Derived from [Location] rather than configured, so the page and the stream
/// cannot be pointed at two different daemons: the UI is served out of the
/// same binary that serves this socket (P3-03), so the page's origin **is**
/// the daemon. `wss` when the page is `https`, because a browser refuses a
/// plaintext socket from a secure page and would fail with no frame to render.
String eventsUrlFor(Location location) {
  final scheme = location.protocol == 'https:' ? 'wss' : 'ws';
  return '$scheme://${location.host}$eventsPath';
}

/// A live attachment to the tree.
///
/// **It attaches once, with no `since`, and never re-snapshots.** That is the
/// whole model (`docs/01-plan.md` §7): the socket opens with the picture and
/// every later change arrives as a delta against it. Re-snapshotting to stay
/// current would hide precisely the defects that made deltas sufficient — F-01
/// (a cursor from one surface refused by the other) and F-02 (subagent
/// creation not reaching the feed).
///
/// **There is no reconnect timer here, deliberately.** The daemon pings every
/// 15 seconds and closes a socket whose peer does not answer; a browser answers
/// pings itself, in the engine, with nothing asked of this code. F-06 was that
/// mechanism going wrong — every socket was closed at 30 seconds whether or not
/// the client answered — and it is fixed. A client-side timer added on top
/// would fight a working mechanism and hide it breaking again.
class TreeSocket {
  /// Opens [url] and starts decoding.
  TreeSocket(this._socket) {
    // **Every message arrives as a binary frame, never text.**
    // `HandleWebSocket.sendResponse` reads `response.body.read()`, which is a
    // `Stream<List<int>>` in `BodyImpl` whatever the payload was, and hands
    // those chunks to `webSocket.add`. Without this the browser delivers a
    // `Blob`, which is asynchronous to read and arrives out of order. Recorded
    // by P2-05 in `docs/02-open-findings.md` at the cost of real time.
    _socket.binaryType = 'arraybuffer';
    _socket.onmessage = ((MessageEvent event) {
      final data = event.data;
      if (!data.isA<JSArrayBuffer>()) {
        _fail('the socket delivered a non-binary message');
        return;
      }
      _read((data as JSArrayBuffer).toDart.asUint8List());
    }).toJS;
    _socket.onclose = ((CloseEvent event) {
      // A close is not a `bye`. The `bye` frame, if one arrived, is already in
      // the stream and says why; this only reports that the connection is
      // gone, which is the case the protocol calls "a stream that simply
      // stopped".
      _closed = true;
      unawaited(_frames.close());
    }).toJS;
    _socket.onerror = ((Event event) {
      _fail('the socket reported an error');
    }).toJS;
  }

  /// Opens the tree socket for the page's own origin.
  factory TreeSocket.attach(Location location) =>
      TreeSocket(WebSocket(eventsUrlFor(location)));

  final WebSocket _socket;
  final FrameReader _reader = FrameReader();
  final StreamController<ProtocolFrame> _frames =
      StreamController<ProtocolFrame>();
  bool _closed = false;

  /// Every frame, in the order the daemon sent it.
  ///
  /// Errors on the stream are real: a frame that could not be decoded, or a
  /// byte stream that is not frames at all. They are not swallowed, because a
  /// consumer that quietly ignored what it could not read would show a stale
  /// tree and never say why.
  Stream<ProtocolFrame> get frames => _frames.stream;

  /// Hangs up.
  void close() {
    if (_closed) return;
    _closed = true;
    _socket.close();
  }

  void _read(Uint8List bytes) {
    try {
      for (final frame in _reader.add(bytes)) {
        _frames.add(frame);
      }
    } on ProtocolFormatException catch (error) {
      _fail('$error');
    } on WireFormatException catch (error) {
      _fail('$error');
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _frames.addError(StateError(message));
  }
}
