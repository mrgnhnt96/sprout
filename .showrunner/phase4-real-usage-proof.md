# sprout Phase 4 — REAL-USAGE PROOF on trunk

Not the test suite, and not a branch. A **compiled** `sprout` from trunk, a throwaway `git init`
repository, and **real `claude -p` sessions that really ran and really wrote files**.

The developer's bar, in their words: *"If you don't think that this works, then we aren't done.
You'll need to test this to make sure that it works. Both via tests and real usage."*

  binary : dart compile exe sproutd/bin/sprout.dart   (trunk, with P4-07 merged)
  repo   : a fresh `git init` with one commit and `.worktrees/` ignored
  model  : claude-opus-5[1m], real sessions, real cost

---

## 1. `sprout delegate` — a real depth-2 delegation

The plan, in full:

{
  "parent_id": "trunk-real-delegation",
  "task": "add two small text files that agree on the same greeting word",
  "mode": {
    "declared": {
      "mode": "build",
      "reason": "both files must use the identical greeting, so the decision is shared"
    }
  },
  "shared_decisions": [
    "the greeting word is exactly: bonjour",
    "no trailing punctuation"
  ],
  "children": [
    {
      "id": "alpha",
      "task": "Create a file named alpha.txt in the current directory whose only contents are the agreed greeting word. Then stop.",
      "files": {"paths": ["alpha.txt"]},
      "success_conditions": [
        {"command": ["sh", "-c", "grep -qx bonjour alpha.txt"]}
      ]
    },
    {
      "id": "beta",
      "task": "Create a file named beta.txt in the current directory whose only contents are the agreed greeting word. Then stop.",
      "files": {"paths": ["beta.txt"]},
      "success_conditions": [
        {"command": ["sh", "-c", "grep -qx NOT_THE_WORD beta.txt"]}
      ]
    }
  ]
}

**The load-bearing detail:** the word `bonjour` appears **only** in `shared_decisions`. Neither
child's own `task` contains it. If both children write `bonjour`, then `Decomposition.briefFor`
really did push the parent's shared decision down into a live model — which is the `build` half of
docs/01-plan.md §2.3 having an observable consequence rather than being a field nobody reads.

### What ran

tree $0.0000 over 0 nodes
delegate trunk-real-delegation
2 children in 1 wave (max width 2)
  mode build: both files must use the identical greeting, so the decision is shared
  wave 0: alpha, beta
node mtl3agt7-38bf008a (the delegation)
wave 0: 2 child(ren)
[alpha] node mtl3agt7-9cbf6a44  pid 15696  /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3agt7-9cbf6a44
[beta] node mtl3agv1-e27b96b5  pid 15704  /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3agv1-e27b96b5
[alpha] session 1900a5ea-2364-49b0-8930-eddef3a529ae  model claude-opus-5[1m]
[beta] session 172d5004-a63c-4159-8934-1e8fca6a39b7  model claude-opus-5[1m]
[alpha] I'll create the file with the agreed greeting word.
[alpha] Created `alpha.txt` in the worktree root containing exactly `bonjour` (with a trailing newline, no punctuation). Stopping here as instructed.
[alpha] acceptance accepted mtl3agt7-9cbf6a44: 1 condition(s) passed; the child answered and its subtree had drained
[beta] Created `beta.txt` in the worktree root containing exactly `bonjour` (single line, trailing newline, no punctuation). Stopping here.
result
  accepted    1  alpha
  rejected    1  beta (conditionFailed)
  undecidable 0
  refused     0
  not started 0
  worktrees   removed 0, kept 2

### stderr

sprout: [alpha] worktree kept /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3agt7-9cbf6a44 (uncommittedChanges): /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3agt7-9cbf6a44 holds 0 changed and 1 untracked file(s). Removing it would destroy them, and they may be the only copy.
sprout: [beta] acceptance rejected mtl3agv1-e27b96b5 (conditionFailed): sh -c grep -qx NOT_THE_WORD beta.txt exited 1
sprout: [beta] worktree kept, not accepted — /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3agv1-e27b96b5

### The tree it left in the store

cursor s1.b0cff26de13ac662.122
checkpointed · mtl3agt7-38bf008a · add two small text files that agree on the same greeting word · since 05:33Z (1m) · next NONE SCHEDULED · >=$0.4616 (1 unknown)
  checkpointed · mtl3agt7-9cbf6a44 · Create a file named alpha.txt in the current directory whose only contents are the agreed greeting word. Then stop. This is one part of: add two small text files that agree on the same greeting word Decisions the parent has already made. Follow them; do not re-decide them: - the greeting word is exactly: bonjour - no trailing punctuation · since 05:33Z (1m) · next NONE SCHEDULED · $0.2223
  checkpointed · mtl3agv1-e27b96b5 · Create a file named beta.txt in the current directory whose only contents are the agreed greeting word. Then stop. This is one part of: add two small text files that agree on the same greeting word Decisions the parent has already made. Follow them; do not re-decide them: - the greeting word is exactly: bonjour - no trailing punctuation · since 05:33Z (1m) · next NONE SCHEDULED · $0.2393
holds nothing
journal readable

Two children under one delegation node, by `parent_id`. The parent's spend reads `>=` with an
unknown count, which is F-23 being honest rather than guessing.

### What the children actually wrote

$ cat alpha.txt
bonjour
$ cat beta.txt
bonjour

Both wrote `bonjour`. The shared decision reached both real models through the brief.

`alpha` passed its condition and was accepted — and its worktree was **still kept**, because it
held an untracked file. Acceptance is not authorization to destroy. `beta` wrote a perfectly good
file and was **rejected**, because its success condition genuinely failed. Note that `beta`'s
session exited 0 and reported success: the deterministic verifier overruled the model's own
self-report, which is exactly what §2.4 argues for.

---

## 2. The delegation floor — refusing to decompose, for real

$ sprout delegate --plan <a plan with one child>
delegate too-small-to-split: NOT DECOMPOSED
  singleChild: This splits into one child, which is a handoff rather than a split: it wins no concurrency and still pays for a session, a brief and a return. Do the work in this session — docs/01-plan.md §3 makes "just do it yourself" a first-class branch — or split it into children that can genuinely run at the same time.
  floor refusals {singleChild: 1, nothingEstimable: 0, noConcurrencyWon: 0}
  nothing was spawned

Exit code **10**. Every refusal reason present in the tally even at zero (INV8's positive control),
and the message names the remedy rather than just saying no. Verified afterwards: the store still
held 3 nodes and no node carrying that task, and the repository still had exactly 2 worktrees —
**nothing was created**. §3's "the cheapest performance win consists of *not* building a tree",
actually happening.

---

## 3. `sprout run --worktree --accept-if` — the single-session path, also real

Run before P4-07 landed, against trunk 34ae278, same method.

sprout — REAL-USAGE PROOF on trunk 34ae278, compiled binary, real claude -p children
Not the test suite. A throwaway git repo, a compiled sprout, and two sessions that really ran.

  binary : dart compile exe bin/sprout.dart  (trunk 34ae278)
  repo   : a fresh git init with one commit

== RUN 1 — the condition PASSES ==
$ sprout run --worktree --accept-if "test -f greeting.txt" "Create a file called greeting.txt ... containing exactly the word: hello."
tree $0.0000 over 0 nodes
worktree /private/tmp/sprout-demo-2Q03AW/.worktrees/sprout-mtl28pj1-e5f28f6e
branch   sprout/mtl28pj1-e5f28f6e  from HEAD fc16b6fb6c03379417efca936a74faf92230d2b3
node mtl28pj1-e5f28f6e  pid 64306
log  /tmp/sprout-demo-2Q03AW/.sproutlogs/mtl28pj1-e5f28f6e.ndjson
session d5d5d598-4249-4928-a1f3-2515829c33e3  model claude-opus-5[1m]
Created `greeting.txt` containing `hello`.
exit 0  result success  cost $0.3053  frames 108
acceptance accepted mtl28pj1-e5f28f6e: 1 condition(s) passed; the child answered and its subtree had drained
sprout: worktree kept /private/tmp/sprout-demo-2Q03AW/.worktrees/sprout-mtl28pj1-e5f28f6e (uncommittedChanges): /private/tmp/sprout-demo-2Q03AW/.worktrees/sprout-mtl28pj1-e5f28f6e holds 0 changed and 1 untracked file(s). Removing it would destroy them, and they may be the only copy.

== RUN 2 — the condition FAILS ==
$ sprout run --worktree --accept-if "test -f NEVER_CREATED.txt" "Create a file called other.txt containing the word world."
exit 0  result success  cost $0.3118  frames 122
sprout: acceptance rejected mtl29hci-f2d5684d (conditionFailed): test -f NEVER_CREATED.txt exited 1
sprout: worktree kept, rejected mtl29hci-f2d5684d (conditionFailed): test -f NEVER_CREATED.txt exited 1 — /private/tmp/sprout-demo-2Q03AW/.worktrees/sprout-mtl29hci-f2d5684d

---

## What this does NOT prove

- **Depth 3.** Both proofs are depth 2. The cap is 3 and nothing here exercised a grandchild.
- **A wave that is genuinely too wide.** Both real plans fit in one wave; F-26's half-refused wave
  was reached only in the test suite.
- **The board.** See the UI note recorded separately.
