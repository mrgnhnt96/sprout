/// Tests for `sprout snapshot` and `sprout watch` — Phase 2's CLI consumers.
///
/// **The end-to-end join is the deliverable.** `docs/01-plan.md` §11 says CLI
/// consumer first, correctness of the protocol before any pixels, and the one
/// thing unit tests on either side cannot check is whether the two halves
/// actually meet: a snapshot taken by one process, and a `watch --since` in
/// another process resuming from its cursor and being carried to the head with
/// no gap and no double-apply. That test drives the real entrypoint as a
/// process, against a store seeded from the Phase 0 fixtures — and it is what
/// found the one thing the deltas cannot carry, which it now asserts rather
/// than works around.
///
/// The faster tests call `sprout()` in-process, following `test/app_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/protocol.dart';
import 'package:sproutd/snapshot.dart';
import 'package:sproutd/store.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;

const _fixtureRoot = '../docs/research/fixtures/phase0/streams';

String _fixturePath(String name) => p.absolute('$_fixtureRoot/$name');

/// Writes a `claude` stand-in into [dir] that replays [fixture].
String _fakeClaude(Directory dir, String fixture) {
  final script = File(p.join(dir.path, 'claude-$fixture'));
  script.writeAsStringSync('''
#!/bin/sh
cat "${_fixturePath(fixture)}"
''');
  Process.runSync('chmod', ['+x', script.path]);
  return script.path;
}

/// One JSON object per line, decoded — the shape `watch --json` emits.
List<ProtocolFrame> _frames(String stdout) => [
  for (final line in const LineSplitter().convert(stdout))
    if (line.trim().isNotEmpty) ProtocolFrame.decodeLine(line),
];

void main() {
  late Directory tmp;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sprout_observe_test');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String db() => p.join(tmp.path, 'sprout.db');

  Future<int> run(List<String> arguments) =>
      cli.sprout(arguments, out: out, err: err, environment: const {});

  /// Seeds the store by running the CLI's own `run` against a Phase 0 capture.
  ///
  /// Real events, written by the real projection, rather than rows invented
  /// here — the events a consumer replays have to be the events sprout
  /// actually writes or the join proves nothing (INV10).
  Future<void> seedFrom(String fixture) async {
    final code = await cli.sprout(
      [
        'run',
        'task from $fixture',
        '--claude',
        _fakeClaude(tmp, fixture),
        '--db',
        db(),
        '--logs',
        p.join(tmp.path, 'sessions'),
        '-C',
        tmp.path,
      ],
      out: StringBuffer(),
      err: err,
      environment: const {},
    );
    expect(code, cli.exitOk, reason: err.toString());
  }

  /// Runs the real entrypoint as a process and returns it.
  Future<ProcessResult> cliProcess(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    ['bin/sprout.dart', ...arguments],
  );

  group('sprout snapshot', () {
    test('prints the fields that survive compression, as literals, and their '
        'opposites', () async {
      final store = SproutStore.open(path: db());
      store
        // No `since`, no `next_checkin`, and no cost reported: three
        // absences, each of which must be loud rather than blank.
        ..putNode(
          const SproutNode(
            id: 'silent',
            project: '/p',
            status: NodeStatus.checkpointed,
          ),
        )
        // The paired positive. Without it, a renderer that printed
        // `NONE SCHEDULED` unconditionally would pass the assertion below,
        // and a check that cannot fail is not a check (INV8).
        ..putNode(
          SproutNode(
            id: 'scheduled',
            project: '/p',
            status: NodeStatus.working,
            currentTask: 'a task',
            since: DateTime.utc(2026, 9, 1, 12),
            nextCheckin: DateTime.utc(2026, 9, 1, 13, 45),
          ),
        )
        ..append(nodeId: 'silent', kind: 'runner.spawned');
      store.close();

      expect(await run(['snapshot', '--db', db()]), cli.exitOk);
      final text = out.toString();

      // The literals, spelled out. These are exactly the fields that
      // silently become an empty string, so the test asserts the string a
      // human would read and not only the constant it came from.
      expect(text, contains('NONE SCHEDULED'));
      expect(text, contains('since ?'));
      expect(text, contains('spend ?'));
      expect(text, contains('journal readable'));
      expect(noCheckinText, 'NONE SCHEDULED');
      expect(unknownValueText, '?');
      expect(journalReadableText, 'journal readable');

      // And their opposites, in the same run: the scheduled node prints a
      // clock rather than NONE SCHEDULED, and the working node is holding
      // its project directory rather than `holds nothing`.
      expect(text, contains('next 13:45Z'));
      expect(text, contains('holds /p'));
      expect(text, isNot(contains(nothingHeldText)));

      final silent = const LineSplitter()
          .convert(text)
          .firstWhere((line) => line.contains('silent'));
      expect(silent, contains('NONE SCHEDULED'));
      expect(silent, contains('since ?'));
      // A node with no task is `?` in its own column, never blank.
      expect(silent.split(' \u00b7 ')[2], unknownValueText);
    });

    test(
      'renders an empty store as something rather than as nothing',
      () async {
        expect(await run(['snapshot', '--db', db()]), cli.exitOk);
        final text = out.toString();
        expect(text, contains(noNodesText));
        expect(text, contains(nothingHeldText));
        expect(text, contains(journalReadableText));
        expect(text, contains('cursor s1.'));
      },
    );

    test(
      '--json carries every key, with an explicit null where absent',
      () async {
        final store = SproutStore.open(path: db());
        store
          ..putNode(
            const SproutNode(
              id: 'silent',
              project: '/p',
              status: NodeStatus.checkpointed,
            ),
          )
          ..append(nodeId: 'silent', kind: 'runner.spawned');
        store.close();

        expect(await run(['snapshot', '--db', db(), '--json']), cli.exitOk);
        final json = jsonDecode(out.toString()) as Map<String, Object?>;

        // Present-and-null, not omitted: an absent key is the JSON spelling of
        // a blank field, and a blank field reads as "fine".
        expect(json.containsKey(journalUnreadableKey), isTrue);
        expect(json[journalUnreadableKey], isNull);
        final node = (json['nodes'] as List).single as Map<String, Object?>;
        for (final key in ['since', 'next_checkin', 'own_cost_usd', 'role']) {
          expect(node.containsKey(key), isTrue, reason: '$key is missing');
          expect(node[key], isNull, reason: '$key should be an explicit null');
        }
        expect(Cursor.tryParse(json['cursor']! as String), isNotNull);
      },
    );

    test('refuses a store it cannot read, and reads one it can', () async {
      final broken = p.join(tmp.path, 'not-a-database');
      File(broken).writeAsStringSync('this is not a SQLite file');
      expect(await run(['snapshot', '--db', broken]), cli.exitStoreUnreadable);
      expect(err.toString(), contains('cannot read the store at $broken'));

      // The paired positive, in the same test: a real store still exits ok,
      // so the code above is a refusal rather than a verb that never works.
      out.clear();
      expect(await run(['snapshot', '--db', db()]), cli.exitOk);
      expect(out.toString(), contains(journalReadableText));
    });
  });

  group('sprout watch', () {
    test('gives a foreign cursor and a malformed one different codes and '
        'different words, and accepts its own', () async {
      await seedFrom('A.ndjson');
      expect(await run(['snapshot', '--db', db(), '--json']), cli.exitOk);
      final mine =
          (jsonDecode(out.toString()) as Map<String, Object?>)['cursor']!
              as String;

      // Well formed, wrong daemon. The consumer's cursor is not corrupt, so
      // the message names both instances and points at a fresh snapshot.
      out.clear();
      err.clear();
      final foreign = Cursor(
        instanceId: '00000000deadbeef',
        position: 3,
      ).encode();
      expect(
        await run(['watch', '--db', db(), '--since', foreign, '--replay-only']),
        cli.exitCursorForeign,
      );
      expect(err.toString(), contains('00000000deadbeef'));
      expect(err.toString(), contains('take a fresh snapshot'));
      // The stream still says goodbye rather than just stopping.
      expect(out.toString(), contains('bye | refused'));

      // Not a cursor at all. A different code and a different message: the
      // remedy here is to fix the value, not to take a new snapshot.
      out.clear();
      err.clear();
      expect(
        await run([
          'watch',
          '--db',
          db(),
          '--since',
          'total-nonsense',
          '--replay-only',
        ]),
        cli.exitCursorMalformed,
      );
      expect(err.toString(), contains('not a sprout cursor'));
      expect(err.toString(), isNot(contains('take a fresh snapshot')));
      expect(cli.exitCursorForeign, isNot(cli.exitCursorMalformed));

      // The third outcome, in the same test: this instance's own cursor is
      // accepted. Without it the two refusals above would be satisfied by a
      // verb that refuses everything.
      out.clear();
      err.clear();
      expect(
        await run(['watch', '--db', db(), '--since', mine, '--replay-only']),
        cli.exitOk,
      );
      expect(out.toString(), contains('ready | $mine'));
    });

    test(
      'emits ready on an empty backlog, and never a bare delta in its place',
      () async {
        await seedFrom('A.ndjson');
        expect(await run(['snapshot', '--db', db(), '--json']), cli.exitOk);
        final head =
            (jsonDecode(out.toString()) as Map<String, Object?>)['cursor']!
                as String;

        // Resuming from the head: nothing to replay. The consumer must still
        // be told replay is over, or it waits on a blank screen forever.
        out.clear();
        expect(
          await run(['watch', '--db', db(), '--since', head, '--replay-only']),
          cli.exitOk,
        );
        expect(out.toString(), contains('end of replay'));

        // The same run in --json, so the assertion is about frame types
        // rather than about wording.
        out.clear();
        expect(
          await run([
            'watch',
            '--db',
            db(),
            '--since',
            head,
            '--replay-only',
            '--json',
          ]),
          cli.exitOk,
        );
        var frames = _frames(out.toString());
        expect(frames, hasLength(1));
        expect(frames.single, isA<ReadyFrame>());
        expect(frames.single.marksEndOfReplay, isTrue);
        expect(frames.whereType<DeltaFrame>(), isEmpty);

        // The paired case: with a backlog, deltas arrive *before* the ready,
        // and the ready is still exactly one frame. A consumer branching on
        // "did that delta carry events" would call the first delta the end of
        // replay here and the blank stream above never-ending.
        out.clear();
        expect(
          await run([
            'watch',
            '--db',
            db(),
            '--since',
            Cursor(
              instanceId: Cursor.parse(head).instanceId,
              position: 0,
            ).encode(),
            '--replay-only',
            '--json',
          ]),
          cli.exitOk,
        );
        frames = _frames(out.toString());
        expect(frames.whereType<DeltaFrame>(), isNotEmpty);
        expect(frames.where((f) => f.marksEndOfReplay), hasLength(1));
        expect(frames.last.marksEndOfReplay, isTrue);
      },
    );

    test('refuses a store it cannot read, and reads one it can', () async {
      final broken = p.join(tmp.path, 'not-a-database');
      File(broken).writeAsStringSync('this is not a SQLite file');
      expect(
        await run(['watch', '--db', broken, '--replay-only']),
        cli.exitStoreUnreadable,
      );
      expect(err.toString(), contains('cannot read the store at $broken'));

      out.clear();
      expect(await run(['watch', '--db', db(), '--replay-only']), cli.exitOk);
      expect(out.toString(), contains('end of replay'));
    });

    test('refuses a heartbeat interval that would never fire', () async {
      expect(
        await run(['watch', '--db', db(), '--heartbeat-ms', '0']),
        cli.exitUsage,
      );
      expect(err.toString(), contains('--heartbeat-ms'));
    });
  });

  group('the snapshot / watch join, driven as a process', () {
    test(
      'watch --since a snapshot cursor carries the consumer to the head with '
      'no gap and no double-apply',
      () async {
        await seedFrom('A.ndjson');

        // 1. The picture, taken by one process.
        final first = await cliProcess(['snapshot', '--db', db(), '--json']);
        expect(first.exitCode, cli.exitOk, reason: '${first.stderr}');
        final before =
            jsonDecode(first.stdout as String) as Map<String, Object?>;
        final cursor = Cursor.parse(before['cursor']! as String);

        // 2. The world moves on: a second capture, with its own nodes.
        await seedFrom('C.ndjson');

        // 3. The truth as of now, taken by a third process.
        final second = await cliProcess(['snapshot', '--db', db(), '--json']);
        expect(second.exitCode, cli.exitOk, reason: '${second.stderr}');
        final after =
            jsonDecode(second.stdout as String) as Map<String, Object?>;
        final head = Cursor.parse(after['cursor']! as String);

        // The join is only meaningful if the cursor actually moved. Without
        // this the assertions below would pass over an empty delta set.
        expect(head.position, greaterThan(cursor.position));

        // 4. The deltas, taken by a fourth process, resuming from step 1's
        //    cursor. That a cursor minted in one process is accepted in
        //    another is the whole promise: see `SproutInstance.forFeed` in
        //    lib/protocol.dart, which namespaces the cursor by the feed rather
        //    than by the process, and which the daemon's socket calls too.
        final watched = await cliProcess([
          'watch',
          '--db',
          db(),
          '--since',
          cursor.encode(),
          '--replay-only',
          '--json',
        ]);
        expect(watched.exitCode, cli.exitOk, reason: '${watched.stderr}');
        final frames = _frames(watched.stdout as String);

        expect(cursor.instanceId, head.instanceId);
        for (final frame in frames) {
          expect(frame.cursor.instanceId, cursor.instanceId);
        }

        // Replay, then exactly one ready, and the ready last.
        expect(frames.where((f) => f.marksEndOfReplay), hasLength(1));
        expect(frames.last, isA<ReadyFrame>());
        expect(frames.last.cursor, head, reason: 'the two halves must meet');

        // No gap and no double-apply: the seqs are exactly cursor+1 .. head,
        // contiguous, each one once.
        final seqs = [
          for (final delta in frames.whereType<DeltaFrame>())
            for (final event in delta.events) event.seq,
        ];
        expect(seqs.first, cursor.position + 1, reason: 'no double-apply');
        expect(seqs.last, head.position, reason: 'no gap at the head');
        expect(
          seqs,
          List.generate(
            head.position - cursor.position,
            (i) => cursor.position + 1 + i,
          ),
        );

        // Where the consumer arrives, and where it does not.
        final knownBefore = {
          for (final node
              in (before['nodes']! as List).cast<Map<String, Object?>>())
            node['id']! as String,
        };
        final namedByDeltas = {
          for (final delta in frames.whereType<DeltaFrame>())
            for (final event in delta.events) event.nodeId,
        };
        final knownAfter = {
          for (final node
              in (after['nodes']! as List).cast<Map<String, Object?>>())
            node['id']! as String,
        };
        // The deltas never invent a node, and never lose one the snapshot
        // already had. That much the consumer does get right.
        expect(knownAfter.containsAll(namedByDeltas), isTrue);
        expect(knownAfter.containsAll(knownBefore), isTrue);
        expect(knownAfter.length, greaterThan(knownBefore.length));
        // A new ROOT announces itself: `runner.spawned` is appended against
        // its own id, so the consumer learns of it from the feed alone.
        expect(namedByDeltas.difference(knownBefore), isNotEmpty);

        // **But a subagent node is invisible to the feed.**
        // `StoreProjection._syncSubagents` writes the subagent's row with
        // `putNode` and appends no event for it
        // (`lib/src/runner/projection.dart:143`), while every frame it emits
        // is attributed to the node that emitted it. So a consumer holding
        // this snapshot plus every delta after it still does not know the
        // subagent exists, and only a fresh `snapshot` will tell it.
        //
        // Asserted rather than skipped, and asserted as a *fact about the
        // feed* rather than relaxed away: a test that simply stopped looking
        // here would report the same green as one that checked (INV8). The
        // feed is written in `lib/src/runner/`, which this leaf does not own,
        // so this is reported rather than repaired. When node creation gains
        // an event, this expectation fails and says exactly what changed.
        final invisible = knownAfter.difference(
          knownBefore.union(namedByDeltas),
        );
        expect(
          invisible,
          isNotEmpty,
          reason:
              'if this is now empty, node creation reached the feed and the '
              'comment above is stale',
        );
        for (final id in invisible) {
          expect(
            id,
            contains('/'),
            reason:
                'only subagent nodes should be missing from the feed; a '
                'missing root would mean runner.spawned stopped being appended',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'shows heartbeats on an idle tree, says bye on Ctrl-C, and exits',
      () async {
        await seedFrom('A.ndjson');
        final process = await Process.start(Platform.resolvedExecutable, [
          'bin/sprout.dart',
          'watch',
          '--db',
          db(),
          '--heartbeat-ms',
          '100',
        ]);
        final lines = <String>[];
        final reading = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add);

        // Nothing at all happens in the tree while this waits. A stream that
        // has died would print exactly what a quiet one prints — nothing —
        // which is what the heartbeat exists to tell apart, and what a
        // consumer that hid them would put back.
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (lines.where((l) => l.startsWith('heartbeat')).length < 3 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          lines.where((l) => l.startsWith('heartbeat')),
          hasLength(greaterThanOrEqualTo(3)),
          reason: 'heartbeats must be visible to the consumer',
        );

        process.kill(ProcessSignal.sigint);
        // The process must actually exit. `async*` + `await for` would leave
        // a cancel pending on an idle tree (dart-lang/sdk#26686); this is the
        // assertion that the StreamController-driven session does not.
        expect(await process.exitCode, cli.exitOk);
        await reading.cancel();

        // Ended, and said so. A stream that simply stopped did not end, it
        // broke, and the two must not look the same.
        expect(lines.last, startsWith('bye | shutdown'));
        expect(lines.last, contains('interrupted'));
        expect(lines.first, startsWith('ready'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
