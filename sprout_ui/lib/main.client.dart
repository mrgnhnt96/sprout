/// The client entrypoint. `jaspr build` compiles this file, and only this
/// file, to `main.client.dart.js` — the single script `web/index.html` loads.
///
/// Nothing here runs on a server. Client mode emits a static payload with no
/// run-time Dart at all, which is what lets P3-03 embed the whole UI in the
/// sproutd binary as byte constants (`docs/01-plan.md` §13).
library;

import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:sprout_protocol/protocol.dart';
import 'package:universal_web/web.dart' show window;

import 'app.dart';
import 'src/live_tree.dart';
import 'src/tree_socket.dart';

void main() {
  runApp(const Board());
}

/// The one stateful thing in the UI: the socket, and the tree it advances.
///
/// Everything below it is a pure function of a [LiveTree], which is what makes
/// the board testable on a machine with no browser — see `test/board_test.dart`.
class Board extends StatefulComponent {
  /// Creates the board.
  const Board({super.key});

  @override
  State<Board> createState() => _BoardState();
}

class _BoardState extends State<Board> {
  LiveTree _tree = LiveTree.attaching;
  String? _error;
  TreeSocket? _socket;
  StreamSubscription<ProtocolFrame>? _frames;

  @override
  void initState() {
    super.initState();
    final socket = TreeSocket.attach(window.location);
    _socket = socket;
    _frames = socket.frames.listen(
      (frame) => setState(() {
        try {
          _tree = _tree.apply(frame);
        } on ProtocolFormatException catch (error) {
          // Shown, not swallowed. A board that quietly dropped an event it
          // could not read would freeze at the last frame it understood and
          // look exactly like a quiet tree (INV8).
          _error = '$error';
        }
      }),
      onError: (Object error) => setState(() => _error = '$error'),
      // No reconnect. The daemon's 15s ping is what reclaims a peer that
      // vanished, a browser answers it in the engine, and F-06 was that
      // mechanism going wrong. A timer here would fight a working one and hide
      // it breaking again. What the user gets instead is the reason the stream
      // ended, which `App.liveness` prints.
      onDone: () => setState(() {}),
    );
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    _socket?.close();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => App(tree: _tree, error: _error);
}
