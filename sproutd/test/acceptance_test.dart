/// Tests for `lib/acceptance.dart` — the parent's per-return acceptance check.
///
/// **The three outcomes are proved against real processes**, not only against
/// the seam: a check whose only evidence is that its own fake answered the way
/// the test told it to proves nothing about whether a command's exit code is
/// ever read (INV8). `git` is the binary used, because this suite already
/// requires it and it offers all three cases without a shell — a version query
/// that exits 0, a ref query that exits non-zero, and a name no PATH resolves.
///
/// The fake is kept for the two things a real command cannot show cheaply:
/// which conditions were run *at all*, and in what order.
@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/acceptance.dart';
import 'package:sproutd/decomposition.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/worktree.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;

/// A condition that a real `git` satisfies.
final _passes = SuccessCondition(['git', '--version']);

/// A condition a real `git` runs and refuses: no such ref.
final _fails = SuccessCondition([
  'git',
  'rev-parse',
  '--verify',
  'refs/heads/p406-no-such-ref',
]);

/// A condition nothing can run: no such executable, anywhere.
final _unrunnable = SuccessCondition(['sprout-no-such-binary-p406']);

/// A child that answered and whose subtree had drained.
const _drained = ChildReturn(
  nodeId: 'child-1',
  exitCode: 0,
  hasResult: true,
  incompleteSubagents: 0,
);

/// A [ConditionRunner] that answers from a queue and records what it was
/// asked, so a test can assert what was **not** run.
final class RecordingConditions implements ConditionRunner {
  RecordingConditions(this._answers);

  final List<ConditionRun Function(SuccessCondition)> _answers;

  /// Every condition this runner was handed, in order.
  final List<SuccessCondition> asked = [];

  @override
  Future<ConditionRun> run(
    SuccessCondition condition, {
    required String workspace,
  }) async {
    asked.add(condition);
    return _answers.removeAt(0)(condition);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sprout_acceptance_test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('the three outcomes, against real commands', () {
    test('a passing condition on a drained return is accepted', () async {
      final check = AcceptanceCheck();
      final outcome = await check.judge(
        returned: _drained,
        conditions: [_passes],
        workspace: tmp.path,
      );

      expect(outcome, isA<ChildAccepted>());
      expect(outcome.isAccepted, isTrue);
      expect(outcome.kind, acceptanceAcceptedKind);
      // The command really ran: an exit code exists and it is git's own.
      expect(outcome.conditions, hasLength(1));
      final run = outcome.conditions.single;
      expect(run, isA<ConditionRan>());
      expect((run as ConditionRan).exitCode, 0);
      expect(run.stdout, contains('git version'));
    });

    test('a failing condition is rejected, and names what failed', () async {
      final check = AcceptanceCheck();
      final outcome = await check.judge(
        returned: _drained,
        conditions: [_fails],
        workspace: tmp.path,
      );

      expect(outcome, isA<ChildRejected>());
      outcome as ChildRejected;
      expect(outcome.reason, RejectionReason.conditionFailed);
      expect(outcome.kind, acceptanceRejectedKind);
      expect(outcome.isAccepted, isFalse);
      // The exit code is git's, not a value this library invented.
      final run = outcome.conditions.single as ConditionRan;
      expect(run.exitCode, isNot(0));
      expect(run.passed, isFalse);
      expect(outcome.explanation, contains('rev-parse'));
    });

    test('a condition nothing can run is undecidable', () async {
      final check = AcceptanceCheck();
      final outcome = await check.judge(
        returned: _drained,
        conditions: [_unrunnable],
        workspace: tmp.path,
      );

      expect(outcome, isA<AcceptanceUndecidable>());
      outcome as AcceptanceUndecidable;
      expect(outcome.reason, UndecidableReason.conditionUnrunnable);
      expect(outcome.kind, acceptanceUndecidableKind);
      expect(outcome.isAccepted, isFalse);
      // No exit code exists here, and none was invented.
      final run = outcome.conditions.single;
      expect(run, isA<ConditionCouldNotRun>());
      expect((run as ConditionCouldNotRun).why, isNotEmpty);
      expect(run.toJson().containsKey('exit_code'), isFalse);
    });

    test('undecidable is not a kind of rejected, in every field', () async {
      // The distinction the leaf exists to hold. Asserted on the type, the
      // wire kind and the payload, because collapsing the two is a one-line
      // change in any of them.
      final rejected = await AcceptanceCheck().judge(
        returned: _drained,
        conditions: [_fails],
        workspace: tmp.path,
      );
      final undecidable = await AcceptanceCheck().judge(
        returned: _drained,
        conditions: [_unrunnable],
        workspace: tmp.path,
      );

      expect(rejected, isA<ChildRejected>());
      expect(undecidable, isNot(isA<ChildRejected>()));
      expect(rejected.kind, isNot(undecidable.kind));
      expect(rejected.toJson()['reason'], 'conditionFailed');
      expect(undecidable.toJson()['reason'], 'conditionUnrunnable');

      // And neither is accepted — the pair that keeps the negative honest.
      expect(rejected.isAccepted, isFalse);
      expect(undecidable.isAccepted, isFalse);
    });

    test('every condition is run when they all pass, in order', () async {
      final runner = RecordingConditions([
        for (var i = 0; i < 3; i++)
          (c) =>
              ConditionRan(condition: c, exitCode: 0, stdout: '', stderr: ''),
      ]);
      final a = SuccessCondition(['a']);
      final b = SuccessCondition(['b']);
      final c = SuccessCondition(['c']);
      final outcome = await AcceptanceCheck(
        runner: runner,
      ).judge(returned: _drained, conditions: [a, b, c], workspace: tmp.path);

      expect(outcome, isA<ChildAccepted>());
      expect(runner.asked, [a, b, c]);
      expect(outcome.conditions, hasLength(3));
    });

    test('the first failure decides, and stops the rest running', () async {
      // The paired positive of the test above: with the same three conditions
      // and a failure in the middle, the third is never asked for. Without
      // this, "runs them all" and "runs until one decides" look identical.
      final runner = RecordingConditions([
        (c) => ConditionRan(condition: c, exitCode: 0, stdout: '', stderr: ''),
        (c) => ConditionRan(condition: c, exitCode: 7, stdout: '', stderr: ''),
        (c) => fail('the third condition must not be run'),
      ]);
      final a = SuccessCondition(['a']);
      final b = SuccessCondition(['b']);
      final c = SuccessCondition(['c']);
      final outcome = await AcceptanceCheck(
        runner: runner,
      ).judge(returned: _drained, conditions: [a, b, c], workspace: tmp.path);

      expect(
        (outcome as ChildRejected).reason,
        RejectionReason.conditionFailed,
      );
      expect(runner.asked, [a, b]);
      expect(outcome.conditions, hasLength(2));
    });

    test('an unrunnable condition stops the rest too', () async {
      final runner = RecordingConditions([
        (c) => ConditionCouldNotRun(condition: c, why: 'no such file'),
        (c) => fail('the second condition must not be run'),
      ]);
      final outcome = await AcceptanceCheck(runner: runner).judge(
        returned: _drained,
        conditions: [
          SuccessCondition(['a']),
          SuccessCondition(['b']),
        ],
        workspace: tmp.path,
      );

      expect(outcome, isA<AcceptanceUndecidable>());
      expect(runner.asked, hasLength(1));
    });

    test('the condition runs in the workspace it was given', () async {
      // A real command whose answer depends on the cwd, so the parameter is
      // proved to arrive rather than proved to exist.
      final inside = Directory(p.join(tmp.path, 'inside'))..createSync();
      final run = await const ProcessConditions().run(
        SuccessCondition(['git', 'rev-parse', '--show-toplevel']),
        workspace: inside.path,
      );
      // Not a repository, so git refuses — but it refuses about THIS path.
      expect(run, isA<ConditionRan>());
      expect((run as ConditionRan).passed, isFalse);

      final repo = await _repository(tmp);
      final ok = await const ProcessConditions().run(
        SuccessCondition(['git', 'rev-parse', '--show-toplevel']),
        workspace: repo,
      );
      expect((ok as ConditionRan).passed, isTrue);
      expect(ok.stdout.trim(), endsWith(p.basename(repo)));
    });

    test('a condition\'s own workingDirectory is resolved under it', () async {
      // `SuccessCondition.workingDirectory` exists so a check can name a
      // package inside the child's tree — `.game_loop/verify.yaml`'s own rules
      // are all `cd <package> && ...` — and it is the field most likely to be
      // carried and never read. Proved with a real command whose answer
      // differs between the two directories, and paired with the same
      // condition run from the root, because "the field is used" and "the
      // field is ignored" pass the same test without the pair.
      final repo = await _repository(tmp);
      Directory(p.join(repo, 'sub')).createSync();
      File(p.join(repo, 'sub', 'only-here.txt')).writeAsStringSync('x\n');
      final git = const ProcessGit();
      for (final argv in [
        ['add', 'sub/only-here.txt'],
        ['commit', '-m', 'sub'],
      ]) {
        final r = await git.run(argv, workingDirectory: repo);
        expect(r.ok, isTrue, reason: r.label);
      }
      final argv = ['git', 'ls-files', '--error-unmatch', 'only-here.txt'];

      final fromSub = await const ProcessConditions().run(
        SuccessCondition(argv, workingDirectory: 'sub'),
        workspace: repo,
      );
      expect((fromSub as ConditionRan).passed, isTrue, reason: fromSub.said);

      final fromRoot = await const ProcessConditions().run(
        SuccessCondition(argv),
        workspace: repo,
      );
      expect((fromRoot as ConditionRan).passed, isFalse);
    });
  });

  group('INV12 — the return decides before any command runs', () {
    test('a session that never answered is rejected, unrun', () async {
      final runner = RecordingConditions([
        (c) => fail('nothing may run for a child that did not answer'),
      ]);
      final outcome = await AcceptanceCheck(runner: runner).judge(
        returned: const ChildReturn(
          nodeId: 'n',
          exitCode: 0,
          hasResult: false,
          incompleteSubagents: 0,
        ),
        conditions: [_passes],
        workspace: tmp.path,
      );

      expect((outcome as ChildRejected).reason, RejectionReason.noResult);
      expect(runner.asked, isEmpty);
      expect(outcome.conditions, isEmpty);
      // Exit 0 and still rejected: this is the exact pair INV12 names.
      expect(outcome.returned.exitCode, 0);
    });

    test('a subtree that had not drained is rejected, unrun', () async {
      final runner = RecordingConditions([
        (c) => fail('nothing may run while the subtree is still going'),
      ]);
      final outcome = await AcceptanceCheck(runner: runner).judge(
        returned: const ChildReturn(
          nodeId: 'n',
          exitCode: 0,
          hasResult: true,
          incompleteSubagents: 2,
        ),
        conditions: [_passes],
        workspace: tmp.path,
      );

      expect(
        (outcome as ChildRejected).reason,
        RejectionReason.subtreeNotDrained,
      );
      expect(outcome.explanation, contains('2 subagent'));
      expect(runner.asked, isEmpty);
    });

    test('a non-zero exit that answered and drained is ACCEPTED', () async {
      // The positive half of INV12, and the one that makes the negative mean
      // something: sprout does not judge on the exit code in EITHER direction.
      // Without this, "exit code ignored" and "exit code required to be 0"
      // pass the same tests.
      final outcome = await AcceptanceCheck().judge(
        returned: const ChildReturn(
          nodeId: 'n',
          exitCode: 143,
          hasResult: true,
          incompleteSubagents: 0,
        ),
        conditions: [_passes],
        workspace: tmp.path,
      );

      expect(outcome, isA<ChildAccepted>());
      expect(outcome.returned.exitCode, 143);
      expect(outcome.toJson()['returned'], containsPair('exit_code', 143));
    });

    test(
      'the check order is fixed: no result outranks a live subtree',
      () async {
        // Both true at once. The order is asserted rather than left emergent,
        // because a refactor can reverse it with nothing else noticing.
        final outcome = await AcceptanceCheck().judge(
          returned: const ChildReturn(
            nodeId: 'n',
            exitCode: 0,
            hasResult: false,
            incompleteSubagents: 3,
          ),
          conditions: [_passes],
          workspace: tmp.path,
        );
        expect((outcome as ChildRejected).reason, RejectionReason.noResult);
      },
    );

    test(
      'an answered child with a live subtree is still not accepted',
      () async {
        // The other diagonal of the same pair.
        final outcome = await AcceptanceCheck().judge(
          returned: const ChildReturn(
            nodeId: 'n',
            exitCode: 0,
            hasResult: true,
            incompleteSubagents: 1,
          ),
          conditions: [_passes],
          workspace: tmp.path,
        );
        expect(outcome.isAccepted, isFalse);
      },
    );

    test('a child with no declared condition is refused, not accepted', () {
      // §2.4's `must`, enforced where a `should` would have been. There is
      // deliberately no OUTCOME for the empty case: `PlannedChild` already
      // refuses a child that declares none, so an arm for it would be an arm
      // no plan could reach — the vacuous-guard shape recorded in
      // `.showrunner/p4-05-mutations.md`. A throw is reachable from any caller.
      expect(
        () => AcceptanceCheck().judge(
          returned: _drained,
          conditions: const [],
          workspace: tmp.path,
        ),
        throwsArgumentError,
      );
    });
  });

  group('INV14 — every judgement is counted', () {
    test('a fresh tally is zero everywhere and says so by key', () {
      final counts = AcceptanceCounts.zero();
      expect(counts.total, 0);
      expect(counts.accepted, 0);
      // Every key present even at zero: a key that vanishes makes "never
      // happened" and "not counted" look the same.
      expect(counts.toWireMap().keys.toSet(), {
        'accepted',
        for (final r in RejectionReason.values) 'rejected.${r.wire}',
        for (final r in UndecidableReason.values) 'undecidable.${r.wire}',
      });
      expect(counts.toWireMap().values.every((n) => n == 0), isTrue);
    });

    test('all three outcomes land in three different buckets', () async {
      final check = AcceptanceCheck();
      await check.judge(
        returned: _drained,
        conditions: [_passes],
        workspace: tmp.path,
      );
      await check.judge(
        returned: _drained,
        conditions: [_fails],
        workspace: tmp.path,
      );
      await check.judge(
        returned: _drained,
        conditions: [_unrunnable],
        workspace: tmp.path,
      );

      expect(check.counts.accepted, 1);
      expect(check.counts.rejected(RejectionReason.conditionFailed), 1);
      expect(
        check.counts.undecidable(UndecidableReason.conditionUnrunnable),
        1,
      );
      expect(check.counts.total, 3);
      expect(check.counts.rejectedTotal, 1);
      expect(check.counts.undecidableTotal, 1);
    });

    test('accepted is counted too — the positive control', () async {
      // INV8's second bit. A gate that counted only its refusals would report
      // the same zero whether it accepted everything or never ran at all.
      final check = AcceptanceCheck();
      expect(check.counts.total, 0);
      await check.judge(
        returned: _drained,
        conditions: [_passes],
        workspace: tmp.path,
      );
      expect(check.counts.accepted, 1);
      expect(check.counts.toWireMap()['accepted'], 1);
    });

    test('a refused judgement is not counted, because it never happened', () {
      final check = AcceptanceCheck();
      expect(
        () => check.judge(
          returned: _drained,
          conditions: const [],
          workspace: tmp.path,
        ),
        throwsArgumentError,
      );
      expect(check.counts.total, 0);
    });

    test('rejection and undecidable reasons cannot collide on a key', () {
      final keys = AcceptanceCounts.zero().toWireMap().keys.toList();
      expect(keys.toSet(), hasLength(keys.length));
      for (final r in RejectionReason.values) {
        expect(keys, contains('rejected.${r.wire}'));
      }
    });
  });

  group('the outcome carries its own kind, declared in sprout_protocol', () {
    test('each outcome names the protocol constant, not a literal', () async {
      final accepted = await AcceptanceCheck().judge(
        returned: _drained,
        conditions: [_passes],
        workspace: tmp.path,
      );
      expect(accepted.kind, acceptanceAcceptedKind);
      expect(accepted.kind, startsWith(acceptanceKindPrefix));
    });

    test('the area spells no kind of its own', () {
      // F-11 and F-12 in one assertion: a `kind` written where it is used is a
      // second declaration of vocabulary the browser also reads.
      expect(_areaSource(), isNot(contains("'acceptance.")));
      expect(_areaSource(), contains('acceptanceAcceptedKind'));
    });

    test('and it never destroys anything or asks a model', () {
      // The area's promise, asserted over the whole directory the way
      // `worktree_test.dart` asserts `--force` appears nowhere in its own.
      // §6: an acceptance check is a parent judging a child, never a channel
      // by which a parent grants what only the developer can.
      for (final banned in [
        'deleteSync',
        '--force',
        'branch -D',
        'Process.start',
      ]) {
        expect(_areaSource(), isNot(contains(banned)), reason: 'found $banned');
      }
    });
  });

  group('teardown after acceptance — and the refusal still wins', () {
    test(
      'an ACCEPTED child with a dirty worktree keeps it, files and all',
      () async {
        final repo = await _repository(tmp);
        final worktrees = Worktrees(repositoryRoot: repo);
        final created =
            await worktrees.create(nodeId: 'accepted-dirty') as WorktreeCreated;

        // What a child session's whole job is: leave something behind.
        // Untracked on purpose — a file nobody ran `git add` on is the case
        // most likely to be destroyed by a cleanliness check that only looks
        // at tracked changes.
        final left = File(p.join(created.path, 'the-only-copy.txt'))
          ..writeAsStringSync('real work\n');

        final outcome = await AcceptanceCheck().judge(
          returned: _drained,
          conditions: [_passes],
          workspace: created.path,
        );
        expect(outcome.isAccepted, isTrue, reason: 'the child was accepted');

        final teardown = await worktrees.remove(
          nodeId: 'accepted-dirty',
          baseSha: created.baseSha,
        );

        // Accepted, and kept anyway. Acceptance is not authorization to
        // destroy.
        expect(teardown, isA<WorktreeKept>());
        expect(
          (teardown as WorktreeKept).reason,
          WorktreeKeepReason.uncommittedChanges,
        );
        expect(left.existsSync(), isTrue, reason: 'the file is still on disk');
        expect(Directory(created.path).existsSync(), isTrue);
      },
    );

    test('an accepted child with a clean worktree really loses it', () async {
      // The positive control for the test above. Without it, "kept" could be
      // the only thing this path ever produces and both tests would pass.
      final repo = await _repository(tmp);
      final worktrees = Worktrees(repositoryRoot: repo);
      final created =
          await worktrees.create(nodeId: 'accepted-clean') as WorktreeCreated;

      final outcome = await AcceptanceCheck().judge(
        returned: _drained,
        conditions: [_passes],
        workspace: created.path,
      );
      expect(outcome.isAccepted, isTrue);

      final teardown = await worktrees.remove(
        nodeId: 'accepted-clean',
        baseSha: created.baseSha,
      );
      expect(teardown, isA<WorktreeRemoved>());
      expect(Directory(created.path).existsSync(), isFalse);
    });
  });

  group('end to end, through the real CLI', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    Future<int> sprout(List<String> arguments) =>
        cli.sprout(arguments, out: out, err: err, environment: const {});

    /// Every event of [kind] in the store at [db].
    List<SproutEvent> events(String db, String kind) {
      final store = SproutStore.open(path: db);
      try {
        return store.eventsSince(0).where((e) => e.kind == kind).toList();
      } finally {
        store.close();
      }
    }

    test(
      'a passing --accept-if accepts, records the kind, and lets the teardown '
      'run',
      () async {
        final repo = await _repository(tmp);
        final db = p.join(tmp.path, 'accepted.db');
        final code = await sprout([
          'run',
          'do the thing',
          '--project',
          repo,
          '--db',
          db,
          '--logs',
          p.join(tmp.path, 'logs'),
          '--claude',
          _fakeClaude(tmp, 'A.ndjson'),
          '--worktree',
          '--accept-if',
          'git --version',
        ]);

        expect(code, 0, reason: '$out\n$err');
        final accepted = events(db, acceptanceAcceptedKind);
        expect(accepted, hasLength(1), reason: '$out\n$err');
        expect(accepted.single.payload['counts'], containsPair('accepted', 1));
        expect(out.toString(), contains('acceptance accepted'));

        // The teardown was offered and, the session having written nothing, it
        // really removed the room.
        expect(events(db, worktreeRemovedKind), hasLength(1));
        expect(events(db, acceptanceRejectedKind), isEmpty);
      },
    );

    test('a failing --accept-if rejects and the worktree is KEPT', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'rejected.db');
      final code = await sprout([
        'run',
        'do the thing',
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        _fakeClaude(tmp, 'A.ndjson'),
        '--worktree',
        '--accept-if',
        'git rev-parse --verify refs/heads/p406-no-such-ref',
      ]);

      // The session itself succeeded; the acceptance check is what said no.
      expect(code, 0, reason: '$out\n$err');
      final rejected = events(db, acceptanceRejectedKind);
      expect(rejected, hasLength(1), reason: '$out\n$err');
      expect(rejected.single.payload['reason'], 'conditionFailed');

      // Not accepted, so the teardown was never offered — neither answer is on
      // the feed, and the directory is still there.
      expect(events(db, worktreeRemovedKind), isEmpty);
      expect(events(db, worktreeKeptKind), isEmpty);
      expect(err.toString(), contains('worktree kept'));
      expect(Directory(p.join(repo, '.worktrees')).listSync(), hasLength(1));
    });

    test(
      'an ACCEPTED child whose session left a file keeps the worktree, through '
      'the CLI',
      () async {
        // The whole leaf in one run: the check accepts, the teardown is
        // offered, and the teardown refuses on its own terms because the room
        // holds work.
        final repo = await _repository(tmp);
        final db = p.join(tmp.path, 'accepted-dirty.db');
        final code = await sprout([
          'run',
          'do the thing',
          '--project',
          repo,
          '--db',
          db,
          '--logs',
          p.join(tmp.path, 'logs'),
          '--claude',
          _fakeClaude(tmp, 'A.ndjson', leaves: 'the-only-copy.txt'),
          '--worktree',
          '--accept-if',
          'git --version',
        ]);

        expect(code, 0, reason: '$out\n$err');
        expect(events(db, acceptanceAcceptedKind), hasLength(1));

        final kept = events(db, worktreeKeptKind);
        expect(kept, hasLength(1), reason: '$out\n$err');
        expect(kept.single.payload['reason'], 'uncommittedChanges');
        expect(events(db, worktreeRemovedKind), isEmpty);

        final room = Directory(p.join(repo, '.worktrees')).listSync().single;
        expect(
          File(p.join(room.path, 'the-only-copy.txt')).existsSync(),
          isTrue,
          reason: 'the file the session left is still on disk',
        );
      },
    );

    test('with no --accept-if nothing is judged, and it says so', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'unjudged.db');
      await sprout([
        'run',
        'do the thing',
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        _fakeClaude(tmp, 'A.ndjson'),
        '--worktree',
      ]);

      // No row of any acceptance kind, and the output says why rather than
      // being silent about it (INV8, from the permissive side).
      expect(events(db, acceptanceAcceptedKind), isEmpty);
      expect(events(db, acceptanceRejectedKind), isEmpty);
      expect(events(db, acceptanceUndecidableKind), isEmpty);
      expect(out.toString(), contains('acceptance not checked'));
      // And the unchanged path still runs: the teardown was offered.
      expect(events(db, worktreeRemovedKind), hasLength(1));
    });

    test(
      'an unrunnable --accept-if is undecidable, and keeps the room',
      () async {
        final repo = await _repository(tmp);
        final db = p.join(tmp.path, 'undecidable.db');
        await sprout([
          'run',
          'do the thing',
          '--project',
          repo,
          '--db',
          db,
          '--logs',
          p.join(tmp.path, 'logs'),
          '--claude',
          _fakeClaude(tmp, 'A.ndjson'),
          '--worktree',
          '--accept-if',
          'sprout-no-such-binary-p406',
        ]);

        final undecidable = events(db, acceptanceUndecidableKind);
        expect(undecidable, hasLength(1), reason: '$out\n$err');
        expect(undecidable.single.payload['reason'], 'conditionUnrunnable');
        expect(events(db, acceptanceRejectedKind), isEmpty);
        expect(events(db, worktreeRemovedKind), isEmpty);
      },
    );

    test('--accept-if with no command is a usage error', () async {
      final repo = await _repository(tmp);
      final code = await sprout([
        'run',
        'do the thing',
        '--project',
        repo,
        '--db',
        p.join(tmp.path, 'usage.db'),
        '--accept-if',
        '   ',
      ]);
      expect(code, isNot(0));
      expect(err.toString(), contains('--accept-if'));
    });
  });
}

/// The whole of `lib/src/acceptance/`, as one string.
String _areaSource() =>
    Directory('lib/src/acceptance')
        .listSync()
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join('\n');

/// Creates a real git repository with one commit, under [tmp].
Future<String> _repository(Directory tmp) async {
  final repo = p.join(tmp.path, 'repo${_repositories++}');
  Directory(repo).createSync();
  Future<void> git(List<String> arguments) async {
    final result = await const ProcessGit().run(
      arguments,
      workingDirectory: repo,
    );
    expect(result.ok, isTrue, reason: 'setup failed: ${result.label}');
  }

  await git(['init', '--initial-branch=main']);
  await git(['config', 'user.email', 'test@example.com']);
  await git(['config', 'user.name', 'sprout test']);
  File(p.join(repo, 'README.md')).writeAsStringSync('hello\n');
  await git(['add', 'README.md']);
  await git(['commit', '-m', 'first']);
  return repo;
}

int _repositories = 0;

/// Writes a `claude` stand-in that replays [fixture] and, if asked, leaves a
/// file behind in whatever directory it was started in.
///
/// The file is written by the *fake session* rather than by the test, so the
/// run being asserted is the one a real child produces: work left in the room
/// it was given.
String _fakeClaude(Directory dir, String fixture, {String? leaves}) {
  final path = p.absolute('../docs/research/fixtures/phase0/streams/$fixture');
  final script = File(p.join(dir.path, 'claude-${_fakes++}'));
  script.writeAsStringSync(
    '#!/bin/sh\n'
    '${leaves == null ? '' : 'echo left behind > "\$PWD/$leaves"\n'}'
    'cat "$path"\n',
  );
  Process.runSync('chmod', ['+x', script.path]);
  return script.path;
}

int _fakes = 0;
