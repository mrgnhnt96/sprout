# P4-07 — one real run of `sprout delegate`, captured

The suite is not the proof this leaf owes. F-27 was a finding about code
that passes its own tests and is reached by nothing, so a leaf that closed on a green suite alone
would be answering the wrong question. This is the verb, run once, end to end, outside the test
runner.

## What was run

A throwaway git repository in a temp directory, two children, real success conditions, and a `claude`
stand-in that is a **real process with a real pipe** — `/bin/sh` writing genuine stream-json to
stdout, sleeping a second in the middle so the two children genuinely overlap. No real `claude -p`
child was spawned: that would be a recursive session inside a session, and it would make the proof
weaker rather than stronger, because it would be a branch proof of something the orchestrator runs
on trunk against a compiled binary.

```
$ dart run bin/sprout.dart delegate \
    --plan    /tmp/p407-real/plan.json \
    --project /tmp/p407-real/repo \
    --db      /tmp/p407-real/sprout.db \
    --logs    /tmp/p407-real/logs \
    --claude  /tmp/p407-real/claude
```

The plan: **build** mode with a declared reason, two shared decisions, two children on disjoint
files, one child costed and one not, one condition that passes (`git --version`) and one that fails
(`git rev-parse --verify refs/heads/no-such-branch`).

## stdout, verbatim

```text
tree $0.0000 over 0 nodes
delegate p407-real-run
2 children in 1 wave (max width 2)
  mode build: the two files have to agree on the constant they export
  wave 0: one, two
node mtl2t5ey-cc69c12d (the delegation)
wave 0: 2 child(ren)
[one] node mtl2t5f8-21694502  pid 88310  /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5f8-21694502
[two] node mtl2t5hn-bf1a5a66  pid 88316  /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5hn-bf1a5a66
[two] session p407-88316  model stand-in
[one] session p407-88310  model stand-in
[one] worked in /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5f8-21694502
[two] worked in /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5hn-bf1a5a66
[one] acceptance accepted mtl2t5f8-21694502: 1 condition(s) passed; the child answered and its subtree had drained
result
  accepted    1  one
  rejected    1  two (conditionFailed)
  undecidable 0
  refused     0
  not started 0
  worktrees   removed 0, kept 2
```

## stderr, verbatim

```text
sprout: [two] acceptance rejected mtl2t5hn-bf1a5a66 (conditionFailed): git rev-parse --verify refs/heads/no-such-branch exited 128: fatal: Needed a single revision
sprout: [two] worktree kept, not accepted — /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5hn-bf1a5a66
sprout: [one] worktree kept /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5f8-21694502 (uncommittedChanges): /private/tmp/p407-real/repo/.worktrees/sprout-mtl2t5f8-21694502 holds 0 changed and 1 untracked file(s). Removing it would destroy them, and they may be the only copy.
```

Exit code **11** — `exitChildRejected`.

## The three things this shows that the suite could not

**The mode reached the argv of a real process.** Each child's worktree holds the brief the stand-in
wrote out of `$2`, and both carry build's Context column:

```text
update lib/one.dart

This is one part of: bring lib/one.dart and lib/two.dart up to date

Decisions the parent has already made. Follow them; do not re-decide them:
- the constant is named `answer`
- no new dependencies
```

**The store holds a real depth-2 tree, and `sprout snapshot` renders it.** Running the *other* verb
against the same database, in a separate process:

```text
checkpointed · mtl2t5ey-cc69c12d · bring lib/one.dart and lib/two.dart up to date · since 05:20Z (0m) · next NONE SCHEDULED · >=$0.0246 (1 unknown)
  checkpointed · mtl2t5f8-21694502 · update lib/one.dart … · since 05:20Z (0m) · next NONE SCHEDULED · $0.0123
  checkpointed · mtl2t5hn-bf1a5a66 · update lib/two.dart … · since 05:20Z (0m) · next NONE SCHEDULED · $0.0123
holds nothing
journal readable
```

The delegation is `checkpointed`, not stuck live — F-24's shape, avoided. The spend is `>=$0.0246
(1 unknown)` rather than a total, because the delegation node itself reported no dollars: INV7
holding through a verb that did not exist when it was written.

The whole feed, by kind:

```text
acceptance.accepted|1   acceptance.rejected|1   delegate.planned|1
frame.assistant|2       frame.result|2          frame.system.init|2
runner.exited|2         runner.observed|3       runner.session|2
runner.spawned|2        runner.updated|5        worktree.created|2
worktree.kept|1
```

**The accepted child's worktree was kept, in a real run, by the mechanism rather than by the gate.**
This is the outcome worth reading, and it was not staged: the stand-in wrote its `brief.txt` into
the room it was given, so the accepted child's worktree held one untracked file, and
`Worktrees.remove` refused. Acceptance decided the teardown would be *offered*; the teardown decided
it would not happen. Those are two different decisions and both of them fired in this run, which is
`docs/01-plan.md` §6's *"a brief is not a human"* observed rather than asserted.

## One thing the counts disagree about, and it is real

The report says `worktrees removed 0, kept 2` and the feed carries **one** `worktree.kept` row. They
are both right and they are counting different things: the rejected child's room was never offered
to `Worktrees.remove`, so that library never produced a `WorktreeKept` to write. Recorded as F-31 in
`docs/02-open-findings.md` rather than repaired here, because the repair is a new `kind` and there
is a real argument that it should instead be derived from the `acceptance.rejected` row that is
already on that node's feed.
