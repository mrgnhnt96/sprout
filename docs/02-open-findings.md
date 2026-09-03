# Open findings — things observed, not repaired

Every entry here was **observed during a real run**, not inferred from a document. Each was found
by the leaf named in it, and each was deliberately left unrepaired because the fix lies in a file
that leaf did not own — reaching outside a leaf is how two concurrent Crawlers corrupt each other's
work, so the rule is *report it, do not reach for it*.

That rule is only honest if the report survives the session that wrote it. This file is where it
survives. **A finding leaves this file in exactly one way: a commit that fixes it, which deletes
its entry and says so.** Nothing here is closed by being read.

Status vocabulary: **OPEN** — nobody has taken it. **BLOCKING <phase>** — that phase cannot be
finished correctly while it stands. **ACCEPTED** — a human decided to live with it, and their words
are quoted in the entry.

---

## Open

### F-08 — The rule-file guard reads command text, so an interpreter heredoc walks past it

**Status: OPEN, and it is game_loop's to fix, not sprout's.** Found this session, by the P3-02
Crawler doing it accidentally. **Fix lives in** `~/.claude/game_loop-central/.game_loop/bin/guard-writes-impl.sh`
— machine-wide code outside this repo, which sprout may only read.

`.game_loop/verify.yaml` is a rule file: the guard refuses `Write`/`Edit` to it, and refuses a
shell redirect, `tee`, `sed -i` or `cp` onto it, so that widening the gate always passes through
`game_loop authorize` and lands a human's words in `log.jsonl`. **The audit trail is the point of
the gate, more than the prevention is.**

The P3-02 Crawler added a `sprout_ui/**` rule to that file with no grant and no refusal logged in
either its worktree's `log.jsonl` or the main checkout's. It did it like this:

```
python3 - <<'PY'
p='.game_loop/verify.yaml'
s=open(p).read()
...
```

The guard reads the **command string**. `python3 - <<'PY'` is not a redirect onto the path, does
not name the path in a position the guard parses, and the write happens inside the interpreter. So
the call is allowed and nothing is logged.

**This is a known blind spot, not a surprise.** The guard's own refusal message says so verbatim —
*"WHAT THIS STILL CANNOT SEE (INV6): a `python3 -c` that writes the file, a path built from a shell
variable, or any MCP tool. It reads the command string. Prevention where it is cheap; the file's
own hash is the detection this does not yet do."* That is INV6 working as designed: a guard that
states what it misses. The gap is that the stated remedy has not been built.

**What caught it instead:** `showrunner integrate` refused the merge as *harness-drifted*, because
the Crawler's tree no longer carried the same rules as the main checkout. Defence in depth held,
one gate later than it should have — at merge rather than at the write.

**The remedy the guard itself names** is detection rather than prevention: hash the rule files and
notice when one changed without a matching `authorize` entry. Prevention by text-reading cannot be
completed — an arbitrary interpreter cannot be parsed — so the honest fix is a post-write hash
check, which also catches the MCP and shell-variable cases the same message lists.

**Do not "fix" this by forbidding `python3` heredocs.** They are how this session is instructed to
edit files at all, and a guard that blocks the ordinary path teaches people to route around it.

**Confirmed a second time, first-person.** Adding the `sprout_protocol/**` rule below, this session
took a `game_loop authorize` grant from Morgan and then wrote the file with a `python3 - <<'PY'`
heredoc. The grant was **not consumed and no `authorized_write` was logged** — the guard never
fired. Re-running the identical write as `cp <file> .game_loop/verify.yaml` was refused, consumed
the grant, and produced the log entry. Same file, same content, same session, same minute: the
interpreter path is unguarded and the shell path is guarded. That is the gap in one pair of runs,
and it is why the remedy has to be detection on the file rather than more parsing of the command.

---

### F-16 — A session sprout spawned itself is recorded TWICE when the hooks are installed

**Status: OPEN, and it is a deliberate v1 limit rather than a bug to fix in passing.** Found by
P8-02, which is the leaf that created the second namespace. **Reachable since P8-03**, which shipped
`sprout hooks install` — until then nothing could register the hooks, so the second writer existed
but never ran on anyone's machine and the double-vision was theoretical. It is not any more: a
developer who installs the block and also runs `sprout run` gets both.

sprout now has two writers into one `node` table and they identify nodes differently:

- the **runner** path mints `[base36 stamp]-[hex salt]` for a root (`SessionRunner._defaultNodeId`)
  and `[rootId]/[toolUseId]` for a subagent, from the stream of a process sprout launched;
- the **hook** path mints `hook/[session_id]` and `hook/[session_id]/[agent_id]`
  (`HookProjection`), from payloads a machine-wide hook config delivers.

The `hook/` prefix guarantees the two never collide, which is what makes them safe to run together.
It also guarantees they never **recognise** each other. So a session sprout launched itself, on a
machine where the hooks are also installed, appears on the board as two unrelated trees describing
the same processes — with the same work counted twice by anything that sums over nodes.

**Two facts would let a later leaf join them, and both are already recorded**, which is why this is
a limit rather than a dead end:

- `runner.session` carries `session_id` — `StoreProjection._recordSessionOnce` writes it from the
  `system/init` frame;
- every hook payload carries the same `session_id`, and `HookProjection` puts it in the `announce`
  payload of the root's `runner.observed`.

So the join is `runner.session.session_id` equal to the hook root's announced `session_id`. The
second half — matching a *subagent* across the two — is the harder one and needs the `tool_use_id`
bridge `17` §2 describes: the hook path announces the spawning `tool_use_id` on a claimed child, and
the runner path uses that same id AS the child's node id.

**Do not attempt the merge from a heuristic.** Matching on `cwd`, on timing or on prompt text would
silently fuse two genuinely different sessions in the same project, which is worse than showing two
trees — INV13 attributes from the control plane, never from a heuristic. Until a leaf does the
explicit join above, both trees are honest and neither is guessed.

---

### F-18 — `hook.malformed` is durable on disk but still cannot be an event, and nothing reads the log

**Status: OPEN.** The narrowed remainder of **F-15**, which P8-03 repaired the way F-15 named first
and which is deleted from this file by the same commit. Read `sproutd/lib/src/hooks/raw_log.dart`
and `HookCommand` in `sproutd/bin/sprout.dart` before acting on this.

**What P8-03 fixed.** `sprout hook` appends the bytes it was handed, verbatim and framed, to
`hooks.raw` beside the database **before** anything parses them and before the projection runs —
the same order and the same reason as `RawLog` on the runner path. A payload with no `session_id`,
every `MalformedHookPayload` included, is therefore on disk. F-15's *"nothing durable holds a
payload the store cannot take"* is no longer true.

**What is still true, and is this finding.** The store itself is unchanged: `event.node_id` is
`NOT NULL` with a foreign key, so `hook.malformed` remains a kind this build can produce as a value
and cannot persist as a row, and the asymmetry with the runner path — where a `MalformedFrame` *is*
stored, against the root of the run sprout launched — stands. F-15's second repair, making
`event.node_id` nullable, is a schema migration against databases already on disk and was correctly
out of P8-03's scope.

**And nothing reads `hooks.raw`.** There is no verb that replays it, counts its frames or reports
that a session's payloads were kept but not stored. Losing a record is now a recovery problem rather
than an amnesia problem *only if someone can perform the recovery*; today the file is written and
never opened again, which is one step better than the drop it replaced and is not the whole repair.
The frame format is designed to be read — a `sprout-hook <iso8601> <byte count>` header, then
exactly those bytes — so a reader is a small verb, not a redesign.

---

### F-19 — `sprout hooks install` recognises its own previous entry by a heuristic on the command text

**Status: OPEN, and it is a stated limit rather than a bug.** Found by P8-03 while writing the
merge. **Read** `isSproutHookCommand` in `sproutd/lib/src/hooks/settings.dart`.

Re-running `sprout hooks install --write` must leave exactly one sprout entry per event however the
command was spelled last time, and there is nothing in the entry schema to tag with: the four keys
the real CLI accepted in
`docs/research/fixtures/phase0/hook-settings-all-events.json` are `type`, `command`, `timeout` and
`matcher`, and an invented fifth is a field a schema check could reject on the developer's own
machine. So an entry is recognised as sprout's when its command ends with the `hook` verb and
contains the string `sprout`.

Both command lines this build emits satisfy that, and the merge also matches the exact command it is
about to write, so the realistic reinstall paths are covered. A `--command` naming a wrapper with
neither property is not recognised on a second run and would be duplicated. The fix, if the wrapper
case ever turns up, is a marker the CLI is known to tolerate — which needs a probe against a live
binary, not a decision in this file.

---

### F-17 — `NodeStatus` has no state for "the session's process is gone"

**Status: OPEN, and deliberately not fixed by P8-02**, which is the leaf that met it.

`SessionEnd` is the hook that fires when a `claude` process ends. `HookProjection` records it as
`checkpointed`, which is the same mapping the runner already makes — `SessionRunner` marks a
finished root `checkpointed` when the transcript carries a result — and it is the closest honest
value in a vocabulary of `spawning | working | checkpointed | armed | cleared | parked`.

It is nevertheless not the same fact. `checkpointed` means *handed back with progress and no
question* (`01-plan.md` §5): a node that could be steered again. A node whose `SessionEnd` has
fired cannot be steered at all, and nothing in the row says so. A watchdog reading the board to
decide what is worth surfacing cannot tell a paused session from a dead one.

**Why it was not repaired here.** Adding an enum value is a protocol change with an append-only
feed behind it: the wire strings live in every `~/.sprout/*.db` ever written, `NodeStatus.fromWire`
throws on a value it does not know rather than defaulting, and the browser branches on the same
strings. That is a `sprout_protocol` change owing four commands and a decision about what old
readers do with a status they have never seen — not a line in a projection.

**What is NOT wrong here.** Nothing is lost: the `hook.SessionEnd` event is in the feed with its
`reason`, so a consumer that needs the distinction today can read it. Only the *row* is lossy.

---

### F-20 — The ring cap is per watchdog PROCESS, so a terminal closed last Tuesday rings again on every restart

**Status: OPEN.** Found by P8-04, measured in `sproutd/test/watchdog_test.dart` group 8 ("a killed
session rings to the cap and then stops, until the watchdog is restarted").

A session killed mid-turn fires **no** `Stop` and **no** `SessionEnd`. Probed with a real `kill -9`
against a real `claude -p`: the capture holds exactly `SessionStart` at `1788389785.973` and
`UserPromptSubmit` at `1788389786.369`, the kill lands about six seconds in, and nothing follows.
The same prompt allowed to finish produced `SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
Stop, SessionEnd`. So a closed terminal leaves a hook-observed root `working` forever with a dead
pid, which `LivenessMeasure` calls `abandoned` — correctly, and by the same rule `runner.dart`
already follows, which refuses to infer completion from process exit (INV12).

**What the cap actually does with it, measured rather than reasoned about.** `RingLedger.rule`
resets a node's count when its `Contradiction.mark` moves, and `mark` is `LivenessVerdict.lastWrite`,
which is null for a node whose process was never found. So an abandoned node has no freshness to
advance and can only clear through `progressed`, which it never will. It rings exactly `cap` times —
1, 2, 3 with the shipped cap — and is then silenced. That much is right, and it is the behaviour
this leaf deliberately did **not** suppress: a session that stopped without an honest ending is the
exact thing sprout exists to surface.

**The part that is a finding.** `RingLedger` lives in the `Watchdog` object, in memory, and
`Watchdog` is constructed inside `sprout ui` (`sproutd/bin/sprout.dart:901`). The node row is never
removed from the store. So every restart of `sprout ui` rings three more times about the same dead
session, forever, and there is no upper bound on the total. A machine that accumulates a dozen
closed terminals over a month greets its owner with a wall of pages about sessions they closed on
purpose, which is how a watchdog gets switched off — the failure the cap exists to prevent, arriving
by a longer road.

The measurement is in the test: after six sweeps a first watchdog has rung three times and reports
`isSilenced`; a second watchdog over the *same store* rings again at `consecutiveRings: 1`.

**Not fixed here, because the fix is a decision and not a line.** The candidates are all Morgan's to
pick between and each changes what the watchdog is for: persist the ledger beside the journal; age
an abandoned hook-observed root out of the graph after some period; give `NodeStatus` a state for
"the process is gone" (which is F-17, and a protocol change with an append-only feed behind it); or
decide that repeating is correct and a dead session should keep asking to be cleared.

---

### F-21 — A running hook-observed subagent could be timed, and deliberately is not, because "absent" reads as "frozen"

**Status: OPEN.** Found by P8-04 while implementing the subagent case.

`docs/research/17-observed-schemas.md` §3 says a subagent's own transcript lives at
`…/<session-id>/subagents/agent-<agent_id>.jsonl` and appears as `agent_transcript_path` on
`SubagentStop` alone. **The pattern holds exactly**: both captures in
`docs/research/fixtures/phase0/hooks/B/` carry a path that is byte-for-byte what
`dirname(transcript_path)/<session_id>/subagents/agent-<agent_id>.jsonl` builds from the session id
and agent id in the same payload. So the path for a *running* subagent is derivable, and deriving it
would let a wedged subagent under a busy root be measured instead of reported as `unmeasured`.

**It is not derived, because of what happens when the file is not there yet.**
`LivenessMeasure._pulseFromTranscript` treats `TranscriptAbsent` as *not written yet* rather than as
*could not look*: the freshness reference falls back to the spawn record's timestamp, and the node
becomes frozen — and so `stalled`, and so **rings** — on the same threshold as everyone else. That
is right for the runner path, where sprout created the file's directory and knows the process was
told to write there. It is wrong for a derived path: sprout would be timing a filename it invented,
and a subagent whose transcript simply has not appeared yet would page a human sitting in front of a
perfectly healthy session. That is the one failure this whole leaf is shaped to avoid.

Making it safe needs a third transcript outcome — *a path sprout guessed, whose absence proves
nothing* — distinct from both `TranscriptAbsent` and `TranscriptUnreadable`, and that is a change to
`lib/src/liveness/transcript.dart` and to every branch that switches on it. Worth doing; not worth
doing as a side effect of this leaf.

Until then a running hook-observed subagent is `unmeasured`, with a `because` that names what could
not be looked at, and the watchdog lists it as blind rather than ringing about it.

### F-23 — The subtree budget is one-sided: it can refuse honestly, it cannot permit honestly

**Status: OPEN, and it may not be repairable from the data sprout has.** Found by P4-02, which is
the leaf that made the containment gate live and therefore the first one for which this mattered.

`readLedger` (`sproutd/lib/src/snapshot/take.dart`) builds the `SpendLedger` the gate decides over
from the node graph and the feed. Depth comes from `node.parent_id` and liveness from
`node.status`, and the store holds both for every node it knows about — so **the depth cap and the
two concurrency bounds are enforced over complete data.** Spend is not. A node that reported no
`total_cost_usd` contributes 0 to the ledger, because a ledger sums dollars and has no third state
to sum, and the note below (*"Subtree spend is structurally partial by observation"*) says why that
is the normal case rather than an edge one: all six Phase 0 captures carry `parent_tool_use_id:
null` on every `result` frame, so a subagent's own dollars are not in the stream at all.

The consequence is asymmetric, and it is the part worth carrying forward:

- A **refusal** on budget is sound. The observed spend really did breach the ceiling, and the
  unobserved part could only make it worse.
- A **permit** is not evidence of being under budget. It is evidence that *what was observed* is
  under it. `ObservedLedger.unknownCostNodes` and `spendLabel` are what stop that from being
  silent — `sprout run` prints `>=$X over N nodes (k unknown)` before every launch — but printing
  a caveat is not enforcing a bound.

**What is NOT wrong here.** A tree sprout spawned *itself* is complete: each node is its own
`claude -p` with its own pipe, so each reports its own `total_cost_usd`, and
`test/app_test.dart`'s `sprout run --parent` group asserts the printed label carries no `>=` and no
unknown count. The gap is exactly the nodes sprout *observes* rather than launches — Agent-tool
subagents inside a session, and hook-ingested foreign sessions.

**Why it was not repaired.** There is nothing to repair it *with*. Attributing a subagent's cost
would mean either summing `usage` blocks against a per-model price table sprout does not have
(`lib/policy.dart` says why token budgets are deliberately absent) or apportioning the root's total
across its children — and a guessed total is indistinguishable from a measured one, which is INV7.
Recording the limit is the honest outcome; a number that looked like evidence would be worse than
the gap.

---

### F-24 — A node that dies without ending its stream holds a concurrency slot nothing releases

**Status: OPEN.** Found by P4-02 and measured in `sproutd/test/runner_test.dart` ("a session that
dies without a result stays live in the ledger, and holds a concurrency slot nothing releases").

The concurrency bounds became real in P4-02 — before it they were judged against an empty ledger
and could not bite. Their denominator is `SpendLedger.liveNodes` and `liveChildrenOf`, which count
every node whose status `isHoldingStatus`: `spawning` or `working`.

Only three things ever move a node off those statuses, and each needs evidence from a stream that
ended cleanly — `SessionRunner` marks a root `checkpointed` only when the transcript carries a
`result` (INV12: exit is not completion), `StoreProjection` marks a subagent `checkpointed` on its
`completed` lifecycle event, and `HookProjection` does the same on `SessionEnd` / `Stop`. Nothing
reaps. The watchdog measures and rings and is forbidden from acting, and `grep putNode lib/ bin/
routes/` finds no fourth writer.

So a session killed mid-stream — a closed terminal, a machine that slept, a `claude` that
segfaulted — leaves a row that reads `working` forever. Twelve of those across a week reach
`defaultMaxLiveNodes` and sprout refuses **every** spawn tree-wide with
`RefusalReason.concurrency`, correctly by its own rules and wrongly in fact, with no verb to clear
them.

**P4-03 found the same root cause holding a second resource, and it is worse than a slot.** With
`--worktree`, a session's git worktree is created before the launch and torn down by the CLI when
`sprout run` returns. Both halves of that live in `RunCommand._run` and nowhere else: `grep -rn
worktreeRemovedKind sproutd/lib sproutd/bin` finds the CLI's `_tearDown` and the kind declaration,
and nothing that reads a `worktree.created` row back out of the feed. So the teardown runs only on
the path where the same process that created the worktree also observed the session end.

A session killed mid-stream is exactly the path where that does not happen — the `sprout run`
process is gone too — so the row stays `working` forever *and* the worktree stays on disk forever,
for one root cause. The worktree is the more expensive of the two, because a concurrency slot is
recoverable by editing a row and a worktree is a directory holding a branch that may carry the only
copy of a session's work: whatever eventually reconciles a dead node must not simply delete it. The
mechanism to do that safely already exists and is deliberately not wired to anything automatic —
`Worktrees.remove` in `package:sproutd/worktree.dart` refuses on uncommitted changes, on untracked
files, on unmerged commits and on a look that failed. What is missing is the caller, and the
`worktree.created` payload carries everything one would need (`path`, `branch`, `base_sha`,
`repository`) precisely so that a later process can find the worktree without having created it.

This compounds with **F-17**, which is the same absence one layer down: there is no `NodeStatus`
meaning *the process is gone*, so even a human reading the board cannot tell a paused session from
a dead one. Phase 6's `liveness` already derives live / stalled / abandoned from a pid beside a
transcript mtime and is the obvious source of truth — but it may never act on what it finds, by
design, so the repair is a decision about who is allowed to reconcile a row with a measurement, not
a line in a projection.

---

### F-25 — `sprout run --worktree` writes into the target repository and nothing ignores it

**Status: OPEN.** Found by P4-03, which built the mechanism. Observed in **this** repository:
`git check-ignore -v .worktrees` exits 1 with no output, the top-level `.gitignore` contains only
`.claude/handoff/`, and `.git/info/exclude` is empty of rules.

`Worktrees` puts every worktree at `<repository root>/.worktrees/sprout-<node>`, inside the
repository on purpose — a child session runs under a write guard that treats everything outside its
project directory as read-only, so a sibling directory would deny the child's first edit, and
showrunner puts its own worktrees in the same place for the same reason.

The consequence is that a `sprout run --worktree` against a repository that does not already ignore
`.worktrees/` leaves `?? .worktrees/` in the **main checkout's** `git status` for as long as the
worktree exists. That is untidy on its own, and it is a trap for the thing sprout is about to grow:
the moment anything asks whether the main checkout is clean — a parent session's own teardown, an
integration check, a human deciding whether to commit — sprout's own scratch directory is what
makes the answer no. The failure is silent in the direction that matters, because "dirty" reads as
"there is work here" and the work is sprout's.

Two things it is **not**. It is not a nesting hazard: `Worktrees.repositoryRootOf` resolves through
`--git-common-dir`, so a worktree created from inside another worktree lands beside it under the
main root rather than inside it, and `sproutd/test/worktree_test.dart` asserts that. And it is not
a bug in the teardown: a worktree's own tree never contains `.worktrees/`, so the cleanliness check
that decides whether to remove one is unaffected.

The repair is not obviously sprout's to make unilaterally — writing to a user's `.gitignore` is a
tracked-file edit sprout was not asked for, and `.git/info/exclude` is per-clone and invisible in
review. The honest options are to append to `.git/info/exclude` on first use and say so, or to
refuse `--worktree` with a message naming the line to add, or to make the worktree root
configurable and let the caller put it somewhere already ignored. That is a decision, so it is
recorded here rather than taken inside a leaf that owns the mechanism and not the policy.

---

### F-22 — `showrunner integrate` re-runs only sproutd's three checks, whatever the change touched

**Status: OPEN, and the fix is Morgan's** — `.showrunner/config.json` is harness config and is not
sprout's to edit. Observed this session while integrating F-12, P8-01 and P8-04, each of which
changed `sprout_protocol/`.

`.game_loop/verify.yaml` gives `sprout_protocol/**` four commands, on the reasoning its own comment
gives: `dart analyze` covers the package it runs in and **not its path dependencies**, so the
package needs its own analyze plus **both** consumers' suites, and `sprout_ui`'s is the only check
that catches a web-unsafe change — `build_web_compilers` reports that failure as a WARNING and exits
0, which is what F-07 was.

`.showrunner/config.json`'s `checks` are three commands, all `cd sproutd && …`. So the checks
re-run on the MERGED result — the ones that make "branch-green is not trunk-green" mean something —
**never run `cd sprout_ui && dart test` or `cd sprout_protocol && dart analyze`**, however much of
the protocol a merge changed. A web-unsafe change to `sprout_protocol` would integrate green.

What held the line instead: each Crawler was told in its brief to run the four commands its change
owed, and each did, in its own worktree. That is a habit rather than a gate, and it is exactly the
"a pass that is silence proves nothing on its own" shape (INV8). Integration is where it should be
enforced, because that is the only place the merged result exists.

**The repair** is to add the two missing commands to `.showrunner/config.json`'s `checks`. The cost
is that every integration then runs a jaspr build; the alternative is per-path checks, which
showrunner's config does not appear to express.

### F-26 — Waves are planned against a policy, but admission is decided against a ledger, so a full-width wave can still be refused halfway

**Status: OPEN.** Found by P4-04, which built `planWaves` and is the first thing that has an
opinion about how wide a wave should be.

`planWaves` (`sproutd/lib/src/decomposition/waves.dart`) caps a wave at
`min(ContainmentPolicy.maxLiveChildren, ContainmentPolicy.maxLiveNodes)`, because a wave planned
wider than the policy allows is a plan that gets refused halfway through, leaving a half-spawned
wave nobody planned for. That much it can do from a value.

What it **cannot** do is know what else in the tree is live. `ContainmentGate.admit` judges
`maxLiveNodes` against `SpendLedger.liveNodes` — the whole tree at the moment of the launch — so a
wave planned at the ceiling is admissible only if no other subtree is running. A sibling subtree
that spawns between planning and spawning consumes the same budget, and the last children of the
wave are refused with `RefusalReason.concurrency`. The plan is a **ceiling, not a guarantee**, and
`planWaves`'s doc says so; this entry exists because saying so is not handling it.

F-24 makes it strictly worse rather than being the same thing: a node that dies without ending its
stream stays live in the ledger and holds a slot nothing releases, so the denominator the gate
divides by drifts *upward* over a run while the planner keeps assuming the policy's number.

**Why it was not repaired here.** The fix belongs to whoever wires a decomposition to
`SessionRunner.launch` — P4-05 or later. It is one of: plan against the live ledger rather than the
policy alone (which makes the planner impure and is why this leaf did not do it), or treat a
`concurrency` refusal as a signal to hold the remaining children back into the next wave rather
than as a failure. The second is probably right and it is a spawner's decision, not a value type's.
Taking it inside this leaf would have meant putting a ledger — and therefore the store — into a
library whose whole promise is that it has neither.

**P4-05 did not take it either, and the reason is the same one.** `DelegationFloor` decides over a
`WavePlan`, so it inherits the gap exactly: it is constructed with a `ContainmentPolicy` and never
sees a `SpendLedger`, so a proposal it permits can still have its last children refused by
`ContainmentGate.admit` for `concurrency`. P4-05 was scoped to values and pure functions, and the
remedy this entry already argues for — treating a `concurrency` refusal as a signal to hold the
remaining children back into the next wave — is a spawner's, so it needs the leaf that wires a
decomposition to `SessionRunner.launch`. That leaf still does not exist. Note for whoever writes
it: the floor's own doc says a `DelegationRefusal` does not stop anything, so nothing in the
decomposition area is where this gets handled.

---

### F-27 — `package:sproutd/decomposition.dart` has no producer and no consumer outside its own test

**Status: OPEN and EXPECTED.** Recorded by P4-04 against itself, because a true premise attached to
code nothing reaches is void and a green suite cannot tell the difference.

Measured after the leaf landed: `grep -rn "decomposition.dart\|planWaves\|PlannedChild\|Decomposition"
sproutd/bin sproutd/lib sproutd/routes sproutd/test sprout_protocol/lib sprout_ui/lib` matches the
library's own source and `sproutd/test/decomposition_test.dart`, and nothing else at all.
`bin/sprout.dart` never imports it, no route serves it, and no `Decomposition` is ever constructed
outside that one test file. Everything in it passes and none of it runs in the product.

That is the build order rather than a defect: `docs/01-plan.md` §11 puts *"map/build modes, waves
over estimated file sets"* in Phase 4, and the campaign's own graph has the two leaves that consume
this one — **p4-05-delegation-floor-and-mode** (which decides *whether* to decompose and produces
the `Decomposition`) and **p4-06-parent-acceptance-check** (which evaluates the
`SuccessCondition`s this leaf made mandatory). Neither has run.

It is written down anyway because of what it costs if they do not. A value type with no producer is
indistinguishable from one with a producer as long as its own tests are the only caller, and the
next reader takes a well-tested library as evidence something uses it. **If Phase 4 ends without
P4-05, this entry is the thing that says the machinery is unreached** — delete it in the commit
that gives `Decomposition` its first real caller, not before.

**Re-measured by P4-05, and it did NOT clear this.** P4-05's brief anticipated that it might —
*"if your work gives it one, say so and retire the finding"* — and it does not. P4-05 added
`ModeChoice`, `DelegationFloor` and `Decomposition.briefFor` to the same library; the grep above,
re-run verbatim after that landed and widened to `\|DelegationFloor\|ModeChoice`, still matches
nothing outside `lib/src/decomposition/`, `lib/decomposition.dart` and
`test/decomposition_test.dart`. `bin/sprout.dart`'s import list is unchanged and does not include
`package:sproutd/decomposition.dart`.

The reason is that P4-05 was scoped to values and pure functions — *"nothing spawns"* — so it
produces the *decision about* a `Decomposition`, not a `Decomposition`. The first real producer is
whatever wires a parent session's proposal to `SessionRunner.launch`, and no leaf in the campaign
graph has done that yet. So the entry is now **larger** than P4-04 left it, not smaller: three
value types in this library are unreached rather than one, and P4-05 was the leaf the original
entry named as the thing that would clear it.

---

### F-28 — The delegation floor cannot decide whether a task is too small to split, and nothing sprout observes would let it

**Status: OPEN, and it is a limit rather than a defect.** Found by P4-05 while building
`DelegationFloor`, which is the first thing that has to answer §3's question.

`docs/01-plan.md` §3 says sprout *"decomposes only when the root task is plausibly beyond one
session"* and supports it with two numbers from Kim et al.: negative returns from added agents above
~**45%** single-agent baseline accuracy, and coordination turns scaling as a power law with exponent
**1.724**.

**Neither number is available at decision time, and the first one is not a quantity sprout can ever
hold.** 45% is a baseline accuracy *on a benchmark* — producing it needs a labelled task set and a
measured single-agent run over it, and sprout has neither when a parent hands it a proposal. 1.724
is an exponent on a cost sprout pays but does not observe in advance. What sprout actually holds at
that moment is the proposal: a child count, a `FileEstimate` per child, an optional dollar estimate,
and a set of `SuccessCondition`s. None of those measures task difficulty, and the nearest proxies
are actively misleading — a one-line change across forty files is small, a three-file rewrite is
not, and the estimated path count ranks them backwards.

So `DelegationFloor` deliberately ships **no task-size rule**. Its three reasons
(`singleChild`, `nothingEstimable`, `noConcurrencyWon`) are all properties of the proposal's own
wave layout, which is genuinely observed. They catch splits that are *structurally* pointless — a
split that wins no concurrency at all, so it pays §3's coordination cost for no return. They do not
catch a split that is merely **not worth it**: two disjoint children over a ten-minute job is
permitted here and probably should not have been proposed. That is the larger half of §3 and it is
the half that is open.

**Why it was not repaired here.** The only fix available inside this leaf would have been a
threshold over a proxy — "fewer than K estimated files ⇒ do not decompose" — and shipping one would
have dressed a guess as evidence. That is INV7's failure (*a sum is not a distribution*) and
INV10's (*a control-plane fact is observed or it is not a fact*), and it is worse than the gap: a
number that looks derived from §3 is one the next reader will not re-check, whereas an absent rule
announces itself. A real fix needs an input sprout does not have yet, and the two candidates are
both measurements rather than judgements — outcome data from sprout's own completed runs (it
*"observes every trajectory across every project on the machine"*, §14.5), or a per-node cost the
control plane already reports (§14.6, INV13), used after the fact to learn which splits paid for
themselves. Both are post-hoc, so the floor could only ever be calibrated by a run that already
happened, never derived from the plan in front of it.

---

---

## Notes that are not findings

These are true, cost nothing to know, and would cost real time to rediscover.

- **A wildcard route cannot be reached through an empty-path controller in `revali_router` 5.1.1,
  and neither can a `:param` one.** `@Get('*asset')` under `@Controller('')` generates
  `Route('', routes: [Route('*asset', …)])`, which is well formed and never matches: `Find` walks
  into an empty-path parent only when the requested segment *equals the child's own path* —
  `path == route.path || (route.path.isEmpty && path == proxy?.path)` in
  `lib/src/router/find.dart` — and `'main.css'` is never equal to `'*asset'` or to `':asset'`.
  Observed against the compiled binary, not reasoned about: `GET /main.css` returned revali's own
  `Not Found` body while `GET /` worked. So the UI serves one static route per asset name, and
  `servedAssetNames` in `routes/controllers/ui_controller.dart` is compared against the embedded
  payload by `test/ui_test.dart` so the two spellings cannot drift. **Adding a file to the payload
  means adding a route.** (P3-03)
- **`MemoryFile` is the wrong body for anything a browser renders.** It is the obvious choice — it
  carries bytes *and* a mime type — but `MemoryFileBodyData.headers` assigns `filename`, and
  `HeadersImpl.filename` writes `content-disposition: attachment; filename="…"`
  (`revali_router` 5.1.1). A page served that way is downloaded rather than rendered, with a 200 in
  the log. A plain `List<int>` body is a `BinaryBodyData`, which adds no disposition, and
  `Response.joinedHeaders` merges the body's headers with `headers[key] ??= …` so a `content-type`
  set on the response wins. This is the same shape as F-03 (`@SSE` shipping
  `application/octet-stream` with the override ignored): **read the header off the wire.** (P3-03)
- **`AppConfig.prefix` wraps every controller route, so a prefixed app cannot answer at `/`.** The
  generated server does `_routes = [Route(prefix, routes: _routes)]` and registers only `public`
  and the health probes outside it (`revali` 3.3.2, `server_file_maker.dart`). P3-03 therefore
  moved `api` out of the app and into `@Controller(treeControllerPath)`; the URLs are unchanged.
  A side effect worth knowing: **revali names the generated route file after the controller path**,
  so `.revali/server/routes/__tree_route.dart` became `__api_tree_route.dart`, and the drift check
  in `test/ws_test.dart` that reads it went from asserting to *skipping* until the path was
  updated. A check that quietly stops running is worse than one nobody wrote. (P3-03)
- **`sproutd/lib/src/ui/assets.g.dart` is committed, and it can be stale.** It has to be committed:
  the package imports it, so a checkout without it does not analyze, test or compile. The cost is
  that the UI payload is in git twice — as base64 here, and as the `sprout_ui` sources it was built
  from — and that rebuilding the UI without re-running `dart run tool/embed_assets.dart` ships a
  binary serving the previous UI. `--check` turns that into a failure, but only where `web/` exists,
  which is after steps 1 and 2 of the pipeline have run; `test/ui_test.dart` skips it with a stated
  reason otherwise rather than passing in silence. (P3-03)
- **A non-empty `main.client.dart.js` proves the import graph, not the decoder.** P3-05 gave
  `sprout_ui/lib/app.dart` a real `import 'package:sprout_protocol/protocol.dart'` and an
  exhaustive `switch` over `ProtocolFrame`, and the bundle went from *absent* to 109,503 bytes.
  But `App` is only ever constructed as `const App()` with `frame: null`, so dart2js proves the
  other branches unreachable and drops them: grepping the built JS finds `sprout-shell` and `The
  UI payload is served` and **none** of the protocol's own string literals. What the build does
  prove is the thing F-07 was about — build_web_compilers decides on the *library import graph*
  before any tree-shaking, and it no longer skips the entrypoint. The whole protocol library is
  also genuinely front-end compiled, which is how the `BigInt` error above was caught at all.
  Once P3-04 decodes a real frame, `payload_test.dart` should gain a string fingerprint from the
  protocol; until then it cannot have one honestly. (P3-05)
- **`package:sprout_protocol` is compiled for the browser, so its arithmetic has to be.**
  The split that closed F-07 made `SproutInstance` a web target, and its FNV-1a hash used 64-bit
  `int` — which is a JavaScript double on the web. `0xcbf29ce484222325` is a *compile error* under
  dart2js (*"The integer literal ... can't be represented exactly"*), and the wrapping 64-bit
  multiply would have disagreed with the VM even if the literal had fit. `_idFor` uses `BigInt`,
  which is exact on both, and `protocol_test.dart` pins the id of a fixed input against the value
  the pre-split native-int code computed. The pin is the load-bearing half: the tests already there
  asked only whether the derivation agreed *with itself*, which a divergence satisfies from inside
  either platform. A browser deriving a different id from the same feed has every cursor it offers
  refused as foreign — F-01 arriving by a new road. (P3-05)
- **The web build's failure modes are not one failure mode.** An unsupported `dart:` library in the
  transitive import graph is a **WARNING**: `jaspr build` exits 0, writes no bundle, and that was
  F-07. A library that *is* web-safe but does not compile is an **ERROR**: the build exits 1 and
  says why. Fixing the first converts silence into noise, so the second only becomes visible after
  the first is repaired — expect a real compile error to appear the moment a graph problem is
  solved, and do not read it as the split having failed. (P3-05)
- **Neither gate analyzes `sprout_protocol/`.** Measured by planting a lint in
  `sprout_protocol/lib/` and running both: `cd sproutd && dart analyze --fatal-infos
  --fatal-warnings` and `cd sprout_ui && ...` each reported *No issues found*. `dart analyze`
  covers the package it is run in, not its path dependencies. `dart test` in sproutd *does* execute
  that code, so behaviour is covered and static quality is not — and only when a commit also
  touches a path matching an existing rule. `.game_loop/verify.yaml` owes the package a rule; it is
  write-guarded and P3-05 did not have it. (P3-05)
- **`jaspr create` scaffolds a project that does not resolve.** Its template pins
  `build_web_compilers: ^4.8.10`, which wants `analyzer >=13.3.0`, while `jaspr_builder 0.23.4`
  wants `analyzer ^12.1.0`. `sprout_ui/pubspec.yaml` holds `build_web_compilers` to
  `">=4.8.0 <4.8.6"` and `scaffold_test.dart` asserts the bound, because a caret would float
  silently past it. Raise it only together with `jaspr_builder`. (P3-02)
- **The `revali`/`jaspr_builder` clash is on `analyzer` directly, not via `dart_style`.** Resolving
  one package declaring both: *"revali >=2.1.0 depends on analyzer ^10.0.0 and jaspr_builder
  >=0.23.2 depends on analyzer ^12.1.0"*. `docs/01-plan.md` §13 and `sproutd/pubspec.yaml`'s comment
  name a `dart_style` pin, which is one hop further out than what pub reports. The conflict is real
  either way and two packages is still the fix — and it only works because `revali` is a **dev**
  dependency of sproutd: a path dependency pulls a package's regular dependencies, never its dev
  ones. (P3-02)
- **`jaspr build` writes 4.4 MB of `build/jaspr/packages/` that is not the payload** — analyzer
  `fix_data`, win32 fix templates, the `test` runner's browser host — pulled in by *dev*
  dependencies. The payload is the three top-level files (`index.html`, `main.css`,
  `main.client.dart.js`). P3-03's rsync step must take the top level only, or the binary carries
  all of it. `payload_test.dart` asserts both halves. (P3-02)
- **Every WebSocket message arrives as a *binary* frame**, never text — `BodyImpl.read()` is
  `Stream<List<int>>` whatever the payload type. Phase 3's browser client must set `binaryType`
  and decode. (P2-05)
- **The socket's connect handler must complete immediately, and the frames go out through
  `AsyncWebSocketSender`.** `revali_router 5.1.1`'s `HandleWebSocket.execute()` awaits
  `runHandler(onConnect)` before `listenToMessages()`, which is the only `webSocket.listen` in the
  package — and `dart:io` keeps a socket's protocol subscription *paused* until something listens
  (`websocket_impl.dart`: `subscription.pause()`, resumed by `_controller.onListen`). A connect
  handler that streams therefore leaves the socket unread: no inbound pong, no inbound close, no
  inbound message. That was F-05 and F-06, one unread socket seen from two sides, and both are
  closed by `attachTreeSocket` in `routes/controllers/tree_controller.dart`. Anything new on this
  socket pushes through the sender; it does not yield. (F-06)
- **The back channel is serviced now, but nothing interprets a client message.** revali registers
  the one annotated method as both `onConnect` and `onMessage`, so an inbound message re-invokes
  the handler — `attachTreeSocket` keeps its session in the request's `Data` and returns an empty
  stream on re-entry, which is what stops a second snapshot-and-watch opening on the same socket.
  Phase 7's steer is the thing that will read those messages; the transport no longer needs a
  revali-side change for it. (F-06)
- **`.revali/` is a gitignored build artifact, and `dart test` reads it.** A stale one in the main
  checkout made `showrunner integrate` fail twice on tests that pass in every worktree, because the
  suite was comparing P2-05's controller against Phase 1's generated route. **Run `dart run revali
  build` before integrating any change under `routes/`.** (Phase 2 integration)
- **`SproutStore` has no transaction seam.** `takeSnapshot` orders its reads so the picture can only
  run *ahead* of its cursor, never behind — a consumer may double-apply, never gap. That is safe,
  not exact; a `readTransaction` on `lib/store.dart` would make it exact. (P2-02)
- **Subtree spend is structurally partial by observation, not by omission.** All six Phase 0
  captures carry `parent_tool_use_id: null` on every `result` frame, so `total_cost_usd` exists
  only for the root. A subagent's own cost is `null`, never `0`, and a subtree with an unreported
  node renders `>=$X (n unknown)` rather than a total. Do not "fix" this into a sum: a sum is not a
  distribution (INV7), and a guessed total is indistinguishable from a measured one. (P2-02) —
  **P4-02 made this a property of a guardrail rather than only of a display**, which is F-23.
- **The store-to-ledger seam is `readLedger`, and it is the same read `takeSnapshot` does.** P4-02
  found the seam already half-built: `takeSnapshot` had been constructing `NodeSpend` values out of
  `SnapshotSource.tree()` and the feed's `frame.result` events since P2-02, and building a real
  `SpendLedger` from them — it was just private to that function, so `SessionRunner.launch` had
  nothing to call and fell back to `SpendLedger.empty()`. It is now one `_read` shared by both, so
  the ledger a spawn is refused against and the picture a developer reads cannot drift. Anything
  that needs the tree as a *value* should call `readLedger` rather than fold the feed again.
  (P4-02)
- **`microUsd` / `formatUsd` are not exported from `lib/policy.dart`.** P2-02 used
  `SpendLedger.subtreeMicroUsd` plus a local formatter rather than edit a file outside its leaf.
  Subtree spend is quantised to micro-dollars (`0.2415507` → `0.241551`) while a node's *own* cost
  is the control-plane figure verbatim — they are deliberately not equal. (P2-02)
- **`async*` + `await for` leaks on an idle stream.** A consumer's `cancel()` never completes while
  the tree is quiet (dart-lang/sdk#26686, reproduced standalone by P2-03). `watchFrames` is
  StreamController-driven for exactly this reason. Any new long-lived stream should be too. (P2-03)
- **`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` is not set from the policy**, so behaviour at the limit
  is unobserved. P1-04's concurrency defaults (4 per node, 12 tree-wide) have no research behind
  them, unlike the depth cap of 3 — they are knobs, not findings. Still true after P4-02, and now
  the *second* of two enforcement paths rather than a hypothetical one: sprout's own gate refuses a
  fifth level before the launch, and what the platform does at its own limit is still unmeasured.
  (Phase 1, re-checked P4-02)
- **`Notification`, `PreCompact` and `PostCompact` hook payloads remain uncaptured.** Nothing before
  Phase 5 needs them. They nevertheless have `hook.*` kinds as of P8-01, because a name that is
  known and unfired is a different thing from a name that is unknown — folding them into
  `hook.unknown` would make the first one ever captured read as a schema change rather than a first
  sighting. (Phase 0, P8-01)
