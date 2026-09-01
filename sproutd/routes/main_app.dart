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

/// The route prefix, set explicitly.
///
/// `AppConfig` defaults `prefix` to `'api'` even when none is passed, so a
/// route written as `tree` is served at `/api/tree` either way. Naming it here
/// makes the URL shape a decision rather than a surprise; the research doc's
/// first 404 was this.
const String daemonPrefix = 'api';

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
  /// Binds [daemonHost] on the configured port under [daemonPrefix].
  MainApp()
    : super(
        host: daemonHost,
        port: daemonPortFrom(Platform.environment),
        prefix: daemonPrefix,
      );

  @override
  Future<void> configureDependencies(DI di) async {
    // Lazy: the file is opened on the first request that needs it, and the
    // controllers take it by constructor.
    di.registerLazySingleton<SproutStore>(
      () => SproutStore.open(path: databasePathFrom(Platform.environment)),
    );
  }
}
