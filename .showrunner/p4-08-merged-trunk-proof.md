# F-32 / P4-08 — the fix, re-proved on the MERGED trunk

Branch-green is not trunk-green. The Crawler's A/B was between its branch and trunk 515997d;
this is the same scenario re-run against a binary compiled from the MERGED result, in the same
repository the bug was originally observed in.

  $ sprout delegate --plan <2 children> --parent <a node at depth 3>   # depth cap refuses both

## Before — trunk 515997d, the bug as originally observed
[gamma] worktree removed /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3fki1-27d3bef0 and branch sprout/mtl3fki1-27d3bef0
[delta] worktree removed /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3fkma-3048d5ce and branch sprout/mtl3fkma-3048d5ce
  refused     2  gamma (depthCap), delta (depthCap)
  worktrees   removed 0, kept 0

## After — merged trunk, same plan, same repository
[gamma] worktree removed /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3ua28-d5a7d5bc and branch sprout/mtl3ua28-d5a7d5bc
[delta] worktree removed /private/tmp/sprout-delegate-ZNCH9G/.worktrees/sprout-mtl3ua6p-f761455a and branch sprout/mtl3ua6p-f761455a
  refused     2  gamma (depthCap), delta (depthCap)
  worktrees   removed 2, kept 0

Both runs exit 2 (exitRefused) and both really removed the two rooms; only the count changed.
