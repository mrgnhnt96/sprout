# Recursive agent harnesses — theory & literature notes

**Sources:** (all fetched directly unless noted)

- https://arxiv.org/abs/2606.13643 · https://arxiv.org/abs/2606.13643v1 · https://arxiv.org/pdf/2606.13643 · https://arxiv.org/html/2606.13643v1 — *Recursive Agent Harnesses* (RAH)
- https://github.com/RecursiveMAS/RecursiveMAS · https://recursivemas.github.io/ — RecursiveMAS
- https://www.anthropic.com/engineering/multi-agent-research-system — Anthropic, *How we built our multi-agent research system*
- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents — Anthropic, *Effective context engineering for AI agents*
- https://arxiv.org/html/2604.15597v1 — Laban, Schnabel, Neville (MSR), *LLMs Corrupt Your Documents When You Delegate* (DELEGATE-52)
- https://arxiv.org/abs/2512.08296 · https://arxiv.org/html/2512.08296v3 — Kim et al., *Towards a Science of Scaling Agent Systems*
- https://arxiv.org/abs/2503.13657 — Cemri et al. (Berkeley), *Why Do Multi-Agent LLM Systems Fail?* (MAST), NeurIPS 2025 D&B
- https://arxiv.org/html/2605.16205 — Bogdanov et al., *Context, Reasoning, and Hierarchy*
- https://arxiv.org/abs/2310.08118 · https://arxiv.org/html/2310.08118v1 — Valmeekam, Marquez, Kambhampati, *Can LLMs Really Improve by Self-critiquing Their Own Plans?*
- https://arxiv.org/abs/2505.02709 — Arike et al. (Apollo), *Evaluating Goal Drift in Language Model Agents*
- https://cognition.com/blog/dont-build-multi-agents — Walden Yan, Cognition
- https://readysolutions.ai/blog/2026-06-11-claude-code-nested-subagents/ — third-party probe of Claude Code nested subagents (secondary; treated as anecdotal)
- https://www.zartis.com/the-compounding-errors-problem-... — secondary; used ONLY to trace a citation back to arXiv 2512.08296, which was then verified directly

**Confidence:**

- **Verified by direct fetch:** existence + contents of RAH (2606.13643) and RecursiveMAS; all numbers attributed to 2604.15597, 2512.08296, 2605.16205, 2310.08118, 2505.02709, and both Anthropic posts.
- **Verified existence, abstract only:** MAST (2503.13657). The 14 failure modes' individual frequencies and the "+15.6 points" intervention figure came from search-result summaries, NOT from the paper body. Treated as unconfirmed and flagged inline.
- **Not verified:** no public RAH code repo exists yet (paper says "will be released shortly", no URL). Claude Code depth-cap behavior is one blogger's probe, not a controlled study.
- **Gap I could not close:** nobody has published a controlled ablation of *delegation depth* in a process-level agent tree. See Open questions.

---

## Verification results

**1. RAH — arXiv:2606.13643 — EXISTS AND IS SUBSTANTIVE.** The ID resolves. *Recursive Agent Harnesses*, Elias Lumer, Sahil Sen, Kevin Paul, Vamse Kumar Subbiah; submitted 11 June 2026; cs.CL; CC BY 4.0. Full HTML text is on arXiv. It is close to sprout's problem — arguably the closest published thing. **No code is released**; the paper says the implementation "will be released shortly" and gives no URL. The person who supplied the link was correct about that.

**2. RecursiveMAS — EXISTS, IS SUBSTANTIVE, AND IS IRRELEVANT TO SPROUT.** Real repo (~927 stars, 57 commits, Python, MIT, active mid-2026), real project page, real training/inference code, real benchmarks. But "latent-space recursive multi-agent systems" means literally what it says: agents exchange **hidden-state vectors**, not text, through a trained ~13M-parameter "RecursiveLink" module, and only the final recursion round decodes to tokens. Nothing in it is portable to sprout. Detail below.

**3. Broader literature — EXISTS, and is mostly bad news for deep recursion.** The empirical results that exist point consistently at shallow trees with hard verification at the coordination point. There is no published evidence supporting arbitrary depth.

---

## RecursiveMAS

**What it actually is.** A framework that treats a multi-agent system as one unified differentiable computation in latent space. Each agent's final hidden states are mapped back into its own input embedding space (the "inner link", producing "latent thoughts" with no token decoding) and projected into the next agent's input space (the "outer link", which also bridges differing hidden dimensions). The whole system loops: last agent's latent output feeds back to the first agent. Only the final round emits text.

**Numbers claimed** (project page, not independently verified): +8.3% average accuracy over the strongest baselines across 9 benchmarks (MATH500, AIME, GPQA-D, MedQA, LiveCodeBench, etc.); 2.4× speedup vs. text-based MAS; 75.6% token reduction at recursion round r=3. Models are small — Qwen3-1.7B, Llama3.2-1B/3B, Gemma3-4B class. Training is a two-stage inner/outer loop backpropagating through the RecursiveLinks.

**Portability to sprout: essentially zero.** Bluntly:

1. The recursion is over *forward passes*, not over *tasks*. There is no task decomposition, no delegation, no subtask semantics. "Recursion round r=3" means the tensor went around the ring three times.
2. It requires **training** — you must fit RecursiveLink weights against your agent lineup. sprout orchestrates black-box hosted agent sessions it cannot backprop through.
3. It assumes co-located models sharing a tensor runtime. sprout's unit is an OS process with a filesystem and a shell.
4. Its "agents" are 1–4B models doing benchmark QA, not tool-using coding agents.
5. Nothing in it addresses sprout's actual hard problems: drift across depth, termination, verification, reporting.

The name collision is the whole of the relevance. **Do not spend more time here.**

---

## Recursive Agent Harnesses (RAH)

This one is worth reading in full. It is the closest published analogue to sprout, though its evaluation is much narrower than sprout's use case.

**Framing.** RAH extends Recursive Language Models from recursion over *model calls* to recursion over *full agent harnesses*. Their words: "the recursive unit is a full agent harness with filesystem tools, code execution, and planning" — as opposed to "a model call with no tools." They call this **harness recursion**, "the code-first extension to the model recursion of RLMs." That is precisely sprout's thesis, published.

**Architecture.** A harness has: filesystem (`read_file`, `write_file`, `ls`, `glob`, `grep`), shell (run commands and scripts), and sub-agents ("spawn a fresh agent harness for a self-contained subtask").

**Two spawn paths, selected by workload size** — this is the most directly stealable idea in the paper:
- **1–5 subtasks:** call the Task tool directly as structured JSON.
- **Larger:** the parent *writes a self-contained script* in which each subagent task is a `Task()` object, all collected into a single async call that runs them in parallel. The parent runs the script through its shell tool. This "bypasses the per-turn cap and scales to thousands of subagent harnesses in parallel."

**Context flow is strictly one-way and lossy by design.** "The parent executes the script through its shell tool and receives only the aggregated stdout output once all subagents complete. Intermediate subagent reasoning, tool calls, and filesystem writes are invisible to the parent."

**Recursion control — note how thin this is.** "Recursion depth is bounded by a configurable limit (default 3), which prevents unbounded tree growth while allowing multi-level decomposition when the workload warrants it." That is the entire mechanism: a static depth counter. No token budget, no time budget, no fan-out cap (fan-out is workload-determined), no supervisor. Subagents stop on ordinary task-completion conditions, not on any recursion-specific logic. **Default 3, and they never ablate it** (see below).

**Evaluation.** Oolong-Synthetic validation split, 199 samples stratified across 13 context-length buckets from 1K to 4M tokens.

| Config | Score |
|---|---|
| RLM baseline (GPT-5) | 64.38% |
| Codex coding-agent baseline (GPT-5) | 71.75% |
| **RAH (GPT-5)** | **81.36%** (95% CI [76.0, 86.5]) |
| **RAH (Claude Sonnet 4.5)** | **89.77%** |

Per-category (Table 2): COMPARISON 89.29%, USER 87.27%, LABEL 86.54%, NUMERIC 69.33%, DATE 60.00% (n=5). Sonnet 4.5 holds >86% through 524K tokens and >76% through 4M.

**Failure modes they report (§4.6):**
1. "On a small number of instances the parent answered directly without writing a spawning script, which collapses RAH to a single coding agent." — *the parent silently declines to delegate.*
2. NUMERIC scoring artifact: the `0.75^|y−ŷ|` metric penalizes an off-by-one count down to 0.75, so sound subagent reasoning still loses points.
3. High variance on answer types with few instances.

**Limitations they state (§5), verbatim-ish:** evaluation is limited to Oolong-Synthetic; generalization "to domains where per-entry evidence is more ambiguous or less literally present in the context remains an open question"; "RAH further depends on the parent agent reliably generating syntactically correct spawning scripts"; and — critically — **"We do not ablate individual design choices such as recursion depth... Isolating their contributions is left to future work."** They also did not instrument token or wall-clock profiles for GPT-5, noting only that "prompt caching can cut token cost by up to 80%" and "latency is bounded by parallelism rather than by the count of subagents."

**Honest read for sprout.** Oolong-Synthetic is a long-context *reading* benchmark: shard the context, have N children each read a disjoint slice, aggregate. It is embarrassingly parallel, children are independent, and results are mechanically checkable. That is the friendliest possible shape for recursive delegation — and it is *not* the shape of "build me this feature," where subtasks share state, conflict, and have no ground truth. **Do not read 81.36% → 89.77% as evidence that recursive delegation works for software work.** It is evidence that recursive fan-out works for map-reduce over a huge context. The depth-3 default is an unvalidated engineering guess, by the authors' own admission.

---

## Findings from the broader literature

### Decomposition — when hierarchy helps and when it costs you

**Finding: adding agents has a performance ceiling above which it strictly hurts.** *Towards a Science of Scaling Agent Systems* (Kim et al., arXiv:2512.08296; 260 configurations, 6 agentic benchmarks, 5 canonical architectures, 3 LLM families): "tasks where single-agent performance already exceeds 45% accuracy experience negative returns from additional agents, as coordination costs exceed diminishing improvement potential." **Evidence: strong** (largest controlled sweep found).

**Finding: coordination cost scales super-linearly in agent count.** Same paper: turn count follows a power law in number of agents with exponent **1.724**. Doubling agents ≈ 3.3× the turns. **Evidence: strong.**

**Finding: bounded hierarchy with strict I/O contracts can beat deeper per-agent reasoning — but distributing *reasoning* across the hierarchy is actively harmful.** *Context, Reasoning, and Hierarchy* (Bogdanov et al., arXiv:2605.16205; three-axis ablation, 72 model-configuration pairs, adversarial POMDP). Their three conclusions verbatim: "**context engineering dominates**: deterministic programmatic state abstraction yields the largest and most consistent gains per token"; "**hierarchy can substitute for deliberation**: bounded specialist decomposition achieves the best absolute performance through strict I/O contracts rather than deeper per-agent reasoning"; "**deliberation is not modular**: distributing deliberation tools across a hierarchy produces a *deliberation cascade* that degrades returns while increasing token expenditure." Numbers: bounded hierarchy was best or near-best for 4 of 6 models, but Llama *degraded 22%* under hierarchy; hierarchy+deliberation worsened **all six** models, Devstral by 3.37× (−37.8 → −127.4 return), while costing 1.8–2.7× more tokens than bounded hierarchy. Hierarchy alone already costs ~2.4–5× the tokens of the flat baseline. **Evidence: strong for the direction, moderate for magnitudes (single domain).**

**Finding: what the agent *sees* beats how deeply it *thinks*.** Same paper: swapping raw observations for structured programmatic state improved Llama by 76% and Qwen by 71%, cutting failure rates from >90% to <10% for the strongest models, "at near-zero marginal cost." **Evidence: strong within domain.** This is the single highest-leverage finding in the whole sweep and it is *not* about recursion at all.

### Depth and drift — sprout's #1 risk

**Finding: delegated editing corrupts ~25% of content over 20 interactions, and it is NOT gradual.** *LLMs Corrupt Your Documents When You Delegate* (Laban/Schnabel/Neville, MSR, arXiv:2604.15597; DELEGATE-52 benchmark, 52 professional domains, round-trip backtranslation relay, 2–5k-token seed docs + 8–12k tokens of distractors). "Frontier models (Gemini 3.1 Pro, Claude 4.6 Opus, GPT 5.4) corrupt an average of 25% of document content by the end of long workflows." After 20 interactions: Gemini 3.1 Pro 80.9% reconstruction, Claude 4.6 Opus 73.1%, GPT 5.4 71.5%. Mean across all 19 models tested: **50% degradation**. **Evidence: strong.**

**Finding: degradation does not plateau.** GPT 5.4 extended relay — 10 interactions: 79.7%; 20: 72.9%; 30: 69.7%; 50: 66.2%; 100: 58.7%. "Degradations continue to accumulate in longer relays, with none of the models showing signs of plateauing." **Evidence: strong.** For sprout, "interactions" is a decent proxy for hops through a delegation tree.

**Finding — the most important mechanical detail here: failure is sparse and catastrophic, not diffuse.** "Models are not failing due to 'death by a thousand cuts'... they maintain near-perfect reconstruction in some rounds, and experience critical failures in a few rounds, typically losing 10-30+ points in a single round trip. These sparse critical failures explain about 80% of total document degradation." **Evidence: strong.** Implication: continuous-drift monitoring will mostly see noise. You need **per-hop gates that can catch one bad handoff**, not trend detection.

**Finding: agentic tool use made delegation *worse*, not better.** Same paper: "The four tested models perform worse when operated agentically with tools than without, incurring an average additional degradation of 6% by the end of simulation." Models invoked 8–12 tools per task and consumed 2–5× more input tokens. "Under our basic harness, the tested LLMs do not benefit from agentic tool use." **Evidence: suggestive** (one basic harness; a better harness might invert this — but it is a direct shot at the assumption that more tooling fixes drift).

**Finding: bigger inputs compound faster with more hops.** GPT 5.4 at 20 interactions by doc size: 1k → 91.4%, 4k → 79.0%, 10k → 59.9%. "Each additional 1,000 tokens in a document degrades GPT 5.4's ability to preserve content by roughly 0.7% after two interactions, but 3.6% after 20 interactions: a ~5-fold increase over the course of interaction." Distractors likewise compound: −0.4% at 2 interactions, −6.3% at 20. **Evidence: strong.** Depth multiplies the penalty for a bloated brief.

**Finding: error amplification depends sharply on topology — and the orchestrator is what contains it.** Kim et al. (2512.08296), Table 5: "Independent systems amplify trace-level errors **17.2×** through unchecked error propagation, where individual mistakes cascade to the final output. Centralized coordination, however, contains this to **4.4×**." Their framing: "architectures without centralized verification tend to propagate errors more than those with centralized coordination." **Evidence: strong.** Caveat I verified: the paper models the orchestrator as a *single* verification point and does **not** vary hierarchy depth — so 4.4× is the containment you get at *one* level of orchestration, and there is no published number for what it becomes at three or four.

**Finding: goal adherence survives long horizons in the best case but degrades with context length in general.** *Evaluating Goal Drift in LM Agents* (Arike et al., arXiv:2505.02709): the best agent (scaffolded Claude 3.5 Sonnet) "maintains nearly perfect goal adherence for more than 100,000 tokens in our most difficult evaluation setting," but "all evaluated models exhibit some degree of goal drift," and "goal drift correlates with models' increasing susceptibility to pattern-matching behaviors as the context length grows." **Evidence: suggestive** (adversarial-pressure setup, not delegation depth). Encouraging that drift is not automatic; the mechanism — pattern-matching pull growing with context — is exactly what a deep tree feeds.

**Finding: nested subagents are shipping in production harnesses, at shallow caps.** Claude Code v2.1.172 (10 June 2026) changelog: "Sub-agents can now spawn their own sub-agents (up to 5 levels deep)." A third-party probe reports the cap did not actually bind at nine levels and describes the context contract as: "On the way down, only the dispatch prompt crosses each boundary. On the way up, only the final summary message returns." **Evidence: anecdotal** (one blogger, no controlled measurement). Relevant to sprout mainly as an existence proof of the shape and as a warning that a documented cap is not necessarily an enforced one.

### Context isolation vs. sharing

This is where the literature genuinely disagrees, and the disagreement is not sloppiness — the two camps are solving different task shapes.

**Position A — isolate. Evidence: strong for read-heavy, parallel work.** Anthropic's *multi-agent research system*: "a multi-agent system with Claude Opus 4 as the lead agent and Claude Sonnet 4 subagents outperformed single-agent Claude Opus 4 by **90.2%** on our internal research eval." Cost: "agents typically use about 4× more tokens than chat interactions" and "multi-agent systems use about 15× more tokens than chats" — viable only "where the value of the task is high enough to pay for the increased performance." From *Effective context engineering*: each subagent "might explore extensively, using tens of thousands of tokens or more, but returns only a condensed, distilled summary of its work (often **1,000-2,000 tokens**)."

**Position B — share. Evidence: anecdotal but mechanistically sharp, and it is about *building* things.** Cognition's *Don't Build Multi-Agents*. Principle 1: "Share context, and share full agent traces, not just individual messages." Principle 2: "Actions carry implicit decisions, and conflicting decisions carry bad results." Their Flappy Bird example: one subagent builds a Super Mario Bros-style background, another builds a bird that "doesn't look like a game asset and moves nothing like the one in Flappy Bird" — "Subagent 1 and subagent 2 cannot see what the other was doing... The actions subagent 1 took and the actions subagent 2 took were based on conflicting assumptions not prescribed upfront." Their recommendation is a single-threaded linear agent with a dedicated compression model that summarizes history "into key details, events, and decisions."

**Reconciliation [inferred, but well-supported].** Isolation wins when children's work is *independent and read-only* (research, search, reading a sharded context — Anthropic's and RAH's domains). Isolation fails when children's work must *compose into one artifact* (code, design — Cognition's domain), because the decisions that must agree were never written down. sprout is squarely in the second category. Anthropic's own post concedes the boundary: their subagents are given "clear task descriptions" precisely because early versions produced agents doing "exact same searches as other agents, without an effective division of labor."

**Corollary from Anthropic:** "context rot" — "as the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases." So you cannot resolve Cognition's objection by simply passing the whole parent trace down. Both more context and less context degrade you; the answer has to be *curated* context.

### Termination and runaway control

**Finding: the mechanism that stops a loop must live outside the loop.** Consensus across every practitioner source found, and structurally implied by the RAH parent-collapse failure mode (the model declined to delegate when it was supposed to; a model can equally decline to stop). **Evidence: suggestive** — widely asserted, and I found no controlled study isolating in-prompt limits vs. code-enforced limits.

**Finding: budget-awareness is learnable and pays.** Progressive Interval Estimation — agents predict upper/lower bounds on remaining spend at each planning step and trigger early termination or mode-switch when completion looks infeasible within the residual budget; SFT+RL yields early-stop savings of **28–64% on failed trajectories**. **Evidence: suggestive** — I read this via search summary of a Budget-Aware LLM Agents paper and did not fetch the primary; do not cite the numbers without checking.

**Finding: static depth caps are the only termination mechanism actually used in the recursive-harness literature.** RAH: "configurable limit (default 3)." That is it. Nobody has published anything better *for recursion specifically*. **Evidence: strong that this is the state of the art; that is a statement about the field's immaturity, not an endorsement.**

### Verification

**Finding: a same-model self-critic makes things worse, and its false positives are the reason.** Valmeekam, Marquez & Kambhampati (arXiv:2310.08118), Blocksworld planning, GPT-4 as both generator and verifier, 100 instances:

| Setup | Plan accuracy | Avg iterations |
|---|---|---|
| No verification | 40/100 | 1.00 |
| **LLM self-critique** | **55/100** | 3.48 |
| **External sound verifier (VAL)** | **88/100** | 4.18 |

The verifier LLM produced "54 true positives and 38 false positives (type-1 errors)" — 61% overall accuracy against ground truth. Conclusion: "self-critiquing appears to diminish plan generation performance, especially when compared to systems with external, sound verifiers." Feedback granularity (binary vs. detailed) "showed minimal impact." **Evidence: strong.**

**The number that should drive sprout's design: 38% false-positive rate on the *approve* direction.** The critic waves through bad work more than a third of the time. In a depth-4 tree with a critic at each hop, the probability that a bad result survives every gate is ~0.38⁴ ≈ 2%… but only if failures are independent, which they are not — a parent and child sharing a model share the misconception. **[inferred: correlated failure means the real survival rate is much worse than 0.38ⁿ.]**

**Finding: the deterministic verifier is worth 33 points over the LLM verifier** (88 vs. 55 above). Wherever a real checker exists — compiler, test suite, linter, type checker — it dominates an LLM critic and is not close. **Evidence: strong.**

**Finding: MAST puts "task verification" among the three top-level causes of MAS failure.** Cemri et al. (arXiv:2503.13657, NeurIPS 2025 D&B): 1600+ annotated traces across 7 frameworks, 14 failure modes in 3 categories — system design issues, inter-agent misalignment, and task verification — with annotator agreement κ = 0.88. The authors conclude identified failures "require more sophisticated solutions," i.e. prompt-and-verify patches are not enough. **Evidence: strong for the taxonomy.** *Unverified:* search summaries cite framework failure rates of 41–86.7%, ChatDev at 33.33% on ProgramDev, and a +15.6-point gain from better prompts plus multi-level verification. I did **not** confirm these in the paper body — treat as unconfirmed until checked.

---

## What this means for sprout

1. **Cap depth at 3, hard, in code — not in a prompt.** RAH's default is 3 and they never validated it; nobody has published a depth ablation at all. Combine that with DELEGATE-52's non-plateauing degradation and 17.2× vs 4.4× topology amplification, and there is no evidence base for depth 4+. Ship depth 3 as the enforced ceiling; make it configurable but *default-refuse* above it. "Arbitrarily deep" is a marketing claim the literature does not support today.

2. **The gate must be outside the agent.** RAH's own failure mode is the parent silently declining to spawn; a parent will equally decline to stop. Depth counter, wall-clock budget, token budget, and spawn count all live in the sprout supervisor process and are checked before a child is launched, never asked of the model.

3. **Enforce a single-orchestrator topology per subtree; forbid peer-to-peer child chatter.** 17.2× → 4.4× error amplification is the single biggest architectural lever measured, and it comes for free from insisting every result flows back through the spawning parent.

4. **Deterministic verification first, LLM critic only as a fallback.** 88% vs 55% (Blocksworld) is the whole argument. sprout should require every leaf to declare a machine-checkable success condition — tests pass, build green, analyzer clean, diff applies — and should treat an LLM critic's approval as weak evidence given its 38% false-positive rate. Never let two agents on the same model be generator and verifier of the same artifact.

5. **Gate every hop, don't monitor trends.** 80% of degradation comes from sparse single-hop catastrophes losing 10–30 points at once. A "drift dashboard" will not catch these. A per-return acceptance check by the parent — against the brief it wrote — will.

6. **Budget the brief, not just the run.** Each additional 1k tokens in the handoff costs ~0.7% at 2 hops but ~3.6% at 20; distractors cost −0.4% at 2 hops and −6.3% at 20. Keep child briefs small and *curated* (Anthropic's 1,000–2,000-token distilled summary is the working number in both directions). Depth makes brief bloat expensive super-linearly.

7. **Resolve the isolation/sharing split by task shape, and make it explicit.** sprout should support two delegation modes: **map mode** (independent, read-only, verifiable children — isolate context, fan out wide, this is where RAH's 81%/90% and Anthropic's 90.2% live) and **build mode** (children producing composing artifacts — Cognition's regime, where you must push shared decisions down in the brief and should prefer narrower fan-out or a single-threaded child). Defaulting build-mode work to map-mode fan-out is how you get a Mario background and a non-Flappy bird.

8. **Push *decisions* down, not transcripts.** Cognition's "share full traces" is right about the problem and wrong about the fix given context rot. sprout's brief should carry an explicit, inherited decision record — conventions, chosen library, file layout, naming, done-criteria — written by the parent, not a dump of its history.

9. **Prefer wide over deep.** RAH gets its wins from fan-out ("thousands of subagent harnesses in parallel"), not from depth. Kim et al. show turn-count scaling at exponent 1.724 in agent *count*, which is a coordination-cost tax you pay at each level anyway — so buy parallelism at depth 1–2 rather than another level.

10. **Add a delegation floor.** Kim et al.: above ~45% single-agent baseline accuracy, adding agents produces *negative* returns. sprout should not decompose a task a single agent would likely complete. A "just do it yourself" branch is a feature, and it should be the default for small tasks.

11. **Budget the token bill up front and show it.** 15× chat tokens for multi-agent (Anthropic), 2.4–5× for hierarchy alone (Bogdanov), 2–5× more input tokens under agentic tooling (DELEGATE-52). Depth multiplies these. sprout's web UI should surface cumulative spend per subtree as a first-class number, and the supervisor should hard-stop on it.

12. **Spend engineering effort on the brief before spending it on depth.** The largest single measured effect in the whole sweep is 76%/71% improvement from structured programmatic context at near-zero cost — bigger than any hierarchy effect, positive or negative. sprout's highest-ROI component is the parent's brief-construction step, not its recursion machinery.

---

## Open questions

1. **Nobody has ablated delegation depth.** RAH explicitly defers it. Kim et al. vary topology but hold hierarchy at one orchestrator level. sprout could produce the first real curve here — depth 1/2/3/4 on a fixed task set — and it would be genuinely novel.
2. **What is the 4.4× containment factor at depth 3?** The measured number is for a single orchestrator. Naively compounding gives 4.4³ ≈ 85×, which would be fatal; that compounding is unmeasured and probably wrong, but the honest answer is we don't know.
3. **Are critic false positives correlated across depth?** If a parent and child run the same model, does the parent's critic catch the child's error, or share it? This determines whether per-hop gates multiply or collapse. Not answered anywhere I found.
4. **Does DELEGATE-52's "agentic tools make it worse" result survive a good harness?** Their harness was deliberately basic. If a strong harness inverts it, that is the argument for sprout existing; if not, it is a serious warning.
5. **Will RAH release code?** Paper says "shortly," no URL. Worth re-checking — it is the closest reference implementation to sprout that exists.
6. **Unconfirmed MAST numbers** (41–86.7% framework failure rates, +15.6 points from prompts+multi-level verification). Fetch the paper body before relying on them.
7. **What actually terminates an open-ended task?** All published mechanisms are proxies — depth, tokens, time, iterations. None answer "is the work done." sprout's machine-checkable-success-condition requirement is the closest available substitute, and it only works when such a condition can be written.
