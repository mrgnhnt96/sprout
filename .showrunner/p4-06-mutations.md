# P4-06 — the INV8 mutation pass

Method, from `.game_loop/INVARIANTS.md` INV8: *"neuter the producer — make the guard permit
everything, the detector find nothing, the validator have no opinions — and see what still passes."*

Each mutant was applied to the real source in the worktree, `dart test test/acceptance_test.dart
test/protocol_test.dart` was run, and the source was restored from a copy taken beforehand.

Baseline before mutating: **85 tests, all passing** (31 in `acceptance_test.dart`, 54 in
`protocol_test.dart`).

| # | Mutation | Result | Failing tests |
|---|---|---|---|
| 1 | `AcceptanceCheck.judge` answers `ChildAccepted` unconditionally — the check always says yes | **caught**, 6 failures | `a passing condition … is accepted`, `a failing condition is rejected`, `a condition nothing can run is undecidable`, `undecidable is not a kind of rejected`, both ordering tests |
| 2 | The `!returned.answered` guard permits everything — a session that never answered is accepted | **caught**, 2 | `a session that never answered is rejected, unrun`, `the check order is fixed` |
| 3 | The `!returned.drained` guard permits everything — a live subtree stops mattering | **caught**, 2 | `a subtree that had not drained is rejected, unrun`, `an answered child with a live subtree is still not accepted` |
| 4 | A non-zero exit code stops being a rejection — the verifier's verdict is ignored | **caught**, 5 | incl. `end to end … a failing --accept-if rejects and the worktree is KEPT` |
| 5 | `ConditionCouldNotRun` answers `ChildRejected` — *undecidable* collapses into *rejected* | **caught**, 5 | incl. `end to end … an unrunnable --accept-if is undecidable, and keeps the room` |
| 6 | `AcceptanceCounts` stops advancing on an acceptance — the positive control goes dark | **caught**, 3 | `accepted is counted too — the positive control`, and the end-to-end payload assertion |
| 7 | `bin/sprout.dart` offers the teardown whatever the verdict said | **caught**, 2 | `a failing --accept-if rejects and the worktree is KEPT`, `an unrunnable --accept-if … keeps the room` |
| 8 | `ProcessConditions` reports a command it could not run as `exitCode: 0` | **caught**, 4 | incl. `all three outcomes land in three different buckets` |
| 9 | `SuccessCondition.workingDirectory` is ignored and everything runs in the workspace root | **caught**, 1 | `a condition's own workingDirectory is resolved under it` |

**None survived.** None crashed the suite either, so INV8's *"a mutant that CRASHES is protected,
not unprotected"* caveat does not apply to any of them — every one produced ordinary assertion
failures.

## Mutant 7 is the one worth reading, and it is a note about method

The first spelling of mutant 7 was `if (verdict == null || verdict.isAccepted)` → `if (true)`, and
it came back "caught" with **a compile error at load**, not an assertion failure: removing the null
test also removed the flow analysis that promoted `verdict` to non-null in the `else` branch, so
`verdict.label` no longer type-checked. That is exactly the reading INV8 warns about — the run went
red, the summary said caught, and **nothing had been measured**, because the suite never started.

Re-spelled as `if (verdict == null || verdict.isAccepted || 1 == 1)`, which neuters the gate while
leaving the program compilable, the mutant is genuinely caught by two end-to-end tests. Both
verdicts read identically in a table; only one of them is evidence.

## Mutant 9 was added because of the P4-05 lesson, not because it failed

`.showrunner/p4-05-mutations.md` records the shape to look for: *a guard whose arms are separated by
a condition something earlier already made impossible is a guard no input exercises, and its own
tests will not say so.* Two candidates were audited in this leaf:

- **`judge`'s empty-conditions throw.** `PlannedChild` already refuses a child with no
  `SuccessCondition`, so an *outcome* arm for the empty case would have been unreachable — which is
  why there is no such arm and the empty list is a throw instead. A throw is reachable from any
  caller, and two tests reach it.
- **`ProcessConditions`'s `workingDirectory == null` branch.** This one *was* at risk: the CLI's
  `--accept-if` never sets a working directory, so nothing in the product reaches the non-null side.
  A test using a real command whose answer differs between two directories was added first, and
  mutant 9 confirms it detects the neutered branch. Without it the field would have been carried and
  never read, and every test would still have been green.
