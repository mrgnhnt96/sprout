import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// The root of sprout's web UI.
///
/// A placeholder on purpose. P3-03 serves this payload from sproutd and P3-04
/// attaches it to the `watch` WebSocket and draws the tree; until then the
/// only thing this component has to prove is that the payload builds, loads
/// and renders.
class App extends StatelessComponent {
  const App({super.key});

  @override
  Component build(BuildContext context) {
    return div(classes: 'sprout-shell', [
      // `Component.text` rather than the top-level `text()` helper: the
      // latter is deprecated in jaspr 0.23.4 and `dart analyze --fatal-infos`
      // rejects it. `jaspr create` still scaffolds the deprecated form.
      h1([Component.text('sprout')]),
      p(classes: 'sprout-status', [
        Component.text('The UI payload is served. No daemon is attached yet.'),
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
