# Staying on task over long runs

**Sources:**
- Yuan et al., *How Coding Agents Fail Their Users: Developer-Agent Misalignment in 20,574 Real-World Sessions* — arXiv:2605.29442
- *Instruction Adherence in Coding Agent Configuration Files: A Factorial Study of Four File-Structure Variables* — arXiv:2605.10039 (1,650 Claude Code CLI sessions)
- *Governance Decay: How Context Compaction Silently Erases Safety Constraints in Long-Horizon LLM Agents* — arXiv:2606.22528 (7 models, 1,323 episodes)
- Ding et al. (Accenture), *ContextEcho: A Benchmark for Persona Drift in Long Agentic-Coding Sessions* — arXiv:2605.24279 (3 donated Claude Code sessions, 3,746–9,716 turns, 23 targets)
- *When Attention Closes: How LLMs Lose the Thread in Multi-Turn Interaction* — arXiv:2605.12922
- Khanal, Tao & Zhou (NKU), *Beyond pass@1: A Reliability Science Framework for Long-Horizon LLM Agents* — arXiv:2603.29231 (396 tasks, 10 models, 23,392 episodes)
- *Push Your Agent: Measuring and Enforcing Quantitative Goal Persistence* (PushBench/QGP) — arXiv:2605.23574
- *Prompt Design at Scale: Format, Instruction Count, and Context Length* — arXiv:2607.19257
- *Long-Horizon-Terminal-Bench* — arXiv:2607.08964 (46 tasks, 17 frontier models)
- *Do Context Files Help Coding Agents? A Two-Agent Ablation Study* — arXiv:2607.27250 (291 runs)
- *Safety Does Not Compose: Non-Decaying Loop State for Autonomous LLM Agents* — arXiv:2608.27141
- Toby Ord, *Is there a half-life for the success rates of AI agents?* — arXiv:2505.05115; METR *Measuring AI Ability to Complete Long Tasks* — arXiv:2503.14499
- Anthropic, *Effective context engineering for AI agents* (engineering blog)
- Prior sprout docs: `04-recursive-theory.md`, `07-local-harnesses.md`, `08-token-cost-audit.md`, `11-quality-per-token.md`

**Confidence:** rated per finding inline. Speculation marked **[inferred]**.

---

## The verdict

**The single highest-leverage mechanism is verbatim re-injection of the goal and its constraints after every context-destroying event — compaction, handoff, session boundary — enforced by the harness, not the model.** Governance Decay measured this directly: when a stated constraint survived compaction, violation rate was 0–1%; when it was dropped, violation jumped to 38–43%, and escalated to **78% after four successive compactions**. Pinning the constraint back verbatim restored 0% violations for all seven models at ~47 tokens and <0.5% overhead, with 99% of allowed actions still completed (strong). That is the best cost/benefit ratio found anywhere in this research. Second-highest leverage is **holding task progress as structured external state that an external controller updates and gates on** — PushBench's controllers took retrieval tasks from 3–47% to 69–78% success with zero duplicate submissions, and took a work-unit task from a universal 0% to 25–50% (strong). Third is **short leaves**: instruction compliance decays measurably *within* a session at roughly 5.6% lower odds per generated function (arXiv:2605.10039, 1,650 Claude Code sessions), which no amount of prompt tuning offsets. Fourth is **capping the number of constraints**: perfect instruction-following collapses to ~0 at 80 simultaneous instructions across every model, format and placement tested (arXiv:2607.19257). Everything else — restating the goal mid-session when it is still present in context, tuning CLAUDE.md structure, episodic memory scaffolds — is either unproven or measurably useless, and two of them are measurably harmful.

---

## The failure modes, distinguished

Frequencies from arXiv:2605.29442 (20,574 real developer/agent sessions, symptom categories; percentages sum >100% because episodes carry multiple symptoms). **Evidence: strong** for the taxonomy and frequencies; it is observational, and captures only failures surfaced by developer pushback — a known undercount.

| Mode | What it looks like | Frequency | What catches it |
|---|---|---|---|
| **Instruction decay / constraint violation** | Early stated rule stops being honored | **38.3%** of episodes (S3); 49.5% in CLI specifically. Root cause C6 "instruction-following failure" **36.5%**; C4 "context loss" 4.3% | Verbatim re-pin after compaction (→0%); deterministic lint/hook that encodes the rule |
| **Premature stopping / false completion** | "Done" without verification; claims tests pass | **22.6%** (S7, inaccurate self-reporting); Qwen3-Thinking early-terminates on 49.0% of tasks (2512.12730); LHTB: agents abandon runs with reward ≥0.75 and time left | External verifier gate on the *stop* action. PushBench's controller blocks termination while verified count < target |
| **Goal drift** (pursuing a different objective) | Objective at minute 90 ≠ minute 0 | Not separately quantified at scale. Arike et al. 2505.02709 (doc 04): best agent held adherence >100K tokens, all models drifted some; drift ∝ context length | Cheap: diff current file-touch set against goal's declared scope. Expensive: LLM judge |
| **Scope creep / overreach** | Unrequested refactors, extra features | **10.2%** (S4); root cause C2 "scope overreach" 9.5%. Co-occurs with intent misreads (lift 1.39). Correlates with developer takeover | Diff-vs-declared-scope check; file allowlist |
| **Looping / step repetition** | Same tool+args repeatedly, minor arg variants | Meltdown rate 0–19% by model/horizon (2603.29231); MAST step-repetition 17.14% (doc 03) | Free: hash (tool, args); sliding-window tool-call entropy (see below) |
| **Artifact erosion** | Goal intact, the code rots underneath | 80% of trajectories (SlopCodeBench, doc `11-quality-per-token.md`); DELEGATE-52 ~25% content corruption over 20 hops (doc `04-recursive-theory.md`) | **Nothing in the transcript.** Only re-running tests / re-diffing the artifact |
| **Persona/register drift** | Verbosity inflation, format contracts broken | 6.16×/7.07×/4.28× length inflation across 3 real Claude Code sessions; drift gap +0.72 at every measured position (2605.24279) | ~80-token anchor turn (see below) |

Severity, same corpus: 90.5% of misalignments cost only effort and trust; 8.4% cause easily reversible damage; 0.07% hard-to-reverse. **Only 3.0% of episodes self-corrected — 91.5% required explicit developer pushback.** Left alone, a drifted agent stays drifted (strong).

**Cross-session contagion:** misalignment in one session raises the probability of misalignment in the *next* session from 0.336 to 0.519 (+54%). Handoff carries the disease (suggestive — observational).

### The decay curve, measured

- **Within a session, per unit of work:** each additional function generated is associated with **OR = 0.944** on compliance — ~5.6% lower odds per step (arXiv:2605.10039, 1,650 Claude Code sessions). Compounded: ~32% of turn-1 odds at 20 functions, ~5.6% at 50. **Evidence: strong** — this is the closest thing to a published instruction-decay curve for a real coding agent.
- **Attention mechanism:** Goal Accessibility Ratio (attention from response tokens to goal tokens) declines monotonically, Mann-Kendall p<10⁻⁷, losing **27–48% of turn-1 value**; under a forced 4096 sliding window the goal channel closes at turn 19–23 depending on model (2605.12922). **Evidence: suggestive** — open-weight models, synthetic setting.
- **Turn count, general:** Multi-IF has o1-preview dropping 88%→71% between turn 1 and turn 3; EvolIF reports frontier models sustain ~18 reliable turns. **Evidence: anecdotal-to-suggestive** — read via search summaries, not primary.
- **Constraint count:** perfect-response rate 0.588–0.938 at N=10 instructions → 0.094–0.312 at N=40 → **0.000–0.019 at N=80**, "for every model, every format, and both placements" (2607.19257). **Evidence: strong.** Sprout's brief has a hard budget, and it is in *rules*, not tokens.
- **Task duration:** aggregate pass@1 76.3% (short) → 52.1% (very long), super-linear vs. an i.i.d. Bernoulli baseline; software-engineering GDS collapses 0.90 → 0.44 while data-processing stays flat 0.74 → 0.71 (2603.29231). **Coding is the worst-decaying domain measured.** **Evidence: strong.**

Does a constraint stated at turn 1 still bind at turn 80? **No.** Take OR=0.944 per work-step at face value and the answer is roughly "one twentieth as reliably."

---

## Re-anchoring: keeping the goal live

**The finding that reconciles the contradictory literature:** re-injection works when the goal has been *removed* from context, and does not work when the goal is *present but attention-starved*.

- **Removed → re-injection is decisive.** Governance Decay: constraints dropped by the compaction summary → 38–43% violation; the same constraints re-injected verbatim after every compaction → **0% across all 7 models**, ~47 tokens, <0.5% token overhead, 99% of allowed actions still completed, 1% over-refusal. Four successive compactions without pinning → 78% violation. **Evidence: strong.** Placing the policy in a preserved system message also gives 0% decay, but only where the operator owns the system prompt.
- **Present but starved → re-injection does not fix it.** arXiv:2605.12922 Appendix H: "periodic user-role goal re-injection" was tested as a mitigation for the closing attention channel and **failed**. **Evidence: suggestive** (a negative result in an appendix). The channel closes because of positional decay in RoPE; adding another copy of the goal does not reopen it.
- **Middle case — register, not goal.** ContextEcho's A-anchor: one ~80-token user turn (a one-sentence identity reminder + a one-shot format demo) restores the judged assistant register to near the rubric ceiling on nearly all 23 targets, with the largest gains on the worst drifters. A ~30-token version already pegs the ceiling on 3 of 4 Anthropic targets. Persistence: inserting 0/1/5/10/20 unanchored turns between anchor and probe left **5/5 probes at ceiling at every offset** — no measured decay inside a 20-turn window. **Evidence: strong within construct.** The authors' own caveat, which sprout should honor: *"A-anchor is a generic compliance amplifier, not a drift-specific remedy."*

### Position effects — measured, and they favor recency

- ContextEcho ablated the same anchor content in a **user turn vs. the system prompt**: user turn wins on all four Anthropic targets — Sonnet 4.6 3.00 vs 2.85, Sonnet 4.5 3.00 vs 2.57, Opus 4.1 2.77 vs 2.50, Haiku 4.5 2.88 vs 2.73. Their explanation: "the model treats the recent user/assistant exchange as more behaviorally salient than the static system prompt." **Evidence: suggestive→strong** (one panel, consistent direction).
- 2607.19257 tested the same move at N=160 instructions and found the effect size at least as large as format, but **direction model-specific**: Claude Haiku +6.6pp for user turn, Qwen3 35B +5.1pp, Gemini Flash −8.7pp, Sonnet 5 indistinguishable. **Evidence: strong.**
- Reconciliation **[inferred]**: for Anthropic models the recent-user-turn slot is the better place for a re-anchor, but the gain is single-digit points, so this is a tiebreak, not a strategy. The large win is *presence* (Governance Decay), not *position*.

### External task state: structured beats prose, and the controller matters more than the file

- **PushBench/QGP is the strongest evidence for externalized task state.** Two controllers sit at the execution layer between policy and environment, see only verifier feedback, and hold structured state — submitted identifiers, seen pages, per-unit status (pending/attempted/passed). Results: retrieval tasks 3–47% (baseline) → **69.4–77.8%** with duplicate submissions eliminated (baselines 0.11–0.87 duplicate rate); work-unit tasks **0% universally** for standard and verifier-gated controllers → **25–50%** with the backlog controller. The controller also *blocks premature termination* while verified count < target. **Evidence: strong.** Note the shape: the state is not in the prompt, it is in the harness, and the harness — not the model — updates it. This is exactly doc 04's "gates must live outside the agent," now with a goal-tracking number attached.
- **Frontier CLI agents still fail on quantity alone:** Claude Code (Sonnet 4.6) and Codex CLI (gpt-5.4) solved many 50-artifact tasks but dropped to **3/9 successes at 100 artifacts** (strong). Volume, not difficulty, is what breaks them.
- **Anthropic's first-party guidance** (structured note-taking; the Pokémon agent tracking "for the last 1,234 steps... Pikachu has gained 8 levels toward the target of 10") describes the same shape: a countable target held outside the window. **Evidence: anecdotal** — a blog illustration, no ablation.
- **A plain to-do list is not the mechanism.** No source found measures a model-written, model-maintained todo list against a control. The measured wins all come from state a *verifier* writes. **[inferred]** A TodoWrite-style list whose checkboxes the agent ticks itself inherits the 22.6% inaccurate-self-reporting rate; it is a display surface, not a control.

---

## Detecting drift from outside the session

This is sprout's home ground — the daemon has metadata and nothing else. Builds on doc `11-quality-per-token.md`'s early-warning table; new material only.

### Detectable from metadata alone

| Signal | Mechanism / calibration | Evidence |
|---|---|---|
| **Sliding-window tool-call entropy (MOP)** | Over window w=5, distribution of tool identities; fire when H(t) > θ_H. Calibrated H* = 1.711 bits from 1,590 baseline episodes (2603.29231). Detects looping, arg-jitter, dead-end thrash | **suggestive** — formal precision/recall explicitly deferred by the authors; δ* calibrated to 0.000, i.e. the "spike" condition collapsed to a plain threshold. Cheap and worth shipping, not worth trusting alone |
| **Repeated (tool, args) pairs** | Their harness used 3 repeats within 6 steps as a loop trip | strong prior (doc 11), free |
| **Turn count / work-units since session start** | The only *published* decay curve is per generated function (OR 0.944). Sprout can count file writes, not functions — a close proxy **[inferred]** | strong for the underlying curve |
| **Number of active constraints in the brief** | Collapse at N=80; degradation already severe at N=40 | strong |
| **Compaction events** | Each one is a discrete constraint-loss event with a 38–43% violation cliff. The daemon can *count* them and re-pin on each | strong |
| **Time / turns since last artifact change** | LHTB: 79% of failures are the budget expiring with the agent still "actively working." Activity is not progress | strong for the pattern |
| **File-touch set vs. declared scope** | Scope creep (10.2%) shows up as writes outside the brief's declared paths, with no model call needed | **[inferred]** — no published measurement, but mechanically direct and free |
| **Output length inflation** | ContextEcho: 4.28×–7.07× length ratio vs. length-matched control across three real sessions; persists at every measured position | suggestive |
| **Repeated identical claims of completion without a passing check** | S7 is 22.6% and *rising* over Feb 2025–Apr 2026 | strong for prevalence |

**Semantic drift detection, cheaply:** the honest answer is that nobody has published a validated cheap version for coding agents. Sentence-embedding cosine against a goal centroid (all-MiniLM-L6-v2, 384-dim) is the standard cheap recipe and has been used for sleeper-agent and prompt-injection detection (arXiv:2511.15992, 2601.12359), not for goal drift in coding runs. **Evidence: anecdotal for this use.** **[inferred]** A cheaper and better-grounded substitute exists for sprout specifically: embed nothing, and instead compare the *set of files written* and the *set of tests run* against the brief's declared targets. That is deterministic, free, and catches the drift shape that actually costs money.

### NOT detectable from outside — the blind spots, stated plainly

1. **Artifact erosion.** The transcript looks healthy; the code is getting worse. SlopCodeBench's 80% and DELEGATE-52's sparse-catastrophic pattern (doc 04: ~80% of degradation comes from a few single-round 10–30 point drops) mean the daemon will see nothing and trend detection will see noise. Only re-running the deterministic checks catches it. **This is the biggest hole.**
2. **Plausible-but-wrong work.** Wrong project diagnosis (11.6%) and misread intent (27.0%) produce clean traces, healthy tool-call entropy, and steady file writes.
3. **Silent constraint violation with no error.** C6 is 36.5% of root causes and produces no failing signal — the agent simply does a different thing successfully.
4. **Whether a passing test suite tests the right thing.** Deterministic gates are only as good as their assertions.
5. **First-compaction drift onset is not predictable.** ContextEcho's dense sweep over turns {1,5,25,100,250,500,1000,1500}: "some targets drift by turn 1, others only after tens of turns, and one remains flat." Drift is **not** a uniform slow build-up, so a fixed turn-count alarm will be wrong in both directions.

Consequence for sprout **[inferred]**: the daemon's job is not to *judge* the work. It is to (a) count destructive events and re-pin after each, (b) enforce budgets, (c) force the deterministic check to run, and (d) surface the cheap signals to a human. Judging is what the gate does, and the gate must be a test, not a critic (doc 04: 88 vs. 55).

---

## Structural defenses

**Short sessions with handoff vs. one long session.** Doc `08-token-cost-audit.md` established long sessions are the expensive thing (22.2% of spend past turn 50). The quality evidence points the same way but is thinner than the cost evidence: within-session compliance decay OR=0.944/function (strong), SE reliability 0.90→0.44 across duration buckets (strong), and 2603.29231's own recommendation that a meltdown signal should trigger **"context resetting: saving the current subtask state, starting a fresh context window, and continuing from the last verified checkpoint"** rather than abandonment. What a handoff always loses: the tacit decisions behind existing code — Cognition's objection in doc 04, and the reason DELEGATE-52 degrades per hop. What it must preserve, per the measured work: the verbatim goal and constraints (Governance Decay), the verifier-owned progress state (PushBench), and the last passing check. **No controlled A/B of "restart at turn N" vs "continue" for coding agents was found.** That is a genuine gap, and one sprout could close.

**Checkpointing and re-grounding.** LHTB's 79%-timeout pattern says agents keep working past the point of usefulness; PushBench's controllers say the fix is that the *verifier*, not the agent, decides whether progress happened. Re-running the deterministic check at each checkpoint is the only intervention that touches the artifact-erosion blind spot.

**Immutable goal artifacts.** Write-protection per se has no measured effect anywhere found. What is measured is *survival*: the goal must still be in context after the destructive event (Governance Decay), and one non-decaying, latching state variable outside the model beats any decaying in-context representation (2608.27141: geometric decay lets a patient adversary wait k* = ⌊log(ρ/θ)/log(1/γ)⌋+1 iterations — a constant independent of episode length; the latched variant held 0% across N=5/10/20). That paper is adversarial-safety, so the transfer to benign goal drift is **[inferred]** — but the mechanic is the same one sprout needs: *state that does not decay, held where the model cannot rewrite it.* Note also Governance Decay's operator-impersonation result: naive pinning went from 0% to 17% violation when something in-context claimed to rescind the policy, so **the pin must come from a channel the session cannot forge** — which is precisely doc `07-local-harnesses.md`'s admitted hole (every gate fires from inside the session that stopped working).

**Stop conditions.** MAST's "unaware of stopping conditions" at 9.8% understates it: 22.6% of real sessions contain a false completion claim, and the rate is *rising* over time. What makes a stop condition bind, with evidence: the stop action itself is gated by an external verifier holding a count (PushBench — blocks termination while verified count < target, and this is the difference between 0% and 25–50%). What does not bind: writing "do not stop until X" in the brief, which is subject to the same 38–43% decay as any other constraint.

**Compaction.** Anthropic's Claude Code compaction "preserves architectural decisions, unresolved bugs, and implementation details while discarding redundant tool outputs" — note that a *standing policy* is none of those three things. Governance Decay explains why: "the policy is old, it is not the current sub-goal, and it competes for a shrinking token budget against the active task state." Two more results sharpen it: soft organizational policies decay ~+50pp while hard safety norms decay only ~+6pp (an 8.3× gap — models refuse `DROP TABLE` intrinsically but forget your naming convention), and provenance/spotlighting prompts leave violations at 43–45%, i.e. you cannot mark your way out of deleted content. ContextEcho adds that compaction is **not a reset** for drift either: across 20 pre/post crossings the drift gap increased about as often as it decreased, and no target reset across all five compactions. **Compaction is a token-management tool with a known 38–43% constraint-loss side effect, and the mitigation is a 47-token verbatim re-pin.**

---

## Long-horizon benchmarks: what fails first

- **Long-Horizon-Terminal-Bench** (46 containerized tasks, 9 domains, ~239 episodes / 9.8M tokens / 88.9 min / $10.80 per task, 17 frontier models): best model 28.3% at reward ≥0.95, mean 6.4%; 62.8% of runs earn meaningful partial reward that binary grading discards. **79% of failures are the 90-minute budget expiring while the agent is still actively working.** Weak self-verification produces false finishes with substantial work left. **Evidence: strong.** The first thing that fails is *finishing*, not *doing*.
- **Beyond pass@1** (23,392 episodes): pass@1 76.3%→52.1% across duration buckets; SE GDS 0.90→0.44 while data-processing is flat. The **MOP paradox** — the two best long-horizon models (DeepSeek V3, MiniMax M2.5, GDS 0.87/0.89) also have the highest meltdown rates (19%/13%), because capable models attempt ambitious multi-step strategies that spiral; weak models emit rote low-entropy sequences that never melt down and never finish. **A quiet trace is not a healthy trace.** **Evidence: strong** for the pattern, **suggestive** for the MOP detector itself.
- **PushBench:** frontier CLI agents hold at 50 artifacts, collapse to 3/9 at 100. Quantity is the axis.
- **Half-life.** Ord (2505.05115) shows METR's data on research-engineering tasks is explained by "a constant rate of failing during each minute a human would take to do the task" — each agent has its own half-life, giving exponentially declining success with task length. **Evidence: strong for the fit, suggestive for the mechanism** (the author flags external validity himself). METR's own trend: 50%-horizon doubling every ~7 months 2019–2025, ~4 months in 2024–25; Time Horizon 1.1 (Jan 2026) extended the suite to 31 tasks of ≥8 human-hours; frontier ~14.5h at 50% as of early 2026. **The implication for sprout is uncomfortable and worth stating: an unattended multi-hour run sits right at the edge of the published 50% horizon.** Half of them will fail; the design goal is that failure is *visible and resumable*, not that it is rare.
- **No published maximum useful session length for coding agents was found.** The nearest anchors: EvolIF's ~18 reliable turns (secondhand), the attention-channel crossover at turns 19–23 under a forced window (2605.12922), the 32K soft alarm from doc 11, and OR=0.944/function. They are not the same unit and do not compose. **This remains open.**

---

## What does NOT work

- **Tuning your CLAUDE.md / AGENTS.md structure.** arXiv:2605.10039, 1,650 Claude Code CLI sessions across two codebases and multiple models, factorially varying file size, instruction position, file architecture, and contradictions in adjacent files: **none of the four produced a detectable effect after multiple-testing correction.** The only real effect was within-session compliance decay. **Evidence: strong.** The hours spent restructuring a rules file are wasted; the same content re-pinned after compaction is worth 38 points.
- **Context files as a correctness intervention.** arXiv:2607.27250, 291 runs, Claude Code + Codex CLI, three real Python repos, three conditions (none / always-on / selective): Claude 53.3% / 55.6% / 55.6%; Codex 58.8% / 56.9% / 52.9%; omnibus permutation p=1.00 and p=0.66. A manipulation probe on the most convention-aligned near-misses found the real AGENTS.md **never** converted a failure to a pass. **Evidence: strong.** Context files still earn their place for conventions and commands; they do not fix drift and they do not fix correctness.
- **Episodic memory scaffolds.** arXiv:2603.29231, all 10 models: the memory-augmented scaffold **never** improved long-horizon GDS over plain ReAct — neutral for 4, negative for 6. "Naive episodic memory augmentation should not be adopted as a default reliability intervention." **Evidence: strong.** Structured, verifier-owned state (PushBench) works; general "remember things" memory does not.
- **Periodic goal re-injection when the goal is already in context.** Failed as a mitigation in 2605.12922 App. H. **Evidence: suggestive.** Re-injection is a *replacement* mechanism for deleted content, not an *amplification* mechanism for present content — and paying for it every turn buys nothing.
- **Compaction as a drift reset.** ContextEcho, 20 pre/post crossings across a real 9,643-turn session: gaps rose about as often as they fell; no target reset across all five compactions. **Evidence: strong.**
- **Provenance/spotlighting prompts to protect constraints across compaction.** 43–45% violation, i.e. no better than nothing. **Evidence: strong.**
- **The agent's own todo list as a drift control.** No supporting measurement exists; it shares an update channel with the 22.6% false-self-report rate. Useful as a *human-facing display*; not a control.
- **Trend-based drift monitoring.** Doc 04's DELEGATE-52 result (sparse catastrophic failures explain ~80% of degradation) plus ContextEcho's target-specific onset (some drift at turn 1, one never) mean smooth-trend alarms will fire late and often. Per-event gates beat trend lines.
- **Expecting self-correction.** 3.0% (strong).

---

## Takeaways for sprout

1. **Re-pin the goal and constraints verbatim after every compaction, handoff, and session boundary — from the harness, in a channel the session cannot forge.** ~47 tokens, <0.5% overhead, 38–43pp → 0% violation. **Essentially free; the highest-value item in this document.** Store the brief as an immutable file; the daemon injects it, the session may read but never write it.
2. **Make the stop action require an external verifier.** Sprout's daemon holds the completion count/criterion; the session cannot end a leaf while the criterion is unmet. PushBench: 0% → 25–50% on the task class where every unguarded controller scored zero. **Costs tokens (re-running checks); it is the only thing that touches false completion.**
3. **Cap the brief in *rules*, not tokens.** Target ≤10 hard constraints per leaf; treat 40 as the danger line and 80 as guaranteed failure. This sharpens doc 11's takeaway #1 ("curate, don't compress") with the axis that actually matters. **Free, and improves quality.**
4. **Keep leaves short and re-enter through verified state.** OR=0.944 per generated function is the number to quote. Reset on a *task-state rule* (subtask closed, check passed), consistent with doc 11 takeaway #3 — not on a token threshold. **Saves money and improves quality; loses tacit context, which is the known cost.**
5. **Hold progress as structured, verifier-owned state — never as prose the model writes about itself.** Per-unit status (pending/attempted/passed), file-touch set, last passing check. This is doc 04's "gates outside the agent" applied to goal-tracking, and the mechanism with the largest published gain. **Free; sprout already has the task graph.**
6. **Ship four metadata alarms in the daemon:** (a) repeated `(tool, args)` within a window; (b) sliding-window tool-call entropy, w=5, threshold calibrated on sprout's own baseline — do not import H*=1.711 blind; (c) turns/minutes since last artifact change; (d) file writes outside the brief's declared scope. All free, none require reading model output. Extends doc 11's six-signal list with (b) and (d).
7. **Count compaction events per session and surface the count.** Each one is a 38–43% constraint-loss cliff and the fourth pushes violation to 78%. A run at 4+ compactions is a run to restart, not to continue. **Free.**
8. **Do not treat quiet as healthy.** The MOP paradox says the models worth using are the models that melt down; low entropy plus no artifact change is a rote-loop signature, not a working one. Alarm on *both* tails. **Free.**
9. **On a meltdown or scope alarm, checkpoint-and-restart, do not kill.** 2603.29231's own recommendation, and consistent with doc 11's note that warned runs sometimes recover. **Costs a fresh prefix — doc 08 measured spawning at 2.0% of spend, so this is cheap.**
10. **Stop tuning rules files.** Redirect that effort to the pin channel and the verifier. **Free; recovers engineering time.**
11. **Do not add general episodic memory.** It was neutral-to-negative in 10/10 models. **Free; avoids a cost.**
12. **Accept a ~50% failure rate for multi-hour unattended runs and design the UI around it.** METR's 50%-horizon is ~14.5h at the frontier; LHTB's best model clears 28.3%. The product promise must be "you can see what happened and resume," not "it worked."
13. **What to put on the glance screen** (extending doc 11's early-warning section, not repeating it): goal text as pinned, with a **turns-since-last-pin** counter; **compaction count**; **verified-progress fraction** (units passed / target) from the verifier, never from the agent; **turns since last artifact change**; **writes outside declared scope**, listed by path; **repeat/entropy alarm**; last passing check and its age. Every one is metadata. The two that make drift *visible* rather than merely suspected are verified-progress-vs-target and out-of-scope writes.

---

## Open questions

1. **Restart-vs-continue has never been A/B'd for coding agents.** Everyone recommends it; nobody has measured the crossover turn. Sprout is instrumented to produce this number — it is the highest-value experiment available to the project.
2. **Does re-pinning help when the goal was never deleted?** Governance Decay only tested the deleted case; 2605.12922 only tested the present case and got nothing. The boundary between them is the actual design rule for sprout's pin frequency, and it is unmeasured.
3. **What is the compliance-decay unit for sprout?** OR=0.944 is per generated function. Is the right proxy file writes, tool calls, or tokens? Different answers give wildly different leaf caps.
4. **Does the ~80-token anchor transfer from persona to goal?** ContextEcho's authors explicitly call it a generic compliance amplifier. If it does transfer, it is the cheapest mid-session intervention available; if not, item 1 above is the only lever.
5. **Do the metadata alarms compose?** Unchanged from doc 11 open question 5 — still nobody has published a combined AUROC. Adding out-of-scope-writes to the panel makes this more worth answering, not less.
6. **Is out-of-scope file writing actually a drift predictor?** It is mechanically obvious and free, but no one has measured its precision. Sprout can label its own runs and find out.
7. **Does depth multiply the decay?** Doc 04 has DELEGATE-52's per-hop corruption and Kim et al.'s 4.4× containment at one orchestration level; nothing published measures constraint survival at depth 2 or 3. Sprout runs to depth 3 by design.
