# P4-08 — the delegate summary now agrees with its own log

Real usage, not the suite: two **compiled** `sprout` binaries, two throwaway `git init`
repositories, the same plan and the same arguments. The only difference between the two runs is
the fix.

No `claude` process is involved anywhere below, and that is on purpose — a containment refusal
happens *before* the launch, so a delegation that trips the depth cap exercises the whole
create-room / refuse / tear-down path for free.

## The setup

`sprout`'s depth cap is 3 (`defaultMaxDepth`). The chain that reaches it was seeded straight into
the store — four nodes, `depth0 → depth1 → depth2 → depth3` — and the delegation was hung under
`depth3`, so the delegation node itself sits at depth 4 and its children would sit at depth 5.

    sprout delegate --plan plan.json --project /tmp/p408/repo --db /tmp/p408/proof.db \
        --logs /tmp/p408/logs --parent depth3

The plan is two independent children, `gamma` and `delta`, each with a real success condition
(`git --version`) that is never reached.

## Before — trunk (`515997d`), exit 2

    tree >=$0.0000 over 4 nodes (4 unknown)
    delegate depth3
    2 children in 1 wave (max width 4)
      mode map: independent and read-only
      wave 0: gamma, delta
    node mtl3ogiu-1ebf558b (the delegation)
    wave 0: 2 child(ren)
    [gamma] worktree removed /private/tmp/p408/repo2/.worktrees/sprout-mtl3ogiw-924ba39b and branch sprout/mtl3ogiw-924ba39b
    [delta] worktree removed /private/tmp/p408/repo2/.worktrees/sprout-mtl3ogn2-280beabc and branch sprout/mtl3ogn2-280beabc
    result
      accepted    0
      rejected    0
      undecidable 0
      refused     2  gamma (depthCap), delta (depthCap)
      not started 0
      worktrees   removed 0, kept 0

Two lines saying a worktree was removed, directly above a summary saying none was. `git worktree
list` afterwards shows only the main checkout, so the log is right and the summary is wrong.

## After — this branch, exit 2

    tree >=$0.0000 over 4 nodes (4 unknown)
    delegate depth3
    2 children in 1 wave (max width 4)
      mode map: independent and read-only
      wave 0: gamma, delta
    node mtl3nwmm-bd59f912 (the delegation)
    wave 0: 2 child(ren)
    [gamma] worktree removed /private/tmp/p408/repo/.worktrees/sprout-mtl3nwmr-3e859365 and branch sprout/mtl3nwmr-3e859365
    [delta] worktree removed /private/tmp/p408/repo/.worktrees/sprout-mtl3nwqx-6a418a52 and branch sprout/mtl3nwqx-6a418a52
    result
      accepted    0
      rejected    0
      undecidable 0
      refused     2  gamma (depthCap), delta (depthCap)
      not started 0
      worktrees   removed 2, kept 0

stderr is identical in both runs and unchanged by the fix:

    sprout: [gamma] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.
    sprout: [delta] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.

And the rooms really are gone, in both runs:

    $ git -C /tmp/p408/repo worktree list
    /private/tmp/p408/repo  5c05416 [main]
    $ ls -A /tmp/p408/repo/.worktrees
    (empty)

The exit code (2, `exitRefused`), the per-teardown lines, and every other counter are unchanged.
Only the `worktrees` line moved.

## What was wrong

`DelegateCommand._tearDown` returned a `bool` and left the tally to its callers. It has three call
sites, and only one — the acceptance path in `_finishChild` — used the answer. The containment
refusal path and the `ProcessException` "could not start the session" path both awaited it and
discarded it, so neither ever reached `_DelegateReport`.

The fix takes the count inside the teardown, so there is no answer left for a caller to drop. The
one kept room that is *not* a teardown — a child that was never accepted, whose room is never
offered to `Worktrees.remove` at all — is still counted by `_finishChild`, and says so in a
comment.

`RunCommand` has its own `_tearDown` with two call sites; it returns `void`, has no report to
under-count, and was not touched.

## Why the harmless direction is not the point

Here the number was wrong low on *removed*, which reads as over-cautious. But `_removed` and
`_kept` are the same discarded boolean: the identical omission under-reports **kept**, and a human
reading `kept 0` when a room was in fact kept would believe their work had been cleaned up when it
is still on disk. INV8's shape — a count that cannot be told from a count of nothing.

## Tests, and the order they were written in

Three assertions were added to `sproutd/test/cli_delegate_test.dart` and **watched fail** against
trunk before any source change:

- the containment-refusal test now asserts `worktrees   removed 2, kept 0` — failed with
  `removed 0, kept 0`;
- a new launch-failure test (`--claude` pointing at a path that does not exist, so `Process.start`
  throws after the room already exists) asserts the same — failed the same way.

Two positive controls were added at the same time and **passed before and after**, which is what
rules out "count everything twice":

- one accepted child and one rejected one → `removed 1, kept 1`;
- two accepted children whose rooms are dirty, so `Worktrees.remove` refuses both →
  `removed 0, kept 2`.

`dart format`, `dart analyze --fatal-infos --fatal-warnings` and the full `dart test` (632 tests)
are green in this tree.

## Stated limits

The ancestor chain was seeded directly into the store rather than grown by four nested real
delegations, so what this run proves about depth is that the *gate* refuses at the cap, not that
four live levels behave. The launch-failure path is covered by the suite only; it was not also
run by hand.
