/// Tests for `sprout hook` and `sprout hooks install` — the machine-wide path.
///
/// **`sprout hook` is driven as a real subprocess with a real pipe, never by
/// calling `sprout()` in process.** The three properties this verb exists to
/// have are properties of a *process*: it reads a payload on stdin, it exits 0
/// whatever happens, and it writes nothing to stdout. An in-process call proves
/// none of the three — it does not open a pipe, it returns an int rather than
/// setting an exit status, and the stdout it would have to check is a
/// `StringBuffer` somebody passed in.
///
/// The entrypoint is compiled once to a kernel snapshot in [setUpAll] and every
/// process runs that. It is the same `bin/sprout.dart`, the same `main`, the
/// same argument parsing and the same real stdin; the snapshot only moves the
/// JIT front-end out of the loop, which takes an invocation from ~1.8s to
/// ~0.27s. That matters here more than anywhere else in this suite, because the
/// central test runs **one process per payload** over a fourteen-payload
/// capture, which is the way it will really happen.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sprout_protocol/values.dart';
import 'package:sproutd/hooks.dart';
import 'package:sproutd/store.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;

const _hookFixtureRoot = '../docs/research/fixtures/phase0/hooks';

/// The settings file a live CLI v2.1.252 accepted and fired all eleven events
/// from. The shape assertion below is against this and nothing else.
const _settingsFixture =
    '../docs/research/fixtures/phase0/hook-settings-all-events.json';

/// The eleven event names, spelled out rather than derived.
///
/// Copied from `docs/research/17-observed-schemas.md` §1. Deliberately a second
/// spelling of `hookKindsByEventName.keys`, which is what the generator reads —
/// a pin is only a pin if it is written independently of the thing it pins. It
/// is worth having because **a misspelled event name is silently ignored under
/// `-p`**: there is no error and no missing-hook message, so nothing at runtime
/// would ever tell anyone that a typo here means a hook that never fires.
const _elevenEvents = [
  'SessionStart',
  'SessionEnd',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'SubagentStart',
  'SubagentStop',
  'Stop',
  'Notification',
  'PreCompact',
  'PostCompact',
];

/// One finished `sprout hook` process.
typedef HookRun = ({int code, String out, String err});

List<File> _payloads(String capture) =>
    (Directory(p.absolute('$_hookFixtureRoot/$capture')).listSync()
          ..sort((a, b) => a.path.compareTo(b.path)))
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();

String _sessionIdOf(File payload) =>
    (jsonDecode(payload.readAsStringSync())
            as Map<String, Object?>)['session_id']!
        as String;

void main() {
  late Directory snapshotDir;
  late String dill;
  late Directory tmp;

  setUpAll(() {
    snapshotDir = Directory.systemTemp.createTempSync('sprout_hook_kernel');
    dill = p.join(snapshotDir.path, 'sprout.dill');
    final compiled = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/sprout.dart',
      '-o',
      dill,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: 'could not build the entrypoint: ${compiled.stderr}',
    );
  });

  tearDownAll(() => snapshotDir.deleteSync(recursive: true));

  setUp(() => tmp = Directory.systemTemp.createTempSync('sprout_hook_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String db() => p.join(tmp.path, 'sprout.db');

  /// Runs `sprout hook` as a process, pipes [stdinBytes] and waits for it.
  ///
  /// [closeStdin] false leaves the pipe open, which is how the deadline is
  /// exercised: a session that opened the pipe and never closed it.
  Future<HookRun> hook(
    List<String> arguments, {
    List<int> stdinBytes = const [],
    bool closeStdin = true,
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      dill,
      'hook',
      ...arguments,
    ], environment: environment);
    process.stdin.add(stdinBytes);
    if (closeStdin) {
      await process.stdin.close();
    } else {
      await process.stdin.flush();
    }
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    if (!closeStdin) await process.stdin.close().catchError((Object _) {});
    return (code: code, out: await out, err: await err);
  }

  /// Runs `sprout hooks install` as a process.
  Future<HookRun> install(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      dill,
      'hooks',
      'install',
      ...arguments,
    ], environment: environment);
    return (
      code: result.exitCode,
      out: result.stdout as String,
      err: result.stderr as String,
    );
  }

  /// Every event in the store at [path] whose kind is a hook kind.
  List<SproutEvent> hookEvents(String path) {
    final store = SproutStore.open(path: path);
    try {
      return store
          .eventsSince(0)
          .where((event) => event.kind.startsWith(hookKindPrefix))
          .toList();
    } finally {
      store.close();
    }
  }

  group('sprout hook', () {
    test(
      'records a real SessionStart payload, exits 0, prints nothing',
      () async {
        final payload = _payloads('A')
            .firstWhere((file) => file.path.contains('SessionStart'));
        final run = await hook([
          '--db',
          db(),
        ], stdinBytes: payload.readAsBytesSync());

        // Both halves, every time. The exit code alone is half the contract:
        // a `UserPromptSubmit` hook's stdout is added to the conversation and a
        // `PreToolUse` hook's stdout is where a permission decision goes, so
        // anything printed there lands in somebody's session (`17` §7).
        expect(run.code, 0, reason: run.err);
        expect(run.out, isEmpty, reason: 'stdout is an input channel here');

        final sessionId = _sessionIdOf(payload);
        final store = SproutStore.open(path: db());
        addTearDown(store.close);
        final node = store.node(HookProjection.rootNodeId(sessionId));
        expect(node, isNotNull, reason: 'the session root must exist');
        expect(node!.id, 'hook/$sessionId');

        final events = hookEvents(db());
        expect(events, hasLength(1));
        expect(events.single.kind, hookSessionStartKind);
        expect(events.single.nodeId, 'hook/$sessionId');
      },
    );

    test('one process per payload rebuilds the depth-2 tree from hooks/B', () async {
      // The closest thing to the real path a test can reach: fourteen separate
      // OS processes, in the order the filenames give, each opening the store,
      // folding one payload and exiting. It is the assertion that would catch a
      // projection which only works while one process holds the store for a
      // whole session.
      final payloads = _payloads('B');
      expect(payloads, hasLength(14));

      for (final payload in payloads) {
        final run = await hook([
          '--db',
          db(),
        ], stdinBytes: payload.readAsBytesSync());
        expect(run.code, 0, reason: '${p.basename(payload.path)}: ${run.err}');
        expect(run.out, isEmpty, reason: p.basename(payload.path));
      }

      final sessionId = _sessionIdOf(payloads.first);
      final store = SproutStore.open(path: db());
      addTearDown(store.close);

      final rootId = HookProjection.rootNodeId(sessionId);
      final children = store.children(rootId);
      expect(children, hasLength(1), reason: 'the root spawned exactly one');
      final child = children.single;
      final grandchildren = store.children(child.id);
      expect(grandchildren, hasLength(1), reason: 'depth 2, not depth 1');

      // The ids the corpus actually carries, so a tree of the right shape built
      // from the wrong identifiers still fails.
      expect(child.id, '$rootId/aab408509339890dd');
      expect(grandchildren.single.id, '$rootId/ac19f9c9fe3fbbac5');
      expect(child.status, NodeStatus.checkpointed);
      expect(store.node(rootId)!.status, NodeStatus.checkpointed);

      // Every payload landed as exactly one event, against the node that
      // emitted it — fourteen processes, fourteen rows.
      expect(hookEvents(db()), hasLength(payloads.length));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('starts from cold: a database directory that does not exist yet', () async {
      // The first hook on a fresh machine may be the thing that creates
      // ~/.sprout. `SproutStore.open` creates the parent recursively; this
      // asserts the verb works end to end from nothing rather than assuming it.
      final fresh = p.join(tmp.path, 'nowhere', 'deeper', 'sprout.db');
      final payload = _payloads('A').first;
      final run = await hook([
        '--db',
        fresh,
      ], stdinBytes: payload.readAsBytesSync());

      expect(run.code, 0, reason: run.err);
      expect(run.out, isEmpty);
      expect(File(fresh).existsSync(), isTrue);
      expect(hookEvents(fresh), hasLength(1));
      expect(File(hookRawLogPathFor(fresh)).existsSync(), isTrue);
    });

    group('every failure is exit 0 with an empty stdout', () {
      test('stdin is not JSON', () async {
        final run = await hook([
          '--db',
          db(),
        ], stdinBytes: utf8.encode('this is not json {'));
        expect(run.code, 0);
        expect(run.out, isEmpty);
        expect(run.err, contains('not a JSON object'));
        expect(hookEvents(db()), isEmpty);
        // F-18: the bytes are not in the store and are not lost either.
        expect(
          File(hookRawLogPathFor(db())).readAsStringSync(),
          contains('this is not json {'),
        );
      });

      test('stdin is empty', () async {
        final run = await hook(['--db', db()]);
        expect(run.code, 0);
        expect(run.out, isEmpty);
        expect(run.err, contains('not a JSON object'));
        expect(hookEvents(db()), isEmpty);
      });

      test('the payload carries no session_id', () async {
        final run = await hook([
          '--db',
          db(),
        ], stdinBytes: utf8.encode('{"hook_event_name":"Stop","cwd":"/tmp"}'));
        expect(run.code, 0);
        expect(run.out, isEmpty);
        // Said out loud, because nothing can be recorded: `event.node_id` is
        // NOT NULL with a foreign key and this payload names no node.
        expect(run.err, contains('no session_id'));
        expect(hookEvents(db()), isEmpty);
        expect(
          File(hookRawLogPathFor(db())).readAsStringSync(),
          contains('"hook_event_name":"Stop"'),
        );
      });

      test('--db points at a directory', () async {
        final directory = Directory(p.join(tmp.path, 'not-a-database'))
          ..createSync();
        final payload = _payloads('A').first;
        final run = await hook([
          '--db',
          directory.path,
        ], stdinBytes: payload.readAsBytesSync());
        expect(run.code, 0);
        expect(run.out, isEmpty);
        expect(run.err, contains('cannot open the store'));
      });

      test('an unknown option is still exit 0 and still silent', () async {
        // `CommandRunner` raises before `HookCommand.run` is ever reached, so
        // this exercises the clamp in `sprout()` rather than the command.
        final run = await hook(['--no-such-option']);
        expect(run.code, 0);
        expect(run.out, isEmpty);
        expect(run.err, contains('Could not find an option named'));
      });

      test('the deadline expires on a pipe that never closes', () async {
        final run = await hook(
          ['--db', db(), '--deadline-ms', '250'],
          stdinBytes: utf8.encode('{"session_id":"never-finished"'),
          closeStdin: false,
        ).timeout(const Duration(seconds: 20));
        expect(run.code, 0);
        expect(run.out, isEmpty);
        expect(run.err, contains('gave up reading stdin'));
        expect(hookEvents(db()), isEmpty);
      });
    });

    test('several processes writing at once all land', () async {
      // What the `busy_timeout` P8-02 added is for, exercised through real
      // processes for the first time: without it a connection that finds the
      // write lock held fails at once with SQLITE_BUSY.
      //
      // It found two races the timeout does not cover, both fixed here and both
      // regression-guarded by this test. `migrate` decided which migration to
      // run *before* taking a lock, so on a fresh database six of eight
      // processes died on `table node already exists`; and `PRAGMA journal_mode
      // = WAL` ran before `busy_timeout` was set, so the one statement in
      // `_configure` that takes the write lock had no timeout in effect.
      const writers = 8;
      final runs = await Future.wait([
        for (var i = 0; i < writers; i++)
          hook(
            ['--db', db()],
            stdinBytes: utf8.encode(
              '{"session_id":"concurrent-$i","hook_event_name":"SessionStart",'
              '"cwd":"/tmp/concurrent"}',
            ),
          ),
      ]);

      for (final run in runs) {
        expect(run.code, 0, reason: run.err);
        expect(run.out, isEmpty);
      }
      final events = hookEvents(db());
      expect(events, hasLength(writers), reason: 'no writer may be dropped');
      expect(
        {for (final event in events) event.nodeId},
        {for (var i = 0; i < writers; i++) 'hook/concurrent-$i'},
      );

      // The raw log is written by the same eight processes and has its own
      // race, which is not SQLite's: `FileMode.writeOnlyAppend` fixes the write
      // offset at open, so without the seek-under-lock in `appendHookRawLog`
      // the later openers overwrite the earlier ones — silently, with every
      // process still exiting 0. Counting the frames is what catches that.
      final log = File(hookRawLogPathFor(db())).readAsStringSync();
      expect(
        hookRawLogFrameMarker.allMatches(log).length,
        writers,
        reason: 'every payload must be durable, not just most of them',
      );
      for (var i = 0; i < writers; i++) {
        expect(log, contains('"session_id":"concurrent-$i"'));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('sprout hooks install', () {
    test('prints the block and writes nothing anywhere', () async {
      final home = Directory(p.join(tmp.path, 'home'))..createSync();
      final run = await install(
        ['--command', '/usr/local/bin/sprout hook'],
        environment: {'HOME': home.path},
      );

      expect(run.code, 0, reason: run.err);
      final printed = jsonDecode(run.out) as Map<String, Object?>;
      expect((printed['hooks']! as Map<String, Object?>).keys, _elevenEvents);
      // The instruction is a human's to act on and goes to stderr, so stdout
      // stays pipeable JSON.
      expect(run.err, contains('~/.claude/settings.json'));
      // The default must touch nothing — not the working directory, and above
      // all not the settings file it is telling the human about.
      expect(home.listSync(), isEmpty);
      expect(tmp.listSync().map((e) => p.basename(e.path)), [
        'home',
      ], reason: 'printing is not a write');
    });

    test('the generated shape is the one a live CLI accepted', () async {
      // Pinned against the settings file the Phase 0 probe actually ran under,
      // with the two knobs normalised away: the fixture's command carries the
      // event name because it was a stdin-dumping script, and its timeout was
      // 15. Everything else — the eleven keys, their order, the nesting, and
      // `"matcher": "*"` on exactly PreToolUse and PostToolUse — is compared.
      const command = 'sprout hook';
      final fixture = jsonDecode(
        File(p.absolute(_settingsFixture)).readAsStringSync(),
      ) as Map<String, Object?>;
      final generated = hookSettingsBlock(command: command, timeoutSeconds: 15);

      Object? normalise(Object? node) => switch (node) {
        final Map<Object?, Object?> map => {
          for (final entry in map.entries)
            entry.key: entry.key == 'command'
                ? command
                : normalise(entry.value),
        },
        final List<Object?> list => [for (final item in list) normalise(item)],
        _ => node,
      };

      expect(normalise(generated), normalise(fixture));
      // Order too — `expect` on maps compares by key, and a settings file whose
      // events arrived in a different order would still be the same file, but a
      // silently *renamed* event would not.
      expect(
        (generated['hooks']! as Map<String, Object?>).keys.toList(),
        (fixture['hooks']! as Map<String, Object?>).keys.toList(),
      );
    });

    test('the eleven event names are the eleven in doc 17 §1', () {
      expect(hookKindsByEventName.keys.toList(), _elevenEvents);
      final generated = hookSettingsBlock(command: 'sprout hook');
      expect(
        (generated['hooks']! as Map<String, Object?>).keys.toList(),
        _elevenEvents,
      );
      for (final event in _elevenEvents) {
        final group =
            ((generated['hooks']! as Map<String, Object?>)[event]!
                        as List<Object?>)
                    .single
                as Map<String, Object?>;
        expect(
          group.containsKey('matcher'),
          hookMatcherEvents.contains(event),
          reason: '$event: matcher belongs on the tool events only',
        );
      }
    });

    test('--write merges: other hooks survive and sprout appears once', () async {
      final settings = File(p.join(tmp.path, 'settings.json'));
      settings.writeAsStringSync(
        jsonEncode({
          'permissions': {'allow': <String>[]},
          'hooks': {
            'SessionStart': [
              {
                'hooks': [
                  {'type': 'command', 'command': '/opt/other/tool.sh'},
                ],
              },
            ],
            'SomethingElse': [
              {
                'hooks': [
                  {'type': 'command', 'command': '/opt/other/else.sh'},
                ],
              },
            ],
          },
        }),
      );

      const command = '/usr/local/bin/sprout hook';
      for (var attempt = 0; attempt < 2; attempt++) {
        final run = await install([
          '--write',
          settings.path,
          '--command',
          command,
        ]);
        expect(run.code, 0, reason: run.err);
        // `--write` prints nothing to stdout: the block went to a file.
        expect(run.out, isEmpty);
        expect(run.err, contains(settings.path));
      }

      final written =
          jsonDecode(settings.readAsStringSync()) as Map<String, Object?>;
      final hooks = written['hooks']! as Map<String, Object?>;

      // Untouched: a key that is not `hooks`, and an event sprout knows nothing
      // about.
      expect(written['permissions'], {'allow': <String>[]});
      expect(hooks.containsKey('SomethingElse'), isTrue);

      // The unrelated hook on an event sprout also registers is preserved
      // beside sprout's, not replaced by it.
      final sessionStart = hooks['SessionStart']! as List<Object?>;
      final commands = [
        for (final group in sessionStart.cast<Map<String, Object?>>())
          for (final entry
              in (group['hooks']! as List<Object?>)
                  .cast<Map<String, Object?>>())
            entry['command'],
      ];
      expect(commands, ['/opt/other/tool.sh', command]);

      // Twice run, once present — on every one of the eleven events.
      for (final event in _elevenEvents) {
        final sprouts = [
          for (final group
              in (hooks[event]! as List<Object?>).cast<Map<String, Object?>>())
            for (final entry
                in (group['hooks']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              if (entry['command'] == command) entry,
        ];
        expect(sprouts, hasLength(1), reason: '$event has ${sprouts.length}');
      }

      // Replaced, not truncated: no half-written file and no temp left behind.
      expect(tmp.listSync().map((e) => p.basename(e.path)).toList(), [
        'settings.json',
      ]);
    });

    test('--write creates a settings file that does not exist yet', () async {
      final settings = p.join(tmp.path, 'fresh', 'settings.json');
      final run = await install(['--write', settings]);
      expect(run.code, 0, reason: run.err);
      expect(run.out, isEmpty);
      final written =
          jsonDecode(File(settings).readAsStringSync()) as Map<String, Object?>;
      expect((written['hooks']! as Map<String, Object?>).keys, _elevenEvents);
    });

    test('--write refuses a settings file that is not JSON', () async {
      final settings = File(p.join(tmp.path, 'settings.json'))
        ..writeAsStringSync('{ not json');
      final run = await install(['--write', settings.path]);
      expect(run.code, cli.exitStoreUnreadable);
      expect(run.out, isEmpty);
      expect(run.err, contains('not readable JSON'));
      // Refused means unchanged, not half-rewritten.
      expect(settings.readAsStringSync(), '{ not json');
    });

    test('the command it writes actually runs, from an unrelated cwd', () async {
      // **The trap this pins, and the reason it is asserted by running the
      // command rather than by matching its text.** Under `dart run` —
      // `Platform.resolvedExecutable` is the VM, not sprout — a block built
      // from the executable alone would say `…/dart-sdk/bin/dart hook`, which
      // is the VM invoked with a subcommand it has never heard of. Nothing at
      // install time would say so: the settings file would be valid JSON, the
      // CLI would accept it, and every hook would fail silently in someone's
      // session. So this takes the emitted command and executes it.
      //
      // Run through the real `dart run bin/sprout.dart` rather than the kernel
      // snapshot the rest of this file uses, because the snapshot is what makes
      // `Platform.script` a temp `.dill` — and it is exactly `Platform.script`
      // that the answer depends on.
      final printed = await Process.run(Platform.resolvedExecutable, [
        'bin/sprout.dart',
        'hooks',
        'install',
      ]);
      expect(printed.exitCode, 0, reason: '${printed.stderr}');
      final block =
          jsonDecode(printed.stdout as String) as Map<String, Object?>;
      final entry =
          ((((block['hooks']! as Map<String, Object?>)['SessionStart']!
                                  as List<Object?>)
                              .single
                          as Map<String, Object?>)['hooks']!
                      as List<Object?>)
                  .single
              as Map<String, Object?>;
      final command = entry['command']! as String;

      // The shape it must NOT have, named so a regression reads clearly.
      expect(command, isNot('${Platform.resolvedExecutable} hook'));

      // And now the real test: split it the way a shell would, run it from a
      // directory that is not this package, and check the store.
      final argv = command.split(' ');
      final payload = _payloads('A')
          .firstWhere((file) => file.path.contains('SessionStart'));
      final process = await Process.start(argv.first, [
        ...argv.skip(1),
        '--db',
        db(),
      ], workingDirectory: tmp.path);
      process.stdin.add(payload.readAsBytesSync());
      await process.stdin.close();
      final out = process.stdout.transform(utf8.decoder).join();
      expect(await process.exitCode, 0);
      expect(await out, isEmpty);
      expect(hookEvents(db()), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
