# Does the work repeat? — measured

**Corpus.** 359 `.jsonl` transcripts under `~/.claude/projects`, **314 sessions**, **225 raw project
dirs collapsing to 15 real repos** (a showrunner Crawler is filed by Claude Code as its own
top-level `--worktrees-…` dir; doc 08's lane rule strips it, so "cross-project" here means
cross-*repo*). Window **2026-08-27T03:52Z → 2026-09-01T05:12Z** (5 days). 30,454 tool calls, of which
**27,175 are Bash (89.2%)**. Total spend **$3,145.13**.

**Method.** `docs/research/tools/repetition-scan.py`, re-runnable, aggregates only — no transcript
content is ever emitted, every example below is a normalized signature with paths/strings/hashes
destroyed. Reused from `cost-audit.py`: the dedupe rule (**usage counted once per distinct
`message.id`**; naive summing inflates 2.026×), the lane/worktree rule, and the pricing table. Reused
from doc 15: the normalization spirit (`/…`→`P`, quoted→`S`, hex→`H`, digits→`N`, collapse, truncate)
and the **two-axis recurrence bar — ≥3 distinct sessions *and* ≥2 distinct repos** (Mozilla topcrash).

**Counting rules, stated before any total.**
- **R1 occurrence** = one `tool_use` block.
- **R2 turn cost** = `price(model, usage)` of the assistant message that issued the call, deduped per
  `message.id`, split evenly across that message's `tool_use` blocks. A **lower bound** on what
  removing the call saves (ignores the cache-read reduction for every later turn) and an **upper
  bound** on attribution (the turn did more than the command).
- **R3 session** = `sessionId`. **R4 project** = project dir minus `--worktrees-<leaf>`.
- **R5 in-session repeat** = signature already seen in this session → a **loop** (bug).
- **R6 cross-session repeat** = signature in ≥2 sessions → a **procedure** (crystallization target).
- **R7 crystallizable** = ≥3 sessions **and** ≥2 projects.

**Two parser cross-checks passed.** Total spend $3,145.13 vs `cost-audit.py`'s $3,144.61 (**0.02%**).
Exact-string in-session Bash repeats **0.71%** vs doc 15's independently-measured 0.70%.

**Confidence.** **Strong** for repetition *inside a 5-day window*. **Weak** for the question actually
asked, because crystallization is a longitudinal claim (the external evidence spans 8 months) and this
corpus spans 5 days. That asymmetry is the single largest caveat and is quantified below.

---

## The answer

**Verdict: NO — do not build crystallization as a headline feature. Ceiling ≈ 1–4% of spend,
$20–130 of $3,145, with a generous-assumption upper bound of 8.5%.**

The decisive numbers:

- **Byte-identical commands recurring across ≥3 sessions and ≥2 repos: 657 of 27,175 Bash calls
  (2.42%), $19.63 = 0.62% of spend** — and every one of them is *already* a single deterministic CLI
  invocation (`git add -A`, `<harness> status`, `--help`).
- **Multi-step procedures: recurrence dies at n=7.** Substantive tool-call n-grams recurring in ≥3
  sessions cover 22.2% of positions at n=3, 15.4% at n=4, 3.2% at n=6, **0.63% at n=7, 0.08% at n=8,
  and exactly zero at n=9 and n=10.** No 9-step workflow in 359 transcripts happens three times.
- **Strip the read/search primitives** (`sed`/`cat`/`grep`/`ls`/`head`/`tail`/`find`…, which are 45.6%
  of all Bash) and the *action* sequence collapses further: **8.56% of positions at n=3, 2.90% at n=4,
  0.82% at n=5, and zero cross-project recurrence at n≥6.**
- **The one big-looking number is an artifact of normalization.** 35.2% of Bash calls sit in a
  normalized signature meeting R7 ($267.02 = 8.49% of spend) — but **98.2% of that population
  (9,394 of 9,566 occurrences) is *parameterized***: the destroyed argument (a path, a pattern, a line
  range) *is* the information. The genuinely fixed-argument remainder is **172 calls = 0.63% of Bash,
  $7.51 = 0.24% of spend.**

**Why the ceiling is low is more interesting than that it is low: this corpus is already
post-crystallization.** The developer has already built the deterministic layer — game_loop,
showrunner, llm_chat, sip, dvm — and **9.6% of all Bash calls are direct invocations of those CLIs**.
The external 0%→45% claim describes a workload migrating *into* that state. sprout's corpus starts on
the far side of the migration. What is left over is not a repeated procedure; it is **locating the
right file, the right line range, the right pattern** — irreducibly parameterized by the task.

---

## Command-level repetition

Bash calls: **27,175**. Distinct normalized signatures: **16,116**, of which **14,276 are singletons
(88.6%)**.

| Definition of "the same work" | occurrences | % of Bash | attributed $ | % of spend |
|---|---:|---:|---:|---:|
| byte-identical command, R7 (82 distinct commands) | 657 | 2.42% | $19.63 | 0.62% |
| normalized sig, **fixed** args, R7 | 172 | 0.63% | $7.51 | 0.24% |
| normalized sig, R7 (incl. parameterized templates) | 9,566 | 35.20% | $267.02 | 8.49% |
| verb+subcommand **family**, R7 (284 families) | 25,006 | 92.02% | $723.05 | 22.99% |

The family row is what you would quote to justify the feature, and it is meaningless: a "family" is
`sed`, `grep`, `git add`. 92% says *the agent keeps using the same tools*, not *the agent keeps
redoing the same work*.

**Loop vs procedure — the two populations, reported separately as required.**

| Population | signatures | repeat calls | attributed $ | % of spend |
|---|---:|---:|---:|---:|
| **Loop** (repeats inside one session, never seen in another) | 513 | 857 | — | — |
| In-session repeat, **normalized** | — | 4,826 (17.76% of Bash) | $190.99 | 6.07% |
| In-session repeat, **byte-identical** | — | **193 (0.71%)** | $14.50 | 0.46% |
| **Procedure** (signature in ≥2 sessions) | 1,324 | 11,516 occ (42.4%) | — | — |

The 17.76% → 0.71% gap is the whole lesson in one line. **17 percentage points of apparent
"in-session repetition" is the same command shape pointed at a different file or a different line
range — i.e. reading, not looping.** Doc 15 already measured retry loops at zero and identical-call
retries at zero; this confirms it from the other direction and shows how a normalized metric would
have manufactured a 25× overstatement.

**What the Bash calls actually are** (classified by the program run, not by substring — `cat
.game_loop/x` is a read, not a harness call):

| bucket | calls | % of Bash | attributed $ | % of spend |
|---|---:|---:|---:|---:|
| read/search primitive | 12,398 | 45.62% | $318.85 | 10.14% |
| file-write primitive | 3,395 | 12.49% | $70.18 | 2.23% |
| **harness-cli (already deterministic)** | 2,620 | 9.64% | $98.59 | 3.13% |
| inline script (agent-authored) | 2,406 | 8.85% | $83.25 | 2.65% |
| vcs | 2,356 | 8.67% | $76.71 | 2.44% |
| other (shell scaffolding, process mgmt, curl) | 2,283 | 8.40% | $63.07 | 2.01% |
| build/test toolchain | 1,717 | 6.32% | $75.49 | 2.40% |

**Side-finding, not crystallization but the largest band in the table:** 45.6% of Bash calls and
**$318.85 (10.14% of spend)** are read/search primitives issued through Bash because the machine-wide
instruction routes all file access through Bash instead of the Read/Grep tools. That is a config
lever, and it is 10× the size of the entire crystallization opportunity.

**Top signatures by distinct sessions** — note that the head of the distribution is *entirely*
file-access primitives, i.e. the population normalization makes look repetitive:

| normalized signature | occ | sessions | projects | $ |
|---|---:|---:|---:|---:|
| `sed -n S P` | 1,473 | 213 | 12 | $37.19 |
| `cat P` | 421 | 180 | 11 | $8.35 |
| `grep -n S P \| head -N` | 329 | 146 | 9 | $4.36 |
| `python3 - <<HD` | 368 | 111 | 10 | $8.92 |
| `git add -A` | 105 | 99 | 7 | $5.82 |
| `git commit -F P` | 89 | 85 | 7 | $7.22 |
| `<harness> status` *(family, not one signature)* | 233 | 102 | 9 | $16.00 |

## Procedure-level repetition

**Substantive threshold, stated:** an n-gram counts only if it has **≥3 distinct token types**,
contains **≥1 Bash/Edit/Write/Agent token**, and **no single token occupies >60% of positions**. This
is what excludes `Read → Edit → Read` padding and `sed → sed → sed` scanning.

**All 30,454 tool positions:**

| n | n-grams in ≥3 sessions (substantive) | of those, ≥2 projects | % positions covered | $ covered | % of spend |
|---:|---:|---:|---:|---:|---:|
| 3 | 479 | 418 | 22.22% | $200.83 | 6.39% |
| 4 | 319 | 283 | 15.41% | $128.76 | 4.09% |
| 5 | 224 | 206 | 9.85% | $73.92 | 2.35% |
| 6 | 60 | 55 | 3.23% | $20.77 | 0.66% |
| 7 | 10 | 8 | 0.63% | $4.66 | 0.15% |
| 8 | 1 | **0** | 0.08% | $0.33 | 0.01% |
| 9 | **0** | 0 | 0.00% | $0 | 0.00% |
| 10 | **0** | 0 | 0.00% | $0 | 0.00% |

**Action-only** (read/search primitives and the Read/Grep/Glob tools removed — 17,576 positions). This
is the fair test of "does the *workflow* repeat":

| n | ≥3 sessions | ≥2 projects | % positions | $ | % of spend |
|---:|---:|---:|---:|---:|---:|
| 3 | 151 | 122 | 8.56% | $57.32 | 1.82% |
| 4 | 43 | 27 | 2.90% | $20.38 | 0.65% |
| 5 | 12 | 3 | 0.82% | $5.25 | 0.17% |
| 6 | 3 | **0** | 0.22% | $1.26 | 0.04% |
| 7 | 1 | 0 | 0.12% | $0.75 | 0.02% |
| ≥8 | **0** | 0 | 0.00% | $0 | 0.00% |

**Shapes of what does recur** (redacted to shape; every one is a harness ritual, not a derived
procedure):

- `git add → git commit` — 19 occ, 7 projects (n=3). The commit ritual.
- `<write message file> → git add -A → git commit -F` — 4 occ, 4 projects (n=4).
- `<llm_chat join> → say → say → mkdir` — 6 occ, 2 projects (n=4). Channel setup.
- `python3 -<script> → dart analyze → dart test` — 8 occ, 4 sessions (n=3). Verify-after-edit.
- `python3 - → python3 - → flutter test → flutter analyze` — 5 occ, 2 projects (n=4).
- `Edit(.dart) → flutter test → cp → flutter test → cp` — 3 occ, 2 projects (n=5). Golden-file update.

**Sensitivity: would a longer window change this?** Action-only n=4 coverage vs fraction of sessions
sampled (seeded single draw):

| sample | sessions | ≥3-session n-grams | coverage | (control) ≥2-session coverage |
|---|---:|---:|---:|---:|
| 25% | 78 | 4 | 0.89% | 2.89% |
| 50% | 157 | 15 | 1.65% | 8.48% |
| 75% | 235 | 35 | 2.57% | 9.20% |
| 100% | 314 | 66 | 3.95% | 10.65% |

The ≥3-session curve is still rising near-linearly, **but that is largely a threshold artifact** — a
fixed absolute bar is mechanically easier to clear in a bigger sample. The constant-k≥2 control curve
(2.89 → 8.48 → 9.20 → 10.65) has **clearly decelerated** past the 50% mark. Extrapolating the control,
a 4× corpus (~3 weeks) would land action-only n≥4 coverage around **13–16% of action positions
[estimated]**, i.e. roughly **2–4% of spend** — a doubling of the ceiling, not a reordering of it.

## Task-level repetition

**Cheap clustering cannot answer this credibly, and I will not produce a number I do not trust.** Two
cheap fingerprints over the same 314 sessions give opposite answers:

| fingerprint | median nearest-neighbour cosine | pairs ≥0.90 | cross-project pairs ≥0.70 | greedy clusters |
|---|---:|---:|---:|---|
| raw bag (tool mix + bash family + file ext) | **0.990** | 311 / 314 | 313 / 314 | 1 cluster holds 294 sessions |
| TF-IDF (same features, ubiquity down-weighted) | **0.358** | 4 / 314 | **0 / 314** | 307 of 310 clusters are singletons |

The raw fingerprint says every session is the same session — because every session is >45% `sed`/
`grep`/`cat` and the tool mix is nearly constant across the whole machine. The TF-IDF fingerprint says
**no two sessions in different repos exceed 0.70 similarity**, and at threshold 0.70 only **3 sessions
(0.96%, 0.07% of spend)** land in any cluster of size ≥3. Neither is a measurement of task shape:
the first measures the harness's file-access convention, the second measures repo vocabulary.

**Conclusion for level 3: unanswered, and unanswerable from cheap signals on this corpus.** Answering
it needs the thing doc 15 identified as the only genuinely LLM-requiring frontier (semantic step
repetition, MAST FM-1.3). Note that both fingerprints bracket the crystallization ceiling anyway:
0.07% at the strict end, and even the degenerate 97% at the loose end carries no procedure to extract.

## The ceiling estimate

**Assumptions stated.** (a) Crystallizing a call removes its turn entirely — R2 cost, a lower bound
since it ignores downstream cache-read savings and an upper bound since the turn did more than the
call. (b) A crystallization candidate must clear R7 (≥3 sessions, ≥2 repos). (c) A parameterized
signature only counts if the parameter is derivable without a model — for `sed -n '120,180p' <path>`
it is not; choosing the file and range *is* the work. (d) 5-day window; sensitivity curve above.

| Ceiling scenario | basis | $ | % of $3,145 spend |
|---|---|---:|---:|
| **Floor** — fixed-argument commands, R7 | 172 calls | $7.51 | **0.24%** |
| **Conservative** — byte-identical commands, R7 | 657 calls | $19.63 | **0.62%** |
| **Central** — action-only recurring procedures n≥3, ≥3 sessions | 8.56% of action positions | $57.32 | **1.82%** |
| **Optimistic** — all-tool recurring procedures n≥4, ≥3 sessions | 15.41% of positions | $128.76 | **4.09%** |
| **Generous upper bound** — every R7 normalized signature, incl. parameterized templates | 9,566 calls | $267.02 | **8.49%** |
| *(rejected)* family-level R7 | 25,006 calls | $723.05 | *22.99%* |
| **Central + 4× window** [estimated] | sensitivity extrapolation | ~$65–130 | **~2–4%** |

**Range: 1–4% of spend, upper bound 8.5%.** The named-candidate backlog below independently
lands at **$19.63 (0.62%) strictly measured / $117.94 (3.75%) at the most generous framing**, which
brackets the same answer from a second direction.

**Against the external claim (doc 10: 0%→45% deterministic over 8 months, >70% cost reduction) — not
plausible for this corpus, for a structural reason rather than a workload-variance one.** By the
family measure, **92.0% of Bash operations here already sit in a recurring deterministic family**, and
9.6% are direct calls into CLIs the developer already wrote. The 45% figure measures a migration this
machine has already made. Reproducing a >70% cost cut would require believing that the remaining
45.6% of calls — locating a file, a pattern, a line range — are crystallizable procedures rather than
reads. They are not: 98.2% of the recurring-signature population is a template whose argument carries
the entire payload.

**For contrast, from doc 08 on the identical corpus:** context growth past turn 50 is **$683.61 =
22.2%** of spend and harness-injected prefix is **$257.09 = 8.3%**. **Either lever is 5–20× the entire
crystallization ceiling**, is deterministic, and needs no cross-session mining to find.

## Crystallization candidates

Listed because the numbers support a *small backlog item*, not a feature area. Reported at the
**generous family framing** — every invocation of the family, not only the instances that appear
inside a recurring n-gram — so these are ceilings, not expected savings. Note that four of the five
are **already CLIs the developer wrote**; the residual value is sequencing them into one call, not
deriving them.

| # | Candidate (shape, redacted) | occ | sessions | projects | attributed $ | % spend |
|---|---|---:|---:|---:|---:|---:|
| 1 | verify gate: `<toolchain> analyze` / `<toolchain> test` | 949 | 169 | 7 | $48.37 | 1.54% |
| 2 | commit ritual: `<write msg file> → git add -A → git commit -F` | 611 | 250 | 9 | $41.94 | 1.33% |
| 3 | leaf closeout: `<llm_chat> join/say → close` | 588 | 227 | 8 | $18.99 | 0.60% |
| 4 | `<harness> checkpoint --notes S` | 78 | 23 | 6 | $4.79 | 0.15% |
| 5 | `<harness> integrate` | 102 | 46 | 6 | $3.85 | 0.12% |
| | **combined** | 2,328 | — | — | **$117.94** | **3.75%** |

**Read that total carefully.** $117.94 / 3.75% is the *entire spend on those command families*, which
assumes running the test suite is itself crystallizable — it is not; running it is the work. The same
five candidates measured strictly (byte-identical, R7) are worth **$19.63 = 0.62%**. The truth is
between, and closer to the bottom. Candidates 6–10 were not written down: every remaining R7 family is
under $1 of attributed spend, which is below the noise floor of the R2 attribution rule.

## Why this number could be wrong

1. **The window is 5 days and crystallization is a longitudinal claim.** This is the dominant risk and
   it points one way: **a procedure that recurs monthly cannot appear here at all.** A release
   checklist, a dependency bump, a quarterly migration — all invisible. The sensitivity curve says the
   ceiling roughly doubles at 4× corpus and is decelerating, but it is a within-window extrapolation
   and cannot see a period longer than the window. sprout should re-run this script at 90 days before
   closing the question permanently; that is the whole point of observing every trajectory forever.
2. **The corpus is one developer, 15 repos, mostly Dart/Flutter, already carrying two custom
   harnesses.** The result "this workload is already crystallized" may be a property of *this*
   developer rather than of agent work. It is exactly the wrong corpus for generalizing a negative.
3. **Normalization is a knob and I set it in both directions to show the swing.** Full-signature R7
   gives 35.2%; family-level gives 92.0%; byte-identical gives 2.4%. I chose byte-identical and
   fixed-argument as the honest levels and reported the others; a different choice yields a different
   headline from the same data. The parameterization split is the discriminator that makes the choice
   defensible, and it is a **[guess]** threshold (≤n/10 distinct raw strings).
4. **R2 cost attribution is crude.** A turn's cost is dominated by re-reading conversation history
   from cache, not by the command it issues. Splitting turn cost across tool calls therefore charges
   commands for context they did not create, and ignores that removing k turns shortens the prefix for
   every later turn. The true saving of a crystallized procedure is probably **higher** than the
   figure I report — but the correction is a multiplier on 1–4%, not a path to 70%.
5. **n-gram tokens are coarse** (`Bash:<verb subcommand>`). A finer token would find *less*
   recurrence; a coarser one would find more. I am already at the generous end, and n≥8 is still zero.
6. **Interleaving hides procedures.** A procedure executed as A-B-C in one session and A-x-B-y-C in
   another is invisible to contiguous n-grams. A gapped/LCS matcher would find more. This is the most
   likely *technical* under-count, and the honest response is that it would move n=4 coverage, not the
   fact that n≥8 recurrence is empty.
7. **Task-level is genuinely unmeasured**, not measured-as-zero. If sessions repeat at the *intent*
   level while diverging at the tool level, this scan cannot see it, and neither can any cheap signal.
