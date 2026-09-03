/// Tests for `sprout delegate` — P4-07's verb, and the only thing that makes
/// `package:sproutd/decomposition.dart` reach a process.
///
/// **Everything here drives the real entrypoint.** `cli.sprout([...])` is the
/// same function `main` calls, over a **real** `git init` repository, with
/// **real** child processes launched through the real `ClaudeLauncher`, and
/// **real** success conditions run as real subprocesses by `ProcessConditions`.
/// The only stand-in is the `claude` binary itself: `--claude` points at a
/// shell script that replays a Phase 0 capture, which is what
/// `test/acceptance_test.dart` established and it is stronger than a fake
/// `SessionLauncher` — the process, the pipe, the exit code and the parse are
/// all the production path, and only the model is absent.
///
/// The script is also the instrument. It writes the brief it was handed to a
/// shared directory, so `Decomposition.briefFor` can be asserted from the
/// **argv of a real process** rather than from a unit test of the string; and
/// it appends `start`/`end` markers to one log, so the wave ordering can be
/// asserted from what actually overlapped rather than from the plan that said
/// it should.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/acceptance.dart';
import 'package:sproutd/decomposition.dart';
import 'package:sproutd/runner.dart';
import 'package:sproutd/store.dart';
import 'package:sproutd/worktree.dart';
import 'package:test/test.dart';

import '../bin/sprout.dart' as cli;

void main() {
  late Directory tmp;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sprout-delegate-');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() {
    // Every worktree this suite creates lives inside its own throwaway
    // repository under `tmp`, so removing the directory removes them too. The
    // repositories are never this checkout.
    tmp.deleteSync(recursive: true);
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

  /// Every node in the store at [db].
  List<SproutNode> nodes(String db) {
    final store = SproutStore.open(path: db);
    try {
      return store.nodes();
    } finally {
      store.close();
    }
  }

  group('the delegation floor refuses, and nothing is spawned', () {
    test('a split into one child spawns nothing at all — the launcher was '
        'never reached, which is asserted on the launcher and not on the '
        'absence of an error', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'floor.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'one', {
          'parent_id': 'the-split',
          'task': 'do a thing',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent'},
          },
          'children': [
            _child(
              'only',
              files: {
                'paths': ['lib/a.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitDelegationRefused, reason: '$out\n$err');
      // The load-bearing assertion: the `claude` stand-in records every
      // invocation, and there were none. "No error was printed" would be
      // satisfied by a run that spawned four children successfully.
      expect(claude.invocations, isEmpty, reason: '$out\n$err');
      expect(out.toString(), contains('NOT DECOMPOSED'));
      expect(out.toString(), contains('singleChild'));
      expect(out.toString(), contains('nothing was spawned'));
      // And the tally is printed, because a decision not to decompose makes no
      // tool call and is therefore invisible unless sprout says so (INV14).
      expect(out.toString(), contains('floor refusals'));
      expect(out.toString(), contains('singleChild: 1'));

      // Nothing was created anywhere: no node row, no worktree, no branch.
      expect(nodes(db), isEmpty);
      expect(
        Directory(p.join(repo, defaultWorktreeDirectory)).existsSync(),
        isFalse,
      );
    });

    test('a fully serial split is refused for noConcurrencyWon, not for '
        'singleChild — the reason names the remedy', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'serial.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'serial', {
          'parent_id': 'the-split',
          'task': 'do a thing',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent'},
          },
          // Both children name the same file, so no wave can hold both.
          'children': [
            _child(
              'a',
              files: {
                'paths': ['lib/same.dart'],
              },
            ),
            _child(
              'b',
              files: {
                'paths': ['lib/same.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitDelegationRefused, reason: '$out\n$err');
      expect(claude.invocations, isEmpty);
      expect(out.toString(), contains('noConcurrencyWon'));
      expect(
        out.toString(),
        contains(
          'split it on file sets that do not '
          'overlap',
        ),
      );
    });
  });

  group('waves run in order and children in a wave run together', () {
    test('four children over two waves: both children of a wave are running '
        'at once, and wave 1 does not start before wave 0 has ended', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'waves.db');
      // Long enough that a serial execution could not produce the interleaving
      // asserted below by accident, short enough that the suite stays fast.
      final claude = _FakeClaude(tmp, sleepSeconds: '0.5');

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'waves', {
          'parent_id': 'the-split',
          'task': 'four things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          // a and c collide on lib/one.dart; b and d collide on lib/two.dart.
          // First-fit therefore lays them out as [a, b] then [c, d]: two waves
          // of two, with the pairs genuinely unable to share a wave.
          'children': [
            _child(
              'a',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'b',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
            _child(
              'c',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'd',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitOk, reason: '$out\n$err');
      expect(claude.invocations, hasLength(4), reason: '$out\n$err');

      // The plan really is two waves of two, and the verb printed it.
      expect(out.toString(), contains('4 children in 2 waves'));

      // What actually overlapped, from the processes themselves. `s` is a
      // child starting, `e` is one ending. Two starts before either end is
      // concurrency inside a wave; a full drain before the third start is
      // ordering between waves. A serial run would read `sesesese`, and a run
      // with no wave boundary would read `sssseeee`.
      expect(claude.lifecycle, 'sseessee', reason: '$out\n$err');
    });
  });

  group('acceptance gates the teardown, in one run, over real processes', () {
    test('one child passes and one fails: the accepted room is removed, the '
        'rejected one is KEPT with its files still on disk, and the store '
        'holds a depth-2 tree', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'mixed.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'mixed', {
          'parent_id': 'the-split',
          'task': 'two things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            // Passes: `git --version` exits 0 in any directory. Leaves
            // nothing behind, so the teardown really can remove the room.
            _child(
              'good',
              files: {
                'paths': ['lib/one.dart'],
              },
              command: ['git', '--version'],
            ),
            // Fails: a ref that does not exist. The marker in the task makes
            // the stand-in leave a file in the room, so "the files are still
            // there" is a claim about work a child produced.
            _child(
              'bad',
              task: 'write the other thing $_leaveMarker',
              files: {
                'paths': ['lib/two.dart'],
              },
              command: [
                'git',
                'rev-parse',
                '--verify',
                'refs/heads/p407-no-such-ref',
              ],
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitChildRejected, reason: '$out\n$err');

      final accepted = events(db, acceptanceAcceptedKind);
      final rejected = events(db, acceptanceRejectedKind);
      expect(accepted, hasLength(1), reason: '$out\n$err');
      expect(rejected, hasLength(1), reason: '$out\n$err');
      expect(rejected.single.payload['reason'], 'conditionFailed');

      // One room removed, one kept — and the kept one still holds the file the
      // child wrote. That is the whole promise of the gate: acceptance decides
      // whether the teardown is *offered*, and a room that was not offered is
      // untouched.
      final removed = events(db, worktreeRemovedKind);
      final kept = events(db, worktreeKeptKind);
      expect(removed, hasLength(1), reason: '$out\n$err');
      expect(kept, isEmpty, reason: 'the rejected room is never offered');
      expect(
        Directory(removed.single.payload['path']! as String).existsSync(),
        isFalse,
      );

      final worktrees = Directory(p.join(repo, defaultWorktreeDirectory))
          .listSync()
          .whereType<Directory>()
          .toList();
      // The positive control for P4-08: the acceptance path already counted
      // correctly, and it still counts each room exactly once — the accepted
      // one removed, the rejected one kept without ever being offered.
      expect(
        out.toString(),
        contains('worktrees   removed 1, kept 1'),
        reason: '$out\n$err',
      );

      expect(worktrees, hasLength(1), reason: 'the rejected room survives');
      expect(
        File(p.join(worktrees.single.path, _leftBehind)).readAsStringSync(),
        contains('left behind'),
      );

      // The tree: one delegation node with both children under it. Depth 2,
      // joined by `parent_id`, which is what makes the board and every
      // containment decision see a tree rather than three roots.
      final all = nodes(db);
      expect(all, hasLength(3), reason: '$out\n$err');
      final roots = all.where((n) => n.parentId == null).toList();
      expect(roots, hasLength(1));
      final children = all.where((n) => n.parentId == roots.single.id).toList();
      expect(children, hasLength(2));
      expect(events(db, delegatePlannedKind), hasLength(1));
      expect(events(db, worktreeCreatedKind), hasLength(2));

      // And the delegation itself does not stay live. A row left `working` is
      // a concurrency slot nothing releases (F-24), and this verb is the one
      // that writes the row.
      expect(roots.single.status, NodeStatus.checkpointed);
    });

    test('an ACCEPTED child whose room is dirty is kept anyway, files intact — '
        'acceptance is not authorization to destroy', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'dirty.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'dirty', {
          'parent_id': 'the-split',
          'task': 'two things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            // Both pass. Both leave a file. Both rooms therefore survive, by
            // `Worktrees.remove`'s own judgement rather than by the gate's.
            _child(
              'one',
              task: 'write one $_leaveMarker',
              files: {
                'paths': ['lib/one.dart'],
              },
              command: ['git', '--version'],
            ),
            _child(
              'two',
              task: 'write two $_leaveMarker',
              files: {
                'paths': ['lib/two.dart'],
              },
              command: ['git', '--version'],
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      // Every child was accepted, so the verb succeeded.
      expect(code, cli.exitOk, reason: '$out\n$err');
      expect(events(db, acceptanceAcceptedKind), hasLength(2));

      // The teardown was offered to both and refused both, on its own terms.
      final kept = events(db, worktreeKeptKind);
      expect(kept, hasLength(2), reason: '$out\n$err');
      for (final event in kept) {
        expect(event.payload['reason'], 'uncommittedChanges');
      }
      expect(events(db, worktreeRemovedKind), isEmpty);
      // The other half of the control: a teardown that was offered and refused
      // counts as kept, once each, and nothing is counted twice.
      expect(
        out.toString(),
        contains('worktrees   removed 0, kept 2'),
        reason: '$out\n$err',
      );

      final rooms = Directory(p.join(repo, defaultWorktreeDirectory))
          .listSync()
          .whereType<Directory>()
          .toList();
      expect(rooms, hasLength(2));
      for (final room in rooms) {
        expect(File(p.join(room.path, _leftBehind)).existsSync(), isTrue);
      }
    });

    test('an unrunnable condition is undecidable, keeps the room, and outranks '
        'a rejection in the exit code', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'undecidable.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'undecidable', {
          'parent_id': 'the-split',
          'task': 'two things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            _child(
              'unrunnable',
              files: {
                'paths': ['lib/one.dart'],
              },
              command: ['p407-no-such-executable-anywhere'],
            ),
            _child(
              'rejected',
              files: {
                'paths': ['lib/two.dart'],
              },
              command: [
                'git',
                'rev-parse',
                '--verify',
                'refs/heads/p407-no-such-ref',
              ],
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      // Both happened; the code reports the one that means sprout could not
      // look. A failure to look is not a verdict (INV8).
      expect(code, cli.exitChildUndecidable, reason: '$out\n$err');
      expect(events(db, acceptanceUndecidableKind), hasLength(1));
      expect(events(db, acceptanceRejectedKind), hasLength(1));
      expect(events(db, worktreeRemovedKind), isEmpty);
    });
  });

  group('a child the containment gate refuses leaves no orphan', () {
    test('the refusal is reported, the run does not crash, and the room that '
        'child would have used is gone', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'refused.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'refused', {
          'parent_id': 'the-split',
          'task': 'two expensive things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            // Each child costs more than the whole run is allowed, so
            // `ContainmentGate.admit` refuses both on budget. This is the same
            // `RefusedSession` path a `concurrency` refusal takes — F-26's own
            // case — reached from the CLI without inventing a bound to reach
            // it with (INV9).
            {
              'id': 'a',
              'task': 'do a',
              'files': {
                'paths': ['lib/one.dart'],
              },
              'estimated_cost_usd': 5.0,
              'success_conditions': [
                {
                  'command': ['git', '--version'],
                },
              ],
            },
            {
              'id': 'b',
              'task': 'do b',
              'files': {
                'paths': ['lib/two.dart'],
              },
              'estimated_cost_usd': 5.0,
              'success_conditions': [
                {
                  'command': ['git', '--version'],
                },
              ],
            },
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
        '--budget-usd',
        '0.01',
      ]);

      expect(code, cli.exitRefused, reason: '$out\n$err');
      // Refused before any process existed, so the stand-in never ran.
      expect(claude.invocations, isEmpty, reason: '$out\n$err');
      expect(events(db, runnerRefusedKind), hasLength(2), reason: '$out\n$err');
      expect(err.toString(), contains('refused (budget)'));

      // The rooms were created before the gate was asked — that order is
      // forced, see `RunCommand` — and nothing ran in them, so both really are
      // removed. A refusal must not leak a directory per child.
      expect(events(db, worktreeCreatedKind), hasLength(2));
      expect(events(db, worktreeRemovedKind), hasLength(2));
      final leftover = Directory(p.join(repo, defaultWorktreeDirectory));
      expect(
        leftover.existsSync() ? leftover.listSync() : const <Object>[],
        isEmpty,
        reason: 'a refused child left an orphan behind',
      );
      expect(out.toString(), contains('refused     2'));
      // P4-08. The log above says two rooms were removed and the store agrees,
      // so the summary — the ten seconds of this a human reads — has to say
      // two as well. It said `removed 0` on trunk, because the refusal path
      // discarded the teardown's answer.
      expect(
        out.toString(),
        contains('worktrees   removed 2, kept 0'),
        reason: 'the summary disagrees with the log it just printed:\n$out',
      );
    });

    test('a child whose session cannot start reports its teardown too — the '
        'summary counts the room it removed on the way out', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'unlaunchable.db');

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'unlaunchable', {
          'parent_id': 'the-split',
          'task': 'two things nothing can run',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            _child(
              'a',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'b',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        // No such binary, so `Process.start` throws and the launch fails
        // *after* the room exists — the second path that tears a room down
        // without ever having judged a child.
        '--claude',
        p.join(tmp.path, 'no-such-claude'),
      ]);

      expect(code, cli.exitRefused, reason: '$out\n$err');
      expect(err.toString(), contains('could not start the session'));
      expect(out.toString(), contains('not started 2'));

      // Both rooms were made and both were removed; the summary says so.
      expect(events(db, worktreeCreatedKind), hasLength(2));
      expect(events(db, worktreeRemovedKind), hasLength(2), reason: '$out$err');
      expect(
        out.toString(),
        contains('worktrees   removed 2, kept 0'),
        reason: 'the summary disagrees with the log it just printed:\n$out',
      );
    });
  });

  group('the brief a child is actually given', () {
    test('build carries the parent\'s task and its shared decisions into the '
        'argv of a real process; map carries neither', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'brief.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'brief', {
          'parent_id': 'the-split',
          'task': 'build the whole flappy bird',
          'mode': {
            'declared': {'mode': 'build', 'reason': 'the artifacts compose'},
          },
          'shared_decisions': ['the bird is a bird'],
          'children': [
            _child(
              'a',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'b',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitOk, reason: '$out\n$err');
      final briefs = claude.briefs;
      expect(briefs, hasLength(2), reason: '$out\n$err');
      for (final brief in briefs) {
        expect(
          brief,
          contains(
            'This is one part of: build the whole flappy '
            'bird',
          ),
        );
        expect(brief, contains('- the bird is a bird'));
      }
    });

    test('a map child is handed its own task and nothing else', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'map-brief.db');
      final claude = _FakeClaude(tmp);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'map-brief', {
          'parent_id': 'the-split',
          'task': 'audit every file',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'read-only and independent'},
          },
          'children': [
            _child(
              'a',
              task: 'audit one',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'b',
              task: 'audit two',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
      ]);

      expect(code, cli.exitOk, reason: '$out\n$err');
      expect(claude.briefs..sort(), ['audit one', 'audit two']);
    });
  });

  group('a child that never returns does not hold its wave for ever', () {
    test('the deadline stops the process, and the child is rejected for '
        'noResult through the ordinary path', () async {
      final repo = await _repository(tmp);
      final db = p.join(tmp.path, 'timeout.db');
      // Sleeps far longer than the deadline and emits nothing before it, so
      // the session genuinely never answers.
      final claude = _FakeClaude(tmp, sleepSeconds: '30', silent: true);

      final code = await sprout([
        'delegate',
        '--plan',
        _writePlan(tmp, 'timeout', {
          'parent_id': 'the-split',
          'task': 'two things',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'independent and read-only'},
          },
          'children': [
            _child(
              'a',
              files: {
                'paths': ['lib/one.dart'],
              },
            ),
            _child(
              'b',
              files: {
                'paths': ['lib/two.dart'],
              },
            ),
          ],
        }),
        '--project',
        repo,
        '--db',
        db,
        '--logs',
        p.join(tmp.path, 'logs'),
        '--claude',
        claude.path,
        '--child-timeout-ms',
        '700',
      ]);

      expect(code, cli.exitChildRejected, reason: '$out\n$err');
      final rejected = events(db, acceptanceRejectedKind);
      expect(rejected, hasLength(2), reason: '$out\n$err');
      for (final event in rejected) {
        expect(event.payload['reason'], 'noResult');
      }
      expect(err.toString(), contains('no ending after 700ms'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('the plan file is refused loudly and specifically', () {
    Future<int> refuse(String name, String contents) async {
      final path = p.join(tmp.path, '$name.json');
      File(path).writeAsStringSync(contents);
      return sprout([
        'delegate',
        '--plan',
        path,
        '--project',
        tmp.path,
        '--db',
        p.join(tmp.path, '$name.db'),
      ]);
    }

    test('a misspelled key is named, not ignored', () async {
      final code = await refuse(
        'typo',
        jsonEncode({
          'parent_id': 'x',
          'task': 'y',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'r'},
          },
          'children': [
            {
              'id': 'a',
              'task': 't',
              'files': {
                'paths': ['lib/a.dart'],
              },
              // The typo the strictness exists for: a lenient reader would
              // spawn this child with no gate at all.
              'succes_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
          ],
        }),
      );
      expect(code, cli.exitUsage);
      expect(err.toString(), contains('children[0]'));
      expect(err.toString(), contains('succes_conditions'));
    });

    test('a child with no success condition is refused by the type, and the '
        'type\'s own sentence reaches the operator', () async {
      final code = await refuse(
        'ungated',
        jsonEncode({
          'parent_id': 'x',
          'task': 'y',
          'mode': {
            'declared': {'mode': 'map', 'reason': 'r'},
          },
          'children': [
            {
              'id': 'a',
              'task': 't',
              'files': {
                'paths': ['lib/a.dart'],
              },
              'success_conditions': <Object?>[],
            },
          ],
        }),
      );
      expect(code, cli.exitUsage);
      expect(
        err.toString(),
        contains(
          'every leaf must declare a '
          'machine-checkable success condition',
        ),
      );
    });

    test('an absent mode is refused rather than defaulted quietly', () async {
      final code = await refuse(
        'nomode',
        jsonEncode({
          'parent_id': 'x',
          'task': 'y',
          'children': [
            {
              'id': 'a',
              'task': 't',
              'files': {
                'paths': ['lib/a.dart'],
              },
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
          ],
        }),
      );
      expect(code, cli.exitUsage);
      expect(err.toString(), contains('mode is missing'));
    });

    test('a file that is not there is a usage error naming it', () async {
      final code = await sprout([
        'delegate',
        '--plan',
        p.join(tmp.path, 'nope.json'),
        '--project',
        tmp.path,
      ]);
      expect(code, cli.exitUsage);
      expect(err.toString(), contains('--plan could not be read'));
    });
  });
}

// ---------------------------------------------------------------------------

/// The marker a child's task carries when the stand-in should leave work in
/// the room it was given.
const String _leaveMarker = 'LEAVE-A-FILE';

/// What it leaves.
const String _leftBehind = 'left-behind.txt';

/// Writes [plan] as JSON under [tmp] and answers the path.
String _writePlan(Directory tmp, String name, Map<String, Object?> plan) {
  final path = p.join(tmp.path, '$name.json');
  File(path).writeAsStringSync(jsonEncode(plan));
  return path;
}

/// One child of a plan, with the defaults every test here would otherwise
/// repeat: a passing condition, and a task naming the child.
Map<String, Object?> _child(
  String id, {
  String? task,
  required Map<String, Object?> files,
  List<String> command = const ['git', '--version'],
}) => {
  'id': id,
  'task': task ?? 'do $id',
  'files': files,
  'success_conditions': [
    {'command': command},
  ],
};

/// A `claude` stand-in that is a real process, and the suite's instrument.
///
/// It replays a Phase 0 capture so the parse, the projection and the store are
/// all the production path. It also records three things a test cannot
/// otherwise see:
///
/// - **that it ran at all**, so "the launcher was never called" is an assertion
///   about the launcher rather than about the absence of an error;
/// - **the brief it was handed**, read off its own argv, so
///   `Decomposition.briefFor` is asserted where it actually lands;
/// - **when it started and ended**, in one shared log, so the wave ordering is
///   asserted from what overlapped rather than from the plan that predicted it.
final class _FakeClaude {
  factory _FakeClaude(
    Directory tmp, {
    String? sleepSeconds,
    bool silent = false,
  }) {
    final index = _fakes++;
    final record = Directory(p.join(tmp.path, 'claude-record$index'))
      ..createSync(recursive: true);
    final lifecycle = p.join(tmp.path, 'lifecycle$index.log');
    final fixture = p.absolute(
      '../docs/research/fixtures/phase0/streams/A.ndjson',
    );
    final script = File(p.join(tmp.path, 'claude-$index'));
    final nap = sleepSeconds ?? '30';
    // `exec` on the silent variant so the sleeping process IS the process
    // sprout launched. A shell that forks its sleep leaves an orphan holding
    // the stdout pipe open after the shell has been signalled, which is a real
    // limit of signalling a pid rather than a process group — F-30. The
    // mechanism under test here is the deadline, so the stand-in does not stage
    // that second problem on top of it.
    script.writeAsStringSync(
      silent
          ? '#!/bin/sh\nexec sleep $nap\n'
          : [
              '#!/bin/sh',
              // The task `claude -p <task>` was given is the second argument:
              // the brief, verbatim, off a real argv.
              r'''printf '%s' "$2" > "''' + record.path + r'''/brief-$$.txt"''',
              r'case "$2" in',
              '  *$_leaveMarker*) echo left behind > '
                  '"\$PWD/$_leftBehind" ;;',
              'esac',
              "printf 's' >> '$lifecycle'",
              if (sleepSeconds != null) 'sleep $sleepSeconds',
              "cat '$fixture'",
              "printf 'e' >> '$lifecycle'",
              '',
            ].join('\n'),
    );
    Process.runSync('chmod', ['+x', script.path]);
    return _FakeClaude._(script.path, record, lifecycle);
  }

  _FakeClaude._(this.path, this._record, this._lifecycle);

  /// The stand-in's path, for `--claude`.
  final String path;

  final Directory _record;
  final String _lifecycle;

  /// One entry per invocation.
  List<File> get invocations => _record.listSync().whereType<File>().toList();

  /// The brief each invocation was handed, in no particular order.
  List<String> get briefs => [
    for (final file in invocations) file.readAsStringSync(),
  ];

  /// `s` for a child starting and `e` for one ending, in the order they
  /// happened.
  String get lifecycle {
    final file = File(_lifecycle);
    return file.existsSync() ? file.readAsStringSync() : '';
  }
}

int _fakes = 0;

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
