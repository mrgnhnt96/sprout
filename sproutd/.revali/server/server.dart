import 'dart:io';
import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:revali_router/revali_router.dart';
import 'package:revali_core/data/data.dart';
import 'package:revali_core/request/clean_up/clean_up.dart';
import 'package:revali_core/response/response.dart';
import 'package:revali_core/types/string_content.dart';
import 'package:revali_core/web_socket/async_web_socket_sender.dart';
import 'package:revali_core/web_socket/close_web_socket.dart';
import 'package:sproutd/src/store/sprout_store.dart';

import '../../routes/controllers/tree_controller.dart';
import '../../routes/controllers/ui_controller.dart';
import '../../routes/main_app.dart';

part 'definitions/__public.dart';
part 'definitions/__reflects.dart';
part 'definitions/__routes.dart';
part 'routes/__api_tree_route.dart';
part 'routes/__r0_route.dart';

List<Isolate> _revaliWorkerIsolates = <Isolate>[];

bool _revaliIsWorker = false;

final WorkerFleet _revaliWorkerFleet = WorkerFleet();

SendPort? _revaliWorkerRegistration;

int _revaliIsolateIndex = 0;

Future<HttpServer> _bindServer(
  AppConfig app, {
  HttpServer? providedServer,
  bool shared = false,
}) async {
  if (providedServer != null) {
    return providedServer;
  }

  final host = switch (app.host) {
    'localhost' => InternetAddress.anyIPv6,
    final String h => h,
  };

  final v6Only = app.host != 'localhost';

  // --cert/--key (revali dev) take precedence over AppConfig.secure's own
  // securityContext, since they're an explicit run-time request for TLS.
  const certPath = String.fromEnvironment('REVALI_CERT');
  const keyPath = String.fromEnvironment('REVALI_KEY');
  final usingCliTls = certPath.isNotEmpty && keyPath.isNotEmpty;
  final securityContext = usingCliTls
      ? (SecurityContext()
          ..useCertificateChain(certPath)
          ..usePrivateKey(keyPath))
      : app.securityContext;

  // AppConfig.onServerStarted only knows about app.securityContext, so it
  // can't tell this override happened -- print it here instead.
  if (usingCliTls) {
    print('TLS enabled via --cert/--key');
  }

  if (securityContext != null) {
    return await HttpServer.bindSecure(
      host,
      app.port,
      securityContext,
      requestClientCertificate: app.requestClientCertificate,
      v6Only: v6Only,
      shared: shared,
      backlog: app.backlog,
    );
  }

  return await HttpServer.bind(
    host,
    app.port,
    shared: shared,
    v6Only: v6Only,
    backlog: app.backlog,
  );
}

void _revaliWorkerMain(List<Object> boot) {
  _revaliIsWorker = true;
  _revaliWorkerRegistration = boot[1] as SendPort;
  _revaliIsolateIndex = boot[2] as int;
  createServer(null, (boot[0] as List).cast<String>());
}

void main(List<String> args) {
  createServer(null, args);
}

Future<HttpServer> createServer([
  HttpServer? providedServer,
  List<String> rawArgs = const [],
]) async {
  final isWorker = _revaliIsWorker;
  _revaliIsWorker = false;
  final workerRegistration = _revaliWorkerRegistration;
  _revaliWorkerRegistration = null;
  final isolateIndex = _revaliIsolateIndex;
  _revaliIsolateIndex = 0;
  final args = Args.parse(rawArgs);
  final AppConfig app = MainApp.new();
  IsolateIdentity.setCurrentForGeneratedCode(
    IsolateIdentity(index: isolateIndex, workerCount: app.workers),
  );

  if (!isWorker && providedServer == null && app.workers > 1) {
    for (final isolate in _revaliWorkerIsolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    _revaliWorkerIsolates = <Isolate>[];
    // Also drops the previous generation's command ports, which a hot reload
    // would otherwise accumulate on every restart.
    final registration = _revaliWorkerFleet.open();
    for (var i = 1; i < app.workers; i++) {
      _revaliWorkerIsolates.add(
        await Isolate.spawn(_revaliWorkerMain, <Object>[
          rawArgs,
          registration,
          i,
        ]),
      );
    }
  }

  return app.runStartup(() async {
    late final HttpServer server;
    try {
      server = await _bindServer(
        app,
        providedServer: providedServer,
        shared: app.workers > 1 || isWorker,
      );
    } catch (e) {
      print('Failed to bind server:\n$e');
      exit(1);
    }

    final dependencyInjection = app.initializeDI();
    dependencyInjection.registerSingleton(args);
    await app.configureDependencies(dependencyInjection);
    final di = DIHandler(dependencyInjection);
    di.finishRegistration();

    var _routes = routes(di);

    if (app.prefix case final prefix? when prefix.isNotEmpty) {
      _routes = [Route(prefix, routes: _routes)];
    }

    final inFlight = InFlightRequests();

    final router = Router(
      inspect: bool.fromEnvironment('REVALI_INSPECT'),
      inspectLogPath: String.fromEnvironment(
        'REVALI_INSPECT_LOG',
        defaultValue: '',
      ),
      routes: [
        ..._routes,
        ...public,
        ...healthRoutes(
          settings: app.health,
          isDraining: () => inFlight.isDraining,
        ),
      ],
      reflects: reflects,
      defaultResponses: app.defaultResponses,
      trustedProxy: app.trustedProxy,
      compression: app.compression,
      di: di,
    );

    handleRouterRequests(
      server,
      router,
      router.close,
      inFlight: inFlight,
    ).ignore();

    Future<void> drainThisIsolate(Duration drainDelay) async {
      await shutdownServer(
        server: server,
        inFlight: inFlight,
        timeout: app.shutdownTimeout,
        drainDelay: drainDelay,
        onStopped: app.onServerStopped,
        log: print,
      );
      router.close();
    }

    if (isWorker) {
      // Every isolate binds the same port and keeps its own in-flight set, so a
      // worker has to drain itself. It never watches signals: the parent waits
      // for the reply before exiting, and exit() would take the whole process
      // down with requests still running here.
      if (workerRegistration case final registration?) {
        listenForDrainCommands(registration, drainThisIsolate);
      }
    } else if (providedServer == null && app.handleShutdownSignals) {
      listenForShutdown((signal) async {
        print('Received $signal, shutting down...');
        // SIGINT is a human at a terminal who wants the process gone now.
        // SIGTERM is an orchestrator, which is who the delay exists for.
        final drainDelay = signal == ProcessSignal.sigterm
            ? app.drainDelay
            : Duration.zero;
        // Concurrently, so every isolate flags its own readiness at once and
        // probes report 503 across the whole fleet rather than only whichever
        // isolate happened to handle the signal.
        await Future.wait([
          _revaliWorkerFleet.drainAll(
            drainDelay: drainDelay,
            timeout: drainDelay + app.shutdownTimeout,
            log: print,
          ),
          drainThisIsolate(drainDelay),
        ]);
        exit(0);
      });
    }

    if (!isWorker) {
      app.onServerStarted(server);
    }

    return server;
  });
}
