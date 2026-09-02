/// Tests for the Revali app under `routes/` and the `sprout` CLI in `bin/`.
///
/// The CLI is driven against a fake `claude` — a shell script that records
/// its argument vector and replays a Phase 0 fixture — so nothing here costs
/// money. One test runs the real entrypoint as a process; the rest call
/// `sprout()` in-process for speed. The HTTP surface is tested at the
/// controller: the generated server is verified by building and running it
/// (`README.md`), which a unit test cannot stand in for.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
// The socket handler takes four parameters revali injects off the request
// context by type; this test supplies them by hand.
import 'package:revali_router/revali_router.dart' hide WebSocket;
import 'package:sproutd/liveness.dart';
import 'package:sproutd/protocol.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watchdog.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;
import '../routes/controllers/tree_controller.dart';
import '../routes/main_app.dart';

const _fixtureRoot = '../docs/research/fixtures/phase0/streams';

String _fixturePath(String name) => p.absolute('$_fixtureRoot/$name');

/// Writes a `claude` stand-in into [dir] that replays [fixture].
///
/// Every launch appends a line to `launches.txt` and overwrites `argv.txt`
/// with the arguments it was given, so a test can assert how many processes
/// the CLI started and what it told them.
String _fakeClaude(Directory dir, String fixture) {
  final script = File(p.join(dir.path, 'claude'));
  script.writeAsStringSync('''
#!/bin/sh
printf '%s\\n' "\$@" > "${dir.path}/argv.txt"
echo launched >> "${dir.path}/launches.txt"
cat "${_fixturePath(fixture)}"
''');
  Process.runSync('chmod', ['+x', script.path]);
  return script.path;
}

List<String> _argv(Directory dir) =>
    File(p.join(dir.path, 'argv.txt')).readAsLinesSync();

int _launches(Directory dir) {
  final file = File(p.join(dir.path, 'launches.txt'));
  return file.existsSync() ? file.readAsLinesSync().length : 0;
}

void main() {
  group('the app config', () {
    test('binds 127.0.0.1 literally, never localhost', () {
      final app = MainApp();
      expect(app.host, '127.0.0.1');
      // The generated `_bindServer` maps exactly the string 'localhost' to
      // InternetAddress.anyIPv6, which is every interface. The literal above
      // is the whole guard, and this is the case it guards against.
      expect(app.host, isNot('localhost'));
      expect(daemonHost, app.host);
    });

    test('carries no prefix of its own, so something can answer at /', () {
      // AppConfig defaults prefix to 'api' when none is passed, so equality
      // alone would pass with the argument deleted. The source check is what
      // makes this a decision rather than the default.
      //
      // It is EMPTY as of P3-03, and that is what the UI at `/` costs.
      // `AppConfig.prefix` wraps every controller route — the generated server
      // does `_routes = [Route(prefix, routes: _routes)]` — and only `public`
      // and the health probes are registered outside it (`revali` 3.3.2,
      // `server_file_maker.dart`). A prefixed app has no way to answer at the
      // root at all.
      expect(MainApp().prefix, isEmpty);
      final source = File('routes/main_app.dart').readAsStringSync();
      expect(source, contains('prefix: daemonAppPrefix'));

      // The paired half, and the one that matters to a consumer: the API URL
      // did not move. `test/ui_test.dart` asserts the same thing off a real
      // socket.
      expect(treeControllerPath, '$daemonPrefix/tree');
      expect(
        File('routes/controllers/tree_controller.dart').readAsStringSync(),
        contains('@Controller(treeControllerPath)'),
      );
    });

    test('takes the port from SPROUT_PORT and refuses a non-port', () {
      expect(daemonPortFrom(const {}), defaultDaemonPort);
      expect(daemonPortFrom(const {'SPROUT_PORT': ''}), defaultDaemonPort);
      expect(daemonPortFrom(const {'SPROUT_PORT': '9000'}), 9000);
      expect(
        () => daemonPortFrom(const {'SPROUT_PORT': 'eight'}),
        throwsFormatException,
      );
      expect(
        () => daemonPortFrom(const {'SPROUT_PORT': '70000'}),
        throwsFormatException,
      );
    });

    test('resolves the database from SPROUT_DB, treating empty as unset', () {
      expect(databasePathFrom(const {}), isNull);
      expect(databasePathFrom(const {'SPROUT_DB': ''}), isNull);
      expect(databasePathFrom(const {'SPROUT_DB': '/tmp/x.db'}), '/tmp/x.db');
      // The CLI reads the same variable, so a daemon and a CLI pointed at one
      // file see one tree.
      expect(cli.databaseEnvVariable, databaseEnvVariable);
    });
  });

  group('the routes directory', () {
    final sources = Directory('routes')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync())
        .join('\n');

    test('imports revali_router and never the revali_server package', () {
      expect(sources, contains("import 'package:revali_router/revali_router"));
      expect(
        RegExp(
          r"^import 'package:revali_server",
          multiLine: true,
        ).hasMatch(sources),
        isFalse,
        reason:
            'revali_server is a construct built into revali 3.x, not a '
            'package, and the published one cannot co-resolve',
      );
    });

    test('streams over @WebSocket and never @SSE', () {
      expect(
        RegExp(r'^\s*@WebSocket[.(]', multiLine: true).hasMatch(sources),
        isTrue,
      );
      expect(
        RegExp(r'^\s*@SSE\b', multiLine: true).hasMatch(sources),
        isFalse,
        reason:
            "Revali's SSE is application/octet-stream with no data: framing "
            'and the header override is ignored',
      );
    });

    test('has no public/ directory to read from the process CWD', () {
      // The positive half: the scan above found real route sources.
      expect(Directory('routes').existsSync(), isTrue);
      expect(sources, isNotEmpty);
      expect(
        Directory('public').existsSync(),
        isFalse,
        reason: 'public/ is served relative to CWD and 500s from anywhere else',
      );
    });
  });

  group('the tree controller', () {
    late SproutStore store;

    setUp(() => store = SproutStore.memory());
    tearDown(() => store.close());

    test('snapshots an empty store as no nodes, at a real cursor', () {
      // Phase 2's snapshot, not Phase 1's: `GET /api/tree` and the socket's
      // opening frame are the same `takeSnapshot`, so the two cannot drift
      // into two different pictures of one tree.
      final snapshot = TreeController(store, WatchdogBoard()).snapshot();
      expect(snapshot['nodes'], isEmpty);
      expect(Cursor.parse(snapshot['cursor']! as String).position, 0);
      // The fields that must survive any compression are present even here.
      expect(snapshot['journal_unreadable'], isNull);
      expect(snapshot['resources'], isEmpty);
    });

    test(
      'snapshots parents before children with depth, and an orphan as a root',
      () {
        final since = DateTime.utc(2026, 9, 1, 12);
        store
          ..putNode(
            SproutNode(
              id: 'a',
              project: '/p',
              status: NodeStatus.working,
              currentTask: 'root task',
              since: since,
            ),
          )
          ..putNode(
            SproutNode(
              id: 'a/child',
              parentId: 'a',
              project: '/p',
              status: NodeStatus.checkpointed,
            ),
          )
          // A parent that was never recorded: the runaway shape. Reported as
          // a root of its own fragment, not dropped and not adopted.
          ..putNode(
            SproutNode(
              id: 'z',
              parentId: 'ghost',
              project: '/p',
              status: NodeStatus.spawning,
            ),
          );
        store.append(nodeId: 'a', kind: 'runner.spawned');

        final snapshot = TreeController(store, WatchdogBoard()).snapshot();
        // Three rows, each announcing itself as it was written, then the
        // `runner.spawned` above: the cursor is the head of that feed.
        expect(Cursor.parse(snapshot['cursor']! as String).position, 4);
        final nodes = (snapshot['nodes'] as List).cast<Map<String, Object?>>();
        // Depth first, each parent immediately before its own children —
        // `takeSnapshot`'s order, not the store's breadth-first tree().
        expect(nodes.map((n) => n['id']), ['a', 'a/child', 'z']);
        expect(nodes.map((n) => n['depth']), [0, 1, 0]);
        expect(nodes[0], containsPair('parent_id', null));
        expect(nodes[0], containsPair('status', 'working'));
        expect(nodes[0], containsPair('current_task', 'root task'));
        expect(nodes[0], containsPair('since', '2026-09-01T12:00:00.000Z'));
        // Absence is transmitted, never estimated: no check-in is null here
        // and NONE SCHEDULED where a human reads it.
        expect(nodes[0], containsPair('next_checkin', null));
        expect(nodes[2]['parent_id'], 'ghost');
        expect(nodes[1]['status'], 'checkpointed');
        // Revali encodes the return value; a map it cannot encode is a 500.
        expect(() => jsonEncode(snapshot), returnsNormally);
      },
    );

    test('opens a socket with a snapshot frame rather than a hello', () async {
      // P1-06's `hello` stub is gone: the socket opens with the whole world,
      // because "an event saying leaf.closed is not a picture, it is a delta
      // against one". What the socket does *after* that frame — and that it
      // stays open at all, which the stub did not — is `test/ws_test.dart`,
      // over a real server and a real client.
      //
      // The frames arrive on the sender rather than on the returned stream:
      // that stream is deliberately already done, so `HandleWebSocket` reaches
      // the read loop that lets an inbound pong through (F-06).
      final sent = <String>[];
      final data = DataImpl();
      final frames = TreeController(store, WatchdogBoard()).events(
        null,
        data,
        CleanUpImpl(),
        AsyncWebSocketSenderImpl<Stream<StringContent>>(
          (pushed) => pushed.listen((frame) => sent.add(frame.value)),
        ),
        CloseWebSocketImpl((code, reason) async {}),
      );
      addTearDown(() => data.get<TreeSocketSession>()?.stop());

      expect(await frames.isEmpty, isTrue, reason: 'already done, on purpose');
      for (var i = 0; i < 20 && sent.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final frame = jsonDecode(sent.first) as Map<String, Object?>;
      expect(frame['type'], snapshotFrameType);
      expect(frame['nodes'], isEmpty);
    });

    test('a stall reaches the socket, and recovery takes it off', () async {
      // **The wiring, end to end through the route.** P6-02 shipped the
      // watchdog with no production caller at all; this is the assertion that
      // says something now reaches it. The board is the daemon's journal, so
      // a sweep recorded onto it must come out of the socket as a `watchdog`
      // frame — and the sweep after it, which names no node, must come out as
      // a frame that says the tree is not stalled without anything having
      // written a status row.
      final board = WatchdogBoard();
      addTearDown(board.close);
      // Recorded BEFORE the client attaches: a board that opened during a
      // stall must not wait out a sweep interval to hear about it.
      await board.record(
        SweepRecord(
          at: DateTime.utc(2026, 9, 2, 21, 45, 48),
          took: const Duration(milliseconds: 9),
          nodesSwept: 1,
          why: 'rang for 1 of 1 node(s): n1 stalled',
          rang: [
            Ring(
              nodeId: 'n1',
              liveness: Liveness.stalled,
              because: 'pid 33134 is alive and the transcript last grew 3s ago',
              consecutiveRings: 1,
              at: DateTime.utc(2026, 9, 2, 21, 45, 48),
              pid: 33134,
            ),
          ],
        ),
      );

      final sent = <String>[];
      final data = DataImpl();
      final frames = TreeController(store, board).events(
        null,
        data,
        CleanUpImpl(),
        AsyncWebSocketSenderImpl<Stream<StringContent>>(
          (pushed) => pushed.listen((frame) => sent.add(frame.value)),
        ),
        CloseWebSocketImpl((code, reason) async {}),
      );
      addTearDown(() => data.get<TreeSocketSession>()?.stop());
      expect(await frames.isEmpty, isTrue);

      Future<List<ProtocolFrame>> settle() async {
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        return [for (final line in sent) ProtocolFrame.decodeLine(line.trim())];
      }

      final opening = await settle();
      expect(opening.first, isA<SnapshotFrame>());
      final stall = opening.whereType<WatchdogFrame>().single;
      expect(stall.stalled.single.nodeId, 'n1');
      expect(stall.stalled.single.liveness, 'stalled');
      expect(stall.conclusive, isTrue);
      // The frame's cursor is this socket's position, not a new one: a sweep
      // is not a feed event and must never carry a consumer past one.
      expect(stall.cursor.encode(), opening.first.cursor.encode());

      // The node writes again; the next sweep names nobody.
      await board.record(
        SweepRecord(
          at: DateTime.utc(2026, 9, 2, 21, 46, 18),
          took: const Duration(milliseconds: 7),
          nodesSwept: 1,
          why:
              'no ring: the 1 node(s) that could be measured were live or '
              'ended',
        ),
      );

      final after = (await settle()).whereType<WatchdogFrame>().toList();
      expect(after, hasLength(2));
      expect(after.last.stalled, isEmpty);
      expect(after.last.conclusive, isTrue);
    });
  });

  group('sprout run', () {
    late Directory tmp;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sprout_app_test');
      out = StringBuffer();
      err = StringBuffer();
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    String db() => p.join(tmp.path, 'sprout.db');
    String logs() => p.join(tmp.path, 'sessions');

    Future<int> run(List<String> arguments, {Map<String, String>? env}) =>
        cli.sprout(
          ['run', ...arguments],
          out: out,
          err: err,
          environment: env ?? const {},
        );

    SproutStore open([String? path]) {
      final store = SproutStore.open(path: path ?? db());
      addTearDown(store.close);
      return store;
    }

    test(
      'spawns exactly one session at depth 0 and streams it to disk',
      () async {
        final fake = _fakeClaude(tmp, 'A.ndjson');
        final code = await run([
          'say hi',
          '--claude',
          fake,
          '--db',
          db(),
          '--logs',
          logs(),
          '-C',
          tmp.path,
        ]);
        expect(code, cli.exitOk, reason: err.toString());

        // One process, told the task and the budget sprout enforces.
        expect(_launches(tmp), 1);
        final argv = _argv(tmp);
        expect(argv.take(2), ['-p', 'say hi']);
        expect(argv[argv.indexOf('--max-budget-usd') + 1], '1.0');

        // One node, a root, and it reached the end of its stream.
        final store = open();
        final tree = store.tree();
        expect(tree, hasLength(1));
        final root = tree.single;
        expect(root.depth, 0);
        expect(root.node.parentId, isNull);
        expect(root.node.project, tmp.path);
        expect(root.node.currentTask, 'say hi');
        expect(root.node.status, NodeStatus.checkpointed);

        final kinds = store.eventsSince(0).map((e) => e.kind).toList();
        expect(kinds.where((k) => k == 'runner.spawned'), hasLength(1));
        expect(kinds.where((k) => k == 'runner.exited'), hasLength(1));
        expect(kinds, contains('frame.result'));

        // The raw log is the fixture, byte for byte.
        final rawLog = File(p.join(logs(), '${root.node.id}.ndjson'));
        expect(
          rawLog.readAsBytesSync(),
          File(_fixturePath('A.ndjson')).readAsBytesSync(),
        );

        expect(out.toString(), contains('node ${root.node.id}'));
        expect(out.toString(), contains('result success'));
      },
    );

    test(
      'records subagents it observes but launches only the one process',
      () async {
        // C carries a spawned subagent. The projection records it as a node
        // under the root — that is observation — while the launch count stays
        // at one, which is what "no delegation" means in Phase 1.
        final fake = _fakeClaude(tmp, 'C.ndjson');
        final code = await run([
          'delegate something',
          '--claude',
          fake,
          '--db',
          db(),
          '--logs',
          logs(),
          '-C',
          tmp.path,
        ]);
        expect(code, cli.exitOk, reason: err.toString());
        expect(_launches(tmp), 1);

        final store = open();
        final tree = store.tree();
        // The root is the only node without a parent. C's subagent sits under
        // the unobserved-parent marker — a fragment root, but still a node
        // sprout recorded rather than a process it started.
        expect(tree.where((n) => n.node.parentId == null), hasLength(1));
        expect(tree, hasLength(greaterThan(1)));
        expect(
          store.eventsSince(0).where((e) => e.kind == 'runner.spawned'),
          hasLength(1),
        );
      },
    );

    test('defaults the database to SPROUT_DB, then to HOME', () async {
      final fake = _fakeClaude(tmp, 'A.ndjson');
      final envDb = p.join(tmp.path, 'from-env.db');
      var code = await run(
        ['hi', '--claude', fake, '-C', tmp.path],
        env: {'SPROUT_DB': envDb, 'HOME': tmp.path},
      );
      expect(code, cli.exitOk, reason: err.toString());
      expect(open(envDb).tree(), hasLength(1));
      // Logs land beside the database when --logs is not given.
      expect(Directory(p.join(tmp.path, 'sessions')).listSync(), isNotEmpty);

      code = await run(
        ['hi', '--claude', fake, '-C', tmp.path],
        env: {'HOME': tmp.path},
      );
      expect(code, cli.exitOk, reason: err.toString());
      final homeDb = p.join(tmp.path, '.sprout', 'sprout.db');
      expect(File(homeDb).existsSync(), isTrue);
      expect(open(homeDb).tree(), hasLength(1));
    });

    test('refuses to run without a task', () async {
      final code = await run(['--db', db()]);
      expect(code, cli.exitUsage);
      expect(err.toString(), contains('A task is required'));
      expect(File(db()).existsSync(), isFalse, reason: 'nothing was opened');
    });

    test('refuses a non-positive budget', () async {
      final code = await run(['hi', '--budget-usd', '0', '--db', db()]);
      expect(code, cli.exitUsage);
      expect(err.toString(), contains('--budget-usd'));
    });

    test('reports a claude that cannot be started, and records it', () async {
      final missing = p.join(tmp.path, 'no-such-claude');
      final code = await run([
        'hi',
        '--claude',
        missing,
        '--db',
        db(),
        '--logs',
        logs(),
        '-C',
        tmp.path,
      ]);
      expect(code, cli.exitLaunchFailed);
      expect(err.toString(), contains('could not start $missing'));
      final kinds = open().eventsSince(0).map((e) => e.kind);
      expect(kinds, contains('runner.launch_failed'));
      expect(kinds, isNot(contains('runner.spawned')));
    });

    test('the real entrypoint runs end to end as a process', () async {
      final fake = _fakeClaude(tmp, 'A.ndjson');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/sprout.dart',
        'run',
        'say hi',
        '--claude',
        fake,
        '--db',
        db(),
        '--logs',
        logs(),
        '-C',
        tmp.path,
      ]);
      expect(result.exitCode, cli.exitOk, reason: '${result.stderr}');
      expect(result.stdout, contains('result success'));
      expect(open().tree(), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('sprout ui', () {
    // P4-01. Every test here drives the verb as a PROCESS, and that is not
    // laziness about speed: `UiCommand` reads `Platform.environment` on
    // purpose, because the server it starts builds `MainApp` and its DI out of
    // the process's own environment. A test calling `sprout()` in-process
    // could not set `SPROUT_PORT` or `SPROUT_DB` for the thing under test, and
    // one that pretended to would be asserting against a server holding
    // different values than the ones it passed.
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('sprout-ui-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// A port nothing is listening on, released before it is returned.
    ///
    /// Racy in principle and not in practice — and the alternative, a fixed
    /// port, races against the developer's own `sprout ui` and against every
    /// sibling worktree running this suite at the same time, which is a
    /// collision that actually happens here.
    Future<int> freePort() async {
      final probe = await ServerSocket.bind(daemonHost, 0);
      final port = probe.port;
      await probe.close();
      return port;
    }

    test('is a registered verb, so `sprout` lists it', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/sprout.dart',
        '--help',
      ]);
      expect(result.stdout, contains('\n  ui '));
      // The paired negative: `usage` prints every registered command, so this
      // would pass on any string. These are the other three.
      expect(result.stdout, contains('\n  run '));
      expect(result.stdout, contains('\n  snapshot '));
      expect(result.stdout, contains('\n  watch '));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('refuses arguments rather than ignoring them', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/sprout.dart',
        'ui',
        '9999',
      ]);
      expect(result.exitCode, cli.exitUsage);
      expect(result.stderr, contains('takes no arguments'));
      expect(result.stderr, contains(daemonPortEnvVariable));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('refuses a port that is already taken, and starts nothing', () async {
      // The brief's rule, and the reason `UiCommand` binds the socket itself:
      // left to revali's `_bindServer` this is `print(...)` on stdout and
      // `exit(1)`, which a caller cannot tell from a session failure.
      final held = await ServerSocket.bind(daemonHost, 0);
      addTearDown(held.close);
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/sprout.dart', 'ui'],
        environment: {
          'SPROUT_PORT': '${held.port}',
          'SPROUT_DB': p.join(tmp.path, 'ui.db'),
        },
      );
      expect(result.exitCode, cli.exitPortInUse);
      expect(result.stderr, contains('cannot listen on $daemonHost:'));
      expect(result.stderr, contains('already up'));
      // It refused before opening anything: the store is created by the DI on
      // first use, and there was no first use.
      expect(File(p.join(tmp.path, 'ui.db')).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('refuses a SPROUT_PORT that is not a port', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/sprout.dart', 'ui'],
        environment: {'SPROUT_PORT': 'eighty-eighty'},
      );
      expect(result.exitCode, cli.exitUsage);
      expect(result.stderr, contains(daemonPortEnvVariable));
      expect(result.stderr, contains('eighty-eighty'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'serves the page, the API and the socket, then stops on Ctrl-C',
      () async {
        final port = await freePort();
        final dbPath = p.join(tmp.path, 'ui.db');
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'bin/sprout.dart', 'ui'],
          environment: {'SPROUT_PORT': '$port', 'SPROUT_DB': dbPath},
        );
        addTearDown(() => process.kill(ProcessSignal.sigkill));

        final out = <String>[];
        final lines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(out.add);
        final errors = StringBuffer();
        final errLines = process.stderr
            .transform(utf8.decoder)
            .listen(errors.write);

        // Wait for the LAST of the three banner lines, then assert all three.
        // Waiting on the URL line alone would race the two after it.
        await _lineAppears(
          () => out,
          'Ctrl-C to stop.',
        ).timeout(const Duration(seconds: 60));

        // Exactly one URL, and that is a regression guard rather than
        // tidiness: `AppConfig.onServerStarted` prints its own `Serving at
        // ...` line built from `server.address.host`, so until `MainApp`
        // overrode it this verb printed two slightly different URLs for one
        // server and left the human to pick.
        expect(
          out.where((line) => line.contains('http://')),
          hasLength(1),
          reason: 'one server, one URL. Full stdout: $out',
        );

        // The URL is read off stdout rather than assumed — the verb's whole
        // deliverable is that a human does not have to know it in advance.
        final url = out.firstWhere((line) => line.startsWith('http://'));
        expect(url, 'http://$daemonHost:$port/');
        expect(out, contains('db  $dbPath'));

        final client = HttpClient();
        addTearDown(client.close);

        final page = await (await client.getUrl(Uri.parse(url))).close();
        expect(page.statusCode, 200);
        expect(page.headers.contentType?.mimeType, 'text/html');
        await page.drain<void>();

        final api = await (await client.getUrl(Uri.parse('${url}api/tree')))
            .close();
        expect(api.statusCode, 200);
        await api.drain<void>();

        final socket = await WebSocket.connect(
          'ws://$daemonHost:$port/api/tree/events',
        );
        // `connect` completing IS the 101: dart:io throws
        // WebSocketException on any other status.
        expect(socket.readyState, WebSocket.open);
        await socket.close();

        // Loopback only, still — and IPv4 loopback only. P1-06's guarantee,
        // re-checked against the launcher because a launcher is exactly the
        // thing that gets "made convenient" by widening the bind. Asserted at
        // the TCP layer rather than over HTTP: nothing may accept a connection
        // here at all, which is a stronger claim than "no route answers".
        await expectLater(
          Socket.connect(InternetAddress.loopbackIPv6, port),
          throwsA(isA<SocketException>()),
        );

        process.kill(ProcessSignal.sigint);
        expect(await process.exitCode, cli.exitOk, reason: '$errors');
        expect(out, contains('sprout: stopping.'));
        await lines.cancel();
        await errLines.cancel();
        expect(
          File(dbPath).existsSync(),
          isTrue,
          reason: 'served off the store',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

/// Polls [lines] until [wanted] is among them.
///
/// A poll rather than a `firstWhere` on the stream because the caller keeps
/// the whole transcript for later assertions, and a stream cannot be listened
/// to twice.
Future<void> _lineAppears(List<String> Function() lines, String wanted) async {
  while (!lines().contains(wanted)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
