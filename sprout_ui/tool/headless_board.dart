/// The board, driven off a real socket and printed instead of painted.
///
/// ```
/// dart run tool/headless_board.dart ws://127.0.0.1:8787/api/tree/events 40
/// ```
///
/// **This is not a substitute for looking at the page, and it does not claim
/// to be.** It exists because the machine this UI was built on has no browser:
/// what it exercises is the whole client except the paint — the same
/// [FrameReader] that reassembles the daemon's 1024-byte chunks, the same
/// [LiveTree] that folds deltas onto a snapshot, and the same `App.lines` the
/// rendered board is built from, all compiled into `main.client.dart.js` by
/// the very next build. The one substitution is `dart:io`'s WebSocket for the
/// browser's, because `lib/src/tree_socket.dart` is browser-only by
/// construction.
///
/// Its value is that it fails where a screenshot would: a frame the client
/// cannot read, a delta that changes nothing, a tree that stops advancing.
library;

import 'dart:async';
import 'dart:io';

import 'package:sprout_ui/app.dart';
import 'package:sprout_ui/src/frame_reader.dart';
import 'package:sprout_ui/src/live_tree.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: headless_board.dart <ws-url> <seconds>');
    exitCode = 64;
    return;
  }
  final socket = await WebSocket.connect(args[0]);
  final reader = FrameReader();
  var tree = LiveTree.attaching;
  var last = '';

  void draw(String why) {
    final board = App.lines(tree).join('\n');
    // Only when it CHANGED, so the output is the history of the board rather
    // than a log of frames — a delta that moved nothing is visible by its
    // absence here.
    if (board == last) return;
    last = board;
    stdout.writeln('\n--- after $why ---\n$board');
  }

  draw('nothing (before the socket said anything)');
  final done = Completer<void>();
  socket.listen(
    (Object? message) {
      for (final frame in reader.add(message as List<int>)) {
        tree = tree.apply(frame);
        draw(frame.type);
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await Future.any([
    done.future,
    Future<void>.delayed(Duration(seconds: int.parse(args[1]))),
  ]);
  await socket.close();
  stdout.writeln('\n=== FINAL BOARD ===\n${App.lines(tree).join('\n')}');
}
