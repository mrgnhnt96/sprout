@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/liveness.dart';
import 'package:sproutd/store.dart';
import 'package:test/test.dart';

/// Long enough that a sweep (which shells out to `ps` per node) cannot age a
/// transcript past it by accident, short enough that a test can wait it out.
const frozenAfter = Duration(seconds: 2);

/// Comfortably past [frozenAfter], so a frozen transcript really is frozen.
const pastFrozen = Duration(milliseconds: 2600);

void main() {
  late Directory dir;
  late SproutStore store;
  final running = <Process>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sprout-liveness-');
    store = SproutStore.memory();
  });

  tearDown(() {
    for (final process in running) {
      process.kill(ProcessSignal.sigkill);
    }
    running.clear();
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String transcriptPath(String nodeId) => p.join(dir.path, '$nodeId.ndjson');

  /// Records a node and the `runner.spawned` event for [pid].
  ///
  /// [spawnedAt] defaults to now, which is the honest ordering: the runner
  /// appends this event *after* the process exists, so a real process always
  /// started at or before it.
  void record(
    String nodeId, {
    required int pid,
    String? parentId,
    DateTime? spawnedAt,
    NodeStatus status = NodeStatus.working,
    String? rawLog,
  }) {
    final at = spawnedAt ?? DateTime.now().toUtc();
    store.putNode(
      SproutNode(
        id: nodeId,
        parentId: parentId,
        project: dir.path,
        status: status,
      ),
      ts: at,
    );
    store.append(
      nodeId: nodeId,
      kind: runnerSpawnedKind,
      payload: {'pid': pid, 'raw_log': rawLog ?? transcriptPath(nodeId)},
      ts: at,
    );
  }

  /// A real process that appends to its own transcript forever.
  Future<Process> writer(String nodeId) async {
    final process = await Process.start('/bin/sh', [
      '-c',
      r'while :; do printf "{}\n" >> "$0"; sleep 0.05; done',
      transcriptPath(nodeId),
    ]);
    running.add(process);
    // Do not record the spawn until the process has actually written, so the
    // "live" case is a transcript that grew rather than one that might.
    final file = File(transcriptPath(nodeId));
    while (!file.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return process;
  }

  /// A real process that is alive and writes nothing at all.
  Future<Process> sleeper(String nodeId, {bool withTranscript = true}) async {
    final process = await Process.start('/bin/sh', ['-c', 'sleep 300']);
    running.add(process);
    if (withTranscript) {
      File(transcriptPath(nodeId)).writeAsStringSync('{"seed":true}\n');
    }
    return process;
  }

  LivenessMeasure measureOver({
    ProcessProbe? processes,
    TranscriptIndex? transcripts,
    DateTime Function()? clock,
    Duration? frozen,
  }) {
    return LivenessMeasure(
      store: store,
      processes: processes ?? const PsProcessProbe(),
      transcripts: transcripts ?? const FileTranscripts(),
      frozenAfter: frozen ?? frozenAfter,
      clock: clock,
    );
  }

  group('PsProcessProbe against real processes', () {
    test('reports this very process as running, started before now', () async {
      final look = await const PsProcessProbe().inspect(pid);
      expect(look, isA<ProcessRunning>());
      final running = look as ProcessRunning;
      expect(running.pid, pid);
      expect(running.startedAt.isUtc, isTrue);
      // Second resolution, so "before now" is the only safe ordering.
      expect(
        running.startedAt.isAfter(DateTime.now().toUtc()),
        isFalse,
        reason: 'a process cannot have started in the future',
      );
    });

    test('reports a reaped child as gone, not as unreadable', () async {
      final process = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await process.exitCode;
      final look = await const PsProcessProbe().inspect(process.pid);
      expect(look, isA<ProcessGone>());
    });

    test('a ps that cannot be run is unreadable, never gone', () async {
      // The distinction this whole class exists for: a failed look must not
      // become "the process is not there", or every node reads as abandoned
      // the moment the tool is missing.
      const probe = PsProcessProbe(executable: '/nonexistent/ps');
      final look = await probe.inspect(pid);
      expect(look, isA<ProcessUnreadable>());
      expect((look as ProcessUnreadable).why, contains('/nonexistent/ps'));
    });

    test('a pid that is not a pid is unreadable', () async {
      expect(await const PsProcessProbe().inspect(0), isA<ProcessUnreadable>());
      expect(
        await const PsProcessProbe().inspect(-1),
        isA<ProcessUnreadable>(),
      );
    });

    test('parses the lstart macOS actually prints, and rejects junk', () {
      // Captured by running `ps -o lstart= -p $$` in this repo's shell, not
      // copied from a man page. Note the two spaces before a single-digit day
      // and the trailing padding ps emits.
      final parsed = PsProcessProbe.parseLstart('Wed Sep  2 14:09:09 2026   ');
      expect(parsed, isNotNull);
      expect(parsed!.isUtc, isTrue);
      expect(
        parsed,
        DateTime(2026, 9, 2, 14, 9, 9).toUtc(),
        reason: 'ps prints LOCAL time with no offset',
      );
      expect(PsProcessProbe.parseLstart('Sat Aug 29 07:19:44 2026'), isNotNull);
      expect(PsProcessProbe.parseLstart(''), isNull);
      expect(PsProcessProbe.parseLstart('Wed Xyz 2 14:09:09 2026'), isNull);
      expect(PsProcessProbe.parseLstart('2026-09-02T14:09:09Z'), isNull);
    });
  });

  group('live — a real process writing to its transcript', () {
    test('is live, and stays live while the file keeps growing', () async {
      final process = await writer('w1');
      record('w1', pid: process.pid);
      final measure = measureOver();

      expect((await measure.verdictFor('w1'))!.liveness, Liveness.live);

      // The negative half of the stalled test, and the one that matters: a
      // node must NOT flip while its transcript is still being written. Waited
      // out in real time, past the same threshold that flips the sleeper.
      await Future<void>.delayed(pastFrozen);
      final later = (await measure.verdictFor('w1'))!;
      expect(later.liveness, Liveness.live);
      expect(later.frozenFor!, lessThan(frozenAfter));
    });

    test('a legitimate pid is never mistaken for a recycled one', () async {
      // The direction of the start-time check, pinned. A real process always
      // starts BEFORE its own runner.spawned event is appended, and `ps`
      // rounds start times DOWN to the second, so both errors point the same
      // way. A check written the other way round — "older than the spawn means
      // an impostor" — would call every healthy node abandoned.
      final process = await writer('w2');
      record('w2', pid: process.pid);
      final verdict = (await measureOver().verdictFor('w2'))!;
      expect(verdict.liveness, Liveness.live);
      expect(
        verdict.processStartedAt!.isAfter(verdict.spawnedAt!),
        isFalse,
        reason: 'the process must predate the event that recorded it',
      );
    });
  });

  group('stalled — a real process alive and writing nothing', () {
    test('flips from live to stalled as the transcript ages', () async {
      final process = await sleeper('s1');
      record('s1', pid: process.pid);
      final measure = measureOver();

      final fresh = (await measure.verdictFor('s1'))!;
      expect(fresh.liveness, Liveness.live, reason: 'just seeded, not frozen');

      await Future<void>.delayed(pastFrozen);
      final stale = (await measure.verdictFor('s1'))!;
      expect(stale.liveness, Liveness.stalled);
      expect(stale.pid, process.pid);
      expect(stale.processStartedAt, isNotNull);
      expect(stale.frozenFor!, greaterThanOrEqualTo(frozenAfter));
      expect(stale.because, contains('${process.pid}'));
    });

    test('a stalled verdict is worth surfacing and is still a verdict', () {
      // `worthSurfacing` was `pages` until P6-03 settled F-13. The SET is
      // unchanged — `unmeasured` is still in it, which was P6-01's whole point
      // — and only the name moved, so that it stops reading as the watchdog's
      // ring predicate. That one is `ringingVerdicts`, and
      // `test/watchdog_test.dart` pins the two side by side.
      expect(Liveness.stalled.worthSurfacing, isTrue);
      expect(Liveness.stalled.isVerdict, isTrue);
      expect(Liveness.live.worthSurfacing, isFalse);
      expect(Liveness.unmeasured.worthSurfacing, isTrue);
      expect(Liveness.unmeasured.isVerdict, isFalse);
      expect(Liveness.ended.worthSurfacing, isFalse);
      expect(Liveness.ended.isVerdict, isFalse);
    });

    test(
      'a node that never wrote a transcript is young, then stalled',
      () async {
        // An absent transcript is not a frozen one. Without this, a node is
        // stalled for the few hundred milliseconds between spawning and its
        // first frame — and worse, an unwritable log directory would page for
        // every node in the tree.
        final process = await sleeper('s2', withTranscript: false);
        record('s2', pid: process.pid);
        final measure = measureOver();
        expect((await measure.verdictFor('s2'))!.liveness, Liveness.live);
        await Future<void>.delayed(pastFrozen);
        expect((await measure.verdictFor('s2'))!.liveness, Liveness.stalled);
      },
    );
  });

  group('abandoned — no live process and no honest ending', () {
    test('a process that exited with nothing recorded is abandoned', () async {
      final process = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await process.exitCode;
      record('a1', pid: process.pid);
      final verdict = (await measureOver().verdictFor('a1'))!;
      expect(verdict.liveness, Liveness.abandoned);
      expect(verdict.because, contains('no process holds pid ${process.pid}'));
    });

    test('process exit alone is not an ending, even with a result', () async {
      // INV12, from the other side. `runner.dart` refuses to infer completion
      // from exit, so a node still `working` with a dead pid is abandoned no
      // matter what the feed says about how the process finished.
      final process = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await process.exitCode;
      record('a2', pid: process.pid);
      store.append(nodeId: 'a2', kind: 'runner.exited', payload: {'code': 0});
      expect(
        (await measureOver().verdictFor('a2'))!.liveness,
        Liveness.abandoned,
      );
    });

    test('a node the gate refused is abandoned, in the gate words', () async {
      store.putNode(
        const SproutNode(
          id: 'r1',
          project: '/tmp',
          status: NodeStatus.spawning,
        ),
      );
      store.append(
        nodeId: 'r1',
        kind: runnerRefusedKind,
        payload: {'reason': 'depth', 'explanation': 'depth 4 exceeds the cap'},
      );
      final verdict = (await measureOver().verdictFor('r1'))!;
      expect(verdict.liveness, Liveness.abandoned);
      expect(verdict.because, contains('depth 4 exceeds the cap'));
    });

    test('a launch that failed names the error', () async {
      store.putNode(
        const SproutNode(
          id: 'l1',
          project: '/tmp',
          status: NodeStatus.spawning,
        ),
      );
      store.append(
        nodeId: 'l1',
        kind: runnerLaunchFailedKind,
        payload: {'error': 'ProcessException: claude not found'},
      );
      final verdict = (await measureOver().verdictFor('l1'))!;
      expect(verdict.liveness, Liveness.abandoned);
      expect(verdict.because, contains('claude not found'));
    });
  });

  group('the recycled pid', () {
    test('a live pid recorded before that process started is abandoned', () async {
      // Constructed rather than waited for: the OS cannot be asked to recycle
      // a pid on demand, so this produces the observable state recycling
      // produces — pid P is genuinely alive, and P's process demonstrably
      // started AFTER the node recorded P. Real process, real `ps`, real start
      // time; only the recorded spawn is backdated.
      final process = await sleeper('p1');
      record(
        'p1',
        pid: process.pid,
        spawnedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
      final verdict = (await measureOver().verdictFor('p1'))!;
      expect(verdict.liveness, Liveness.abandoned);
      expect(verdict.because, contains('the pid was reused'));
      expect(verdict.pid, process.pid);
      expect(verdict.processStartedAt!.isAfter(verdict.spawnedAt!), isTrue);
    });

    test(
      'and a live writer under the same backdating is still abandoned',
      () async {
        // The dangerous half: a busy process wearing a reused pid would
        // otherwise read as a healthy node, because its transcript is growing.
        // The start-time check has to run before the transcript is consulted.
        final process = await writer('p2');
        record(
          'p2',
          pid: process.pid,
          spawnedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        );
        expect(
          (await measureOver().verdictFor('p2'))!.liveness,
          Liveness.abandoned,
        );
      },
    );

    test('newest wins: the newer spawn event decides', () async {
      final dead = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await dead.exitCode;
      final alive = await writer('n1');
      final old = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      store.putNode(
        SproutNode(id: 'n1', project: dir.path, status: NodeStatus.working),
        ts: old,
      );
      store.append(
        nodeId: 'n1',
        kind: runnerSpawnedKind,
        payload: {'pid': dead.pid, 'raw_log': transcriptPath('n1')},
        ts: old,
      );
      store.append(
        nodeId: 'n1',
        kind: runnerSpawnedKind,
        payload: {'pid': alive.pid, 'raw_log': transcriptPath('n1')},
        ts: DateTime.now().toUtc(),
      );
      final verdict = (await measureOver().verdictFor('n1'))!;
      expect(verdict.liveness, Liveness.live);
      expect(verdict.pid, alive.pid);
    });
  });

  group('waiting is not stalled', () {
    test('a frozen parent with an advancing child is live', () async {
      final parent = await sleeper('root');
      final child = await writer('kid');
      record('root', pid: parent.pid);
      record('kid', pid: child.pid, parentId: 'root');

      await Future<void>.delayed(pastFrozen);
      final verdicts = await measureOver().sweep();
      expect(verdicts['kid']!.liveness, Liveness.live);
      expect(
        verdicts['root']!.liveness,
        Liveness.live,
        reason: 'the parent is waiting on a child that is working',
      );
      expect(verdicts['root']!.waitingOn, 'kid');
      expect(verdicts['root']!.because, contains('waiting, not stalled'));
      // The evidence is still carried: the parent really is frozen, and a
      // human reading the report can see both facts at once.
      expect(verdicts['root']!.frozenFor!, greaterThanOrEqualTo(frozenAfter));
    });

    test('the rescue is transitive through a frozen middle node', () async {
      final root = await sleeper('t-root');
      final mid = await sleeper('t-mid');
      final leaf = await writer('t-leaf');
      record('t-root', pid: root.pid);
      record('t-mid', pid: mid.pid, parentId: 't-root');
      record('t-leaf', pid: leaf.pid, parentId: 't-mid');

      await Future<void>.delayed(pastFrozen);
      final verdicts = await measureOver().sweep();
      expect(verdicts['t-leaf']!.liveness, Liveness.live);
      expect(verdicts['t-mid']!.liveness, Liveness.live);
      expect(verdicts['t-root']!.liveness, Liveness.live);
      expect(verdicts['t-root']!.waitingOn, 't-leaf');
    });

    test('a frozen parent whose subtree has finished is stalled', () async {
      // The paired negative, and the one that keeps the rescue honest: if a
      // busy descendant excuses a frozen parent, a subtree that has ENDED must
      // not. Otherwise a watchdog stops firing the moment a node has children.
      final parent = await sleeper('e-root');
      final child = await writer('e-kid');
      record('e-root', pid: parent.pid);
      record(
        'e-kid',
        pid: child.pid,
        parentId: 'e-root',
        status: NodeStatus.checkpointed,
      );

      await Future<void>.delayed(pastFrozen);
      final verdicts = await measureOver().sweep();
      expect(verdicts['e-kid']!.liveness, Liveness.ended);
      expect(verdicts['e-root']!.liveness, Liveness.stalled);
      expect(verdicts['e-root']!.waitingOn, isNull);
    });

    test('a dead parent is not rescued by a busy child', () async {
      // A node whose own process is gone is not waiting on anything. Letting a
      // descendant rescue it would hide a dead orchestrator behind its
      // children — which is a runaway subtree with nobody minding it.
      final dead = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await dead.exitCode;
      final child = await writer('d-kid');
      record('d-root', pid: dead.pid);
      record('d-kid', pid: child.pid, parentId: 'd-root');

      final verdicts = await measureOver().sweep();
      expect(verdicts['d-kid']!.liveness, Liveness.live);
      expect(verdicts['d-root']!.liveness, Liveness.abandoned);
    });
  });

  group('ended is not a liveness question', () {
    for (final status in endedStatuses) {
      test('${status.wire} with a dead pid is ended, not abandoned', () async {
        final process = await Process.start('/bin/sh', ['-c', 'exit 0']);
        await process.exitCode;
        record('end-${status.wire}', pid: process.pid, status: status);
        final verdict = (await measureOver().verdictFor('end-${status.wire}'))!;
        expect(verdict.liveness, Liveness.ended);
        expect(verdict.because, contains(status.wire));
      });
    }

    test('park is an ending here, and only a human sets it', () {
      // §5's three honest endings plus the human-only fourth, and nothing
      // else. `spawning` and `working` are the states a verdict is ABOUT.
      expect(endedStatuses, contains(NodeStatus.parked));
      expect(endedStatuses, isNot(contains(NodeStatus.working)));
      expect(endedStatuses, isNot(contains(NodeStatus.spawning)));
      expect(endedStatuses.length, 4);
    });
  });

  group('a failed read is never folded into a verdict', () {
    test('an unreadable ps is unmeasured, not abandoned', () async {
      final process = await sleeper('u1');
      record('u1', pid: process.pid);
      final measure = measureOver(
        processes: const PsProcessProbe(executable: '/nonexistent/ps'),
      );
      final verdict = (await measure.verdictFor('u1'))!;
      expect(verdict.liveness, Liveness.unmeasured);
      expect(verdict.because, contains('could not look at pid'));
    });

    test('an unreadable transcript is unmeasured, not stalled', () async {
      final process = await sleeper('u2');
      record('u2', pid: process.pid);
      final measure = measureOver(transcripts: const _BrokenTranscripts());
      final verdict = (await measure.verdictFor('u2'))!;
      expect(verdict.liveness, Liveness.unmeasured);
      expect(verdict.because, contains('permission denied'));
    });

    test('a spawn event with no raw_log is unmeasured', () async {
      final process = await sleeper('u3');
      store.putNode(
        SproutNode(id: 'u3', project: dir.path, status: NodeStatus.working),
      );
      store.append(
        nodeId: 'u3',
        kind: runnerSpawnedKind,
        payload: {'pid': process.pid},
      );
      final verdict = (await measureOver().verdictFor('u3'))!;
      expect(verdict.liveness, Liveness.unmeasured);
      expect(verdict.because, contains('no raw_log path'));
    });

    test('a missing transcript file is absent, not epoch-old', () async {
      final look = await const FileTranscripts().lastWrite(
        p.join(dir.path, 'nothing-here.ndjson'),
      );
      expect(look, isA<TranscriptAbsent>());
    });
  });

  group('the sweep', () {
    test('covers every node in the graph and no others', () async {
      final one = await writer('sw-a');
      final two = await sleeper('sw-b');
      record('sw-a', pid: one.pid);
      record('sw-b', pid: two.pid, parentId: 'sw-a');
      final verdicts = await measureOver().sweep();
      expect(verdicts.keys, unorderedEquals(['sw-a', 'sw-b']));
    });

    test('verdictFor returns null for an id the graph does not hold', () async {
      expect(await measureOver().verdictFor('nobody'), isNull);
    });

    test('the threshold is a knob P6-02 can pass its own value for', () async {
      final process = await sleeper('k1');
      record('k1', pid: process.pid);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        (await measureOver(frozen: const Duration(days: 1)).verdictFor('k1'))!
            .liveness,
        Liveness.live,
      );
      expect(
        (await measureOver(frozen: const Duration(milliseconds: 1))
                .verdictFor('k1'))!
            .liveness,
        Liveness.stalled,
      );
      expect(defaultFrozenAfter, const Duration(minutes: 5));
      expect(defaultStartTimeTolerance, const Duration(seconds: 2));
    });
  });

  group('never auto-reclaim', () {
    test('nothing under lib/src/liveness can act on a process', () {
      // §5: "Never auto-reclaim a stalled node" — the real incident behind
      // that rule held four uncommitted files and a green test suite. This is
      // the rule as a check rather than as a sentence in a doc comment: the
      // library reads `ps` and `stat` and has no way to signal anything, and
      // P6-02 adding one here fails this test instead of shipping.
      final offenders = Directory('lib/src/liveness')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) =>
                RegExp(r'\.kill\(|ProcessSignal|Process\.killPid|\.terminate\(')
                    .hasMatch(f.readAsStringSync()),
          )
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'liveness surfaces and pages. Acting on a stalled node belongs to '
            'a human, and to no file in this directory.',
      );
    });

    test('and the only process it runs is a read-only ps', () {
      final source = File('lib/src/liveness/process_probe.dart')
          .readAsStringSync();
      expect(source, contains("['-o', 'lstart=', '-p', "));
      expect(source, isNot(contains('Process.start')));
    });
  });

  group('the runner event kinds this library re-spells', () {
    test('still match what session_runner.dart writes', () {
      // F-12: these three strings are declared in `measure.dart` as well as in
      // `session_runner.dart`, because lifting them into one declaration means
      // editing a file this leaf does not own. Until that happens, a rename
      // fails HERE rather than silently making every node abandoned — which is
      // the failure F-11 was, and it is invisible to a green suite otherwise.
      final source = File('lib/src/runner/session_runner.dart')
          .readAsStringSync();
      for (final kind in [
        runnerSpawnedKind,
        runnerRefusedKind,
        runnerLaunchFailedKind,
      ]) {
        expect(
          source,
          contains("kind: '$kind'"),
          reason: '$kind is no longer what the runner appends',
        );
      }
    });

    test('and the runner still records the pid and the raw log path', () {
      final source = File('lib/src/runner/session_runner.dart')
          .readAsStringSync();
      expect(source, contains("'pid': process.pid"));
      expect(source, contains("'raw_log': rawLogPath"));
      expect(source, contains(r"p.join(logDirectory, '$nodeId.ndjson')"));
    });
  });
}

/// A transcript index whose every look fails. Stands in for a log directory
/// the daemon has lost permission to read.
final class _BrokenTranscripts implements TranscriptIndex {
  const _BrokenTranscripts();

  @override
  Future<TranscriptLook> lastWrite(String path) async =>
      TranscriptUnreadable(path, 'permission denied');
}
