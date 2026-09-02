/// P6-02 — the watchdog loop, driven against real processes.
///
/// The two halves that make a watchdog demonstrable, and neither is optional:
/// **a watchdog that has never fired is not known to be a watchdog, and one
/// that has never declined to fire is not known to be quiet.** So every group
/// below that shows a ring has a partner that shows a silence, with the `why`
/// the silence was logged with.
///
/// The processes here are real `/bin/sh` children — one that appends to its
/// transcript forever, one that is alive and writes nothing. A watchdog tested
/// only against a stubbed probe has not been shown to work on the thing it
/// exists to watch.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/liveness.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/watchdog.dart';
import 'package:test/test.dart';

/// Long enough that a sweep (one `ps` and one `stat` per node) cannot age a
/// transcript past it by accident, short enough that a test can wait it out.
const frozenAfter = Duration(seconds: 2);

/// Comfortably past [frozenAfter], so a frozen transcript really is frozen.
const pastFrozen = Duration(milliseconds: 2600);

/// A settle that a test can wait out. The shipped default is five seconds.
const testSettle = Duration(milliseconds: 120);

void main() {
  late Directory dir;
  late SproutStore store;
  late RecordingBell bell;
  late MemoryWatchdogJournal journal;
  final running = <Process>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sprout-watchdog-');
    store = SproutStore.memory();
    bell = RecordingBell();
    journal = MemoryWatchdogJournal();
  });

  tearDown(() {
    // The test harness cleans up the children it started. The watchdog never
    // does, and `never acts` below asserts it has no way to.
    for (final process in running) {
      process.kill(ProcessSignal.sigkill);
    }
    running.clear();
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String transcriptPath(String nodeId) => p.join(dir.path, '$nodeId.ndjson');

  /// Records a node and the `runner.spawned` event carrying [pid].
  void record(
    String nodeId, {
    required int pid,
    String? parentId,
    NodeStatus status = NodeStatus.working,
  }) {
    final at = DateTime.now().toUtc();
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
      payload: {'pid': pid, 'raw_log': transcriptPath(nodeId)},
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
    final file = File(transcriptPath(nodeId));
    while (!file.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return process;
  }

  /// A real process that is alive and writes nothing at all — the stall.
  Future<Process> sleeper(String nodeId) async {
    final process = await Process.start('/bin/sh', ['-c', 'sleep 300']);
    running.add(process);
    File(transcriptPath(nodeId)).writeAsStringSync('{"seed":true}\n');
    return process;
  }

  Watchdog watchdogOver({
    ProcessProbe? processes,
    TranscriptIndex? transcripts,
    WatchdogJournal? into,
    WatchdogBell? onto,
    int ringCap = defaultRingCap,
    Duration settle = testSettle,
    Duration? interval,
    Future<void> Function(Duration)? sleep,
  }) {
    return Watchdog(
      store: store,
      bell: onto ?? bell,
      journal: into ?? journal,
      processes: processes ?? const PsProcessProbe(),
      transcripts: transcripts ?? const FileTranscripts(),
      frozenAfter: frozenAfter,
      settleFor: settle,
      interval: interval ?? const Duration(milliseconds: 20),
      ringCap: ringCap,
      sleep: sleep,
    );
  }

  group('1 — it rings on a real stall', () {
    test('a live child writing nothing rings, and says what it saw', () async {
      final process = await sleeper('stall-1');
      record('stall-1', pid: process.pid);
      // One line written after the spawn, then silence — the shape of a
      // session that started, said something, and wedged. Without it the
      // freshness reference is the spawn rather than the transcript, and this
      // test would not exercise the mtime at all.
      File(transcriptPath('stall-1'))
          .writeAsStringSync('{"hello":true}\n', mode: FileMode.append);
      await Future<void>.delayed(pastFrozen);

      final sweep = await watchdogOver().sweepOnce();

      expect(bell.rings, hasLength(1), reason: 'exactly one node contradicts');
      final ring = bell.rings.single;
      expect(ring.nodeId, 'stall-1');
      expect(ring.liveness, Liveness.stalled);
      expect(ring.consecutiveRings, 1);
      expect(ring.pid, process.pid);
      // The page has to be arguable by hand: a pid, a start time and a
      // frozen-for, so a human can check it in one `ps`.
      expect(ring.because, contains('pid ${process.pid} is alive'));
      expect(ring.because, contains('the transcript last grew'));
      expect(ring.frozenFor!.inSeconds, greaterThanOrEqualTo(2));

      expect(sweep.quiet, isFalse);
      expect(sweep.why, contains('rang for 1 of 1 node(s)'));
      expect(sweep.why, contains('stall-1 stalled'));
      expect(journal.last, same(sweep));
    });

    test(
      'a node whose process is gone rings as abandoned',
      () async {
        // A real process that really exited, so this is not a fabricated pid.
        final process = await Process.start('/bin/sh', ['-c', 'exit 0']);
        await process.exitCode;
        record('gone-1', pid: process.pid);

        await watchdogOver().sweepOnce();

        expect(bell.rings, hasLength(1));
        expect(bell.rings.single.liveness, Liveness.abandoned);
        expect(bell.rings.single.because, contains('no process holds pid'));
      },
      onPlatform: const {'windows': Skip('the fixtures are /bin/sh children')},
    );
  });

  group('2 — it does not ring while work is happening', () {
    test('a child that is writing is quiet, with a why', () async {
      final process = await writer('busy-1');
      record('busy-1', pid: process.pid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sweep = await watchdogOver().sweepOnce();

      expect(bell.rings, isEmpty);
      expect(sweep.quiet, isTrue);
      expect(sweep.why, startsWith('no ring:'));
      expect(sweep.why, contains('the 1 node(s) that could be measured'));
      expect(sweep.settledClear, isEmpty, reason: 'no settle was needed');
    });

    test('a frozen parent waiting on an advancing child does not ring', () {
      // P6-01 got the waiting case right; this asserts the loop does not undo
      // it. A watchdog that pages every time an orchestrator waits on its
      // children is switched off within a day, and then it guards nothing.
      return () async {
        final parent = await sleeper('wait-root');
        final child = await writer('wait-kid');
        record('wait-root', pid: parent.pid);
        record('wait-kid', pid: child.pid, parentId: 'wait-root');
        await Future<void>.delayed(pastFrozen);

        // The parent really is frozen — the measurement says so on its own.
        final verdicts = await LivenessMeasure(
          store: store,
          frozenAfter: frozenAfter,
        ).sweep();
        expect(verdicts['wait-root']!.waitingOn, 'wait-kid');

        final sweep = await watchdogOver().sweepOnce();

        expect(bell.rings, isEmpty, reason: 'waiting is not stalled');
        expect(sweep.why, contains('the 2 node(s) that could be measured'));
      }();
    });

    test('an ended node is not a contradiction', () async {
      final process = await sleeper('done-1');
      record('done-1', pid: process.pid, status: NodeStatus.checkpointed);
      await Future<void>.delayed(pastFrozen);

      final sweep = await watchdogOver().sweepOnce();

      expect(bell.rings, isEmpty);
      expect(sweep.why, contains('were live or ended'));
    });
  });

  group('3 — the cap holds, and then it resets', () {
    test('consecutive unproductive rings stop at the cap', () async {
      final process = await sleeper('cap-1');
      record('cap-1', pid: process.pid);
      await Future<void>.delayed(pastFrozen);
      final watchdog = watchdogOver(ringCap: 2);

      final first = await watchdog.sweepOnce();
      final second = await watchdog.sweepOnce();
      final third = await watchdog.sweepOnce();

      expect(bell.rings.map((r) => r.consecutiveRings), [1, 2]);
      expect(first.rang, hasLength(1));
      expect(second.rang, hasLength(1));

      // The third sweep still SEES the contradiction. It declines to ring, and
      // says so — the node is silenced until it advances, not for good.
      expect(third.rang, isEmpty);
      expect(third.silenced, hasLength(1));
      expect(third.silenced.single.consecutiveRings, 2);
      expect(third.silenced.single.why, contains('the cap of 2'));
      expect(third.why, contains('at the ring cap of 2'));
      expect(third.why, contains('not silenced for good'));
      expect(watchdog.ledger.isSilenced('cap-1'), isTrue);
    });

    test('progress resets the count and ringing resumes', () async {
      final process = await sleeper('cap-2');
      record('cap-2', pid: process.pid);
      await Future<void>.delayed(pastFrozen);
      final watchdog = watchdogOver(ringCap: 2);

      await watchdog.sweepOnce();
      await watchdog.sweepOnce();
      expect(watchdog.ledger.ringsFor('cap-2'), 2);
      expect((await watchdog.sweepOnce()).rang, isEmpty, reason: 'capped');

      // The node advances: its transcript grows, exactly as a session waking
      // up would make it grow.
      File(transcriptPath('cap-2'))
          .writeAsStringSync('{"awake":true}\n', mode: FileMode.append);

      final recovered = await watchdog.sweepOnce();
      expect(recovered.rang, isEmpty, reason: 'it is live again, not stalled');
      expect(recovered.why, contains('their ring counts reset'));
      expect(recovered.why, contains('cap-2'));
      expect(watchdog.ledger.ringsFor('cap-2'), 0, reason: 'the reset');

      // And it can ring again the next time it freezes, which is the whole
      // point of a cap that resets rather than a cap that ends the watch.
      await Future<void>.delayed(pastFrozen);
      final again = await watchdog.sweepOnce();
      expect(again.rang, hasLength(1));
      expect(again.rang.single.consecutiveRings, 1);
    });

    test(
      'the cap is per node, so one stuck node cannot mute the tree',
      () async {
        final stuck = await sleeper('cap-stuck');
        final other = await sleeper('cap-other');
        record('cap-stuck', pid: stuck.pid);
        await Future<void>.delayed(pastFrozen);
        final watchdog = watchdogOver(ringCap: 1);

        await watchdog.sweepOnce();
        expect(watchdog.ledger.isSilenced('cap-stuck'), isTrue);

        // A second node goes stale only now. The first node's exhausted budget
        // must not silence it — a tree-wide counter is a global mute wearing a
        // cap's clothing.
        record('cap-other', pid: other.pid);
        await Future<void>.delayed(pastFrozen);
        final sweep = await watchdog.sweepOnce();

        expect(sweep.rang.map((r) => r.nodeId), ['cap-other']);
        expect(sweep.silenced.map((s) => s.nodeId), ['cap-stuck']);
      },
    );

    test('a still-stalled node whose mark moved counts as progress', () {
      // The second reset path, driven on the ledger directly. Staging it
      // against real processes would need a node that advanced AND is frozen
      // again inside one sweep, which a 2-second threshold cannot hold still
      // for; the path it exercises is the one a five-minute threshold reaches
      // in production, where a node writes, goes quiet for six minutes, and is
      // a NEW stall rather than the continuation of the rung one.
      final ledger = RingLedger(cap: 1);
      final at = DateTime.utc(2026, 9, 2, 12);
      LivenessVerdict frozenAt(DateTime mark) => LivenessVerdict(
        nodeId: 'm1',
        liveness: Liveness.stalled,
        because: 'frozen',
        lastWrite: mark,
      );

      expect(ledger.rule(Contradiction(frozenAt(at))).rings, isTrue);
      expect(ledger.rule(Contradiction(frozenAt(at))).rings, isFalse);

      final moved = ledger.rule(
        Contradiction(frozenAt(at.add(const Duration(minutes: 7)))),
      );
      expect(moved.rings, isTrue, reason: 'the node advanced between rings');
      expect(moved.why, contains('the node advanced since its last ring'));
      expect(moved.consecutiveRings, 1);
    });

    test('a cap of zero is refused rather than silently muting', () {
      expect(() => RingLedger(cap: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('4 — every quiet exit is logged with a why', () {
    test('a quiet sweep leaves a line, and no sweep leaves none', () async {
      final path = p.join(dir.path, 'journal', 'watchdog.ndjson');
      final file = File(path);

      // "No sweep at all" is the state before anything runs, and it is
      // observable: no file. This is the comparison the whole rule exists for
      // — a watchdog quiet because the tree is healthy and one quiet because
      // it crashed at 03:00 look identical from outside unless the healthy one
      // leaves something behind.
      expect(file.existsSync(), isFalse);

      final process = await writer('log-1');
      record('log-1', pid: process.pid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sweep = await watchdogOver(into: FileWatchdogJournal(path))
          .sweepOnce();

      expect(sweep.rang, isEmpty, reason: 'this sweep was quiet');
      expect(file.existsSync(), isTrue, reason: 'and it still wrote a line');
      final lines = file.readAsLinesSync();
      expect(lines, hasLength(1));
      final logged = jsonDecode(lines.single) as Map<String, Object?>;
      expect(logged['rang'], isEmpty);
      expect(logged['nodes_swept'], 1);
      expect(logged['why'], isA<String>());
      expect(logged['why'] as String, isNotEmpty);
      expect(logged['why'] as String, contains('no ring'));
      expect(logged['at'], isA<String>());
    });

    test('every sweep outcome carries a non-empty why', () async {
      // Each of the paths, driven for real, then asserted as a set. A `why`
      // that is required by the constructor but empty on one branch is the
      // failure this catches.
      final stalling = await sleeper('why-1');
      record('why-1', pid: stalling.pid);
      final watchdog = watchdogOver(ringCap: 1);

      final young = await watchdog.sweepOnce(); // live, nothing to ring
      await Future<void>.delayed(pastFrozen);
      final rang = await watchdog.sweepOnce(); // rings
      final capped = await watchdog.sweepOnce(); // silenced

      for (final sweep in [young, rang, capped]) {
        expect(sweep.why, isNotEmpty);
        expect(sweep.why.length, greaterThan(20), reason: '$sweep');
      }
      expect(young.why, contains('no ring'));
      expect(rang.why, contains('rang for'));
      expect(capped.why, contains('no ring'));
    });

    test(
      'a sweep that could not be taken says so, and rings nothing',
      () async {
        // A `parent_id` cycle makes `store.tree()` throw `TreeIntegrityError`,
        // which is the measurement refusing to report on a subset rather than
        // returning a short one — "a silently short sweep and a small tree look
        // the same". The loop must record that as "could not look", never as
        // "found nothing".
        //
        // A cycle and not an orphan: `tree()` deliberately anchors a node whose
        // parent is missing as a root, precisely so the runaway is never absent
        // from a sweep (`sprout_store.dart`, `tree()`). So an orphan sweeps
        // fine, and only a cycle leaves a node unreachable.
        final one = await sleeper('cyc-a');
        final two = await sleeper('cyc-b');
        record('cyc-a', pid: one.pid);
        record('cyc-b', pid: two.pid, parentId: 'cyc-a');
        store.putNode(
          SproutNode(
            id: 'cyc-a',
            parentId: 'cyc-b',
            project: dir.path,
            status: NodeStatus.working,
          ),
        );

        final sweep = await watchdogOver().sweepOnce();

        expect(sweep.rang, isEmpty);
        expect(sweep.nodesSwept, 0);
        expect(sweep.failure, isNotNull);
        expect(sweep.why, contains('no sweep was taken'));
        expect(sweep.why, contains('nothing here says the tree is healthy'));
      },
    );

    test('the journal exposes no getter that reads silence as health', () {
      // Asserted as an API fact rather than a doc sentence: `SweepRecord` has
      // `quiet`, which means "rang about nothing", and deliberately nothing
      // named healthy/ok/green that a caller could read a blind sweep off.
      final source = File('lib/src/watchdog/journal.dart').readAsStringSync();
      expect(
        RegExp(r'bool get (healthy|isHealthy|ok|allWell|green)')
            .hasMatch(source),
        isFalse,
        reason:
            'a boolean health getter would answer true for a sweep that could '
            'not see half the tree',
      );
    });
  });

  group('5 — unmeasured never rings, and is never counted healthy', () {
    test('a ps that cannot run neither rings nor reports health', () async {
      final process = await sleeper('blind-1');
      record('blind-1', pid: process.pid);
      await Future<void>.delayed(pastFrozen);

      final sweep = await watchdogOver(
        processes: const PsProcessProbe(executable: '/nonexistent/ps'),
      ).sweepOnce();

      // Half one: it does not ring. A failed look contradicts nothing.
      expect(bell.rings, isEmpty);
      expect(sweep.rang, isEmpty);
      expect(sweep.quiet, isTrue);

      // Half two: it does not report health either. The node is named, the
      // reason is carried, and the `why` says both things out loud.
      expect(sweep.blind.map((b) => b.nodeId), ['blind-1']);
      expect(sweep.blind.single.because, contains('could not look at pid'));
      expect(sweep.why, contains('the blind node(s) are blind-1'));
      expect(sweep.why, contains('not rung'));
      expect(sweep.why, contains('NOT counted healthy'));
      expect(
        sweep.why,
        contains('not one of the 1 node(s) could be measured'),
        reason: 'the count has to be of what was LOOKED at, not of the tree',
      );
      expect(
        sweep.why,
        isNot(contains('were live or ended')),
        reason: 'a blind sweep must not claim the tree measured live',
      );
    });

    test('unmeasured does not reset a ring count either', () async {
      // The other direction, and the reason blindness is not treated as
      // progress: a probe that fails every other sweep would keep a genuinely
      // stalled node ringing forever with the cap never reached.
      final process = await sleeper('blind-2');
      record('blind-2', pid: process.pid);
      await Future<void>.delayed(pastFrozen);
      final watchdog = watchdogOver(ringCap: 2);

      await watchdog.sweepOnce();
      expect(watchdog.ledger.ringsFor('blind-2'), 1);

      final blindSweep = await Watchdog(
        store: store,
        bell: bell,
        journal: journal,
        processes: const PsProcessProbe(executable: '/nonexistent/ps'),
        frozenAfter: frozenAfter,
        settleFor: testSettle,
        ringCap: 2,
      ).sweepOnce();
      expect(blindSweep.blind, hasLength(1));

      // Back on the real probe, the count is where it was.
      await watchdog.sweepOnce();
      expect(watchdog.ledger.ringsFor('blind-2'), 2);
      expect((await watchdog.sweepOnce()).silenced, hasLength(1));
    });

    test('the ringing set is exactly stalled and abandoned', () {
      expect(ringingVerdicts, {Liveness.stalled, Liveness.abandoned});
      expect(ringingVerdicts, isNot(contains(Liveness.unmeasured)));
      expect(ringingVerdicts, isNot(contains(Liveness.ended)));
      expect(ringingVerdicts, isNot(contains(Liveness.live)));
      // And it is NOT `Liveness.pages`, which P6-01 shipped with `unmeasured`
      // returning true. The disagreement is deliberate and is recorded as F-13
      // in docs/02-open-findings.md; this pins it so it cannot drift back
      // silently.
      expect(Liveness.unmeasured.pages, isTrue);
      expect(ringingVerdicts.contains(Liveness.unmeasured), isFalse);
    });
  });

  group('settle before measuring', () {
    test(
      'a node caught mid-write clears during the settle and is not rung',
      () async {
        // The race the settle exists for, staged deterministically: the first
        // reading finds the transcript frozen, and the transcript grows while
        // the watchdog is settling. A bare sleep could not tell these apart —
        // only the SECOND reading can.
        final process = await sleeper('settle-1');
        record('settle-1', pid: process.pid);
        await Future<void>.delayed(pastFrozen);

        final sweep = await watchdogOver(
          sleep: (d) async {
            File(transcriptPath('settle-1')).writeAsStringSync(
              '{"was-writing":true}\n',
              mode: FileMode.append,
            );
          },
        ).sweepOnce();

        expect(bell.rings, isEmpty, reason: 'it was writing, not frozen');
        expect(sweep.settledClear, ['settle-1']);
        expect(sweep.why, contains('cleared during the'));
        expect(sweep.why, contains('caught mid-write rather than frozen'));
      },
    );

    test('a genuinely frozen node survives the settle and rings', () async {
      // The partner assertion. A settle that swallowed every contradiction
      // would pass the test above and be useless, and the two together are
      // what says it is doing the right thing rather than nothing.
      final process = await sleeper('settle-2');
      record('settle-2', pid: process.pid);
      await Future<void>.delayed(pastFrozen);

      final sweep = await watchdogOver().sweepOnce();

      expect(sweep.settledClear, isEmpty);
      expect(sweep.rang.map((r) => r.nodeId), ['settle-2']);
    });

    test('a healthy tree is not settled at all', () async {
      var slept = 0;
      final process = await writer('settle-3');
      record('settle-3', pid: process.pid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await watchdogOver(sleep: (d) async => slept++).sweepOnce();

      expect(slept, 0, reason: 'the healthy path costs one sweep');
    });
  });

  group('the loop itself', () {
    test('run sweeps repeatedly and stop ends it', () async {
      final process = await writer('loop-1');
      record('loop-1', pid: process.pid);
      final watchdog = watchdogOver(interval: const Duration(milliseconds: 10));

      final looping = watchdog.run();
      expect(watchdog.isRunning, isTrue);
      while (journal.sweeps.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await watchdog.stop();
      await looping;

      expect(watchdog.isRunning, isFalse);
      final swept = journal.sweeps.length;
      expect(swept, greaterThanOrEqualTo(3));
      // Every one of them left a why, including the ones that did nothing.
      expect(journal.sweeps.every((s) => s.why.isNotEmpty), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(journal.sweeps, hasLength(swept), reason: 'stopped means stopped');
    });

    test(
      'sweeps immediately rather than waiting out the first interval',
      () async {
        final process = await sleeper('loop-2');
        record('loop-2', pid: process.pid);
        await Future<void>.delayed(pastFrozen);
        final watchdog = watchdogOver(interval: const Duration(hours: 1));

        final looping = watchdog.run();
        while (bell.rings.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await watchdog.stop();
        await looping;

        expect(bell.rings, hasLength(1));
      },
    );

    test('a second run is refused rather than doubling the sweeps', () async {
      final watchdog = watchdogOver(interval: const Duration(hours: 1));
      final looping = watchdog.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watchdog.run, throwsStateError);
      await watchdog.stop();
      await looping;
    });
  });

  group('never acts', () {
    test('nothing under lib/src/watchdog can act on a process', () {
      // §5: "Never auto-reclaim a stalled node" — the real incident behind
      // that rule held four uncommitted files and a green test suite. P6-01
      // asserts this of `lib/src/liveness/`; the same guard has to hold here
      // independently, because the temptation to "just clean up the dead one"
      // arrives at the thing that DECIDES a node is dead, not at the thing
      // that measures it.
      final offenders = Directory('lib/src/watchdog')
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
            'the watchdog surfaces and pages. Acting on a stalled node belongs '
            'to a human, and to no file in this directory.',
      );
    });

    test('and it starts no processes of its own', () {
      // The wider form: the watchdog reads the store and delegates every look
      // to `package:sproutd/liveness.dart`, whose only child process is a
      // read-only `ps`. A `Process.run` appearing here would be a new way to
      // touch the world that this directory's tests do not cover.
      final offenders = Directory('lib/src/watchdog')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) =>
                RegExp(r'Process\.(run|start|runSync|start Sync)')
                    .hasMatch(f.readAsStringSync()),
          )
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty);
    });

    test('a bell cannot answer back', () {
      // `ring` returns Future<void>. A bell that could return "handled" is the
      // first half of the auto-reclaim that must never exist, so the absence
      // of a return value is asserted rather than left to a doc comment.
      final source = File('lib/src/watchdog/bell.dart').readAsStringSync();
      expect(source, contains('Future<void> ring(Ring ring);'));
      expect(source, isNot(contains('Future<bool> ring')));
    });
  });

  group('the knobs are the loop\'s own', () {
    test('the watchdog passes its own frozen-after to the measurement', () {
      // §11 leaves the threshold undecided and P6-01 says its own default is
      // "a knob, not a finding". So the watchdog declares one rather than
      // borrowing, and the two are separate constants that happen to agree.
      expect(watchdogFrozenAfter, const Duration(minutes: 5));
      expect(defaultSweepInterval, const Duration(seconds: 30));
      expect(defaultSettleFor, const Duration(seconds: 5));
      expect(defaultRingCap, 3);

      final watchdog = Watchdog(
        store: store,
        bell: bell,
        journal: journal,
        frozenAfter: const Duration(seconds: 7),
      );
      expect(watchdog.measure.frozenAfter, const Duration(seconds: 7));
      expect(watchdog.frozenAfter, const Duration(seconds: 7));
    });

    test('the defaults track this repo own game_loop watchdog config', () {
      // Not invented numbers: the interval, the settle and the cap are the
      // ones this project already runs its own sessions under. Read from the
      // file so the claim cannot go stale silently.
      final config = jsonDecode(
        File('../.game_loop/config.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final theirs = config['watchdog']! as Map<String, Object?>;
      expect(defaultSweepInterval.inSeconds, theirs['idle_sec']);
      expect(defaultSettleFor.inSeconds, theirs['settle_sec']);
      expect(defaultRingCap, theirs['ring_cap']);
    });
  });
}
