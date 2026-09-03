/// A git worktree per child, created and torn down safely.
///
/// `docs/01-plan.md` §11 asks Phase 4 for a *worktree per child*, and this is
/// the mechanism half of it: create a room for one node's session, read what is
/// in it, and — this is the part with teeth — **refuse to destroy it** whenever
/// removing it would lose work.
///
/// Start at [Worktrees]. Every verb is keyed by node id, so a caller cannot ask
/// this library to remove an arbitrary directory:
///
/// - [Worktrees.create] runs `git worktree add -b` for a branch and directory
///   named after the node, cut from a base ref, and answers with a
///   [WorktreeCreation]. It **refuses** rather than overwrites when the path or
///   the branch is already taken.
/// - [Worktrees.inspect] answers with a [WorktreeInspection]: the tracked
///   changes, the **untracked files**, and how far the branch is ahead of the
///   commit it was cut from.
/// - [Worktrees.remove] answers with a [WorktreeTeardown] — removed, or kept
///   with the reason and the evidence.
///
/// **Its own area rather than a corner of `runner`**, on the argument
/// `scaffold_test.dart` makes for `hooks` against `stream`: this code shells
/// out to `git` and touches the filesystem under a promise the runner does not
/// make — *it never destroys work* — and a promise like that is easier to keep
/// true of a library, where a test can read the whole area's source and assert
/// that `--force` and `git branch -D` do not appear in it, than of a few
/// functions living beside code with different rules.
///
/// **Three things this library refuses to do.**
///
/// It does not force. There is no `--force` on the removal and no `-D` on the
/// branch delete, and no parameter that would add one. The rule comes from
/// `docs/research/07-local-harnesses.md`: *"an abandoned worktree may hold the
/// only copy of real work: surface it, do not silently reuse it and do not
/// silently delete it."*
///
/// It does not treat a failed look as an empty one. A `git status` that could
/// not run produces [WorktreeKeepReason.unreadable], never a clean tree — that
/// distinction is the difference between a guard and a deletion (INV8).
///
/// And it does not merge, rebase or commit on a session's behalf. sprout makes
/// the room; integrating what a child left in it is not Phase 4's, and a branch
/// that is ahead of its base is a [WorktreeKept], not a problem to solve here.
///
/// The `worktree.*` event kinds this area's callers append are declared in
/// `package:sprout_protocol/values.dart` and re-exported below, not written as
/// literals — that was findings F-11 and F-12, each of which cost a leaf.
///
/// Implementation lives under `lib/src/worktree/`. See `docs/01-plan.md` §11.
library;

export 'package:sprout_protocol/values.dart'
    show
        worktreeCreatedKind,
        worktreeKeptKind,
        worktreeKindPrefix,
        worktreeRemovedKind;

export 'src/worktree/git.dart'
    show GitResult, GitRunner, ProcessGit, gitCouldNotRun;
export 'src/worktree/outcome.dart'
    show
        WorktreeCreateFailed,
        WorktreeCreated,
        WorktreeCreation,
        WorktreeInspection,
        WorktreeKeepReason,
        WorktreeKept,
        WorktreeObserved,
        WorktreeRefusalReason,
        WorktreeRefused,
        WorktreeRemoved,
        WorktreeTeardown,
        WorktreeUnreadable,
        WorktreeUnregistered;
export 'src/worktree/worktrees.dart'
    show Worktrees, branchPrefix, defaultWorktreeDirectory, worktreeNamePrefix;
