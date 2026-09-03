@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/worktree.dart';
import 'package:test/test.dart';

/// Every `git` invocation this suite makes, recorded, and delegating to a real
/// one underneath.
///
/// A recorder rather than a fake. The argv assertions want a seam; the safety
/// property does not — it is `git`'s behaviour, and *"a test that only proves
/// your fake refuses proves nothing"* (INV8). So the same object does both:
/// commands are captured on the way through and answered by the real binary.
final class RecordingGit implements GitRunner {
  RecordingGit([this._inner = const ProcessGit()]);

  final GitRunner _inner;

  /// Every argv, in order.
  final List<List<String>> calls = [];

  @override
  Future<GitResult> run(
    List<String> arguments, {
    required String workingDirectory,
  }) {
    calls.add(arguments);
    return _inner.run(arguments, workingDirectory: workingDirectory);
  }

  /// The flat text of every command, for asserting what was *not* run.
  String get transcript => calls.map((c) => c.join(' ')).join('\n');
}

/// A [GitRunner] that answers everything with a failure, so the "could not
/// look" path can be reached without breaking a real repository.
final class BrokenGit implements GitRunner {
  const BrokenGit();

  @override
  Future<GitResult> run(
    List<String> arguments, {
    required String workingDirectory,
  }) async => GitResult(
    arguments: arguments,
    exitCode: gitCouldNotRun,
    stdout: '',
    stderr: 'ProcessException: No such file or directory',
  );
}

void main() {
  late Directory tmp;
  late String repo;
  late RecordingGit git;
  late Worktrees worktrees;

  /// Runs git in [directory] and fails the test if it did not exit 0.
  ///
  /// Deliberately not `|| true` and with no redirect: a setup step that failed
  /// quietly would produce a repository the assertions below misread.
  Future<void> run(List<String> arguments, {String? directory}) async {
    final result = await const ProcessGit().run(
      arguments,
      workingDirectory: directory ?? repo,
    );
    expect(result.ok, isTrue, reason: 'setup failed: ${result.label}');
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sprout_worktree_test');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    await run(['init', '--initial-branch=main']);
    await run(['config', 'user.email', 'test@example.com']);
    await run(['config', 'user.name', 'sprout test']);
    File(p.join(repo, 'README.md')).writeAsStringSync('hello\n');
    await run(['add', 'README.md']);
    await run(['commit', '-m', 'first']);

    git = RecordingGit();
    worktrees = Worktrees(repositoryRoot: repo, git: git);
  });

  tearDown(() {
    // `git worktree add` writes into `<repo>/.git/worktrees/`, which is inside
    // the tree being deleted, so nothing outside `tmp` survives this.
    tmp.deleteSync(recursive: true);
  });

  /// The sha `HEAD` is at right now.
  Future<String> head({String? directory}) async {
    final result = await const ProcessGit().run([
      'rev-parse',
      'HEAD',
    ], workingDirectory: directory ?? repo);
    expect(result.ok, isTrue, reason: result.label);
    return result.stdout.trim();
  }

  group('creating a worktree', () {
    test('makes a real one, on a new branch, at the named path', () async {
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1');

      expect(created, isA<WorktreeCreated>());
      created as WorktreeCreated;
      expect(created.path, p.join(repo, '.worktrees', 'sprout-n1'));
      expect(created.branch, 'sprout/n1');
      expect(created.baseSha, base);

      // The artifact is not the claim: the directory existing is asserted
      // alongside git agreeing that it is a worktree and that the file the
      // base commit carries actually came across.
      expect(Directory(created.path).existsSync(), isTrue);
      expect(File(p.join(created.path, 'README.md')).existsSync(), isTrue);

      final listed = await const ProcessGit().run([
        'worktree',
        'list',
        '--porcelain',
      ], workingDirectory: repo);
      expect(listed.stdout, contains('sprout-n1'));
      expect(listed.stdout, contains('branch refs/heads/sprout/n1'));
    });

    test(
      'refuses when the path is already there, and does not touch it',
      () async {
        final path = worktrees.pathFor('n1');
        Directory(path).createSync(recursive: true);
        final squatter = File(p.join(path, 'somebody-elses-work.txt'))
          ..writeAsStringSync('the only copy');

        final created = await worktrees.create(nodeId: 'n1');

        expect(created, isA<WorktreeRefused>());
        expect(
          (created as WorktreeRefused).reason,
          WorktreeRefusalReason.pathExists,
        );
        expect(squatter.readAsStringSync(), 'the only copy');
        // The refusal is BEFORE the branch is created, not after: a refused
        // create that had already made `sprout/n1` would refuse the retry for
        // the other reason forever.
        expect(git.transcript, isNot(contains('worktree add')));
        final branch = await const ProcessGit().run([
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/sprout/n1',
        ], workingDirectory: repo);
        expect(branch.ok, isFalse);
      },
    );

    test('refuses when the branch is already there', () async {
      await run(['branch', 'sprout/n1']);

      final created = await worktrees.create(nodeId: 'n1');

      expect(created, isA<WorktreeRefused>());
      expect(
        (created as WorktreeRefused).reason,
        WorktreeRefusalReason.branchExists,
      );
      expect(Directory(worktrees.pathFor('n1')).existsSync(), isFalse);
      expect(git.transcript, isNot(contains('worktree add')));
    });

    test('reports a git that failed as failed, not as a refusal', () async {
      final created = await worktrees.create(nodeId: 'n1', base: 'no-such-ref');

      // The distinction `runner.refused` draws against `runner.launch_failed`:
      // sprout deciding no is not the machine saying no, and one arm for both
      // would hide which a run hit.
      expect(created, isA<WorktreeCreateFailed>());
      expect(Directory(worktrees.pathFor('n1')).existsSync(), isFalse);
    });

    test('a git that cannot run at all is a failure, never a create', () async {
      final broken = Worktrees(repositoryRoot: repo, git: const BrokenGit());
      final created = await broken.create(nodeId: 'n1');
      expect(created, isA<WorktreeCreateFailed>());
      expect((created as WorktreeCreateFailed).result.couldNotRun, isTrue);
    });
  });

  group('inspecting one', () {
    test('counts tracked changes and untracked files apart', () async {
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;

      File(p.join(created.path, 'README.md')).writeAsStringSync('changed\n');
      File(p.join(created.path, 'brand-new.txt')).writeAsStringSync('new\n');

      final seen = await worktrees.inspect(
        nodeId: 'n1',
        baseSha: base,
      ) as WorktreeObserved;

      expect(seen.modifiedFiles, 1);
      expect(seen.untrackedFiles, 1, reason: '?? lines are work too');
      expect(seen.unmergedCommits, 0);
      expect(seen.isClean, isFalse);
      expect(seen.holdsWork, isTrue);
    });

    test('a clean worktree is clean', () async {
      final base = await head();
      await worktrees.create(nodeId: 'n1');

      final seen = await worktrees.inspect(
        nodeId: 'n1',
        baseSha: base,
      ) as WorktreeObserved;

      expect(seen.modifiedFiles, 0);
      expect(seen.untrackedFiles, 0);
      expect(seen.unmergedCommits, 0);
      expect(seen.holdsWork, isFalse);
    });

    test('counts commits the base does not reach', () async {
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;

      File(p.join(created.path, 'work.txt')).writeAsStringSync('done\n');
      await run(['add', 'work.txt'], directory: created.path);
      await run(['commit', '-m', 'the work'], directory: created.path);

      final seen = await worktrees.inspect(
        nodeId: 'n1',
        baseSha: base,
      ) as WorktreeObserved;

      expect(seen.unmergedCommits, 1);
      expect(seen.isClean, isTrue, reason: 'the files are committed');
      expect(seen.holdsWork, isTrue, reason: 'the history is not');
    });

    test(
      'the base is compared as a SHA, so a moved base still counts',
      () async {
        final base = await head();
        final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;
        File(p.join(created.path, 'work.txt')).writeAsStringSync('done\n');
        await run(['add', 'work.txt'], directory: created.path);
        await run(['commit', '-m', 'the work'], directory: created.path);

        // main moves on, exactly as it would while a child session ran. A
        // teardown that re-resolved the REF would compare against this new
        // commit, find the branch not ahead of it, and delete the work.
        File(p.join(repo, 'other.txt')).writeAsStringSync('meanwhile\n');
        await run(['add', 'other.txt']);
        await run(['commit', '-m', 'main moved']);

        final seen = await worktrees.inspect(
          nodeId: 'n1',
          baseSha: base,
        ) as WorktreeObserved;
        expect(seen.unmergedCommits, 1);
      },
    );

    test('a path git does not list is unregistered, not clean', () async {
      final base = await head();
      Directory(worktrees.pathFor('n1')).createSync(recursive: true);

      final seen = await worktrees.inspect(nodeId: 'n1', baseSha: base);
      expect(seen, isA<WorktreeUnregistered>());
    });

    test('a look that failed is unreadable, not clean', () async {
      final broken = Worktrees(repositoryRoot: repo, git: const BrokenGit());
      final seen = await broken.inspect(nodeId: 'n1', baseSha: 'abc');
      expect(seen, isA<WorktreeUnreadable>());
    });
  });

  group('tearing one down', () {
    test('removes a clean one, and deletes the branch with -d', () async {
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;

      final teardown = await worktrees.remove(nodeId: 'n1', baseSha: base);

      expect(teardown, isA<WorktreeRemoved>());
      expect((teardown as WorktreeRemoved).branchDeleted, isTrue);
      expect(Directory(created.path).existsSync(), isFalse);

      final listed = await const ProcessGit().run([
        'worktree',
        'list',
        '--porcelain',
      ], workingDirectory: repo);
      expect(listed.stdout, isNot(contains('sprout-n1')));
    });

    test('REFUSES a dirty one, and the files are still there afterwards', () async {
      // The leaf. Proved against a real repository, because the property is
      // git's behaviour and a fake that refused would prove only that the fake
      // refuses.
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;

      final tracked = File(p.join(created.path, 'README.md'))
        ..writeAsStringSync('half-finished work\n');
      final untracked = File(p.join(created.path, 'notes.md'))
        ..writeAsStringSync('the only copy of the notes\n');

      final teardown = await worktrees.remove(nodeId: 'n1', baseSha: base);

      expect(teardown, isA<WorktreeKept>());
      final kept = teardown as WorktreeKept;
      expect(kept.reason, WorktreeKeepReason.uncommittedChanges);
      expect(kept.evidence['modified_files'], 1);
      expect(kept.evidence['untracked_files'], 1);

      // The assertion the whole leaf exists for.
      expect(Directory(created.path).existsSync(), isTrue);
      expect(tracked.readAsStringSync(), 'half-finished work\n');
      expect(untracked.readAsStringSync(), 'the only copy of the notes\n');
      expect(kept.isRemoved, isFalse);
    });

    test('refuses on an untracked file alone', () async {
      // Split out from the case above on purpose: a cleanliness check that
      // looked only at tracked changes passes that test and deletes this file.
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;
      final untracked = File(p.join(created.path, 'brand-new.txt'))
        ..writeAsStringSync('nobody ran git add\n');

      final teardown = await worktrees.remove(nodeId: 'n1', baseSha: base);

      expect(teardown, isA<WorktreeKept>());
      expect(
        (teardown as WorktreeKept).reason,
        WorktreeKeepReason.uncommittedChanges,
      );
      expect(untracked.readAsStringSync(), 'nobody ran git add\n');
    });

    test(
      'refuses a clean worktree whose branch is ahead, and keeps the commit',
      () async {
        final base = await head();
        final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;
        File(p.join(created.path, 'work.txt')).writeAsStringSync('done\n');
        await run(['add', 'work.txt'], directory: created.path);
        await run(['commit', '-m', 'the work'], directory: created.path);
        final childHead = await head(directory: created.path);

        final teardown = await worktrees.remove(nodeId: 'n1', baseSha: base);

        expect(teardown, isA<WorktreeKept>());
        expect(
          (teardown as WorktreeKept).reason,
          WorktreeKeepReason.unmergedCommits,
        );
        expect(Directory(created.path).existsSync(), isTrue);
        // The commit is still reachable, which is what "did not destroy work"
        // means for history rather than for files.
        final still = await const ProcessGit().run([
          'rev-parse',
          '--verify',
          'refs/heads/sprout/n1',
        ], workingDirectory: repo);
        expect(still.stdout.trim(), childHead);
      },
    );

    test('keeps it when sprout could not look', () async {
      final broken = Worktrees(repositoryRoot: repo, git: const BrokenGit());
      final teardown = await broken.remove(nodeId: 'n1', baseSha: 'abc');

      expect(teardown, isA<WorktreeKept>());
      expect((teardown as WorktreeKept).reason, WorktreeKeepReason.unreadable);
    });

    test(
      'will not remove a directory this repository did not register',
      () async {
        final base = await head();
        final path = worktrees.pathFor('n1');
        Directory(path).createSync(recursive: true);
        final stranger = File(p.join(path, 'not-ours.txt'))
          ..writeAsStringSync('somebody else put this here');

        final teardown = await worktrees.remove(nodeId: 'n1', baseSha: base);

        expect(teardown, isA<WorktreeKept>());
        expect(
          (teardown as WorktreeKept).reason,
          WorktreeKeepReason.notAWorktree,
        );
        expect(stranger.readAsStringSync(), 'somebody else put this here');
      },
    );

    test('never asks git to force anything', () async {
      final base = await head();
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;
      File(p.join(created.path, 'dirty.txt')).writeAsStringSync('x\n');
      await worktrees.remove(nodeId: 'n1', baseSha: base);

      // Asserted on the argv this suite actually recorded, and on the source,
      // because the two catch different things: a `--force` added tomorrow on
      // a path no test exercises is invisible to the first and not to the
      // second.
      expect(git.transcript, isNot(contains('--force')));
      expect(git.transcript, isNot(contains(' -f')));
      expect(git.transcript, isNot(contains('branch -D')));
    });
  });

  group('the promise this area makes', () {
    test('no source under lib/src/worktree/ forces or hard-deletes', () async {
      // `liveness_test.dart` greps its own area's source for a kill or a
      // signal for exactly this reason: a promise about what a library never
      // does is a property of the whole area, and a test that only covers the
      // paths it happens to exercise cannot state it.
      final offenders = <String>[];
      for (final file
          in Directory('lib/src/worktree')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        for (final banned in const [
          "'--force'",
          "'-f'",
          "'-D'",
          'deleteSync',
          'Directory(path).delete',
        ]) {
          if (source.contains(banned)) offenders.add('${file.path}: $banned');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'this area removes a worktree only through `git worktree remove` '
            'and a branch only through `git branch -d`, so that git refuses '
            'on its own whenever sprout has miscounted',
      );
    });

    test('a fresh library still has exactly the one delete verb', () {
      // The paired positive, so the negative above cannot pass vacuously: if
      // the removal were deleted outright, every banned string would be absent
      // and that test would go green over a library that removes nothing.
      final source = File('lib/src/worktree/worktrees.dart').readAsStringSync();
      expect(source, contains("'worktree',\n      'remove',"));
      expect(source, contains("'branch',\n      '-d',"));
    });
  });

  group('finding the repository', () {
    test('resolves a subdirectory to the repository root', () async {
      final nested = Directory(p.join(repo, 'a', 'b'))
        ..createSync(recursive: true);
      final found = await Worktrees.repositoryRootOf(nested.path);
      expect(
        found == null ? null : Directory(found).resolveSymbolicLinksSync(),
        Directory(repo).resolveSymbolicLinksSync(),
      );
    });

    test('resolves a linked worktree to the MAIN checkout, not to itself', () async {
      // Otherwise a `sprout run --worktree` started from inside a worktree
      // would nest the next one inside it, and the tree would grow a level per
      // spawn instead of staying flat under the repository.
      final created = await worktrees.create(nodeId: 'n1') as WorktreeCreated;
      final found = await Worktrees.repositoryRootOf(created.path);
      expect(
        found == null ? null : Directory(found).resolveSymbolicLinksSync(),
        Directory(repo).resolveSymbolicLinksSync(),
      );
    });

    test('answers null outside a repository rather than guessing', () async {
      final outside = Directory(p.join(tmp.path, 'not-a-repo'))..createSync();
      expect(await Worktrees.repositoryRootOf(outside.path), isNull);
    });
  });
}
