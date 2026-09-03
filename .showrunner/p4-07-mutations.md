# P4-07 — the INV8 mutation pass

Method, from `.game_loop/INVARIANTS.md` INV8: *"neuter the producer — make the guard permit
everything, the detector find nothing, the validator have no opinions — and see what still passes."*

Each mutant was applied to the real source in the worktree, `dart test test/cli_delegate_test.dart
test/decomposition_test.dart` was run, and the source was restored from a copy taken beforehand.
The restore was verified with `diff -q` against those copies at the end.

Baseline before mutating: **70 tests, all passing** (14 in `cli_delegate_test.dart`, 56 in
`decomposition_test.dart`).

**Every mutant was checked for the P4-06 trap first.** `.showrunner/p4-06-mutations.md` records that
a mutant which fails to *compile* comes back red with nothing measured, because the suite never
starts. So the pass count is in the table: a mutant that ran 68 or 69 of the 70 tests loaded and
executed, and its red is an assertion failure rather than a load failure. None of the eleven below
came back with a count that says otherwise.

| # | Mutation | Result | Ran | Failing tests |
|---|---|---|---|---|
| 1 | `DelegateCommand` ignores the floor's `DelegationRefusal` and decomposes anyway | **caught** | +68 −2 | `a split into one child spawns nothing at all`, `a fully serial split is refused for noConcurrencyWon` |
| 2 | Each child is launched with `child.task` instead of `decomposition.briefFor(child)` | **caught** | +69 −1 | `build carries the parent's task and its shared decisions into the argv of a real process` |
| 3 | The teardown stops being gated on the acceptance — every child is offered it | **caught** | +68 −2 | `one child passes and one fails …`, `an unrunnable condition is undecidable, keeps the room` |
| 4 | Waves are executed **serially**: each child is finished before the next starts | **caught** | +69 −1 | `four children over two waves …` |
| 5 | The **wave boundary** is ignored: every child of every wave starts at once | **caught** | +69 −1 | `four children over two waves …` |
| 6 | A child the containment gate refused keeps its worktree — the orphan F-26 predicts | **caught** | +69 −1 | `the refusal is reported, the run does not crash, and the room that child would have used is gone` |
| 7 | `parsePlan` accepts several file estimates at once and takes the first | **caught** | +69 −1 | `two estimates at once is refused, and so is none` |
| 8 | An absent `estimated_cost_usd` becomes a measured `0` instead of `null` | **caught** | +69 −1 | `an absent cost is UNKNOWN and is not a measured zero` |
| 9 | An unknown key in the plan file is ignored rather than refused | **caught** | +68 −2 | `an unknown key is refused wherever it appears, and named`, `a misspelled key is named, not ignored` |
| 10 | The per-child deadline never fires | **caught** | +69 −1 | `the deadline stops the process, and the child is rejected for noResult` |
| 11 | *Undecidable* is folded into *rejected* in the exit code | **caught** | +69 −1 | `an unrunnable condition is undecidable … and outranks a rejection in the exit code` |

**None survived.**

## Mutants 4 and 5 are the pair worth reading

They are the two halves of the one property the whole leaf turns on, and a test that caught only one
of them would be worthless. Mutant 4 makes the run fully serial — the layout is still computed, the
plan still prints "2 waves", and every child still runs, is judged and has its room dealt with
correctly. Mutant 5 removes the wave boundary — every child of every wave starts at once, which is
exactly the merge conflict `planWaves` exists to prevent, and again every individual outcome is
still right.

Both are invisible to any assertion about *what happened*. They are only visible in *when* things
happened, so the stand-in `claude` appends one byte to a shared log when it starts and one when it
ends, and the test asserts the resulting string is `sseessee` for four children over two waves.
Serial reads `sesesese`; no boundary reads `sssseeee`. That assertion is measured from the processes
themselves rather than from the plan that predicted them, which is the difference between proving
the layout was *computed* and proving it was *obeyed*.

## Mutant 2 is the P4-05 shape, checked deliberately

`.showrunner/p4-05-mutations.md` records the mutant that survived one library over: `briefFor`'s two
branches were separated by a condition the `Decomposition` constructor had already made impossible,
so no input reached them and the test that appeared to prove the behaviour was vacuous. P4-05
repaired `briefFor` itself; what was still unproved after it is that **anything calls `briefFor` at
all** — a verb that passed `child.task` would have left every one of P4-05's tests green, because
they test the method and not its caller.

So this leaf asserts the brief from the **argv of a real process**: the stand-in writes its second
argument (`claude -p <task>`) into a file, and the test reads it back. Mutant 2 confirms that
detects a caller which stopped using it. Without that, `briefFor` would have been a well-tested
method with no producer, which is F-27's shape at a smaller scale.

## What this pass does not cover, per INV6

- **The concurrency variant of F-26 is unreached.** Mutant 6 proves a `RefusedSession` leaves no
  orphan, and the test reaches that path through a *budget* refusal, because a `concurrency` refusal
  cannot be provoked from the CLI: a wave is capped at `min(maxLiveChildren, maxLiveNodes)` = 4 and
  the tree-wide bound is 12, so a plan alone can never exceed it. Reaching it needs a store already
  holding live nodes, which is F-24's residue and has no verb. The handling is identical — both are
  `SpawnRefusal` on the same branch — but only one of the two reasons has been executed.
- **Ctrl-C over a wave is not in the suite.** `SIGINT` is forwarded to every live child, and that is
  asserted only by reading the code. Delivering a real `SIGINT` to the test runner's own process
  would end the run rather than the children.
- **Nothing here mutates `planWaves`, `DelegationFloor` or `AcceptanceCheck` themselves.** They were
  mutated by P4-04, P4-05 and P4-06 against their own suites. What this pass adds is the layer above
  them: that the verb consults them, obeys them, and does the thing their answers call for.
