/// Creating a git worktree for a node, and refusing to destroy one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'git.dart';
import 'outcome.dart';

/// The directory worktrees are created under, relative to the repository root.
///
/// **Inside the repository on purpose**, which looks wrong and is not. A child
/// session runs under its own write guard, and every such guard this project
/// has met treats everything outside the project directory as read-only — so a
/// worktree in a sibling directory would deny the child's first edit. It is
/// also what showrunner does (`docs/research/07-local-harnesses.md`), and
/// matching it means one `.gitignore` entry covers both.
const String defaultWorktreeDirectory = '.worktrees';

/// The prefix on every worktree directory sprout creates.
///
/// So that "did sprout create this?" is answerable by looking, not by
/// remembering. `.worktrees/` is shared with any other harness the repository
/// uses — in this repository it already holds showrunner's — and a teardown
/// that could not tell whose tree it was looking at would be a teardown that
/// eventually removes someone else's.
const String worktreeNamePrefix = 'sprout-';

/// The prefix on every branch sprout creates.
const String branchPrefix = 'sprout/';

/// A repository's worktrees, keyed by node id.
///
/// **The node id is the key, and it is the only honest one.** A worktree is
/// created for one session and torn down when that session's work has been
/// dealt with, and the node id is the single identifier that names exactly
/// that — the task text is not unique, the project directory is shared by the
/// whole tree, and a pid does not exist until after the launch. showrunner uses
/// its leaf name for the same slot; sprout's equivalent is the node.
///
/// So `<repo>/.worktrees/sprout-<nodeId>` on branch `sprout/<nodeId>`, and
/// every verb here takes a node id rather than a path. A caller cannot ask this
/// class to remove an arbitrary directory, which is a property worth having in
/// the one area of sprout that deletes anything.
///
/// Everything here shells out to `git` through [GitRunner] and touches the
/// filesystem. That is why this is its own library rather than a corner of
/// `runner`: it makes a promise the runner does not — **it never destroys
/// work** — and a promise is easier to keep true of an area than of a few
/// functions sitting next to code with different rules.
final class Worktrees {
  /// Manages the worktrees of the repository rooted at [repositoryRoot].
  Worktrees({
    required this.repositoryRoot,
    this.git = const ProcessGit(),
    String? root,
  }) : root = root ?? p.join(repositoryRoot, defaultWorktreeDirectory);

  /// The repository the worktrees are cut from, as an absolute path.
  final String repositoryRoot;

  /// Runs git. Replaced in tests that assert the argv.
  final GitRunner git;

  /// The directory worktrees are created under.
  final String root;

  /// Where the worktree for [nodeId] goes.
  String pathFor(String nodeId) => p.join(root, '$worktreeNamePrefix$nodeId');

  /// The branch the worktree for [nodeId] is on.
  String branchFor(String nodeId) => '$branchPrefix$nodeId';

  /// Resolves the repository root containing [directory], or null.
  ///
  /// Returns the **main** working tree's root, so that a sprout invoked from
  /// inside one worktree cuts the next one from the repository rather than
  /// nesting it. Null when [directory] is not in a git repository at all, and
  /// null is the only thing a failed look may become here — the caller refuses
  /// rather than guessing a root.
  static Future<String?> repositoryRootOf(
    String directory, {
    GitRunner git = const ProcessGit(),
  }) async {
    // `--path-format=absolute` because the answer is used to build paths and
    // to name directories in messages, and git's default for this option is
    // relative to the cwd in some versions.
    final result = await git.run([
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ], workingDirectory: directory);
    if (!result.ok) return null;
    final gitDir = result.stdout.trim();
    if (gitDir.isEmpty) return null;
    // The common dir of a linked worktree is the MAIN checkout's `.git`, which
    // is what makes this resolve to the repository rather than to the worktree
    // `sprout run` happened to be started from. A bare repository has no
    // working tree to cut from and is refused by `git worktree add` itself.
    return p.dirname(gitDir);
  }

  /// Creates the worktree for [nodeId], cut from [base].
  ///
  /// Refuses — never overwrites — when the path or the branch is already
  /// taken. Both refusals mean something exists that sprout did not create in
  /// this call, and in the one case that matters most (a re-run against a node
  /// id that already has a tree) that something is a session's work.
  Future<WorktreeCreation> create({
    required String nodeId,
    String base = 'HEAD',
  }) async {
    final path = pathFor(nodeId);
    final branch = branchFor(nodeId);

    if (Directory(path).existsSync() || File(path).existsSync()) {
      return WorktreeRefused(
        reason: WorktreeRefusalReason.pathExists,
        explanation:
            '$path already exists. sprout will not overwrite it: it may hold '
            'the only copy of another session\'s work. Move it aside, or '
            'spawn under a different node.',
      );
    }

    // `--verify --quiet` exits 0 when the ref is there and 1 when it is not.
    // Anything else is git failing to answer, and an unanswered question is
    // not a no — creating on top of it is exactly how a branch with commits on
    // it gets reused.
    final branchRef = await git.run([
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/heads/$branch',
    ], workingDirectory: repositoryRoot);
    if (branchRef.ok) {
      return WorktreeRefused(
        reason: WorktreeRefusalReason.branchExists,
        explanation:
            'branch $branch already exists, at ${branchRef.stdout.trim()}. '
            'sprout will not check a new session out onto an existing '
            'branch: its commits would land on top of whatever is there.',
      );
    }
    if (branchRef.exitCode != 1) return WorktreeCreateFailed(branchRef);

    final baseSha = await git.run([
      'rev-parse',
      '--verify',
      base,
    ], workingDirectory: repositoryRoot);
    if (!baseSha.ok) return WorktreeCreateFailed(baseSha);

    // `.worktrees/` is deliberately NOT created here. `git worktree add`
    // creates every leading directory itself, and doing it in Dart first
    // reintroduces exactly the failure this area must not have: a `.worktrees`
    // that is a regular file made `Directory.createSync` throw a
    // `FileSystemException` straight out of a method whose whole contract is
    // to answer with a value. Letting git meet the situation turns it into a
    // [WorktreeCreateFailed] carrying git's own message.
    final add = await git.run([
      'worktree',
      'add',
      '-b',
      branch,
      path,
      base,
    ], workingDirectory: repositoryRoot);
    if (!add.ok) return WorktreeCreateFailed(add);

    return WorktreeCreated(
      path: path,
      branch: branch,
      base: base,
      baseSha: baseSha.stdout.trim(),
    );
  }

  /// Reads the worktree for [nodeId]: what is uncommitted in it, and what is
  /// committed on its branch that [baseSha] does not already reach.
  ///
  /// [baseSha] is a commit, not a ref, and that is load-bearing: the ref the
  /// worktree was cut from will have moved by the time anything tears it down,
  /// and comparing against where it points *now* would count a branch that is
  /// merely behind as one that holds nothing.
  Future<WorktreeInspection> inspect({
    required String nodeId,
    required String baseSha,
  }) async {
    final path = pathFor(nodeId);
    final branch = branchFor(nodeId);

    final registered = await _isRegistered(path);
    switch (registered) {
      case _Answer(value: false, :final why):
        return WorktreeUnregistered(path: path, why: why);
      case _Answer(value: null, :final why):
        return WorktreeUnreadable(path: path, why: why);
      case _Answer():
        break;
    }

    // `--porcelain` is the stable format, and it is v1 deliberately: v2 adds
    // fields nothing here reads and changes the column layout that the `??`
    // test below depends on.
    final status = await git.run([
      'status',
      '--porcelain',
    ], workingDirectory: path);
    if (!status.ok) return WorktreeUnreadable(path: path, why: status.label);

    var modified = 0;
    var untracked = 0;
    for (final line in const LineSplitter().convert(status.stdout)) {
      if (line.trim().isEmpty) continue;
      if (line.startsWith('??')) {
        untracked++;
      } else {
        modified++;
      }
    }

    final ahead = await git.run([
      'rev-list',
      '--count',
      '$baseSha..HEAD',
    ], workingDirectory: path);
    if (!ahead.ok) return WorktreeUnreadable(path: path, why: ahead.label);
    final unmerged = int.tryParse(ahead.stdout.trim());
    if (unmerged == null) {
      return WorktreeUnreadable(
        path: path,
        why:
            'git rev-list --count answered "${ahead.stdout.trim()}", which is '
            'not a number, so how far the branch is ahead is unknown',
      );
    }

    return WorktreeObserved(
      path: path,
      branch: branch,
      modifiedFiles: modified,
      untrackedFiles: untracked,
      unmergedCommits: unmerged,
    );
  }

  /// Tears the worktree for [nodeId] down — or keeps it, and says why.
  ///
  /// **This mostly refuses, and that is the point.** A child session's whole
  /// job is to leave changes behind, so the ordinary outcome of a safe teardown
  /// is [WorktreeKept]. From `docs/research/07-local-harnesses.md`: *"an
  /// abandoned worktree may hold the only copy of real work: surface it, do not
  /// silently reuse it and do not silently delete it."*
  ///
  /// There is no `force` parameter and there will not be one. `git worktree
  /// remove --force` and `git branch -D` do not appear anywhere in this
  /// library, and `worktree_test.dart` reads this source to say so — because
  /// the pressure to add a flag "just for the refused case" arrives later, from
  /// someone whose tree really is disposable, and a flag that exists gets
  /// passed.
  Future<WorktreeTeardown> remove({
    required String nodeId,
    required String baseSha,
  }) async {
    final branch = branchFor(nodeId);
    final inspection = await inspect(nodeId: nodeId, baseSha: baseSha);

    final WorktreeObserved observed;
    switch (inspection) {
      case WorktreeUnregistered(:final path, :final why):
        return WorktreeKept(
          path: path,
          branch: branch,
          reason: WorktreeKeepReason.notAWorktree,
          explanation:
              '$path is not a worktree this repository registered, so sprout '
              'will not remove it: $why',
          evidence: {'why': why},
        );
      case WorktreeUnreadable(:final path, :final why):
        return WorktreeKept(
          path: path,
          branch: branch,
          reason: WorktreeKeepReason.unreadable,
          explanation:
              'sprout could not read $path, and a look that failed is not '
              'evidence that there is nothing to lose: $why',
          evidence: {'why': why},
        );
      case WorktreeObserved():
        observed = inspection;
    }

    if (!observed.isClean) {
      return WorktreeKept(
        path: observed.path,
        branch: branch,
        reason: WorktreeKeepReason.uncommittedChanges,
        explanation:
            '${observed.path} holds ${observed.modifiedFiles} changed and '
            '${observed.untrackedFiles} untracked file(s). Removing it would '
            'destroy them, and they may be the only copy.',
        evidence: observed.toJson(),
      );
    }
    if (observed.unmergedCommits > 0) {
      return WorktreeKept(
        path: observed.path,
        branch: branch,
        reason: WorktreeKeepReason.unmergedCommits,
        explanation:
            'branch $branch carries ${observed.unmergedCommits} commit(s) the '
            'base does not reach. The files are clean; the history is not, and '
            'sprout does not merge on a session\'s behalf.',
        evidence: observed.toJson(),
      );
    }

    final removed = await git.run([
      'worktree',
      'remove',
      observed.path,
    ], workingDirectory: repositoryRoot);
    if (!removed.ok) {
      return WorktreeKept(
        path: observed.path,
        branch: branch,
        reason: WorktreeKeepReason.removeFailed,
        explanation:
            'sprout measured ${observed.path} as clean and git still refused '
            'to remove it. git knows something sprout did not measure, so the '
            'worktree stays: ${removed.label}',
        evidence: {...observed.toJson(), 'why': removed.label},
      );
    }

    // `-d`, never `-D`. See `WorktreeRemoved.branchDeleted`: this is git's own
    // second opinion on the count above, and if the two disagree git wins.
    final deleted = await git.run([
      'branch',
      '-d',
      branch,
    ], workingDirectory: repositoryRoot);
    return WorktreeRemoved(
      path: observed.path,
      branch: branch,
      branchDeleted: deleted.ok,
      branchKeptWhy: deleted.ok ? null : deleted.label,
    );
  }

  /// Whether git lists [path] as a worktree of this repository.
  ///
  /// Three answers, not two: true, false, and **null for a look that failed**.
  Future<_Answer> _isRegistered(String path) async {
    final listed = await git.run([
      'worktree',
      'list',
      '--porcelain',
    ], workingDirectory: repositoryRoot);
    if (!listed.ok) {
      return _Answer(null, listed.label);
    }
    final wanted = _canonical(path);
    for (final line in const LineSplitter().convert(listed.stdout)) {
      if (!line.startsWith('worktree ')) continue;
      if (_canonical(line.substring('worktree '.length)) == wanted) {
        return const _Answer(true, 'registered');
      }
    }
    final present = Directory(path).existsSync()
        ? 'the directory is there anyway'
        : 'and the directory is not there either';
    return _Answer(false, 'git worktree list does not name it, $present');
  }

  /// The path as git would name it, so a symlinked temp directory — which is
  /// what `/tmp` is on macOS — compares equal to the `/private/...` path git
  /// prints back.
  static String _canonical(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) return p.normalize(p.absolute(path));
    return p.normalize(directory.resolveSymbolicLinksSync());
  }
}

/// A yes, a no, or a look that failed — with the sentence that explains it.
final class _Answer {
  const _Answer(this.value, this.why);

  final bool? value;
  final String why;
}
