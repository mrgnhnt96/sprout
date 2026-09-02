/// The daemon's HTTP surface: one Revali app, bound to loopback.
///
/// `dart run revali build` reads this file and the controllers beside it and
/// writes `.revali/server/server.dart`, a plain entrypoint that
/// `dart compile exe` turns into the single `sproutd` binary. Nothing under
/// `.revali/` is hand-edited, and the build pipeline is in `README.md`.
///
/// Only `revali_router` is imported. `revali_server` is not a package in
/// revali 3.x but a construct built into `revali` itself, and the published
/// package of that name cannot co-resolve with `revali_router 5.1.1`
/// (`docs/research/05-dart-stack.md`). The annotations arrive through
/// `revali_router`'s re-export of `revali_annotations`.
library;

import 'dart:io';

import 'package:revali_router/revali_router.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watchdog.dart';

/// The loopback address, as a literal.
///
/// Not `'localhost'`: the generated `_bindServer` special-cases that exact
/// string to `InternetAddress.anyIPv6` with `v6Only: false`, which binds every
/// interface on the machine (`revali` 3.3.2,
/// `lib/server/makers/creators/create_bind_server.dart`). A daemon that
/// spawns agents with `acceptEdits` must not be reachable from the LAN.
const String daemonHost = '127.0.0.1';

/// The port the daemon listens on.
const String daemonPortEnvVariable = 'SPROUT_PORT';

/// The port used when [daemonPortEnvVariable] is unset.
const int defaultDaemonPort = 8787;

/// The prefix the JSON API and the socket answer under.
///
/// **Written into the controller's own path, not set on the app**, which is a
/// change P3-03 had to make and not a preference. `AppConfig.prefix` wraps
/// *every* controller route — the generated server does
/// `_routes = [Route(prefix, routes: _routes)]` — and only the `public` routes
/// and the health probes are registered outside it (`revali` 3.3.2,
/// `lib/server/makers/server_file_maker.dart`). So an app carrying a prefix
/// has no way to answer at `/`, and the UI has to. `TreeController` therefore
/// takes [treeControllerPath] and the app takes [daemonAppPrefix].
///
/// `AppConfig` defaults `prefix` to `'api'` even when none is passed, which is
/// the research doc's first 404. Naming both constants here keeps the URL
/// shape a decision rather than a default.
const String daemonPrefix = 'api';

/// The path `TreeController` is mounted at: `/api/tree`, unchanged.
///
/// The same URLs P1-06 and Phase 2 shipped — `GET /api/tree` and
/// `ws://…/api/tree/events`. `test/ui_test.dart` asserts them off a real
/// server, because moving where the prefix is spelled is exactly the kind of
/// change that is easy to make and easy to get subtly wrong.
const String treeControllerPath = '$daemonPrefix/tree';

/// The app-level prefix: none.
///
/// Empty and not null, because the generated server skips the wrapping only
/// when the prefix `isNotEmpty` is false, and an empty string reads as a
/// decision where a null reads as an omission. See [daemonPrefix] for why
/// there is no prefix here at all.
const String daemonAppPrefix = '';

/// The environment variable naming the SQLite file the daemon opens.
///
/// Unset or empty means `SproutStore.defaultDatabasePath()`, which is
/// `~/.sprout/sprout.db`. The `sprout` CLI honours the same variable, so a
/// daemon and a CLI pointed at one file see one tree.
const String databaseEnvVariable = 'SPROUT_DB';

/// The database path [environment] asks for, or null for the default.
///
/// An empty value counts as unset: `SproutStore.open(path: '')` would hand
/// SQLite an empty filename, which opens a private temporary database that
/// vanishes on close — a daemon that appears to work and records nothing.
String? databasePathFrom(Map<String, String> environment) {
  final value = environment[databaseEnvVariable];
  return value == null || value.isEmpty ? null : value;
}

/// The port [environment] asks for, or [defaultDaemonPort].
///
/// A value that is set but not a port throws rather than falling back:
/// someone set it on purpose, and quietly listening elsewhere is worse than
/// not starting.
int daemonPortFrom(Map<String, String> environment) {
  final value = environment[daemonPortEnvVariable];
  if (value == null || value.isEmpty) return defaultDaemonPort;
  final port = int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException(
      '$daemonPortEnvVariable must be a port number in 1..65535',
      value,
    );
  }
  return port;
}

/// The sprout daemon.
///
/// Reads the port from the environment at startup, so the constructor is not
/// `const`; the host is fixed and never read from anywhere.
@App()
final class MainApp extends AppConfig {
  /// Binds [daemonHost] on the configured port, with no prefix of its own.
  MainApp()
    : super(
        host: daemonHost,
        port: daemonPortFrom(Platform.environment),
        prefix: daemonAppPrefix,
      );

  /// Silent, because `sprout ui` prints the banner itself.
  ///
  /// `AppConfig`'s default `print`s `Serving at http://<host>:<port>` (revali_core
  /// 3.2.0, `app_config.dart`). Left in place, `sprout ui` emits that line and
  /// then its own URL — two URLs for one server, one of them built from
  /// `server.address.host` rather than from the address actually bound. A
  /// human reading two slightly different URLs has to work out which one to
  /// paste, and that is the exact confusion this verb exists to remove.
  ///
  /// This silences the banner for every consumer of the app, `revali dev`
  /// included. That is the intended scope: the generated `main` is no longer
  /// how the daemon is started (`bin/sprout.dart` is), so a banner nothing
  /// prints from is one fewer thing to keep in step.
  @override
  void onServerStarted(HttpServer server) {}

  @override
  Future<void> configureDependencies(DI di) async {
    // Lazy: the file is opened on the first request that needs it, and the
    // controllers take it by constructor.
    di.registerLazySingleton<SproutStore>(
      () => SproutStore.open(path: databasePathFrom(Platform.environment)),
    );
    // The board the daemon's watchdog writes its sweeps to, so a socket can
    // hand them to an attached client. **Registered, not constructed**: the
    // watchdog itself is started by `bin/sprout.dart`'s `UiCommand`, which owns
    // the daemon's lifetime, and `WatchdogBoard.shared` is how the two halves
    // in one process find each other — `createServer` builds this app itself,
    // so there is no seam to pass an instance through. See `WatchdogBoard`.
    //
    // An app started some other way (`revali dev`) resolves a board that
    // nothing is writing to, and the client renders that as "no sweep yet"
    // rather than as health — which is correct, because in that process
    // nothing is watching.
    di.registerLazySingleton<WatchdogBoard>(() => WatchdogBoard.shared);
  }
}
