# Quality per token — where cheaper is also better

**Sources:** (all fetched; extraction method noted where it matters)

- https://www.trychroma.com/research/context-rot — Chroma, *Context Rot* (18 models, Jul 2025)
- https://arxiv.org/abs/2502.05167 — Modarressi et al. (Adobe Research), *NoLiMa*, ICML 2025
- https://arxiv.org/pdf/2606.29718 — *Diagnosing and Mitigating Context Rot in Long-horizon Search*
- https://arxiv.org/pdf/2601.07226 — *Lost in the Noise: How Reasoning Models Fail with Contextual Distractors*
- https://arxiv.org/html/2603.24755v1 — *SlopCodeBench* (coding-agent degradation over iterations)
- https://arxiv.org/html/2606.23525 — *Self-Compacting Language Model Agents*
- https://arxiv.org/html/2606.17016 — *TokenPilot: Cache-Efficient Context Management*
- https://arxiv.org/html/2510.11977 — Kapoor/Stroebl/Narayanan et al., *Holistic Agent Leaderboard* (HAL)
- https://arxiv.org/html/2606.12344v1 — *Claw-SWE-Bench* (harness-vs-model ablation, 350 instances)
- https://arxiv.org/html/2607.15263 — *Beyond Success Rate: Cost-Aware Evaluation of Security Agents*
- https://arxiv.org/html/2604.10739v1 — *When More Thinking Hurts*
- https://arxiv.org/pdf/2506.04210 — *Does Thinking More Always Help? Mirage of Test-Time Scaling*
- https://arxiv.org/html/2511.00751 — *Self-Consistency Is Losing Its Edge*
- https://arxiv.org/html/2605.08715 — *AgentForesight* (online failure auditing)
- https://arxiv.org/html/2606.01365v1 — *Early Diagnosis of Wasted Computation via Failure-Aware Observability*
- https://arxiv.org/pdf/2605.06455 — *PrefixGuard: From Agent Traces to Online Failure-Warning Monitors*
- https://arxiv.org/pdf/2512.21919 — *SWE-RM: Execution-free Feedback for SWE Agents*
- https://arxiv.org/pdf/2501.16655 — *LLM Critics for Execution-Free Evaluation of Code Changes*
- https://arxiv.org/pdf/2601.04748 — *When Single-Agent with Skills Replace Multi-Agent Systems and When They Fail*
- https://arxiv.org/pdf/2511.00872 — Yin et al., *Empirical Evaluation of Agent Frameworks on Code-centric SE Tasks*
- https://arxiv.org/html/2604.13120v1 — *AgentForge* (execution-grounded multi-agent)
- https://arxiv.org/html/2605.15206v1 — *AgentStop* (Brave Research)
- https://arxiv.org/pdf/2607.05775 — *Beyond the Leaderboard* (failure synthesis, 27 works / 19 benchmarks)
- https://github.com/anthropics/claude-code/issues/46968 — redundant-read token burn (anecdotal)
- https://www.infoq.com/news/2026/03/opus-4-6-context-compaction/ — Opus 4.6 compaction + adaptive effort (vendor)
- RouteLLM (Ong et al., ICLR 2025) — via search summary

**Extraction caveat (read this before citing anything below).** Chroma, HAL, Claw-SWE-Bench, SlopCodeBench, 2606.29718, 2606.23525, 2606.17016, 2607.15263, 2604.10739, 2511.00751, 2605.08715, 2606.01365 were fetched and read. Numbers from 2601.07226 and 2601.04748 came back as suspiciously round ranges ("15-25%", "40-60%") that read like paraphrase rather than quotation — **do not cite those figures without re-reading the PDFs on disk.** 2511.00872 and 2603.05344 would not extract at all; their claims below come from search summaries only.

**Confidence:** per-finding, inline. Does not repeat docs [03](03-roles-crewai-ag2.md) and [04](04-recursive-theory.md); cites them and builds forward.

---

## The verdict on the hypothesis

**The hypothesis holds over most of the operating range, but the stated mechanism is wrong in a way that changes sprout's design.** Cost and quality do point the same direction far more often than they oppose — but the destructive variable is not *length*, it is *irrelevant, stale, and self-generated content*, and not *agent count*, it is *unstructured coordination*. That distinction is worth money: if the problem were raw length, the fix is compression and compression costs something; because the problem is mostly distractors and staleness, **curation is the fix and curation is free or better than free.** The strongest confirming evidence is the Holistic Agent Leaderboard's finding that in only 1 of 9 benchmarks does the most expensive model sit on the Pareto frontier, and Claw-SWE-Bench's measurement that harness choice moves pass@1 by 27.4 points on a fixed cheap model — enough that a well-built cheap agent (OpenClaw + Qwen 3.6-flash, 66.0% @ $71) beats a badly-built expensive one (Generic + GLM 5.1, 63.1% @ $86). The strongest *disconfirming* evidence is that the best measured quality fixes for long-horizon agents all cost more, not less: context isolation via sub-agents bought +19% accuracy at **+35.6 tool calls** on BrowseComp-class tasks, and the Pareto-optimal Claw-SWE-Bench configuration is the *more* expensive one within its model tier. Higher reasoning effort failed to help in 21 of 36 HAL runs — which also means it did help in 15. So the honest shape is: **the first 60–80% of typical agent spend is waste that also degrades quality; the last 20–40% is real capability you cannot buy any other way.** Cheaper-is-better breaks precisely at the point where you stop deleting garbage and start deleting signal — and the only reliable way to know which side of that line you are on is a deterministic verifier, which is itself the one place where spending more is unambiguously worth it.

---

## Where cost and quality align (spend less, get more)

**1. Deleting irrelevant context is free quality. [strong]**
Chroma (18 models incl. GPT-4.1, Claude 4, Gemini 2.5, Qwen3) isolates input length with task complexity held constant and finds degradation *well before* window overflow. But the modulators are what matter: low needle-question similarity degrades much faster than high; adding 1 distractor measurably hurts and 4 compounds; and — the finding that should reorganise sprout's brief-builder — **models score better on shuffled haystacks than on logically coherent ones.** Their LongMemEval contrast is the headline number for sprout: a ~300-token focused prompt vs a ~113k-token full prompt on the *same* question, with Claude models showing the largest gap and Opus 4 abstaining ("cannot find it") on information that was present.

**2. …but "long" alone is still bad past ~32K on hard retrieval. [strong]**
NoLiMa (Adobe Research, ICML 2025) strips literal lexical overlap between needle and question across 13 models that claim ≥128K: **at 32K, 11 of 13 fall below 50% of their own short-context baseline.** Read this as the *hard-case floor*, not the typical case — NoLiMa deliberately removes the surface cue agents usually have.

**3. ~32K is the recurring inflection, and it shows up behaviourally, not just as lower accuracy. [suggestive → strong]**
2606.29718 (GLM-4.7/5.0, Qwen3.5-397B, MiniMax-M2.5 on BrowseComp / BrowseComp-Plus / xbench-DeepSearch) finds agents *give up* rather than get it wrong: premature-termination rate correlates positively with context length **controlling for query difficulty**, accelerating sharply past model-specific thresholds around 32K. The failure mode of a bloated context is a confident "I couldn't find it," which is exactly the failure a human skimming a summary will not notice.

**4. Compaction with a good *when* rule cuts cost and raises accuracy simultaneously. [suggestive, single paper, but the cleanest "both" result found]**
Self-Compacting agents (2606.23525) pair a model-invoked compaction tool with a rubric for when to fire. Agentic search, per question: GLM-4.7-Flash $0.12→$0.04 (−67%) **and +8.5 accuracy points**; MiniMax-M2.5 $0.19→$0.07 (−63%) **and +9.2 points**; MiMo-V2-Flash −33% and +5.3. Competition math: Qwen3.5-9B +18.1 on IMO-Answerbench. The paper's own ablation is the important part: without the rubric, models compact "at unhelpful moments, others not at all." **The gating rule, not the summarizer, is the artifact.**

**5. Mechanical context management buys cost only — do not expect quality from it. [suggestive; important counterweight to #4]**
TokenPilot (2606.17016) does cache-aware eviction: 56–87% cost reduction, accuracy essentially flat (81.0 vs 80.5 baseline; 81.3 vs 79.2; 63.1 vs **64.5** — a small loss on Claw-Eval). Same for the mitigation ladder in 2606.29718, where every accuracy gain came with a large tool-call increase. Compare with #4: the difference between "cheaper and better" and "cheaper and the same" is whether the policy understands *what the agent is currently doing*.

**6. Long sessions degrade code quality independently of context length. [suggestive → strong]**
SlopCodeBench (2603.24755; 20 iterative problems, 93 checkpoints, agents building on their own prior workspace): structural erosion rises over problem progress in **80% of trajectories**, verbosity in **89.8%**. Agent verbosity 0.33 vs 0.15 for maintained human repos (2.2×); erosion 0.68±0.20 vs 0.31±0.12. Human code stays flat; agent code deteriorates monotonically from the first iteration. This is *not* context rot — the damage is in the artifact, carried forward as real code. Trimming the transcript does not undo it. This is the strongest published argument for sprout's leaf-scoped fresh sessions with a deterministic gate at each boundary.

**7. Over-decomposition costs tokens and accuracy at once. [suggestive; one arm unverified]**
2511.00872 (search summary only) reports multi-agent underperforming single-agent on **all three** code-centric SE tasks, attributing it to interaction overhead and planner information overload. 2601.04748 reports skill-equipped single agents matching multi-agent accuracy at roughly half the tokens and latency — **but its extracted numbers are unverified paraphrase; re-read before citing.** This extends doc 04's Kim et al. 45%-baseline delegation floor from "adding agents stops helping" to "adding agents actively hurts on composing code work."

**8. Excess tool volume is negatively correlated with score. [suggestive]**
2607.15263, on defensive SOC tasks: "high tool volume often accompanies lower scores" — DeepSeek v4 Flash issues 4,450–4,938 tool calls for 73%, while Opus 4.8 reaches 93.9% *and* the best cost efficiency ($2.98 / 1,000 points) through "disciplined tool use... and selective enrichment." Busyness is a negative quality signal, and it is visible from metadata alone.

**9. Reasoning effort past the knee is pure waste. [strong for the direction]**
HAL (21,000 rollouts, 9 models × 9 benchmarks, ~$40k): **"For 21 of 36 runs, higher reasoning effort does not improve accuracy."** 2506.04210 measures the inversion: 82.2%→87.3% as mean thinking tokens go 385→1,100, then **87.3%→70.3%** as they go 1,100→15,980. 2604.10739 gives the marginal curve (R1-32B): +3.2% per 500 tokens at 0.5–2K, +0.1% at 8–12K, **−0.3% at 12–16K**; peak 55.8% at 12K falling to 54.9% at 16K; on AIME the correct→incorrect flip ratio crosses 1.0 at **7K tokens**.

**10. The knee is task-dependent and roughly predictable. [suggestive]**
2604.10739: easy problems (L1–2) peak at ~1.5K thinking tokens; hard (L5) benefit to ~8K; GPQA-style scientific reasoning to ~10K. Stopping at 6K cuts compute ~50% for ~6% accuracy. Three cheap signals forecast overthinking at **76.3% precision at 80% recall**: answer oscillation (r=0.78), hesitation markers ("wait", "actually"), declining confidence trajectory. Anthropic's own guidance for Opus 4.6's four-level effort control says the same thing informally — dial to medium for straightforward tasks.

**11. Redundant tool calls are a context-freshness bug wearing a cost costume. [anecdotal but exactly sprout's shape]**
Claude Code issue #46968: a sub-agent burned 100K+ tokens over 30 tool calls / 21 minutes looping on "File has been modified since read," re-reading and retrying the same edit. The agent's model of the file had diverged from disk; the loop was a symptom, and the remedy is deterministic (invalidate + single re-read, or write elsewhere), not a better prompt. Repeated identical action signatures are also one of the six diagnostic channels in 2606.01365.

---

## Where they genuinely trade off (the money is worth it)

**A. Fixing long-horizon quality costs tool calls. [suggestive → strong; the best falsifier found]**
2606.29718's mitigation ladder, all measured against the same agents:

| Mitigation | Accuracy | Cost |
|---|---|---|
| Context compaction (summarize) | **+11.6%** | +36 tool calls |
| Context trimming (drop old responses) | **+13.2%** | +19 tool calls |
| Context isolation (sub-agents) | **+19%** | +35.6 tool calls |
| Behaviour-aware filtering (drop give-up trajectories) | +2.6–4.9% | **none** |

The best quality fix is the most expensive one, and it is *sub-agent isolation* — the thing sprout does. Cheaper-is-better does not hold here. But note the last row: filtering runs whose text says the agent gave up is free and still worth 2.6–4.9 points.

**B. A stronger model on the deciding step, cheap models elsewhere. [suggestive; best hard number is generic, not coding-specific]**
RouteLLM (Berkeley, ICLR 2025): >85% cost reduction on MT-Bench at 95% of GPT-4 quality, routing only **14%** of queries to the strong model. The "frontier for planning, cheap for execution" pattern is widely asserted for agents with vendor numbers (~97.9% of frontier quality at 5.7× saving) that are **anecdotal and should not be quoted.** Directionally this is also what doc 04's Anthropic finding assumes (Opus lead + Sonnet subagents, +90.2% on their research eval at ~15× chat tokens).

**C. More attempts pay — but only if you have a selector. [strong for the gap; suggestive for the fix]**
pass@k rises reliably (LiveCodeBench Pro: o4-mini-medium 1793 at pass@1 → 2334 at pass@10). But Pass@3 vs Pass³ (all three trials succeeding) drops **2–3×** across models. Capability ≠ reliability, and without a verifier best-of-N is a lottery ticket you cannot cash. Meanwhile *undirected* self-consistency has stopped paying: 2511.00751 finds Gemini 2.5 Flash-Lite gaining **0.4%** on HotpotQA across 20 samples (≈20× cost), MATH-500 peaking at ~10 samples and **declining beyond 15**, and Gemini 2.5 Pro moving 98%→99.6% at 15 samples. Their conclusion is sprout's rule: reserve multi-path sampling for problems that demonstrably exceed single-pass reliability.

**D. Verification is the one place to spend without hesitation — and the critic's *inputs* are what make it good. [strong, extending doc 04]**
Doc 04 established 88 (deterministic VAL) vs 55 (LLM self-critique) vs 40 (none) on Blocksworld. Two additions that sharpen it:
- 2501.16655: execution-free LLM critics for code changes beat baselines by **7.4–12.7%** when the critic is *test-aware* — scored against specific unseen gold tests rather than asked "is this good?"
- Reported verification accuracy on real agent-generated patches: **93% with test specifications, 86% single-shot, 73% difflib similarity.**
- SWE-RM (2512.21919): a learned execution-free reward model correlates well enough with test outcomes to rerank many candidates cheaply, but still leaves a gap to ground truth.

Synthesis: doc 04's "LLM critics are 55%" is really "**spec-free** LLM critics are 55%." Hand the critic a machine-checkable success criterion and it moves into the 86–93% band. That is the cheap middle rung between "run the tests" (best, sometimes impossible) and "ask a model if it looks right" (near-worthless).

**E. Harness engineering. [strong]**
Claw-SWE-Bench: bare adapter reaches **19.1%** pass@1 with 69.1% patch-apply failures; the full adapter reaches **73.4%** with <1.5%. Same model, same tokens. This is not a cost/quality trade at all — it is a fixed engineering cost that dominates both axes. Ditto cache-hit rate: 96.5% (OpenClaw) vs 66.8% (generic adapter) on identical token counts, straight off the bill.

**F. Structured, execution-grounded multi-agent can beat a single agent on code. [suggestive; the honest counter to #7]**
AgentForge (2604.13120) reports **40.0%** on SWE-Bench Lite, +26.0% over its single-agent baseline, via execution grounding. So "decomposition hurts" is not universal — it hurts when coordination is unstructured, and helps when each agent's output is checked by execution. That is the same variable as (D).

---

## The cost/quality frontier for coding agents

**HAL (9 benchmarks, 9 models, 21,000 rollouts, ~$40k). [strong]**
- "In only **1 of 9** benchmarks do we observe the most costly model run on the Pareto frontier."
- Gemini 2.0 Flash appears on the frontier in **7 of 9**; Claude Opus 4.1 — ~10× the cost of mid-tier — appears once.
- Online Mind2Web: SeeAct + GPT-5 Medium **$171** vs Browser-Use + Claude Sonnet 4 **$1,577** — 9× cost for a 2-point accuracy difference.
- ScienceAgentBench: o4-mini 27% at ~5× cheaper than GPT-5's 30%.

**Claw-SWE-Bench (350 issues, 8 languages, harness and model varied independently). [strong — the most directly relevant table found]**

Model sweep, harness fixed (OpenClaw):

| Model | Pass@1 | Cost |
|---|---|---|
| GPT 5.5 | 78.0% | $1,399.10 |
| Claude Opus 4.7 | 77.1% | $1,082.00 |
| GLM 5.1 | 73.4% | $277.00 |
| DeepSeek-V4 Flash | 70.3% | **$8.20** |
| Qwen 3.6-flash | 66.0% | $71.50 |

Harness sweep, model fixed:

| Harness | GLM 5.1 | Qwen 3.6-flash |
|---|---|---|
| OpenClaw | 73.4% / $277 | **66.0% / $71** |
| Hermes-agent | 71.1% / $331 | 62.6% / $103 |
| ZeroClaw | 70.3% / $383 | 58.3% / $49 |
| Generic | **63.1% / $86** | 38.6% / $15 |

Three things fall out. (i) The full cost span is **170×** (\$8.20 → \$1,399) for a **7.7-point** accuracy span — the cost axis dwarfs the quality axis, which is the whole case for optimizing cost first. (ii) Harness choice alone moves Qwen-flash by **27.4 points**, rivalling a model-tier jump. (iii) **OpenClaw + Qwen-flash (66.0%, $71) strictly dominates Generic + GLM 5.1 (63.1%, $86)** — a well-designed cheap agent beating a poorly-designed expensive one, measured. sprout's bet is supported.

**Budget-capped ranking inverts. [suggestive]** 2607.15263 replays finished traces under lower cost ceilings: at a $0.80/sample cap DeepSeek v4 Flash holds **76.1%** while Claude Opus 4.8 collapses to **55.6%**. Leaderboard order at unlimited budget tells you almost nothing about order at *your* budget.

**Caveat on all of the above. [important]** 2607.05775 (27 works, 19 benchmarks) warns that "additional scaffolding does not consistently improve reliability" and that failures compound nonlinearly with task length — strong sub-task scores do not predict end-to-end success. The frontier tables above are per-benchmark; none of these benchmarks is a multi-hour unattended run.

---

## Early warning signals a human can read

Ranked by (evidence × cheapness × metadata-only).

| Signal | Source | Strength |
|---|---|---|
| **Repeated identical action signature** (hash tool+args) | 2606.01365 orchestration-loops channel; MAST step-repetition 17.14% (doc 03); CC #46968 | strong prior, cheap |
| **Tool error / retry rate** | 2606.01365 tool-reliability channel: "calls consuming budget without returning usable state" | suggestive |
| **Tool-call volume relative to peers** | 2607.15263: high volume ↔ lower score (4,450–4,938 calls @ 73%) | suggestive |
| **Information-change rate** — new files touched / new facts per step trending to zero | 2606.01365 information-change channel | suggestive |
| **Turns since last artifact** (no diff, no test run, no file write) | implied by the above; MAST unaware-of-stopping 9.82% | inferred |
| **Give-up / uncertainty language in output** | 2606.29718: filtering these is worth +2.6–4.9% at **zero** extra inference | suggestive, near-free |
| **Answer oscillation + hesitation markers** | 2604.10739: 76.3% precision @ 80% recall for overthinking | suggestive |
| **Context growth rate vs 32K threshold** | NoLiMa; 2606.29718 premature-termination acceleration | strong |
| **First-tool-call features** (lexical overlap between task, query, result; output length; uncertainty markers) | PrefixGuard-class monitors: held-out AUROC **up to 0.94**, predictive after the *first* tool interaction | suggestive |
| Trained prefix auditor | AgentForesight: Exact-F1 66.44 overall (Coding 78.87, Math 77.36, **Agentic 48.70**), false-alarm 2.4% on safe trajectories | suggestive |

Two operational notes. **(a)** 2606.01365 is explicit that warned runs sometimes recover — these are triage signals for *surfacing*, not for auto-killing. **(b)** AgentForesight is markedly worse on agentic tasks (48.70 F1) than on coding (78.87), so a learned auditor is more trustworthy inside a leaf than over the orchestration layer. **(c)** AgentStop (Brave Research) is the counterexample worth knowing: terminating early cut wasted energy 15–20% at <5% utility loss — a good trade, but a real one, not free.

---

## Takeaways for sprout

1. **Curate the brief; do not compress it.** [both] Chroma's ~300-token focused vs ~113k full contrast, plus the distractor and shuffled-haystack results, say the enemy is irrelevance, not length. Doc 04's takeaway #6 ("budget the brief") is right; the mechanism is that removing distractors is a *free* quality gain, so brief construction should be a filter, not a summarizer.
2. **Treat 32K as sprout's soft context alarm, per leaf.** [both] NoLiMa's 32K cliff and 2606.29718's premature-termination acceleration converge there. Surface a per-session context-size gauge and gate at it — the observed failure is a false "not found," which a human reading only the summary will accept.
3. **Compact on a rule about task state, not on a token threshold.** [both] 2606.23525's rubric-gated compaction is the only intervention found that cut cost 33–67% *and* added 5–9 accuracy points; its ablation shows the gating rule is what carries it. sprout's compaction trigger should be "the current subtask closed," which sprout already knows from its task graph — this is a capability sprout has and a chat client does not.
4. **Short leaves, fresh sessions, deterministic handoff.** [both] SlopCodeBench's monotonic erosion (80% / 89.8% of trajectories) is damage to the artifact, not the transcript — so it survives compaction. Cap leaf duration and re-enter through the checked task state.
5. **Give every critic the success criterion, or don't run it.** [improves quality, costs a little] The 88-vs-55 gap in doc 04 is really spec-free vs spec-bearing: test-aware critics gain 7.4–12.7%, and 93% vs 86% vs 73% tracks how much specification the verifier is handed. Rule: deterministic check first; if none exists, an LLM critic is allowed **only** with a written machine-shaped acceptance criterion attached.
6. **Default reasoning effort to medium; escalate on evidence, not on ambition.** [both] 21 of 36 HAL runs got nothing from higher effort; 2506.04210 shows a 17-point *drop* past the knee. Make effort a per-role field (doc 03 Tier 1) with a low default and an explicit escalation path for hard planning steps.
7. **No best-of-N without a selector.** [saves money] Self-consistency now yields 0.4–1.6 points at 15–20× cost and can decline past N=15. sprout should permit N>1 only where a deterministic verifier can pick the winner — i.e. exactly where tests exist. Everywhere else, one attempt plus a real gate.
8. **Spend on the harness before spending on the model.** [both] 19.1% → 73.4% pass@1 from adapter quality alone, and 27.4 points of harness spread on one cheap model. sprout's edge is a fixed engineering cost, and it beats a model upgrade on the same budget. This is the finding that most directly validates the project.
9. **Route the deciding step up, the volume work down.** [both] RouteLLM's 14%-of-queries-to-the-strong-model shape maps onto sprout's parent/child split: strong model writes the brief and accepts the result; cheap models do the leaves. Make `model` a per-role field with different defaults for orchestrator vs leaf.
10. **Instrument the six free signals and put them on the dashboard.** [both] Repeated action signature, tool error rate, tool-call volume, information-change rate, turns-since-last-artifact, give-up language. All are metadata; none require reading model output; and give-up filtering alone is worth 2.6–4.9 points at zero inference cost. Surface them as *warnings*, and let only the hard budget caps auto-kill (2606.01365: warned runs sometimes recover).
11. **Keep the "just do it yourself" branch, and default to it for composing code work.** [both] Extending doc 04's delegation floor: 2511.00872 has multi-agent losing on all three code-centric SE tasks, and 2601.04748 has skill-equipped single agents matching multi-agent accuracy at roughly half the tokens. Decomposition should require a positive justification, not be the default.
12. **…but exempt execution-grounded fan-out.** [improves quality, costs money] AgentForge's +26.0% and 2606.29718's +19% from sub-agent isolation both hold. The distinguishing variable is whether each child's output is machine-checked. sprout should allow wide fan-out **only** for leaves that declare a deterministic success condition — which is already doc 04's rule, now with a second reason to enforce it.
13. **Report cost per *resolved* task, not cost per run.** [improves judgement] HAL's effectiveness-aware cost-per-instance and 2607.15263's retrospective budget caps both show ranking inverting under a budget. sprout's UI should show \$/success and let the developer replay a finished run under a lower cap.
14. **Accept the one real trade honestly.** [costs money] Every measured long-horizon quality fix except give-up filtering cost more tool calls. sprout should not promise cheaper-and-better everywhere; it should promise that the *waste* is removed first, and that what remains is spent on verification and isolation, which are the two things that demonstrably buy quality.

---

## Open questions

1. **Where is the knee for *coding-agent tool loops* specifically?** Every thinking-budget curve found is on math/science QA. Nobody has published accuracy-vs-thinking-tokens for a tool-using coding agent. sprout could produce it.
2. **Does rubric-gated compaction (2606.23525) hold for code, not just search and math?** The mechanism ("compact at a closed reasoning unit") maps cleanly onto sprout's task graph, but the result is unreplicated outside its benchmarks.
3. **Is SlopCodeBench erosion recoverable?** It measures continued sessions only. Does inserting a deterministic refactor/lint gate between checkpoints flatten the curve, or is the damage baked in by the first design decision?
4. **What does the +19% from sub-agent isolation cost at depth 2 and 3?** 2606.29718 measures one level. Combined with doc 04's open question 2 (the 4.4× containment factor at depth 3), this is the same unmeasured hole from two directions.
5. **Do the early-warning signals compose?** Each is reported alone. Nobody has published the AUROC of the six metadata channels combined, which is what sprout would actually deploy.
6. **Re-read 2601.07226 and 2601.04748 from the saved PDFs.** Their extracted numbers are paraphrase-shaped and unverified; the distractors-not-length claim in particular is load-bearing for takeaway 1 and currently rests mainly on Chroma.
7. **Does "high tool volume ↔ lower score" hold for coding?** Measured on SOC investigation tasks (2607.15263). If it holds for coding agents it is the cheapest quality proxy sprout could ship; if it inverts (thorough agents read more files), it is actively misleading.
8. **What is the right \$/success target?** HAL and Claw-SWE-Bench give per-benchmark frontiers, but nobody has published a cost-per-success figure for a multi-hour unattended build task — sprout's actual workload.
