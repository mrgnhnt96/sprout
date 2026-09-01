# Planning before delegation

**Sources:**

- https://arxiv.org/abs/2305.04091 — Wang et al., *Plan-and-Solve Prompting* (ACL 2023)
- https://arxiv.org/html/2605.08477 · https://arxiv.org/pdf/2605.08477 — *Do Agents Need to Plan Step-by-Step? Rethinking Planning Horizon in Data-Centric Tool Calling*
- https://arxiv.org/pdf/2602.22638 — *MobilityBench* (ReAct vs Plan-and-Execute, route planning)
- https://arxiv.org/pdf/2604.13888 — *GeoAgentBench* (Plan-and-React hybrid)
- https://arxiv.org/html/2604.12147v2 · https://arxiv.org/pdf/2604.12147 — *Evaluating Plan Compliance in Autonomous Programming Agents* / *From Plan to Action* (16,991 trajectories)
- https://arxiv.org/html/2606.22953 — *Plans Don't Persist: Why Context Management Is Load Bearing for LLM Agents*
- https://arxiv.org/abs/2402.01817 — Kambhampati et al., *LLMs Can't Plan, But Can Help Planning in LLM-Modulo Frameworks* (ICML 2024)
- https://arxiv.org/abs/2206.10498 — *PlanBench*; https://www.emergentmind.com/papers/2409.13373 — *LLMs Still Can't Plan; Can LRMs? o1 on PlanBench* (secondary summary)
- https://arxiv.org/abs/2310.08118 — Valmeekam, Marquez, Kambhampati, *Can LLMs Really Improve by Self-critiquing Their Own Plans?* (also cited in doc 04)
- https://arxiv.org/html/2605.25284v1 — *Knowing but Not Showing: LLMs Recognize Ambiguity but Rarely Ask Clarifying Questions*
- https://huggingface.co/papers/2603.26233 — *Ask or Assume? Uncertainty-Aware Clarification-Seeking in Coding Agents*
- https://arxiv.org/pdf/2605.09698 — *Ambig-DS: Task-Framing Ambiguity in Data-Science Agents*
- https://arxiv.org/pdf/2605.07937 — *Ask Early, Ask Late, Ask Right*
- https://arxiv.org/pdf/2510.17109 — *VeriMAP: Verification-Aware Planning for Multi-Agent Systems*
- https://arxiv.org/html/2507.05118 — *VerifyLLM: LLM-Based Pre-Execution Task Plan Verification*
- https://arxiv.org/html/2604.22820 — *Complete Cyclic Subtask Graphs for Tool-Using LLM Agents*
- https://www.alphaxiv.org/audio/2411.02400 — *Decomposition Dilemmas* (claim decomposition; secondary summary)
- https://www.anthropic.com/engineering/multi-agent-research-system — Anthropic, *How we built our multi-agent research system*
- https://code.claude.com/docs/en/best-practices — Anthropic, *Best practices for Claude Code*
- https://github.com/github/spec-kit — GitHub Spec Kit; https://kiro.dev/blog/kiro-and-the-future-of-software-development/ — Kiro
- Internal: `04-recursive-theory.md`, `03-roles-crewai-ag2.md`, `08-token-cost-audit.md`, `11-quality-per-token.md`

**Confidence:** Direct-fetch verified: 2604.12147, 2606.22953, 2605.08477, 2605.25284, 2603.26233, 2510.17109, 2402.01817 (abstract only), Anthropic multi-agent post, spec-kit README. Search-summary only (treated as suggestive): MobilityBench, GeoAgentBench, PlanBench-o1 figures, 2411.02400, planner-executor "+7–15%". Vendor claims (spec-kit/Kiro "3–10× first-pass success") are **anecdotal and unverified** — do not build on them.

---

## The verdict on the developer's proposal

**Yes to a planning phase, no to a generic planner subordinate at every level, and the plan must be validated before it is passed down.** The strongest evidence *for* is *Ask or Assume?* (arXiv:2603.26233): a scaffold that **decouples underspecification detection from code execution** hit 69.40% resolve rate on *underspecified* SWE-bench Verified, closing the gap to fully-specified instructions — decoupling is exactly the developer's shape. It is reinforced by *Knowing but Not Showing* (2605.25284): models detect ambiguity at 60–80% accuracy **when explicitly asked**, but ask clarifying questions **<5%** of the time when just given the task, and retrieved context *suppresses* the behaviour further. So an executor handed a one-liner will silently invent an interpretation; only a dedicated step that is *asked* to find the ambiguity will find it. The strongest evidence *against* is the plan-compliance study (arXiv:2604.12147, 16,991 trajectories, 4 models, SWE-bench Verified + Pro): plans help, but **"a subpar plan hurts performance even more than no plan at all"** — a reduced plan scored *below* the no-plan baseline (Devstral-small: 214 → 181 resolved when one phase was dropped). A planner that will not do the work, that has not read the repo, and whose output nobody checks is a machine for manufacturing subpar plans. Kambhampati's critique (arXiv:2402.01817) sharpens this: autoregressive LLMs "cannot, by themselves, do planning or self-verification," and self-critique of plans *lowers* quality versus an external verifier (2310.08118) — so sprout must never validate the plan by asking another LLM whether the plan is good. The correct shape is therefore: **a short-lived planner node at the root only, that explores the repo before writing anything, emits per-child briefs each carrying a machine-checkable done-criterion, and whose plan passes programmatic gates (DAG acyclicity, file-disjointness, criterion-writability, coverage) before any executor is spawned.** At depth 2 and 3 there is no separate planner: the parent's brief *is* the plan, and a nested planner only adds a lossy handoff. This also inverts the developer's phrasing — the planner is not a subordinate that the root delegates to and then forwards blindly; the root owns the gate, and a plan that fails the gate is regenerated, not passed on.

---

## Does a separate planning step help?

**1. An explicit upfront plan is a cost and stability win more than an accuracy win. [strong, in-domain]**
*Do Agents Need to Plan Step-by-Step?* (2605.08477) compared full-horizon planning (whole plan upfront, replan only on failure) against single-step ReAct-style interleaving across KQA Pro, GrailQA, WebQSP, GraphQ, multi-objective HotpotQA, on GPT-4.1-mini, GPT-5-mini, Qwen3-235B, Gemini-3-Flash. Result: **"FH matches SH in accuracy across most settings while using substantially fewer input tokens"** — 2–4.7× fewer (KQA Pro/GPT-4.1-mini: accuracy 0.804 vs 0.806; input tokens 43,719 vs 119,431). And the failure modes diverge hard: single-step agents fell into **repetitive tool-call loops in 30–45% of instances vs 1.9–5.9%** for full-horizon. For sprout, whose whole problem is unattended multi-hour runs, a 30–45% loop rate is the expensive failure and the plan is the cheap fix.

**2. But the win is domain-conditional, and the condition is "does feedback change the plan." [suggestive]**
MobilityBench found the opposite ordering — ReAct achieved better final pass rates than Plan-and-Execute in dynamic mobility scenarios (at ~35% higher input tokens), because static pre-planning "shows a significant lack of robustness when facing dynamic feedback." GeoAgentBench's best configuration was a **Plan-and-React hybrid**: global plan for rigour, local reactive correction for the rigidity. Rule of thumb this yields: plan the *decomposition* (which is stable), do not plan the *steps inside a leaf* (which are not).

**3. Prompt-level planning replicates cleanly. [strong, but weakly transferable]**
Plan-and-Solve (2305.04091) beat Zero-shot-CoT "by a large margin" across 10 datasets / 3 reasoning families, matching 8-shot CoT on math — by adding one sentence, "devise a plan," to fix *missing-step errors*. That is real, but it is one model planning for itself inside one context. It is evidence that planning-then-solving beats solving; it is **not** evidence that agent A planning for agent B beats agent B planning for itself.

**4. Separate agent vs same agent: the crux, and the evidence is thin. [suggestive at best]**
Survey-level claims put planner–executor at **+7–15% over monolithic baselines on multi-task reasoning**, but the same surveys report that gains "are not uniform across platforms or difficulty levels… on some the single agent is slightly better, and on others the planner-executor actually regresses," with the help concentrated on hard tasks (13 of 24 improved tasks rated hard). Practitioner framing of the mechanism is blunt and matches the papers: *the cost of separating planning from execution is a handoff, and handoffs lose context; the plan was written before any evidence arrived.* Combined with #2 and the 45% delegation floor from doc 04, the honest reading is: **separation pays on hard, decomposable work and is a tax on easy work.** sprout should gate the planner on estimated difficulty, not run it unconditionally.

**5. The Kambhampati critique, at full strength. [strong]**
LLM-Modulo (2402.01817): autoregressive LLMs "cannot, by themselves, do planning or self-verification"; their legitimate role is **candidate plan generation and idea suggestion**, with soundness supplied by external model-based verifiers. PlanBench (2206.10498) and the o1 follow-up are the empirical teeth: o1-preview reached **97.8% on Blocksworld (600 instances)** vs GPT-4's 34.6% — but only **52.8% on Mystery Blocksworld**, the *same problems with the predicate names obfuscated*, and it degrades sharply past ~20 steps and cannot reliably recognise unsolvable instances. That gap is the whole critique: performance tracks how familiar the domain *sounds*, not its structure. And 2310.08118 (doc 04) shows self-critique of plans makes generation *worse* than an external sound verifier.

**What it means for sprout.** It does *not* mean "no planning node." It means three specific constraints: (a) sprout's planning problem is in-distribution — repos, files, tests, named libraries — which is the Blocksworld side of the gap, not Mystery Blocksworld; (b) sprout's planner does not need *soundness*, it needs a non-overlapping division of labour, which is a much weaker requirement than optimal plan synthesis under closed-world semantics; (c) whatever validation sprout does on the plan **must be programmatic**, because the one validation method Kambhampati measured — the LLM checking its own plan — is measurably negative. **[inferred]** The counter-evidence to the critique is mostly that its benchmark is adversarially chosen; nobody has shown that obfuscated-Blocksworld failure predicts failure at "split this refactor into four file-disjoint chunks."

---

## From vague one-liner to executable spec

**1. The single most important number here: models see the ambiguity and say nothing. [strong]**
*Knowing but Not Showing* (2605.25284): asked explicitly to judge ambiguity, models are right **60–80%** of the time. Left to answer normally, they ask a clarifying question **<5%** of the time (Claude family highest, still under 5%), and answer directly **80–95%** of the time. Refusals are "almost never observed." Worse for sprout: **retrieved context suppresses clarification further** — an agent that just read your repo is *less* likely to flag that it doesn't know what you meant. Ambiguity detection therefore has to be an **explicitly-prompted separate step**, not a hoped-for emergent behaviour. This is the single best argument for the developer's proposal.

**2. Decoupling detection from execution is measured to work. [strong]**
*Ask or Assume?* (2603.26233): a multi-agent scaffold that **decouples underspecification detection from code execution** reached **69.40%** on underspecified SWE-bench Verified, "significantly outperforming a standard single-agent setup" and closing the gap with agents given fully-specified instructions, while showing calibrated behaviour — conserving queries on simple tasks, seeking information on complex ones. Note precisely what was separated: *detection*, not the whole plan. That is a narrower and cheaper node than "a planner subordinate."

**3. When you cannot ask, generate assumptions and rank interpretations. [suggestive]**
Ambig-DS (2605.09698) tested exactly sprout's constraint and found two interventions help: **multiple plausible interpretations ranked by likelihood**, and **explicitly stated assumptions** about ambiguous elements, which "enables better transparency and reduces mismatches." *Ask Early, Ask Late, Ask Right* (2605.07937) adds that timing matters and that early/interleaved beats late, and lists the vagueness signals: multiple conflicting valid interpretations, inability to decompose into actionable steps, repeated backtracking.

**4. Spec-driven toolchains: useful artifact shapes, worthless numbers. [anecdotal]**
spec-kit's pipeline is `constitution → specify → clarify → plan → tasks → analyze → implement → converge`, with `/speckit.checklist` generating "quality checklists that validate requirements completeness, clarity, and consistency" and `analyze` doing "cross-artifact consistency & coverage analysis." Kiro emits three documents: `requirements.md` (user stories in EARS notation), `design.md`, `tasks.md`. The **"3–10× first-pass success"** figure circulating for both is vendor/early-adopter sourced with no published methodology — **ignore it.** What is worth stealing is structural: (i) a *constitution* — durable project-wide rules separated from per-task spec, which is exactly doc 04's "push decisions down, not transcripts"; (ii) an explicit `clarify` pass before `plan`, matching finding #1; (iii) a machine-run consistency/coverage check over the artifacts, matching the Kambhampati constraint that validation be external.

**5. Is there a principled "too vague to proceed" threshold? No measured one exists. [inferred]**
Nothing in the literature gives a calibrated threshold. The best operational proxy available, and it falls out of §"Anatomy of a good brief": **a task is proceed-able iff the planner can write a machine-checkable done-criterion for every leaf.** If a leaf's acceptance condition can only be phrased as prose ("make it better", "the right way"), that leaf is underspecified in the one way that actually matters — nothing downstream can tell success from failure. Secondary triggers worth wiring, all from 2605.07937: two or more interpretations the planner ranks as near-equally likely *and* whose implementations are mutually exclusive; a goal naming an artifact that does not exist and cannot be located. Everything else: assume, **write the assumption into the plan file**, and proceed.

---

## Anatomy of a good brief

This is the highest-leverage artifact in sprout (doc 04: "sprout's highest-ROI component is the parent's brief-construction step, not its recursion machinery"; doc 03: CrewAI's "80% of your effort should go into designing tasks, and only 20% into defining agents").

**The failure this fixes, first-party and measured.** Anthropic: early versions gave subagents instructions like "research the semiconductor shortage," and "one subagent explored the 2021 automotive chip crisis while 2 others duplicated work investigating current 2025 supply chains, without an effective division of labor." The fix, verbatim: **"Each subagent needs an objective, an output format, guidance on the tools and sources to use, and clear task boundaries."**

### Template

```
## Objective                  [Anthropic, required field #1]
One sentence. The outcome, not the method.

## Done when                  [VeriMAP; the field that makes the brief self-verifying]
- <shell command or test> exits 0
- <named file> contains <named symbol>
Each: one behavior, one condition, one observable result.

## Boundaries                 [Anthropic, required field #4 — the anti-overlap field]
Files you own:   lib/foo/**, test/foo/**
Files you must not touch: everything else
Siblings running concurrently: B owns lib/bar/**, C owns docs/**

## Inherited decisions        [doc 04 takeaway 8; spec-kit "constitution"]
Library: <chosen>, already added to pubspec.
Naming: <convention>. Layout: <where new files go>.
Error handling: <pattern>. Do not re-litigate these.

## Assumptions made for you   [Ambig-DS 2605.09698]
The request said "<one-liner>". We are reading it as <X>, not <Y>, because <evidence>.
If you find hard evidence for <Y>, stop and report; do not switch silently.

## Tools / sources            [Anthropic, required field #3]
Use <these>. Do not <network / migrations / deploys>.

## Output format              [Anthropic, required field #2]
Return: files changed, done-criteria results verbatim, assumptions violated, ≤N tokens.

## Effort budget              [Anthropic scaling heuristic; doc 08]
Expect ~N tool calls. Above 2N, checkpoint and report instead of continuing.
```

**Line-by-line justification.**

- *Objective / output format / tools / boundaries* — the four fields Anthropic names as the fix for the duplicated-work failure. **Strong, first-party, measured.**
- *Done when* — VeriMAP (2510.17109) encodes "planner-defined passing criteria as subtask verification functions (VFs) in **Python and natural language**," validated when each subtask completes, before downstream agents proceed; it "outperforms both single- and multi-agent baselines while enhancing robustness and interpretability" (no public per-benchmark deltas — **suggestive**). Doc 11's conclusion that a deterministic verifier is "the one place where spending more is unambiguously worth it" points the same way. Practitioner guidance converges on one form: *one behaviour, one condition, one observable result, verifiable by someone with no context* — **anecdotal but operationally sound**.
- *Boundaries with explicit sibling ownership* — the semiconductor failure was an ownership failure. Making sibling scopes visible in each brief converts "don't overlap" from a hope into a checkable statement.
- *Inherited decisions* — doc 04 takeaway 8 and the Cognition build-mode argument; spec-kit's `constitution` is the productized version. This is what makes children's outputs *compose* rather than merely each succeed.
- *Assumptions* — Ambig-DS. Also the only mechanism by which a wrong root-level interpretation becomes recoverable rather than silent.
- *Effort budget* — Anthropic's explicit heuristic: "simple fact-finding: just 1 agent with 3-10 tool calls"; "direct comparisons: 2-4 subagents with 10-15 calls each"; complex research: ">10 subagents with clearly divided responsibilities" — which "prevent[s] overinvestment in simple queries." Doc 08 supplies the money version: a spawn not worth ≥10 turns should be an inline tool call; floor cost ~$0.62.

**How long should a brief be?** Doc 04's 1,000–2,000-token figure is Anthropic's number for the *distilled summary a subagent returns*, not for the brief it receives — worth stating plainly, since it is easy to misread. No source measures optimal brief length directly. The available constraint is doc 04's compounding-degradation numbers: each extra 1k tokens in the handoff costs ~0.7% at 2 hops and ~3.6% at 20, and distractors cost −0.4% → −6.3% over the same range. So the target is not a length, it is a property: **every line in the brief must be one the child would otherwise have to spend tool calls to discover, or would get wrong.** Doc 11: the destructive variable is irrelevant/stale content, not length. A 3,000-token brief of pure decisions beats a 1,000-token brief padded with transcript. **[inferred, but tightly constrained by 04 and 11.]**

---

## Plan verification and replanning

**1. Validate the plan programmatically, never by asking an LLM if it's good. [strong]**
2310.08118 and 2402.01817 together: self-critique degrades plan quality; external model-based verifiers improve it. The PDDL world's `VAL` gives the shape — binary validity plus **the first action whose preconditions fail**, which is actionable rather than a vibe. sprout has no PDDL model, but it has cheap structural analogues that are genuinely external:

| Gate | Check | Catches |
|---|---|---|
| Acyclicity | plan DAG has no cycle | deadlocked waves |
| Disjointness | leaf file-globs pairwise disjoint per wave | the semiconductor failure |
| Criterion-writability | every leaf has ≥1 executable done-criterion | underspecified leaf |
| Existence | every path/symbol referenced by the plan exists (or is declared as created by an earlier leaf) | hallucinated file layout |
| Coverage | every clause of the one-liner maps to ≥1 leaf | dropped requirement (spec-kit `/analyze`) |
| Right-sizing | each leaf's expected tool-call count ≥10 | spawns that should be inline (doc 08) |

VerifyLLM (2507.05118) is the pre-execution-verification precedent; spec-kit's `analyze` is the shipped consistency/coverage analogue.

**2. Replan lazily, on failure — not on a schedule. [strong]**
2605.08477: full-horizon planning with **replan-only-on-failure** matched eager step-by-step accuracy at 2–4.7× fewer input tokens *and* cut repetitive-loop incidence from 30–45% to 1.9–5.9%. Thrashing is the named risk on the other side: cyclic-subtask-graph work (2604.22820) finds unrestricted revisitation "can either enable recovery or amplify thrashing." Practical trigger set: a leaf fails its done-criteria twice; a leaf reports an assumption violated; a leaf's boundary claim collides with a sibling's actual writes. Not: "the agent feels stuck."

**3. Plans as contracts — both sides, measured. [strong]**
*Evaluating Plan Compliance in Autonomous Programming Agents* (2604.12147) is the best paper on this question: 16,991 trajectories, GPT-5-mini / DeepSeek-V3 / DeepSeek-R1 / Devstral-small, SWE-bench Verified (500) + Pro (266), 8 plan conditions.
- **For the contract:** plans improve success; agents that resolved issues showed higher plan compliance (significant for Devstral-small and DeepSeek-R1); **periodic plan reminders every 5 steps improved both compliance and success across all models.**
- **Against the contract:** **"a subpar plan hurts performance even more than no plan at all"** — the reduced-plan condition scored *below* no-plan; dropping the Reproduction phase took Devstral-small from 214 to 181 resolved. GPT-5-mini showed a *negative* compliance/success correlation (p = 0.285), i.e. the strongest model did better by adapting. And agents generally "do not rigidly follow suboptimal ordering constraints."
- **Synthesis for sprout:** bind children to the plan's *ends* (done-criteria, boundaries, inherited decisions) and leave the *means* free. Ordering constraints are the part good models correctly ignore; ownership and acceptance are the part they must not.

**4. Plans evaporate from context, so they must live in a file. [strong]**
*Plans Don't Persist* (2606.22953): plan signal peaks one step after elicitation and **drops 4.1× in a single action-observation step** (Llama-3.1-70B/ALFWorld, 0.453 → ~0.027 by step +5); **12.4×** on HotpotQA. Under compression with naive plan eviction, success fell **56.7% → 22.0% (−34.7pp, p<0.001)**. Critically, **re-injecting the plan did not fix it** — probe-gated re-surfacing bought +2.7pp (p = 0.67, n.s.), because the real bottleneck was preserving recent action-observation context, not plan text. Two consequences: (a) the plan must be an external file the child re-reads, matching Anthropic's own practice of "saving its plan to Memory to persist the context"; (b) **do not rely on periodic plan re-injection to rescue a context-compressed long-lived agent** — checkpoint and respawn on a fresh context instead (doc 08 takeaway on turn budgets).

---

## Decomposition quality

**1. The delegation floor, sharpened. [strong for the floor, inferred for the rule]**
Doc 04 / Kim et al. (2512.08296): above ~45% single-agent accuracy, extra agents give negative returns. The usable operationalisation, since sprout cannot measure its own accuracy: use Anthropic's complexity ladder as the proxy — 1 agent / 3–10 tool calls for simple fact-finding, 2–4 subagents for comparisons, >10 only for genuinely broad work — and doc 08's economic floor: a leaf not worth ≥10 turns is an inline tool call, not a spawn.

**2. Over-decomposition is a real, distinct failure. [suggestive]**
*Decomposition Dilemmas* (2411.02400) found **stronger verifiers degrade under decomposition** — decomposition noise outweighs the simplification benefit for models already able to handle the whole input — and that FactScore-style atomicity maximisation produced more over-decomposition errors. Secondary reporting adds ~35% wall-clock penalty for decomposed workflows and the context-loss argument: a leaf reading "find competitor pricing" has lost the "so we can identify underpriced segments" that made it tractable. **This directly contradicts the instinct to make sprout's tree as fine-grained as it can be.** Corollary for the brief template: the *Objective* line must carry the parent's purpose, not just the child's action.

**3. Right-sizing before dispatch. [anecdotal]**
No rigorous estimator exists in the literature I found. The circulating practitioner metrics — Coverage > 0.90 (fraction of task aspects covered), Granularity 4–7 (avg complexity per subtask), Parallelism > 0 (fraction of independent subtasks) — come from blog sources and should be treated as a checklist shape, not calibrated thresholds. The defensible pre-dispatch tests are the ones already in the validation table: expected tool-call count ≥10, file-globs disjoint, ≥1 executable done-criterion, and non-empty inherited-decision block.

---

## Where the planner should live, and what it costs

**Argument from doc 08's own numbers.** Spawning costs ~**$0.30** (2.0% of corpus spend, 6.1% of a median $4.89 Crawler); the expensive thing is duration — "the orchestrator runs twice as long as any worker it spawns." Independent figures agree the planning slice is small: orchestrator overhead ~15–20% of total cost in one Claude-based measurement, and a lightweight strategy-selection phase costs 669–1042 tokens/task, "under 1% of total token consumption" (both **secondary/suggestive**).

**So cost is not the deciding variable — context hygiene is.** Producing a *grounded* plan means reading the repo: greps, file reads, test runs. That exploration is exactly the kind of bulky, quickly-stale content doc 11 identifies as the destructive variable, and doc 04 shows it compounds with depth. If the root does the exploring itself, it carries that residue for the entire multi-hour run — the longest-lived and therefore most expensive context in the system. **Recommendation: a separate, short-lived planner node at the root, spawned as sprout's first act.** It explores freely, returns a plan file plus per-child briefs, and dies; its exploration never enters the root's context and never enters the executors'. The $0.30 spawn buys the root a clean context for hours. This is the same trade Anthropic's post makes when subagents "explore extensively… but return only a condensed, distilled summary."

**Depth 2 and 3: no planner.** The parent's brief already is the plan for that subtree. Adding a nested planner re-pays the handoff loss ("the plan was written before any evidence arrived") with no ambiguity left to resolve — the root's planner already resolved it and wrote the assumptions down. A depth-2 parent that finds its brief genuinely unexecutable should *report upward*, not spawn a planner. **[inferred; no source measures nested planning specifically — this is the clearest gap.]**

---

## What does NOT work

1. **Asking an LLM whether the plan is good.** Self-critique measurably *lowers* plan quality vs. external verification (2310.08118, 2402.01817). A "plan reviewer" subagent is the most tempting and least supported addition.
2. **Handing down a plan nobody validated.** "Use a subordinate to create a plan before passing the buck" fails at the buck-passing: a reduced/wrong plan is *worse than no plan* (2604.12147). The root must own a programmatic gate.
3. **Planning without reading the repo.** PlanBench's Blocksworld → Mystery Blocksworld collapse (97.8% → 52.8%) is what plan-shaped text without grounding looks like.
4. **Waiting for the agent to raise its hand about ambiguity.** <5% clarification rate, and *lower* after reading context (2605.25284).
5. **Periodic plan re-injection as a fix for long contexts.** +2.7pp, p = 0.67 (2606.22953). Respawn instead.
6. **Maximal atomicity.** Over-decomposition degrades strong models and costs ~35% wall-clock (2411.02400 and secondary reporting).
7. **Binding children to step ordering.** Good models correctly override suboptimal ordering (2604.12147); bind ends, not means.
8. **Trusting the "3–10× first-pass success" spec-driven-development numbers.** Vendor-sourced, no methodology.

---

## Takeaways for sprout

1. **Add a root-level planning node. Do not add one at depth 2 or 3.** It is sprout's first spawn, short-lived, and its job is: explore → resolve ambiguity → decompose → write plan file + per-child briefs → die. ($0.30, doc 08; keeps exploration residue out of the longest-lived context.)
2. **Make ambiguity detection an explicit instruction, not an expectation.** Models find it at 60–80% when asked and volunteer it <5% of the time (2605.25284). The planner prompt must contain a literal "list every ambiguity in this request" step, run *before* it reads the repo (context suppresses the behaviour).
3. **Never ask the developer; write assumptions down instead.** Emit ranked interpretations, commit to the top one, record it in the brief's *Assumptions* block with the stop-and-report rule (Ambig-DS). Reserve the one permitted question for: two mutually-exclusive interpretations of near-equal likelihood, or a named artifact that does not exist.
4. **Ship the brief template in §"Anatomy of a good brief" as generated output, not prose guidance.** The four Anthropic fields are non-negotiable; *Done when*, *Inherited decisions* and *Assumptions* are sprout's additions and each traces to a measured failure.
5. **Gate the plan programmatically before any executor spawns.** Acyclicity, pairwise-disjoint file globs, ≥1 executable done-criterion per leaf, referenced paths exist, one-liner coverage, ≥10 expected tool calls per leaf. Regenerate on failure — do not forward.
6. **A leaf with no machine-checkable done-criterion is the vagueness signal.** That is sprout's proceed/ask threshold, absent any measured alternative.
7. **Bind children to ends, not means.** Done-criteria, file ownership, inherited decisions are contractual; step order is advisory.
8. **Replan lazily.** Trigger only on: done-criteria failed twice, assumption reported violated, or boundary collision. Not on a timer, not on "seems stuck." (2605.08477; thrashing risk, 2604.22820.)
9. **The plan lives in a file that children re-read.** Plan signal drops 4.1–12.4× in one step and re-injection does not rescue it (2606.22953).
10. **Refuse to plan small work.** Above the delegation floor (doc 04) / below ~10 expected tool calls (doc 08), skip the planner and let the root just do it. Claude Code's own guidance says the same thing in plain English: *if you can describe the exact diff in one sentence, skip the plan.*
11. **Keep the tree coarse.** Prefer 3–5 substantial leaves to 15 atomic ones; carry the parent's *purpose* into each child's objective line so the leaf keeps the context that made it tractable.

---

## Open questions

1. **Nested planning at depth ≥2 is unmeasured.** My recommendation against it is inference from handoff-loss and doc 04's depth-compounding, not evidence. If sprout ever sees depth-2 briefs failing as unexecutable, that is the datapoint.
2. **Optimal brief length is unmeasured.** The 1,000–2,000-token figure is a *return* budget, not an input budget. sprout should log brief length against leaf success and find its own curve.
3. **Same-agent vs different-agent planning has no clean ablation** in a coding-agent setting. The closest is *Ask or Assume?*, and it separated only *detection*. Worth running as sprout's own A/B once it has volume.
4. **Does the planner need a stronger model than the executors?** Everything suggests plan quality is the leverage point (a bad plan is worse than none), which argues for spending model capability there — but nobody has ablated planner-model vs executor-model separately at fixed cost.
5. **How much of the planner's advantage is just "it read the repo first"?** Possibly all of it. A cheap test: root-does-its-own-exploration vs separate-planner-node, same total tokens.
6. **No source gives a calibrated "too vague to proceed" threshold.** The criterion-writability proxy is mine and untested.
