# P4-09 — a refused spawn no longer holds a concurrency slot

Real usage, not the suite: two **compiled** `sprout` binaries driven against one throwaway
`git init` repository and one four-level chain of **real `claude -p` sessions**. The only
difference between the two runs is the fix; the database each is handed is a byte copy of the
same chain.

Paths are scrubbed (`/Users/USER/`). Node ids are the real ones the run minted.

## The setup

`defaultMaxDepth` is 3, so a child of a depth-3 node sits at depth 4 and is refused. The chain
that reaches it was **not** seeded — four `sprout run` invocations, each launching a real
`claude -p` that really answered, at a real cost of $0.68 across the four:

    sprout run -C <repo> --db chain.db --claude <claude> --budget-usd 5 "Reply with the single word: hi"
    sprout run ... --parent <the node above>          (x3)

Every one ends `checkpointed`. Then twelve spawns are asked for under the deepest node. Each is
refused by the depth cap, so **no process is started for any of them** — the whole demonstration
below the chain is free, which is the point: hitting the cap is not an error condition.

Two of the twelve ask for `--worktree`, so a room is created and torn down around the refusal.

## Before — trunk (`e3f07dc`)

    ### binary: sprout-before
    ### the tree it starts from — four levels, every one of them really ran
    mtl4hgyr-912ab9a9|checkpointed|(root)
    mtl4i2qo-25d3f4fd|checkpointed|mtl4hgyr-912ab9a9
    mtl4i5oj-3e920ceb|checkpointed|mtl4i2qo-25d3f4fd
    mtl4i8o1-abecb52b|checkpointed|mtl4i5oj-3e920ceb

    ### twelve spawns under the deepest node (mtl4i8o1-abecb52b). Depth 4 is past the cap of 3,
    ### so every one is refused and NOTHING is launched. Two ask for a worktree.
    worktree /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itor-8cff2572
    sprout: refused (depthCap), node mtl4itor-8cff2572
    worktree removed /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itor-8cff2572 and branch sprout/mtl4itor-8cff2572
    worktree /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itu9-a3eb5601
    sprout: refused (depthCap), node mtl4itu9-a3eb5601
    worktree removed /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itu9-a3eb5601 and branch sprout/mtl4itu9-a3eb5601
    sprout: refused (depthCap), node mtl4itzb-9904aa91
    sprout: refused (depthCap), node mtl4iu00-0e658350
    sprout: refused (depthCap), node mtl4iu0r-5347e2d9
    sprout: refused (depthCap), node mtl4iu1r-f8b5ff92
    sprout: refused (depthCap), node mtl4iu2j-259b4e98
    sprout: refused (depthCap), node mtl4iu39-be3a1cbe
    sprout: refused (depthCap), node mtl4iu3z-2e80227f
    sprout: refused (depthCap), node mtl4iu4p-eae51ab6
    sprout: refused (depthCap), node mtl4iu5g-8772406d
    sprout: refused (depthCap), node mtl4iu66-e74c682b

    ### what the store says about the twelve rows nothing ever started
    checkpointed|4
    spawning|12

    ### what the board announces as held
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4itzb-9904aa91
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu00-0e658350
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu0r-5347e2d9
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu1r-f8b5ff92
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu2j-259b4e98
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu39-be3a1cbe

    ### and now ONE ordinary root spawn — depth 0, nothing above it, $5 of budget
    tree >=$0.6846 over 16 nodes (12 unknown)
    sprout: refused (concurrency), node mtl4iu7m-947aa3f8
    sprout already has 12 nodes running, at its limit of 12 across the tree. Continue with the work you have, and delegate this once something finishes.
    acceptance not checked: no session ran

**The last three lines are the finding.** Twelve rows that never started a process are
`spawning`, `isHoldingStatus` counts them, and an ordinary root spawn — depth 0, nothing above
it, $5 of budget, on a machine where nothing at all is running — is refused for `concurrency`.
Correct by sprout's own rules and wrong in fact.

The second symptom, in full, from the same store — thirteen entries, because the
refused root spawn at the end of the run left a row too:

    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4itzb-9904aa91
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu00-0e658350
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu0r-5347e2d9
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu1r-f8b5ff92
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu2j-259b4e98
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu39-be3a1cbe
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu3z-2e80227f
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu4p-eae51ab6
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu5g-8772406d
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu66-e74c682b
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway · mtl4iu7m-947aa3f8
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itor-8cff2572 · mtl4itor-8cff2572
    holds /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4itu9-a3eb5601 · mtl4itu9-a3eb5601

Eleven announce the project directory and two announce **worktrees that this same run deleted
seconds earlier** — the `worktree removed` lines above name them, and `.worktrees/` is empty on
disk. Fixing the status fixed this with it: `heldResourcesOf` reports `node.project` for
holding nodes only, so nothing had to change in the resource code.

## After — this branch

    ### binary: sprout-after
    ### the tree it starts from — four levels, every one of them really ran
    mtl4hgyr-912ab9a9|checkpointed|(root)
    mtl4i2qo-25d3f4fd|checkpointed|mtl4hgyr-912ab9a9
    mtl4i5oj-3e920ceb|checkpointed|mtl4i2qo-25d3f4fd
    mtl4i8o1-abecb52b|checkpointed|mtl4i5oj-3e920ceb

    ### twelve spawns under the deepest node (mtl4i8o1-abecb52b). Depth 4 is past the cap of 3,
    ### so every one is refused and NOTHING is launched. Two ask for a worktree.
    worktree /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4izdm-b086c7ba
    sprout: refused (depthCap), node mtl4izdm-b086c7ba
    worktree removed /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4izdm-b086c7ba and branch sprout/mtl4izdm-b086c7ba
    worktree /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4izje-a4606eab
    sprout: refused (depthCap), node mtl4izje-a4606eab
    worktree removed /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/throwaway/.worktrees/sprout-mtl4izje-a4606eab and branch sprout/mtl4izje-a4606eab
    sprout: refused (depthCap), node mtl4izoe-27ec39d7
    sprout: refused (depthCap), node mtl4izp5-03df7e6c
    sprout: refused (depthCap), node mtl4izpw-88404805
    sprout: refused (depthCap), node mtl4izqm-14942eda
    sprout: refused (depthCap), node mtl4izre-e8511360
    sprout: refused (depthCap), node mtl4izs4-cc12947b
    sprout: refused (depthCap), node mtl4izsv-7c33ccda
    sprout: refused (depthCap), node mtl4iztm-c127130c
    sprout: refused (depthCap), node mtl4izuc-ba9747c9
    sprout: refused (depthCap), node mtl4izv3-f5032ddb

    ### what the store says about the twelve rows nothing ever started
    checkpointed|4
    unlaunched|12

    ### what the board announces as held
    holds nothing

    ### and now ONE ordinary root spawn — depth 0, nothing above it, $5 of budget
    tree >=$0.6846 over 16 nodes (12 unknown)
    node mtl4izwk-c1bac2e0  pid 89848
    log  /Users/USER/Development/dart/sprout/.showrunner/scratch/crawler-p409-p4-09-refused-holds-slot/sessions/mtl4izwk-c1bac2e0.ndjson
    session d92c9d05-e6f2-4398-bf0a-2439de29998e  model claude-opus-5[1m]
    hi
    exit 0  result success  cost $0.1626  frames 24
    acceptance not checked: no --accept-if declared

Twelve `unlaunched` rows, `holds nothing`, and the ordinary root spawn is admitted and really
runs. The status moves in `SessionRunner.launch`, beside the `runner.refused` it is recorded
with, so the row and the feed cannot drift apart.

## The store and the board, side by side

    ### the tree it starts from — four levels, every one of them a real claude -p
    mtl4hgyr-912ab9a9|checkpointed|(root)
    mtl4i2qo-25d3f4fd|checkpointed|mtl4hgyr-912ab9a9
    mtl4i5oj-3e920ceb|checkpointed|mtl4i2qo-25d3f4fd
    mtl4i8o1-abecb52b|checkpointed|mtl4i5oj-3e920ceb

    ### every row, BEFORE (13 spawning: the 12 refused children and the refused root)
    checkpointed|4
    spawning|13

    ### everything the board announced as held, BEFORE — the thirteen lines above

    ### every row, AFTER (the 5th checkpointed row is the root spawn that was admitted)
    checkpointed|5
    unlaunched|12

    ### and what the board announces as held, AFTER
    holds nothing

## The cost of the new wire value, measured rather than asserted

`NodeStatus.fromWire` throws on a value it does not know, deliberately. So an **older** binary
reading a **newer** database throws on one of these rows:

    Unhandled exception:
    Invalid argument (value): not a known node status: "unlaunched"
    #0      NodeStatus.fromWire (package:sprout_protocol/src/values/node.dart:48)
    #1      SproutStore._node (package:sproutd/src/store/sprout_store.dart:414)
    #2      SproutStore.tree (package:sproutd/src/store/sprout_store.dart:331)
    #3      StoreSnapshotSource.tree (package:sproutd/src/snapshot/source.dart:71)
        ...
    old-binary exit=255

This is the price of route 1 and it is stated in `NodeStatus.unlaunched`'s own doc comment. It is
one-directional — adding a value cannot break a reader at least as new as the writer, which is
the direction that actually happens — and the alternative was to stretch `checkpointed` (*handed
back with progress*) over a node that never ran, which would put a false sentence in the row for
ever and be unfixable for the same append-only reason.

## The test seen failing first

`sproutd/test/runner_test.dart`, group *"a refused spawn does not hold a concurrency slot"*, was
written first and watched fail with the three source files reverted to trunk. Six of the seven
failed; the seventh is the positive control, which passes on both sides on purpose.

    $ cd sproutd && dart test test/runner_test.dart -n 'does not hold a concurrency slot'
    00:00 +1 -6: Some tests failed.

    Failing tests:
      the row it leaves behind is not counted by the ledger
      and the status moves where the refusal is recorded, so the feed carries both
      it is not announced as holding the project directory it never entered
      a launch that never started holds nothing either
      so five refusals under one parent do not close that parent to a legitimate spawn
      and twelve of them anywhere do not close the whole tree

    Passing, before and after — the positive control:
      but a node that really launched still holds its slot, and the bound still bites

The two denial-of-service failures reported the refusal in sprout's own words, with nothing
running:

    refused for concurrency: This node already has 5 children running, at its limit of 4.
    refused for concurrency: sprout already has 12 nodes running, at its limit of 12 across the tree.

## The six owed checks

This change touches `sprout_protocol/`, so it owes that package's own format and analyze on
top of sproutd's three, plus `sprout_ui`'s suite — the only check that catches a web-unsafe
change, because `build_web_compilers` reports that failure as a warning and exits 0.

    === $ cd sprout_protocol && dart format --output=none --set-exit-if-changed .
    Formatted 13 files (0 changed) in 0.02 seconds.
    exit=0

    === $ cd sprout_protocol && dart analyze --fatal-infos --fatal-warnings
    Analyzing sprout_protocol...
    No issues found!
    exit=0

    === $ cd sproutd && dart format --output=none --set-exit-if-changed .
    Formatted 95 files (0 changed) in 0.28 seconds.
    exit=0

    === $ cd sproutd && dart analyze --fatal-infos --fatal-warnings
    Analyzing sproutd...
    No issues found!
    exit=0

    === $ cd sproutd && dart test
    00:55 +639 ~2: test/watchdog_test.dart: never acts a bell cannot answer back
    00:55 +640 ~2: test/watchdog_test.dart: the knobs are the loop's own the watchdog passes its own frozen-after to the measurement
    00:55 +641 ~2: test/watchdog_test.dart: the knobs are the loop's own the defaults track this repo own game_loop watchdog config
    00:55 +642 ~2: All tests passed!
    exit=0

    === $ cd sprout_ui && dart test
    00:07 +69: test/payload_test.dart: index.html is copied through and still names the bundle
    00:07 +70: test/payload_test.dart: the payload is the three root files, and nothing under packages/
    00:07 +71: test/payload_test.dart: (tearDownAll)
    00:07 +71: All tests passed!
    exit=0
