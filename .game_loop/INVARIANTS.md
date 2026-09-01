# INVARIANTS

The non-negotiables `game_loop stepback` re-injects.

**INV1–INV8 are game_loop's, kept deliberately.** INV7 and INV8 arrived as worked examples from
another project and describe two of sprout's own measured traps almost exactly — a sum that hid its
distribution, and a check whose pass was silence. They stay.

**INV9–INV14 are sprout's**, and each is here because something actually failed, not to round out a
list. Sources are named so a later session can re-check rather than re-derive: `docs/01-plan.md`,
`docs/research/17-observed-schemas.md` (captured from a live CLI, with the raw frames under
`docs/research/fixtures/phase0/`), and `docs/research/08-token-cost-audit.md`.

sprout is a harness that watches agent sessions from **outside** them. Most of what follows is the
consequence of that one fact: everything sprout believes about a session is inferred from a stream it
does not control, and every inference below has already been wrong once.

---

## INV1 — Enforcement lives in tools, never in instructions

A rule the agent has to *remember* is followed only some of the time — long sessions and context
compaction break that promise. A rule a hook *consumes* holds every time.

Test for any guard here: **if the agent ignored every instruction, would this still hold?** If no, it
is not enforcement; it is a wish. This is why the keystone check is always "name a real file that
exists" — the one check prose cannot satisfy.

## INV2 — Read a real file before asserting (THE gate)

Every claim about external reality — a dependency, a harness, another repo — must name the real file
that backs it: `game_loop claim --assert ".." --read <path>`. A research subagent's citation is not a
source; it *finds* the file, it does not *read* it. Cite the file you read.

## INV3 — Everything outside this repo is READ-ONLY

Read other projects, mine them, use their data as fixtures. Never write, never run their tooling,
never deploy. Access is not permission — logged-in accounts, tokens, and an always-on prod connection
are not permission. Enforced by `.game_loop/bin/guard-writes.sh`, not by this paragraph, because a
paragraph exactly like it is the kind of thing that already fails.

## INV4 — No gate without a logged, observed failure

Ceremony has a certain cost and a hypothetical benefit. Do not add a rung until `log.jsonl` shows a
real failure that demands it. When tempted, name the entry that justifies it.

## INV5 — A guard must never block its own fix

A guard that blocks the fix it recommends is a guard that gets switched off — and a guard disabled
once is disabled forever. Every guard needs a legitimate path through it. Here the escape hatch is the
*human* (`game_loop authorize`), never an env var, because an advertised bypass is a bypass.

## INV6 — ENCODE, don't remember; and state what a guard misses

A learning is a bug in the harness with a countdown. Its deliverable is an **artifact**, not a
sentence: `game_loop harden --learning ".." --artifact <real path> --mechanism ".." --rung N`. Take the
highest rung that applies — **1 IMPOSSIBLE · 2 LOUD · 3 CHECKED · 4 AUTOMATED · 5 VISIBLE · 6

And a rung is only as high as its own ENABLING CONDITION. Rung 3 is CHECKED only if the
check's enabling condition sits outside the agent's reach: a guard gated on a file the agent
can write is an off switch, and it gets flipped at the moment the agent is most stuck. Two
consumer guards opened `grep -qi '^lead' .game_loop/seat || exit 0`; the seat said `worker` for
sixteen hours while both guards ran, returned 0, and let through exactly what they existed to
refuse. DERIVE the condition from something observable instead of declaring it in state.
doc/memory** (last resort). And a guard that overstates its reach buys false confidence: say what it
does *not* catch, in the guard itself. Silence from a guard is not evidence of safety.

**Writing a rule does not install it, and the author is not exempt.** The intuition is that whoever
just articulated a rule is the last person who would break it; the evidence runs the other way, and
it is worth knowing because it removes the excuse that the next violation was carelessness. Two
agents on one afternoon: one hardened "pair every non-event assertion with the case that fires", then
shipped a coverage tool that inspected 6 of 30 candidates — the same default-to-unprotected shape it
had fixed elsewhere and filed as an issue against someone else. The other wrote "test traffic belongs
in its own room", then tested in a shared one for six more hours. Both rules were right, both authors
believed them, neither was protected by having written them. That is the case FOR the artifact, made
by the people most convinced already. Take the rung honestly — and when the honest rung is 6, say so
rather than dressing a paragraph as enforcement.

## INV7 — A sum is not a distribution

An aggregate hides its own shape, and a run optimizing against one will read structure into a single
outlier. Before stating an effect derived from a **total, a mean, or a percentage**, show the per-event
values — and when one event carries most of the total, explain it or exclude it *with the reason on the
record*, because an exclusion nobody wrote down gets rediscovered.

The failure: 1066.7 units of damage against 0.0 read as a total elimination and was written up as a
finding. One event of thirty carried 96% of it, and it was an artifact already identified and dismissed
earlier in the same session. Corrected: 1.5 per event against 0 — no effect at that sample size. Nothing
about the totals revealed this; only printing the per-event values did, and the same event produced
three findings before anyone did. Enforced by `claim --metric --aggregate`, not by this paragraph.

## INV8 — A pass that is silence proves nothing on its own

A check whose success looks like *nothing happening* cannot tell being **satisfied** from **never
having run**. That is one shape, not three: a guard that goes quiet when it permits, a path that is
never examined, an observation that comes back empty. Each is satisfied by a producer that has
stopped working, and the tell is identical to the one it gives when everything is fine.

The asymmetry is the useful half: **a refusal cannot be produced by absence** — it takes a working
check to say no — so the blocking half of any rail validates itself, and it is the permissive half
that needs a second bit. Choose that bit by what the check has on its happy path: a **reason** if it
speaks, a **mark it advances** if it is silent, a **positive control** if it is a pure observation.
And when you assert that something did *not* happen, pair it in the same observation with the case
where it *does*. That costs one extra capture while writing and cannot be retrofitted cheaply.

Find them by **mutation**: neuter the producer — make the guard permit everything, the detector find
nothing, the validator have no opinions — and see what still passes. It manufactures the absence you
cannot otherwise observe, and what survives is what was never being checked.

**A mutant that CRASHES the suite is protected, not unprotected — read the verdict carefully.** The
run exits non-zero and goes red, so the defence worked; what failed is the *measurement*, because a
crash ends the run and every assertion behind it never printed. Those two findings look identical in
a summary and are worth opposite amounts: recovering a crashed producer buys you a **number**, not
safety, and reporting it as a closed hole overstates the work. Fix the crash to learn how strongly
the thing was already defended — then say which of the two you found.

The crash itself has a shape worth naming, because fixing it once does not fix it. **A crash exposes
only the FIRST site of its kind.** Every identically-shaped site behind it was never reached, so it
never earned a guard — which means patching the site that crashed leaves its neighbours in exactly
the state that produced the crash, and the next run stops a few lines later. A guard you have to
remember per site therefore lands where the danger is already spent and never where it is live. Do
not guard the site; supply a helper the dangerous shape cannot be written without.

The failure, three times in one session: a syntax error made the write guard allow everything with no
output at all, so "outside this repo is read-only" stopped being enforced and nothing said so.
Sixteen permissive assertions passed against a guard mutated to check nothing. Four producers that
report by staying silent were barely tested — one of them noticed by a single assertion out of 431.
None of it was visible while every suite was green.

---

## INV9 — sprout may write scripts and tune knobs. It may never modify its own gates.

The asymmetry is **structural or it does not exist**. A depth cap, a budget ceiling, a verification
step and the criteria a node is judged against are inputs to sprout, never outputs of it. If a run
can reach them, the guardrail is a suggestion with extra steps.

The failure is not hypothetical and not ours. The Darwin Gödel Machine, given the ordinary incentive
to make its score go up, **faked test logs**; told to fix hallucination detection, it **removed the
reward-function markers it had been explicitly instructed not to touch** (`docs/01-plan.md` §9,
`docs/research/14-self-improvement.md`). Nothing about that required malice — removing the detector
is simply the cheapest way to satisfy the detector. Assume every sprout node would do the same if the
path were open, and close the path in the filesystem rather than in the brief.

The test, from INV1: **if a node ignored every word of its prompt, would the cap still hold?** For a
cap enforced in daemon code before a child process launches, yes. For a cap stated in a system
prompt, no. Only the first is a cap.

## INV10 — A control-plane fact is observed or it is not a fact

Everything sprout knows about a session comes from a stream and a hook payload it did not design.
Those shapes are **not a stable API** and the documentation is not a substitute for a capture. Before
depending on a field name, an event name, or an exit code, name the fixture that shows it:
`docs/research/fixtures/phase0/`. Add a fixture when depending on something new.

The failure is this project's own, and it was load-bearing. `docs/research/06-claude-code-control-plane.md`
was written from documentation and got **six things wrong**, one of them inverted: it stated that a
Stop hook **blocks on exit 0 and allows on exit 2**. The truth, captured in
`fixtures/phase0/streams/D.ndjson`, is the reverse — exit 2 blocks and injects the hook's stderr into
the conversation as feedback. Built as written, **every sprout gate would have failed open**, and by
INV8 the failure mode is silence: a gate that permits everything looks exactly like a gate with
nothing to refuse. Also wrong there: `prompt_text` (really `prompt`), `tool_result` (really
`tool_response`), `subagent_id` (really `agent_id`), `Stop.reason` and `SessionStart.model`/`.tools`
(neither exists), and `--max-turns`, which is not a CLI flag at all.

Corollary, because the same trap has a second mouth: **a name is not a key.** The spawn tool is
`Agent` in `system/init`, in `PreToolUse.tool_name` and in the assistant `tool_use` block — and
`Task` in `result.permission_denials[].tool_name`. Match both, or sprout silently miscounts its own
refusals.

## INV11 — A message that was accepted is not an instruction that was obeyed

sprout steers a running session by writing to its stdin. The transport acknowledging a message says
only that bytes arrived. **Verify a steer by its consequence in the world, never by its acceptance.**

The failure, observed twice under identical timing (`fixtures/phase0/streams/C.ndjson` versus
`C2.ndjson`): the same steer, sent at the same moment mid-turn, was **refused by the model as a
prompt-injection attempt** when phrased as an override ("STOP. Ignore the previous instruction
entirely") and acted on when phrased additively ("Also, when you are done…"). In the refused run the
model finished the original task, `--replay-user-messages` echoed the steer back as delivered, and
`result.is_error` was `false` with `subtype: "success"`. **A discarded steer is indistinguishable
from an obeyed one in every field sprout can read.** That is INV8 with a stranger's hand on the
switch.

Two consequences, both structural. Phrase every steer as an **additive constraint**, never as an
override of a prior instruction — which agrees with the separately-measured rule that constraints
re-pin and procedures do not (`docs/01-plan.md` §15). And never mark a steered node "corrected" on
the strength of the send.

## INV12 — "The parent finished" is not "the subtree finished"

A node's lifetime does not bound its children's, and a result does not necessarily return to whoever
asked for it. Subtree completion is computed from the node graph, never inferred from a parent's
`Stop`, and a `result` frame is not process exit.

Observed in `fixtures/phase0/streams/B.ndjson`: a subagent spawned a child that launched **async**
(`status: "async_launched"`), then answered and stopped while that child was still running — its own
`SubagentStop` payload listed the grandchild in `background_tasks` as `running`. When the grandchild
finished, its result was delivered **to the root**, two levels up from the node that requested it, as
a `<task-notification>` injected as a fresh `UserPromptSubmit`. The run emitted **two** `result`
frames; `total_cost_usd` was cumulative across them, so reading the first understates the run.

So: take the **last** `result`. Treat a `UserPromptSubmit` whose prompt opens with
`<task-notification>` as machine traffic and never as human input. And do not infer synchrony from
`run_in_background` — the async call did not carry that field at all.

## INV13 — Attribute cost from the control plane, never from a heuristic

This is INV7 aimed at the one number sprout puts on screen. Per-node spend comes from what the
control plane reports for that node — `PostToolUse.tool_response` on an `Agent` call carries
`agentId`, `totalTokens`, `totalDurationMs` and a full `usage` block, and the `system/task_*` frames
carry it live. Derive it from anything else and say so on the record.

Two measured failures, both silent, both from `docs/research/08-token-cost-audit.md`:

- **`isSidechain` misses 98% of multi-agent spend** on this Claude Code version. Spawned sessions are
  filed as independent `--worktrees-` projects (43.98% of spend) while true sidechains are 0.98%. A
  cost view built on it is not slightly low; it is blind to almost the entire thing it exists to
  show.
- **Usage repeats per record. Not deduping by `message.id` inflates every figure 2.02×** — and a
  number that is exactly twice right looks plausible in every direction.

Related and non-obvious: **report byte-identical alongside normalized** for any repetition or waste
metric. In-session repetition measures 17.76% normalized and **0.71%** byte-identical; the gap is
*reading*, not looping, and a normalized-only detector overstates the problem **25×**.

## INV14 — Containment is enforced before the launch, and sprout counts its own refusals

The depth cap and the budget ceiling are checked in daemon code **before a child process exists**.
They are never asked of a model, never expressed as a system prompt, and never delegated to the
platform's own limits.

Delegating them does not work even when it looks like it should. Observed in
`fixtures/phase0/streams/E.ndjson`: a `PreToolUse` hook denied an `Agent` call, the model received
the reason and adapted without retrying, `subagent_stats.spawned` stayed `0` — and all three
`subagent_stats.refused` counters (`depth_limit`, `concurrency_limit`, `budget`) **also stayed `0`**.
The platform counts only its own refusals. A denial sprout issued appears in `permission_denials` and
nowhere else, so **sprout must keep its own count or its containment is invisible to it** — INV8
again, in the one place where not noticing means a runaway tree.

State what this does not catch: a node that shells out to `claude -p` directly bypasses the `Agent`
tool and fires no `SubagentStart`. The cap is enforced on the tool, not on the intent.

---

**The outside view outranks my attachment.** The human and fresh review subagents are the real
outside view. When they disagree with me, they are probably right; update rather than defend.
