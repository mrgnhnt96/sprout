/// The answers this area gives: created, observed, removed — or kept, and why.
library;

import 'git.dart';

/// Why sprout declined to *create* a worktree.
///
/// Two reasons and deliberately no `other`, on `RefusalReason`'s argument: a
/// refusal sprout cannot name is one it cannot explain, and both of these mean
/// something is already there that sprout did not put there.
enum WorktreeRefusalReason {
  /// The path already exists. Whatever is in it is not sprout's to overwrite.
  pathExists('pathExists'),

  /// The branch name is already taken, so `git worktree add -b` would fail —
  /// and reusing it would put a new session on top of another one's commits.
  branchExists('branchExists');

  const WorktreeRefusalReason(this.wire);

  /// The string used in explanations and anything persisted. Written out
  /// rather than derived from [name] for `NodeStatus.wire`'s reason.
  final String wire;
}

/// The outcome of asking for a worktree.
///
/// Sealed, and success is a *value* rather than the absence of an exception —
/// INV8 applied here exactly as `SpawnDecision` applies it to the gate. The
/// three arms are the three genuinely different things that happen, and the
/// last two are not the same: [WorktreeRefused] is sprout deciding no,
/// [WorktreeCreateFailed] is the machine, and one arm for both would hide which
/// a run hit. That distinction is `runner.refused` versus
/// `runner.launch_failed`, one library over.
sealed class WorktreeCreation {
  const WorktreeCreation();
}

/// The worktree exists, on a new branch cut from [base].
final class WorktreeCreated extends WorktreeCreation {
  /// Records a created worktree.
  const WorktreeCreated({
    required this.path,
    required this.branch,
    required this.base,
    required this.baseSha,
  });

  /// Where the session's files are. This is what goes in the node's `project`.
  final String path;

  /// The branch its commits land on.
  final String branch;

  /// The ref it was cut from, as asked for.
  final String base;

  /// What [base] resolved to at the moment of creation.
  ///
  /// The field that cannot be recovered later: `base` is a ref and refs move,
  /// so a teardown that re-resolved it could compare the branch against a
  /// commit the worktree was never cut from and conclude it holds no work.
  final String baseSha;

  @override
  String toString() => 'WorktreeCreated($path on $branch from $base@$baseSha)';
}

/// sprout declined to create it, because something is already there.
final class WorktreeRefused extends WorktreeCreation {
  /// Records a refusal.
  const WorktreeRefused({required this.reason, required this.explanation});

  /// Which of the two.
  final WorktreeRefusalReason reason;

  /// Why, naming the path or branch, in a sentence a human can act on.
  final String explanation;

  @override
  String toString() => 'WorktreeRefused(${reason.wire}: $explanation)';
}

/// git was asked and could not do it.
final class WorktreeCreateFailed extends WorktreeCreation {
  /// Records the failure, carrying the command that produced it.
  const WorktreeCreateFailed(this.result);

  /// What git was asked and what it said.
  final GitResult result;

  /// Why, in git's own words.
  String get explanation => result.label;

  @override
  String toString() => 'WorktreeCreateFailed($explanation)';
}

/// What a look at a worktree found.
///
/// Sealed for the reason the whole area is careful: **"could not look" is a
/// third answer**, not a variety of clean. [WorktreeUnreadable] exists so that a
/// `git status` that failed can never be folded into "nothing there", which is
/// the exact shape in which a check whose pass is silence deletes somebody's
/// only copy of real work (INV8).
sealed class WorktreeInspection {
  const WorktreeInspection();
}

/// The worktree was read, and this is what is in it.
final class WorktreeObserved extends WorktreeInspection {
  /// Records a reading.
  const WorktreeObserved({
    required this.path,
    required this.branch,
    required this.modifiedFiles,
    required this.untrackedFiles,
    required this.unmergedCommits,
  });

  /// The worktree read.
  final String path;

  /// The branch checked out in it.
  final String branch;

  /// Lines of `git status --porcelain` that are **not** `??`: tracked files
  /// added, modified, deleted, renamed or in conflict.
  final int modifiedFiles;

  /// Lines of `git status --porcelain` that **are** `??`.
  ///
  /// Counted separately and weighed the same. A new file nobody has run
  /// `git add` on is work, and a cleanliness check that looked only at tracked
  /// changes would delete it — which is the single most likely way this area
  /// destroys something, because a session that created files and did not
  /// commit them is the ordinary case, not the edge one.
  final int untrackedFiles;

  /// Commits on the branch that the base does not already reach.
  final int unmergedCommits;

  /// Whether the working tree has nothing in it that git is not already
  /// tracking as committed — untracked files included.
  bool get isClean => modifiedFiles == 0 && untrackedFiles == 0;

  /// Whether anything here would be lost by removing the worktree.
  bool get holdsWork => !isClean || unmergedCommits > 0;

  /// The counts, for an event payload.
  Map<String, Object?> toJson() => {
    'path': path,
    'branch': branch,
    'modified_files': modifiedFiles,
    'untracked_files': untrackedFiles,
    'unmerged_commits': unmergedCommits,
  };

  @override
  String toString() =>
      'WorktreeObserved($path: $modifiedFiles modified, '
      '$untrackedFiles untracked, $unmergedCommits unmerged)';
}

/// The path is not a worktree this repository knows about.
///
/// Distinct from [WorktreeUnreadable] because it is a definite answer rather
/// than a failed look: git was asked and said no. sprout will still not touch
/// the directory — a path it did not register is a path it did not create.
final class WorktreeUnregistered extends WorktreeInspection {
  /// Records that git does not list this path.
  const WorktreeUnregistered({required this.path, required this.why});

  /// The path asked about.
  final String path;

  /// One sentence naming what git said.
  final String why;

  @override
  String toString() => 'WorktreeUnregistered($path: $why)';
}

/// sprout could not look, and says so rather than answering.
final class WorktreeUnreadable extends WorktreeInspection {
  /// Records a failed look.
  const WorktreeUnreadable({required this.path, required this.why});

  /// The path asked about.
  final String path;

  /// One sentence naming the command that failed and what it said.
  final String why;

  @override
  String toString() => 'WorktreeUnreadable($path: $why)';
}

/// Why sprout kept a worktree instead of removing it.
///
/// Five reasons, and every one of them is a *refusal to destroy*. There is no
/// value here that means "removed anyway" — [WorktreeRemoved] is a different
/// type — because the whole promise of this area is that no answer degrades
/// into deletion.
enum WorktreeKeepReason {
  /// `git status --porcelain` was not empty: tracked changes, untracked files,
  /// or both.
  uncommittedChanges('uncommittedChanges'),

  /// The branch carries commits the base does not reach. The files may be
  /// clean; the history is not.
  unmergedCommits('unmergedCommits'),

  /// sprout could not look. Not evidence of a clean tree.
  unreadable('unreadable'),

  /// The path is not a worktree this repository registered, so it is not
  /// sprout's to remove.
  notAWorktree('notAWorktree'),

  /// Everything checked out clean and `git worktree remove` still failed.
  /// git knows something sprout did not measure; git wins.
  removeFailed('removeFailed');

  const WorktreeKeepReason(this.wire);

  /// The string used in explanations and anything persisted.
  final String wire;
}

/// The outcome of asking for a worktree to be torn down.
///
/// Sealed, a value, and **not a bool** — the reason is that the two arms carry
/// entirely different information and only one of them is actionable. A caller
/// that got `false` would know a worktree survived and nothing about whether a
/// human needs to look at it. Not a throw either: keeping a worktree is the
/// *expected* outcome, since a child session's whole job is to leave changes
/// behind, and an expected outcome delivered as an exception is one a caller
/// eventually wraps in a bare `catch`.
sealed class WorktreeTeardown {
  const WorktreeTeardown();

  /// Whether the files are gone.
  bool get isRemoved => this is WorktreeRemoved;

  /// The one-line rendering, for an operator watching a run.
  String get label;
}

/// The worktree is gone, and nothing was lost.
final class WorktreeRemoved extends WorktreeTeardown {
  /// Records a removal.
  const WorktreeRemoved({
    required this.path,
    required this.branch,
    required this.branchDeleted,
    this.branchKeptWhy,
  });

  /// The path that no longer exists.
  final String path;

  /// The branch it was on.
  final String branch;

  /// Whether the branch was deleted too.
  ///
  /// Attempted only with `git branch -d` and **never** `-D`. That is not
  /// belt-and-braces over sprout's own check so much as a second opinion from
  /// the only party entitled to have one: `-d` refuses a branch whose commits
  /// are not reachable elsewhere, so if sprout's count of unmerged commits were
  /// ever wrong, git declines and the branch stays.
  final bool branchDeleted;

  /// Why the branch was kept, when it was. Null when it was deleted.
  final String? branchKeptWhy;

  /// This removal as an event payload.
  Map<String, Object?> toJson() => {
    'path': path,
    'branch': branch,
    'branch_deleted': branchDeleted,
    'branch_kept_why': ?branchKeptWhy,
  };

  @override
  String get label =>
      'removed $path'
      '${branchDeleted ? ' and branch $branch' : ', kept branch $branch'}';

  @override
  String toString() => 'WorktreeRemoved($label)';
}

/// The worktree is still there, on purpose.
final class WorktreeKept extends WorktreeTeardown {
  /// Records a refusal to remove.
  const WorktreeKept({
    required this.path,
    required this.branch,
    required this.reason,
    required this.explanation,
    this.evidence = const {},
  });

  /// The path that still exists, so the human can go and look at it.
  final String path;

  /// The branch it is on.
  final String branch;

  /// Which of the five.
  final WorktreeKeepReason reason;

  /// Why, naming the numbers or the failed command.
  final String explanation;

  /// What was measured, or the text of the look that failed.
  ///
  /// Carried separately from [explanation] so a consumer can branch on the
  /// counts without parsing a sentence, and so the sentence a human reads and
  /// the numbers a program reads cannot disagree — they are rendered from this.
  final Map<String, Object?> evidence;

  /// This refusal as an event payload.
  Map<String, Object?> toJson() => {
    'path': path,
    'branch': branch,
    'reason': reason.wire,
    'explanation': explanation,
    'evidence': evidence,
  };

  @override
  String get label => 'kept $path (${reason.wire}): $explanation';

  @override
  String toString() => 'WorktreeKept($label)';
}
