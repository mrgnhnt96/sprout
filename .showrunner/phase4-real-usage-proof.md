# sprout Phase 4 — does it actually work? Proved by real usage.

Not the test suite, not a branch. One **compiled** `sprout` from trunk, one throwaway `git init`
repository, and **real `claude -p` sessions that ran and wrote files**.

The bar, in the developer's words: *"If you don't think that this works, then we aren't done.
You'll need to test this to make sure that it works. Both via tests and real usage."*

Every run below is from a single sequence against one repository and one store, with the trunk
binary that carries P4-03 … P4-09. Reproducible: compile, `git init`, run the four commands.

    binary : dart compile exe sproutd/bin/sprout.dart
    model  : claude-opus-5[1m], real sessions, real cost
    suite  : sproutd 632 passing · sprout_ui 71 passing · sprout_protocol clean

---

## 1. A real delegation — floor, waves, worktrees, acceptance

The plan (abridged; the full file is in this document's history):

  mode        : build — "both files must use the identical greeting, so the decision is shared"
  decisions   : "the greeting word is exactly: bonjour", "no trailing punctuation"
  child alpha : write alpha.txt   · success: grep -qx bonjour alpha.txt      (will PASS)
  child beta  : write beta.txt    · success: grep -qx NOT_THE_WORD beta.txt  (will FAIL)

**The load-bearing detail:** `bonjour` appears only in `shared_decisions`. It is in neither child's
own task. If both children write it, `Decomposition.briefFor` really pushed the parent's decision
into a live model — §2.3's `build` mode having an observable consequence, not being a field.

delegate trunk-real-delegation
2 children in 1 wave (max width 2)
  mode build: both files must use the identical greeting, so the decision is shared
  wave 0: alpha, beta
node mtl4w0d6-e1f67946 (the delegation)
wave 0: 2 child(ren)
[alpha] node mtl4w0d7-5af16546  pid 10613  /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4w0d7-5af16546
[beta] node mtl4w0fb-df90df66  pid 10622  /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4w0fb-df90df66
[alpha] session 041377d4-4a1f-4143-90dd-a22ad7db7440  model claude-opus-5[1m]
[beta] session eb7dc207-95fb-4a41-816a-d57d863715c4  model claude-opus-5[1m]
[alpha] I'll create the file with the agreed greeting word.
[alpha] Created `alpha.txt` in the worktree root containing exactly `bonjour` (with a trailing newline, no punctuation). Stopping here as instructed.
[alpha] acceptance accepted mtl4w0d7-5af16546: 1 condition(s) passed; the child answered and its subtree had drained

[beta] Created `beta.txt` in the worktree containing exactly `bonjour` (single line, trailing newline, no punctuation). Stopping here as instructed.
result
  accepted    1  alpha
  rejected    1  beta (conditionFailed)
  undecidable 0
  refused     0
  not started 0
  worktrees   removed 0, kept 2

### stderr

sprout: [alpha] worktree kept /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4w0d7-5af16546 (uncommittedChanges): /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4w0d7-5af16546 holds 0 changed and 1 untracked file(s). Removing it would destroy them, and they may be the only copy.
sprout: [beta] acceptance rejected mtl4w0fb-df90df66 (conditionFailed): sh -c grep -qx NOT_THE_WORD beta.txt exited 1
sprout: [beta] worktree kept, not accepted — /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4w0fb-df90df66

### What the children actually wrote

    alpha.txt   bonjour
    beta.txt    bonjour

Both wrote `bonjour`. The shared decision reached both real models through the brief.

Three things happened here that are the whole point of Phase 4:

- **`alpha` passed and was accepted — and its worktree was still KEPT**, because it held an
  untracked file. Acceptance is not authorization to destroy.
- **`beta` exited 0 and reported success, and was REJECTED**, because its success condition
  genuinely failed. The deterministic verifier overruled the model's own self-report, which is
  what §2.4 argues for and what an LLM critic would have got wrong.
- Both children ran **concurrently, in separate git worktrees**, under one delegation node.

---

## 2. Depth — a four-level tree, then the cap refusing

`sprout delegate --parent <alpha>` put two more real children a level down, both accepted. Then
delegating under one of *those* is refused before anything is launched:

[gamma] worktree removed /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4wwjb-4c4f420e and branch sprout/mtl4wwjb-4c4f420e
[delta] worktree removed /private/tmp/sprout-canon-QHumvG/.worktrees/sprout-mtl4wwnq-d60212ce and branch sprout/mtl4wwnq-d60212ce
  refused     2  gamma (depthCap), delta (depthCap)
  worktrees   removed 2, kept 0

sprout: [gamma] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.
sprout: [delta] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.

Exit **2**. No process started, and the rooms those children would have used are removed — a
refusal leaks no directory, and the summary count agrees with the log (that agreement is P4-08;
before it, this printed `removed 0` under two lines saying it had removed two).

Afterwards the store holds **no stuck rows**:

    checkpointed  7
    unlaunched    2      <- refused, and correctly not counted as live

Before P4-09 those two were `spawning` for ever and counted against `maxLiveNodes` (12) and
`maxLiveChildren` (4). Twelve refusals and sprout refused *every* spawn tree-wide.

---

## 3. The delegation floor — refusing to decompose at all

$ sprout delegate --plan <a plan with one child>
delegate too-small-to-split: NOT DECOMPOSED
  singleChild: This splits into one child, which is a handoff rather than a split: it wins no concurrency and still pays for a session, a brief and a return. Do the work in this session — docs/01-plan.md §3 makes "just do it yourself" a first-class branch — or split it into children that can genuinely run at the same time.
  floor refusals {singleChild: 1, nothingEstimable: 0, noConcurrencyWon: 0}
  nothing was spawned

Exit **10**. Every refusal reason present in the tally even at zero, the message names the remedy,
and nothing was created. §3's *"the cheapest performance win consists of not building a tree"*,
actually happening.

---

## 4. The board, driven off the live socket

`sprout ui`, then the board's own client — the same `FrameReader`, `LiveTree` and `App.lines` that
compile into `main.client.dart.js` — against the real tree:

    === FINAL BOARD ===
    cursor s1.da6dc384959fcbb1.305
    LIVE · heartbeat ?
    WATCHDOG · 06:19Z · rang for 2 of 9 node(s): mtl4wwjb-4c4f420e abandoned, mtl4wwnq-d60212ce abandoned
    checkpointed · mtl4w0d6-e1f67946 · add two small text files that agree on the same greeting word · since 06:18Z (1m) · n
      checkpointed · mtl4w0d7-5af16546 · Create a file named alpha.txt in the current directory whose only contents are the 
        checkpointed · mtl4wg06-2774785d · write two more tiny files, one level deeper · since 06:18Z (0m) · next NONE SCHED
          checkpointed · mtl4wg0b-965f38af · Create a file named gamma.txt in the current directory containing exactly the w
            checkpointed · mtl4wwj4-5e45197b · write two more tiny files, one level deeper · since 06:19Z (0m) · next NONE S
              unlaunched · mtl4wwjb-4c4f420e · Create a file named gamma.txt in the current directory containing exactly the
    STALLED · mtl4wwjb-4c4f420e · abandoned · no process was ever started: the containment gate refused the launch (This chi
              unlaunched · mtl4wwnq-d60212ce · Create a file named delta.txt in the current directory containing exactly the
    STALLED · mtl4wwnq-d60212ce · abandoned · no process was ever started: the containment gate refused the launch (This chi
          checkpointed · mtl4wg28-28c4d63d · Create a file named delta.txt in the current directory containing exactly the w
      checkpointed · mtl4w0fb-df90df66 · Create a file named beta.txt in the current directory whose only contents are the a
    holds nothing

Six levels indented by `parent_id`, `unlaunched` rendered, and **`holds nothing`** — the phantom
"holds a worktree we deleted" lines are gone with P4-09.

---

## What this does NOT prove

- **No browser has painted the page.** This exercises the entire client except the paint. There is
  no Chrome on this machine, and installing one or enabling `safaridriver` was not done unattended.
- **The watchdog still rings an `unlaunched` node `abandoned`** — visible above. That is **F-32**,
  a recorded choice rather than an oversight.
- **A pre-P4-09 database keeps its stuck `spawning` rows.** That is **F-33**; the fix moves the row
  at the moment of refusal and the feed is append-only.
- **No wave was genuinely too wide** for the concurrency bound outside the test suite (F-26).
- **The plan is written by a human, not produced by a model.** Deciding a decomposition is a later
  phase; this proves sprout can execute one.
