import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sprout_protocol/protocol.dart';
import 'package:sprout_protocol/snapshot.dart';

import 'src/live_tree.dart';

/// The root of sprout's web UI: the live tree, as a board.
///
/// **A board, not a transcript** (`docs/00-vision.md` §4). One line per node,
/// no prose, no headings, no narration — `docs/01-plan.md` §8's output budget
/// applied at tree scope. If it does not fit on a phone screen it is wrong.
///
/// The lines are `SnapshotNode.render`, **the protocol's own rendering**, not
/// a second one written for HTML. That is deliberate and it is the same
/// argument the whole package is built on: `sprout snapshot` on a terminal and
/// this page in a browser print the same words about the same node because
/// there is one derivation, not two that agree on the day they were written.
/// What this file adds is presentation — a class per status so the board reads
/// at a glance — and presentation cannot drift from a value it does not
/// compute.
///
/// It carries [ProtocolFrame], read from
/// `package:sprout_protocol/protocol.dart`: **the same declarations sproutd
/// encodes with**, compiled a second time for the browser rather than
/// described a second time in this package. Two derivations of one wire format
/// that must stay equal is what finding F-01 was, and two of them in two
/// packages would be worse.
///
/// That import is also the whole of what finding F-07 made impossible.
/// `package:sproutd/protocol.dart` reached `dart:io` and `dart:ffi` through
/// `store.dart`, and build_web_compilers refuses an entrypoint on its
/// transitive *library import graph* — silently, with `jaspr build` still
/// exiting 0 and writing no bundle. `test/payload_test.dart` is what makes a
/// regression of that loud again.
class App extends StatelessComponent {
  /// Draws [tree].
  const App({this.tree = LiveTree.attaching, this.error, super.key});

  /// Everything this client knows, from one snapshot and every delta since.
  final LiveTree tree;

  /// What went wrong reading the stream, or null.
  ///
  /// Rendered rather than logged. A client that swallowed a decode failure
  /// would show a tree frozen at the last frame it understood and give no
  /// indication that it had stopped keeping up — a stale board that looks
  /// exactly like a quiet one, which is INV8.
  final String? error;

  /// The status line for [frame].
  ///
  /// An exhaustive `switch` over the sealed frame type, which is the reason
  /// [ProtocolFrame] is sealed: adding a frame becomes a compile error here
  /// rather than a line falling through a default branch into nothing.
  static String describe(ProtocolFrame? frame) => switch (frame) {
    null => 'not attached',
    SnapshotFrame(:final snapshot) => '${snapshot.nodes.length} nodes',
    // Never "ready", which would read as a verdict on the tree rather than on
    // the stream. `marksEndOfReplay` is true on this frame alone.
    ReadyFrame() => 'replay complete',
    HeartbeatFrame(:final sentAt) => 'alive ${formatClock(sentAt)}',
    DeltaFrame(:final events) => '${events.length} events',
    // The sweep's own count, never a verdict on it: "2 stalled" and "0
    // stalled" are both facts, and neither is "the tree is fine".
    WatchdogFrame(:final stalled, :final blind) =>
      'watchdog · ${stalled.length} stalled, ${blind.length} unmeasured',
    ByeFrame(:final reason, :final detail) =>
      'ended: ${reason.wire}${detail == null ? '' : ' — $detail'}',
  };

  /// The one line that says whether this board can be believed.
  ///
  /// Four states, and none of them is silence. Before the snapshot it says so;
  /// while the backlog runs it says so, because a half-replayed tree is not
  /// the tree; once live it prints the last heartbeat, which is the only thing
  /// that tells a quiet stream from a dead one (INV8); and when the stream has
  /// ended it prints the reason the `bye` carried, because *"a stream that
  /// simply stops did not end, it broke."*
  static String liveness(LiveTree tree) {
    final bye = tree.ended;
    if (bye != null) {
      final detail = bye.detail;
      return 'STREAM ENDED · ${bye.reason.wire}'
          '${detail == null ? '' : ' · $detail'}';
    }
    if (!tree.isAttached) return 'ATTACHING · no snapshot yet';
    if (!tree.replayComplete) return 'REPLAYING · backlog still arriving';
    final beat = tree.lastHeartbeat;
    return 'LIVE · heartbeat '
        '${beat == null ? unknownValueText : formatClock(beat)}';
  }

  /// The one line that says what the daemon's watchdog last established.
  ///
  /// **There is deliberately no green "watchdog OK".** What this prints is
  /// [WatchdogFrame.why] — the daemon's own sentence, the same one appended to
  /// the NDJSON journal — because that sentence already says what a sweep
  /// actually established and refuses to overstate it. A blind sweep reads
  /// *"not one of the 2 node(s) could be measured, so this sweep establishes
  /// nothing about any of them"*, and no reading of that is health. An
  /// indicator that went green there would rebuild the exact failure §1 was
  /// written about: *"a run sat inert for six hours with the Stop gate,
  /// watchdog, and limit gate all reporting healthy."*
  ///
  /// Three states and none of them is silence: no sweep yet, a sweep that
  /// could not look, and a sweep that could. The last two are told apart by
  /// the leading word as well as by the sentence, because a person scanning a
  /// board reads the first token.
  static String watchdog(LiveTree tree) {
    final sweep = tree.lastSweep;
    if (sweep == null) return 'WATCHDOG · $noSweepYetText';
    final at = formatClock(sweep.sweptAt);
    if (sweep.failure case final failure?) {
      return 'WATCHDOG COULD NOT LOOK · $at · $failure · ${sweep.why}';
    }
    return 'WATCHDOG · $at · ${sweep.why}';
  }

  /// The line the board shows under a node the watchdog is contradicting.
  static String stallLine(StalledNode node) =>
      'STALLED · ${node.nodeId} · ${node.liveness} · ${node.because} '
      '(ring ${node.consecutiveRings}${node.silenced ? ', at the ring cap and '
                'silenced — still stalled' : ''})';

  /// The line the board shows for a node the watchdog could not measure.
  static String blindLine(UnmeasuredNode node) =>
      'UNMEASURED · ${node.nodeId} · ${node.because} · not a stall and NOT '
      'health: the watchdog could not look';

  /// Every line of the board, in order, as text.
  ///
  /// Separated from [build] so the whole rendering is testable on the VM —
  /// there is no browser on the machine this was written on, and a board
  /// asserted only through a component tree would be asserted nowhere.
  static List<String> lines(LiveTree tree) {
    final at = tree.asOf;
    return [
      'cursor ${tree.cursor?.encode() ?? unknownValueText}',
      liveness(tree),
      watchdog(tree),
      if (tree.isAttached && tree.nodes.isEmpty && tree.strangers.isEmpty)
        noNodesText,
      // `asOf` is null only before any frame, and `nodes` is empty then, so
      // this never renders an age against a made-up instant.
      for (final node in tree.nodes)
        if (at != null) ...[
          node.render(at),
          if (tree.stallOf(node.node.id) case final stall?) stallLine(stall),
          if (tree.unmeasuredOf(node.node.id) case final blind?)
            blindLine(blind),
        ],
      for (final MapEntry(key: id, value: count) in tree.strangers.entries)
        '$unknownValueText · $id · $strangerText · $count events',
      // A node the watchdog is contradicting that this client has never been
      // shown. Printed rather than dropped, for the reason a stranger is: an
      // id the daemon is ringing about is a real node, and a board that hid it
      // would report a healthier tree than the daemon can see.
      for (final stall in tree.stalled)
        if (!_isKnown(tree, stall.nodeId)) stallLine(stall),
      for (final blind in tree.unmeasured)
        if (!_isKnown(tree, blind.nodeId)) blindLine(blind),
      if (tree.resources.isEmpty) nothingHeldText,
      for (final resource in tree.resources) resource.label,
      if (tree.journalUnreadable case final why?) '$journalUnreadableKey: $why',
    ];
  }

  static bool _isKnown(LiveTree tree, String nodeId) {
    for (final node in tree.nodes) {
      if (node.node.id == nodeId) return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'sprout-shell', [
      // `Component.text` rather than the top-level `text()` helper: the
      // latter is deprecated in jaspr 0.23.4 and `dart analyze --fatal-infos`
      // rejects it. `jaspr create` still scaffolds the deprecated form.
      div(classes: 'sprout-head', [
        Component.text('cursor ${tree.cursor?.encode() ?? unknownValueText}'),
      ]),
      div(classes: 'sprout-live', [Component.text(liveness(tree))]),
      div(
        classes: tree.lastSweep?.conclusive ?? true
            ? 'sprout-watchdog'
            : 'sprout-watchdog sprout-watchdog-blind',
        [Component.text(watchdog(tree))],
      ),
      if (error case final message?)
        div(classes: 'sprout-error', [Component.text(message)]),
      div(classes: 'sprout-board', [
        if (tree.isAttached && tree.nodes.isEmpty && tree.strangers.isEmpty)
          div(classes: 'sprout-empty', [Component.text(noNodesText)]),
        for (final node in tree.nodes)
          if (tree.asOf case final at?) ...[
            div(
              classes: 'sprout-node',
              attributes: {
                'data-status': node.node.status.wire,
                // **Beside the node, not inside it.** `NodeStatus` has no
                // `stalled` member on purpose: liveness is a verdict recomputed
                // every sweep, so a recovered node loses this attribute on the
                // next frame with nothing having written a status row.
                if (tree.stallOf(node.node.id) case final stall?)
                  'data-watchdog': stall.liveness,
                if (tree.unmeasuredOf(node.node.id) != null)
                  'data-watchdog': 'unmeasured',
              },
              [Component.text(node.render(at))],
            ),
            if (tree.stallOf(node.node.id) case final stall?)
              div(classes: 'sprout-stall', [Component.text(stallLine(stall))]),
            if (tree.unmeasuredOf(node.node.id) case final blind?)
              div(classes: 'sprout-blind', [Component.text(blindLine(blind))]),
          ],
        for (final MapEntry(key: id, value: count) in tree.strangers.entries)
          div(classes: 'sprout-node sprout-stranger', [
            Component.text(
              '$unknownValueText · $id · $strangerText · $count events',
            ),
          ]),
        for (final stall in tree.stalled)
          if (!_isKnown(tree, stall.nodeId))
            div(classes: 'sprout-stall', [Component.text(stallLine(stall))]),
        for (final blind in tree.unmeasured)
          if (!_isKnown(tree, blind.nodeId))
            div(classes: 'sprout-blind', [Component.text(blindLine(blind))]),
      ]),
      div(classes: 'sprout-held', [
        if (tree.resources.isEmpty)
          div([Component.text(nothingHeldText)])
        else
          for (final resource in tree.resources)
            div([Component.text(resource.label)]),
      ]),
      if (tree.journalUnreadable case final why?)
        div(classes: 'sprout-error', [
          Component.text('$journalUnreadableKey: $why'),
        ]),
    ]);
  }

  /// Rendered to `main.css` at build time by the `@css` builder, which is why
  /// the payload has a stylesheet without the package shipping one.
  @css
  static List<StyleRule> get styles => [
    css('.sprout-shell', [
      css('&').styles(
        display: .flex,
        padding: Padding.all(1.rem),
        flexDirection: .column,
        gap: Gap(row: 0.35.rem),
        fontFamily: const FontFamily.list([
          FontFamily('ui-monospace'),
          FontFamily('monospace'),
        ]),
        fontSize: 0.85.rem,
        lineHeight: 1.4.em,
      ),
      // `pre-wrap`, not `pre`: the indent `SnapshotNode.render` puts in front
      // of a nested node is real whitespace that HTML would otherwise collapse,
      // and a line too long for a phone must wrap rather than scroll sideways.
      css('.sprout-node').styles(raw: {'white-space': 'pre-wrap'}),
      css('.sprout-head').styles(opacity: 0.6),
      css('.sprout-live').styles(fontWeight: FontWeight.bold),
      css('.sprout-error').styles(color: const Color('#b00020')),
      // The stall reads as loud as the error it is, and the node line above it
      // is marked so the two are one block at a glance. There is no rule for
      // a HEALTHY node, deliberately: nothing on this board is ever coloured
      // to mean "fine".
      css('.sprout-stall').styles(
        color: const Color('#b00020'),
        fontWeight: FontWeight.bold,
        raw: {'white-space': 'pre-wrap'},
      ),
      css(
        '.sprout-blind',
      ).styles(color: const Color('#8a6d00'), raw: {'white-space': 'pre-wrap'}),
      css('.sprout-node[data-watchdog]').styles(color: const Color('#b00020')),
      css('.sprout-node[data-watchdog="unmeasured"]')
          .styles(color: const Color('#8a6d00')),
      css('.sprout-watchdog').styles(raw: {'white-space': 'pre-wrap'}),
      css('.sprout-watchdog-blind')
          .styles(color: const Color('#8a6d00'), fontWeight: FontWeight.bold),
      css('.sprout-stranger').styles(opacity: 0.7),
      css('.sprout-held')
          .styles(opacity: 0.6, margin: Margin.only(top: .5.rem)),
      css('.sprout-board').styles(
        display: .flex,
        flexDirection: .column,
        gap: Gap(row: 0.15.rem),
      ),
    ]),
  ];
}
