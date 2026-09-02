/// The client entrypoint. `jaspr build` compiles this file, and only this
/// file, to `main.client.dart.js` — the single script `web/index.html` loads.
///
/// Nothing here runs on a server. Client mode emits a static payload with no
/// run-time Dart at all, which is what lets P3-03 embed the whole UI in the
/// sproutd binary as byte constants (`docs/01-plan.md` §13).
library;

import 'package:jaspr/client.dart';

import 'app.dart';

void main() {
  runApp(const App());
}
