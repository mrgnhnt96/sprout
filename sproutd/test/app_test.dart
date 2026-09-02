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
import 'package:sproutd/protocol.dart';
import 'package:sproutd/store.dart';
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

    test('names its prefix explicitly rather than inheriting api', () {
      // AppConfig defaults prefix to 'api' when none is passed, so equality
      // alone would pass with the argument deleted. The source check is what
      // makes this a decision rather than the default.
      expect(MainApp().prefix, 'api');
      final source = File('routes/main_app.dart').readAsStringSync();
      expect(source, contains('prefix: daemonPrefix'));
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
      final snapshot = TreeController(store).snapshot();
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

        final snapshot = TreeController(store).snapshot();
        expect(Cursor.parse(snapshot['cursor']! as String).position, 1);
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
      final first = await TreeController(store).events(null).first;
      final frame = jsonDecode(first.value) as Map<String, Object?>;
      expect(frame['type'], snapshotFrameType);
      expect(frame['nodes'], isEmpty);
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
}
