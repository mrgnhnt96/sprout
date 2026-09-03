# P4-05 — the INV8 mutation pass

Method, from `.game_loop/INVARIANTS.md` INV8: *"neuter the producer — make the guard permit
everything, the detector find nothing, the validator have no opinions — and see what still passes."*

Each mutant was applied to the real source in the worktree, `dart test test/decomposition_test.dart`
was run, and the source was restored from a copy taken beforehand. None of the five crashed the
suite — every one produced ordinary assertion failures or an ordinary pass — so INV8's "a mutant
that CRASHES is protected, not unprotected" caveat does not apply to any of them.

Baseline before mutating: **46 tests, all passing.**

| # | Mutation | Result | Failing tests |
|---|---|---|---|
| 1 | `DelegationFloor._judge` returns `DelegationPermit` unconditionally — the floor always says yes | **caught**, +39 −6 | 6, incl. `a split into one child is a handoff`, `the check order is fixed`, `every decision is counted somewhere` |
| 2 | `buildWaveWidth = 1000000` — build stops narrowing, so the mode changes nothing about the layout | **caught**, +43 −2 | `build and map lay the same four children out differently`, `the two consequences are independent` |
| 3 | `ModeChoice.defaulted` records `wasDefaulted: false` — a defaulted mode stops admitting it was one | **caught**, +43 −2 | `a defaulted mode and a declared build mode are the same mode and different evidence`, `a plan says out loud when nobody chose the mode` |
| 4 | `briefFor` treats `map` exactly as `build` — map stops isolating context | **SURVIVED** at first, see below; **caught**, +43 −3 after the repair | `a map brief never carries the parent's framing`, `the parent's decisions are pushed down in build and withheld in map`, `the two consequences are independent` |
| 5 | The `Decomposition` constructor stops refusing `map` + `sharedDecisions` | **caught**, +45 −1 | `a map decomposition cannot hold shared decisions at all` |

## Mutant 4 is the one worth reading

The first version of `briefFor` had the two branches differ **only** by whether
`sharedDecisions` were appended. The constructor already refuses a `map` decomposition that carries
any shared decisions, so `sharedDecisions` is *always empty* under map — which means no
constructible input could tell the two branches apart, and a `briefFor` mutated to push decisions
down in map too passed the entire suite with 46/46 green.

The guarantee was really the constructor's. The `switch` in `briefFor` read like enforcement and was
decoration, and the test that appeared to prove "map withholds the decisions" was vacuous: the map
decomposition it built had no decisions to withhold.

**Repair, in the same commit:** the build branch now carries the parent's own `task` down as well as
the decisions, so the two branches differ for *every* decomposition rather than only for ones with
something shared. That is a faithful reading of §2.3's Context column — build *"pushes shared
decisions down"*, map *"isolates"* — and it makes the branch reachable, which is what makes the
mutation detectable. Re-run after the repair: mutant 4 fails 3 tests.

This is recorded rather than quietly fixed because the shape generalises: a guard whose two arms are
separated by a condition an *earlier* constructor already made impossible is a guard no input
exercises, and its own tests will not say so.
