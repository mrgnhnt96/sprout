import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_protocol/snapshot.dart';

/// The root of sprout's web UI.
///
/// Still a placeholder shell — P3-03 serves this payload from sproutd and
/// P3-04 attaches it to the `watch` WebSocket and draws the tree. What it
/// carries already is [ProtocolFrame], read from
/// `package:sprout_protocol/protocol.dart`: **the same declarations sproutd
/// encodes with**, compiled a second time for the browser rather than
/// described a second time in this package. Two derivations of one wire format
/// that must stay equal is what finding F-01 was, and two of them in two
/// packages would be worse — they agree on the day they are written and no
/// test compares them.
///
/// That import is also the whole of what finding F-07 made impossible.
/// `package:sproutd/protocol.dart` reached `dart:io` and `dart:ffi` through
/// `store.dart`, and build_web_compilers refuses an entrypoint on its
/// transitive *library import graph* — silently, with `jaspr build` still
/// exiting 0 and writing no bundle. `test/payload_test.dart` is what makes a
/// regression of that loud again.
class App extends StatelessComponent {
  const App({this.frame, super.key});

  /// The most recent frame off the `watch` stream, or null before one arrives.
  ///
  /// Null is the honest state and not an empty snapshot: a tree that has not
  /// been fetched and a tree with nothing in it must not render the same
  /// (INV8), and [describe] keeps them apart.
  final ProtocolFrame? frame;

  /// The status line for [frame].
  ///
  /// An exhaustive `switch` over the sealed frame type, which is the reason
  /// [ProtocolFrame] is sealed: adding a frame becomes a compile error here
  /// rather than a line falling through a default branch into nothing.
  static String describe(ProtocolFrame? frame) => switch (frame) {
    null => 'The UI payload is served. No daemon is attached yet.',
    SnapshotFrame(:final snapshot) =>
      '${snapshot.nodes.length} nodes at ${snapshot.cursor.encode()}',
    ReadyFrame(:final cursor) => 'Replay complete at ${cursor.encode()}.',
    HeartbeatFrame(:final sentAt) => 'Alive at ${formatClock(sentAt)}.',
    DeltaFrame(:final events) => '${events.length} events.',
    ByeFrame(:final reason, :final detail) =>
      'The stream ended: ${reason.wire}${detail == null ? '' : ' - $detail'}',
  };

  @override
  Component build(BuildContext context) {
    return div(classes: 'sprout-shell', [
      // `Component.text` rather than the top-level `text()` helper: the
      // latter is deprecated in jaspr 0.23.4 and `dart analyze --fatal-infos`
      // rejects it. `jaspr create` still scaffolds the deprecated form.
      h1([Component.text('sprout')]),
      p(classes: 'sprout-status', [Component.text(describe(frame))]),
    ]);
  }

  /// Rendered to `main.css` at build time by the `@css` builder, which is why
  /// the payload has a stylesheet without the package shipping one.
  @css
  static List<StyleRule> get styles => [
    css('.sprout-shell', [
      css('&').styles(
        display: .flex,
        height: 100.vh,
        flexDirection: .column,
        justifyContent: .center,
        alignItems: .center,
        fontFamily: const FontFamily.list([
          FontFamily('ui-monospace'),
          FontFamily('monospace'),
        ]),
      ),
      css('h1').styles(margin: Margin.zero, fontSize: 2.rem),
      css('.sprout-status').styles(opacity: 0.6),
    ]),
  ];
}
