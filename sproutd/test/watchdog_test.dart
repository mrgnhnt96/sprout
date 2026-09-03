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
import 'package:sproutd/hooks.dart';
import 'package:sproutd/liveness.dart';
import 'package:sproutd/protocol.dart';
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

/// The 37 hook payloads captured in Phase 0.
///
/// Group 8 folds real captures through `HookProjection` rather than writing
/// rows, for `hooks_test.dart`'s reason: a test that writes the rows itself
/// proves nothing about whether the projection writes them.
const String hookFixtures = '../docs/research/fixtures/phase0/hooks';

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
      // And it is NOT `Liveness.worthSurfacing`, which is true for
      // `unmeasured` as well. That was F-13 while the getter was called
      // `pages`: two declarations answering different questions read as one.
      // P6-03 settled it by renaming rather than narrowing — `worthSurfacing`
      // means *belongs on the board*, `ringingVerdicts` means *rings a stall
      // alarm* — and this pins both halves so neither can drift into the
      // other.
      expect(Liveness.unmeasured.worthSurfacing, isTrue);
      expect(ringingVerdicts.contains(Liveness.unmeasured), isFalse);
      for (final verdict in ringingVerdicts) {
        expect(verdict.worthSurfacing, isTrue, reason: '$verdict');
      }
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

  group('7 — the board, which is P6-03 wiring this into `sprout ui`', () {
    // `WatchdogBoard` is a JOURNAL and not a bell, and this group is why. A
    // bell fires on a ring, which is an edge; the board needs the level, so a
    // node that recovered is simply absent from the next frame with nothing
    // having written a status row anywhere.
    late Cursor at;

    setUp(() {
      at = SproutInstance.forFeed(
        databasePath: store.databasePath,
        firstEvent: store.firstEvent,
      ).cursorAt(0);
    });

    test('a real stall reaches a frame, and recovery removes it', () async {
      final board = WatchdogBoard();
      final seen = <SweepRecord>[];
      final subscription = board.sweeps.listen(seen.add);
      addTearDown(subscription.cancel);

      final process = await sleeper('board-1');
      record('board-1', pid: process.pid);
      File(transcriptPath('board-1')).writeAsStringSync('{"a":1}\n');
      await Future<void>.delayed(pastFrozen);

      final watchdog = watchdogOver(into: FanOutJournal([journal, board]));
      final stalledSweep = await watchdog.sweepOnce();
      expect(stalledSweep.rang, hasLength(1));

      final stalledFrame = watchdogFrameFor(stalledSweep, at: at);
      expect(stalledFrame.type, WatchdogFrame.wireType);
      expect(stalledFrame.conclusive, isTrue);
      expect(stalledFrame.stalled.single.nodeId, 'board-1');
      expect(stalledFrame.stalled.single.liveness, Liveness.stalled.wire);
      expect(stalledFrame.stalled.single.because, contains('${process.pid}'));
      expect(stalledFrame.stalled.single.consecutiveRings, 1);
      expect(stalledFrame.stalled.single.silenced, isFalse);
      expect(stalledFrame.why, stalledSweep.why);

      // The node writes again. Nothing calls a setter, nothing appends a
      // status row: the next sweep simply measures a different thing.
      File(transcriptPath('board-1'))
          .writeAsStringSync('{"a":2}\n', mode: FileMode.append);
      final recovered = await watchdog.sweepOnce();
      final recoveredFrame = watchdogFrameFor(recovered, at: at);
      expect(recoveredFrame.stalled, isEmpty);
      expect(recoveredFrame.conclusive, isTrue);

      // And the node's stored status never moved, which is the point.
      expect(store.node('board-1')!.status, NodeStatus.working);

      // Both sweeps reached the board, in order, through the journal.
      expect(seen, hasLength(2));
      expect(board.last!.why, recovered.why);
    });

    test(
      'a silenced node is STILL on the board, and says it is capped',
      () async {
        final process = await sleeper('capped-1');
        record('capped-1', pid: process.pid);
        File(transcriptPath('capped-1')).writeAsStringSync('{"a":1}\n');
        await Future<void>.delayed(pastFrozen);

        final watchdog = watchdogOver(ringCap: 1);
        await watchdog.sweepOnce();
        final capped = await watchdog.sweepOnce();
        expect(capped.rang, isEmpty, reason: 'the cap silenced the ring');
        expect(capped.silenced, hasLength(1));

        // The RING stopped; the STALL did not. A board that dropped the node
        // here would go quiet about it precisely because the watchdog had
        // already rung — a mute wearing a cap's clothing.
        final frame = watchdogFrameFor(capped, at: at);
        expect(frame.stalled, hasLength(1));
        expect(frame.stalled.single.nodeId, 'capped-1');
        expect(frame.stalled.single.silenced, isTrue);
        expect(frame.stalled.single.liveness, Liveness.stalled.wire);
        expect(frame.stalled.single.because, contains('${process.pid}'));
      },
    );

    test('a blind sweep is not a healthy one, on the frame either', () async {
      record('blind-1', pid: 424242);
      final watchdog = watchdogOver(
        processes: const PsProcessProbe(executable: '/nonexistent/ps'),
      );
      final sweep = await watchdog.sweepOnce();

      final frame = watchdogFrameFor(sweep, at: at);
      expect(frame.stalled, isEmpty);
      expect(frame.blind, hasLength(1));
      expect(frame.blind.single.nodeId, 'blind-1');
      expect(frame.why, contains('establishes nothing'));
      // The frame carries the sweep's own sentence and offers no boolean a
      // consumer could read as health — `conclusive` is about EVIDENCE, and a
      // sweep that measured nothing still took place.
      expect(frame.why, sweep.why);
      expect(frame.toJson().containsKey('healthy'), isFalse);
    });

    test('a sweep that could not be taken says so and is not conclusive', () {
      final sweep = SweepRecord(
        at: DateTime.utc(2026, 9, 2, 21, 45),
        took: Duration.zero,
        nodesSwept: 0,
        failure: 'ps: command not found',
        why: 'no sweep was taken: the measurement threw',
      );
      final frame = watchdogFrameFor(sweep, at: at);
      expect(frame.conclusive, isFalse);
      expect(frame.failure, 'ps: command not found');
    });

    test('the last entry a stopped watchdog writes says nobody is looking', () {
      final crashed = watchdogStoppedRecord(
        at: DateTime.utc(2026),
        error: 'Bad state: boom',
      );
      expect(crashed.failure, 'Bad state: boom');
      expect(crashed.why, contains('THE WATCHDOG STOPPED'));
      expect(watchdogFrameFor(crashed, at: at).conclusive, isFalse);

      final orderly = watchdogStoppedRecord(at: DateTime.utc(2026));
      expect(orderly.why, contains('shutting down'));
      expect(orderly.why, contains('nobody is looking'));
      expect(watchdogFrameFor(orderly, at: at).conclusive, isFalse);
    });

    test('a frame round-trips through the wire decoder', () {
      final sweep = SweepRecord(
        at: DateTime.utc(2026, 9, 2, 21, 45, 48),
        took: const Duration(milliseconds: 12),
        nodesSwept: 2,
        why: 'rang for 1 of 2 node(s)',
        rang: [
          Ring(
            nodeId: 'n1',
            liveness: Liveness.stalled,
            because: 'pid 33134 is alive and the transcript last grew 3s ago',
            consecutiveRings: 1,
            at: DateTime.utc(2026, 9, 2, 21, 45, 48),
            pid: 33134,
            frozenFor: const Duration(seconds: 3),
          ),
        ],
      );
      final line = watchdogFrameFor(sweep, at: at).encodeLine();
      // Decoded by the same `ProtocolFrame.decodeLine` every other frame goes
      // through — the browser's decoder, compiled from the same declarations.
      final back = ProtocolFrame.decodeLine(line);
      expect(back, isA<WatchdogFrame>());
      final frame = back as WatchdogFrame;
      expect(frame.stalled.single.nodeId, 'n1');
      expect(frame.stalled.single.liveness, 'stalled');
      expect(frame.sweptAt, DateTime.utc(2026, 9, 2, 21, 45, 48));
      expect(frame.encodeLine(), line);
    });

    test('what the board surfaces is exactly `worthSurfacing`', () async {
      // F-13, settled: `worthSurfacing` is the broader predicate — it includes
      // `unmeasured`, which `ringingVerdicts` deliberately does not. The frame
      // honours both at once by carrying two lists, and this is the assertion
      // that makes the getter a claim about this daemon rather than a doc
      // comment. `stalled` holds the ringing verdicts; `blind` holds the
      // unmeasured; and together they are every verdict `worthSurfacing`
      // returns true for.
      final surfaced = {
        for (final verdict in Liveness.values)
          if (verdict.worthSurfacing) verdict,
      };
      expect(surfaced, {
        ...ringingVerdicts,
        Liveness.unmeasured,
      }, reason: 'the frame has a list for each half and nothing else');

      final process = await sleeper('both-1');
      record('both-1', pid: process.pid);
      record('both-2', pid: 424243);
      File(transcriptPath('both-1')).writeAsStringSync('{"a":1}\n');
      await Future<void>.delayed(pastFrozen);

      final watchdog = watchdogOver(processes: _OnlyKnows({process.pid}));
      final sweep = await watchdog.sweepOnce();
      final frame = watchdogFrameFor(sweep, at: at);
      expect(frame.stalled.map((n) => n.nodeId), ['both-1']);
      expect(frame.blind.map((n) => n.nodeId), ['both-2']);
    });
  });

  group('8 — a session sprout did not spawn (P8-04)', () {
    // Filled by folding real Phase 0 hook payloads through `HookProjection`,
    // never by writing rows. The whole question this group answers is whether
    // the watchdog rings on the session most likely to be silently stuck: the
    // one a developer started in a terminal, which sprout can only ever see
    // through a hook.

    const String foreignSession = 'f0f0f0f0-0000-4000-8000-00000000c0de';
    final String rootId = HookProjection.rootNodeId(foreignSession);
    const String childAgentId = 'aab408509339890dd';

    Map<String, Object?> payload(String relative, {String? transcript}) => {
      ...jsonDecode(File('$hookFixtures/$relative').readAsStringSync())
          as Map<String, Object?>,
      'session_id': foreignSession,
      'transcript_path': ?transcript,
    };

    void fold(List<Map<String, Object?>> payloads, {required int pid}) {
      final projection = HookProjection(
        store: store,
        clock: () => DateTime.now().toUtc(),
        environment: {
          claudePidEnvVariable: '$pid',
          claudeSessionIdEnvVariable: foreignSession,
        },
      );
      for (final one in payloads) {
        projection.observe(HookRecord.parse(jsonEncode(one)));
      }
    }

    test('a stalled foreign session rings, and the page is readable', () async {
      final process = await sleeper('foreign-stall');
      fold([
        payload(
          'A/1788280943.420722-SessionStart.stdin.json',
          transcript: transcriptPath('foreign-stall'),
        ),
        payload(
          'A/1788280943.696918-UserPromptSubmit.stdin.json',
          transcript: transcriptPath('foreign-stall'),
        ),
      ], pid: process.pid);
      // One line after the record, then silence — a session that started, said
      // something, and wedged.
      File(transcriptPath('foreign-stall'))
          .writeAsStringSync('{"hello":true}\n', mode: FileMode.append);
      await Future<void>.delayed(pastFrozen);

      final sweep = await watchdogOver().sweepOnce();

      expect(bell.rings, hasLength(1));
      final ring = bell.rings.single;
      expect(ring.nodeId, rootId);
      expect(ring.liveness, Liveness.stalled);
      expect(ring.pid, process.pid);
      expect(ring.because, contains('pid ${process.pid} is alive'));
      expect(ring.because, contains('the transcript last grew'));
      expect(sweep.why, contains('$rootId stalled'));
      // And the feed does not claim sprout launched it.
      expect(
        store
            .eventsSince(0, nodeId: rootId)
            .map((e) => e.kind)
            .where((k) => k == runnerSpawnedKind),
        isEmpty,
      );
    });

    test(
      'the same session after Stop never rings, however long it sits',
      () async {
        final process = await sleeper('foreign-idle');
        fold([
          payload(
            'A/1788280943.420722-SessionStart.stdin.json',
            transcript: transcriptPath('foreign-idle'),
          ),
          payload(
            'A/1788280949.837870-Stop.stdin.json',
            transcript: transcriptPath('foreign-idle'),
          ),
        ], pid: process.pid);
        await Future<void>.delayed(pastFrozen);

        // Three sweeps, because "does not ring yet" and "does not ring" are
        // different claims and only the second is the one that matters for a
        // session somebody left open over lunch.
        final watchdog = watchdogOver();
        for (var i = 0; i < 3; i++) {
          await watchdog.sweepOnce();
        }
        expect(bell.rings, isEmpty);
        expect(journal.last!.why, contains('were live or ended'));
      },
    );

    test('a live foreign subagent is blind, not rung about', () async {
      final process = await writer('foreign-subagent');
      fold([
        payload(
          'B/1788280992.087510-SessionStart.stdin.json',
          transcript: transcriptPath('foreign-subagent'),
        ),
        payload(
          'B/1788280995.970887-SubagentStart.stdin.json',
          transcript: transcriptPath('foreign-subagent'),
        ),
      ], pid: process.pid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sweep = await watchdogOver().sweepOnce();
      final childId = HookProjection.subagentNodeId(
        foreignSession,
        childAgentId,
      );

      expect(bell.rings, isEmpty, reason: 'a subagent is not a process');
      expect(sweep.blind.map((b) => b.nodeId), [childId]);
      // Not rung, and not counted healthy either: it reaches the board, in
      // the `blind` list rather than the `stalled` one.
      final frame = watchdogFrameFor(
        sweep,
        at: SproutInstance.forFeed(
          databasePath: store.databasePath,
          firstEvent: store.firstEvent,
        ).cursorAt(0),
      );
      expect(frame.blind.single.nodeId, childId);
      expect(frame.stalled, isEmpty);
      expect(sweep.why, contains('could not be measured'));
    });

    test('a killed session rings to the cap and then stops, until the '
        'watchdog is restarted', () async {
      // The decision this leaf had to make, measured rather than assumed.
      //
      // A session killed mid-turn fires NO Stop and NO SessionEnd — probed
      // with a real `kill -9`, which produced exactly SessionStart and
      // UserPromptSubmit and then silence. So a closed terminal leaves a
      // hook-observed root `working` forever with a dead pid, which is
      // `abandoned`, which rings.
      //
      // What the cap does with it: an abandoned node has no `lastWrite`, so
      // `RingLedger` has no mark to reset against and the count can only clear
      // by the node ceasing to contradict — which it never will. It therefore
      // rings exactly `cap` times and is silenced. It is NOT silenced for
      // good: the ledger lives in the watchdog object, so a new `sprout ui`
      // starts the count again. That is recorded as a finding, not suppressed
      // here.
      final dead = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await dead.exitCode;
      fold([
        payload(
          'A/1788280943.420722-SessionStart.stdin.json',
          transcript: transcriptPath('foreign-killed'),
        ),
        payload(
          'A/1788280943.696918-UserPromptSubmit.stdin.json',
          transcript: transcriptPath('foreign-killed'),
        ),
      ], pid: dead.pid);
      expect(
        store.node(rootId)!.status,
        NodeStatus.working,
        reason: 'no ending was ever recorded, because none was ever sent',
      );

      final watchdog = watchdogOver(ringCap: 3);
      for (var i = 0; i < 6; i++) {
        await watchdog.sweepOnce();
      }
      expect(bell.rings.map((r) => r.consecutiveRings), [1, 2, 3]);
      expect(bell.rings.first.liveness, Liveness.abandoned);
      expect(bell.rings.first.because, contains('no process holds pid'));
      expect(watchdog.ledger.isSilenced(rootId), isTrue);
      expect(journal.last!.silenced, hasLength(1));

      // A second watchdog over the same store — which is what a restarted
      // `sprout ui` is — rings about it again from one.
      final second = RecordingBell();
      final restarted = watchdogOver(ringCap: 3, onto: second);
      await restarted.sweepOnce();
      expect(
        second.rings.single.consecutiveRings,
        1,
        reason: 'the cap is per watchdog process, not durable — see F-20',
      );
    });

    test('runner-spawned nodes are unaffected in the same sweep', () async {
      // The two paths share one measurement and one store, so the honest test
      // of "nothing changed for the runner" is a tree that holds both.
      final busy = await writer('mixed-runner');
      record('mixed-runner', pid: busy.pid);
      final foreign = await writer('mixed-foreign');
      fold([
        payload(
          'A/1788280943.420722-SessionStart.stdin.json',
          transcript: transcriptPath('mixed-foreign'),
        ),
      ], pid: foreign.pid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sweep = await watchdogOver().sweepOnce();
      expect(bell.rings, isEmpty);
      expect(sweep.nodesSwept, 2);
      expect(sweep.blind, isEmpty);
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

    test('nothing in routes/ can act on a process either', () {
      // P6-03 put the watchdog's verdict on a socket, so `routes/` is now a
      // third place the temptation lands — a "clean up the stalled node"
      // endpoint is one `@Post` away and would be the most natural-looking
      // code in the repo. P6-01 guards `lib/src/liveness/`, P6-02 guards
      // `lib/src/watchdog/`, and this guards the surface that carries their
      // output to a human.
      final offenders = Directory('routes')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) => RegExp(
              r'\.kill\(|ProcessSignal|Process\.killPid|Process\.(run|start)'
              r'|\.terminate\(',
            ).hasMatch(f.readAsStringSync()),
          )
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason:
            'the daemon surfaces and pages. Acting on a stalled node belongs '
            'to a human, and to no route.',
      );
    });

    test('and the frame carries nothing to act ON', () {
      // The structural half, which is stronger than any grep: a board cannot
      // signal a process it was never given. `StalledNode` carries an id, a
      // verdict, a sentence and a ring count — deliberately no pid, no command
      // line and no handle — so the endpoint above could not be written
      // against this frame even if someone wanted to. `Ring` does carry a pid,
      // because a page a human cannot check by hand in one `ps` is a page they
      // learn to dismiss; that goes to stderr and to the journal, not to a
      // browser.
      //
      // The pid does appear on the wire — inside `because`, because that
      // sentence is carried through unedited and a stall a human cannot check
      // by hand is a stall they dismiss. What is asserted here is that it is
      // not a FIELD: there is nothing a consumer can read as `node.pid` and
      // hand to a kill, and prising it back out of prose is a thing somebody
      // would have to choose to write.
      final frame = watchdogFrameFor(
        SweepRecord(
          at: DateTime.utc(2026),
          took: Duration.zero,
          nodesSwept: 1,
          why: 'rang for 1 of 1 node(s)',
          rang: [
            Ring(
              nodeId: 'n1',
              liveness: Liveness.stalled,
              because: 'pid 33134 is alive',
              consecutiveRings: 1,
              at: DateTime.utc(2026),
              pid: 33134,
            ),
          ],
        ),
        at: SproutInstance.forFeed(
          databasePath: store.databasePath,
          firstEvent: store.firstEvent,
        ).cursorAt(0),
      );
      final encoded = frame.stalled.single.toJson();
      expect(encoded.keys, isNot(contains('pid')));
      expect(encoded.keys, {
        'node_id',
        'liveness',
        'because',
        'consecutive_rings',
        'silenced',
      });
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

/// A probe that answers for the pids it knows and fails on the rest.
///
/// The two halves in one sweep: a node that is genuinely contradicted, and a
/// node the watchdog could not look at. Blindness that is total is easy to get
/// wrong in the safe direction — nothing rings — so the mixed case is the one
/// that proves the two lists stay separate.
final class _OnlyKnows implements ProcessProbe {
  const _OnlyKnows(this.known);

  final Set<int> known;

  @override
  Future<ProcessLook> inspect(int pid) async => known.contains(pid)
      ? const PsProcessProbe().inspect(pid)
      : ProcessUnreadable(pid, 'this probe was told not to look at $pid');
}
