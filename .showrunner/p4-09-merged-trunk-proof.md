# P4-09 re-proved on the MERGED trunk

Branch-green is not trunk-green. Re-run against a binary compiled from the merged result,
in the same throwaway repository and the same database where the leak was first observed.

  $ sprout delegate --plan <2 children> --parent <a node at depth 3>

sprout: [gamma] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.
sprout: [delta] refused (depthCap) This child would sit at depth 5, past sprout's depth cap of 3. Delegation stops here; do the work in this session, or hand it back with what is still outstanding.
  refused     2  gamma (depthCap), delta (depthCap)
  worktrees   removed 2, kept 0

## Node statuses in that database afterwards

    checkpointed  8
    spawning      2   <- refused by the PRE-fix binary, earlier in this session
    unlaunched    2   <- refused by the MERGED binary, correctly released

The two new refusals no longer hold a slot. The two older rows do, because the fix moves the
row at the moment of refusal and the feed is append-only — it does not rewrite history.
That upgrade case is recorded as F-33; it is not a regression, it is the stated limit.
