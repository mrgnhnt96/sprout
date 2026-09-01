# Roles — CrewAI & AG2 research notes

**Sources:**
- CrewAI source @ `main`: `lib/crewai/src/crewai/agents/agent_builder/base_agent.py`, `agent/core.py`, `task.py`, `translations/en.json`, `tools/agent_tools/{delegate_work_tool,base_agent_tools}.py` — <https://github.com/crewAIInc/crewAI>
- CrewAI docs: [Agents](https://docs.crewai.com/en/concepts/agents), [Tasks](https://docs.crewai.com/en/concepts/tasks), [Processes](https://docs.crewai.com/en/concepts/processes), [Flows](https://docs.crewai.com/en/concepts/flows), [Crafting Effective Agents](https://docs.crewai.com/en/guides/agents/crafting-effective-agents), [Agent Repositories](https://docs-platform.crewai.com/platform/en/features/agent-repositories)
- AG2 v0.14 source: `autogen/agentchat/{conversable_agent,groupchat}.py` — <https://github.com/ag2ai/ag2/tree/v0.14.0>
- AG2 v1.0 source @ `main`: `ag2/agent.py`, `ag2/tools/subagents/{subagent_tool,run_task,background}.py`
- AG2 docs: [Handoffs](https://docs.ag2.ai/latest/docs/user-guide/advanced-concepts/orchestration/group-chat/handoffs/), [Nested chat](https://docs.ag2.ai/latest/docs/user-guide/advanced-concepts/orchestration/nested-chat/), [v0.9 release](https://docs.ag2.ai/latest/docs/blog/2025/04/28/0.9-Release-Announcement/)
- [MAST: Why Do Multi-Agent LLM Systems Fail? (arXiv:2503.13657)](https://arxiv.org/abs/2503.13657) — 1600+ annotated traces, 7 frameworks incl. AG2
- [When "A Helpful Assistant" Is Not Really Helpful (arXiv:2311.10054)](https://arxiv.org/abs/2311.10054) — 162 personas, 4 LLM families, 2410 questions
- [Expert Personas Improve LLM Alignment but Damage Accuracy — PRISM (arXiv:2603.18507)](https://arxiv.org/pdf/2603.18507)
- [When Does Persona Prompting Actually Help? (arXiv:2605.29420)](https://arxiv.org/pdf/2605.29420)
- [Why CrewAI's Manager-Worker Architecture Fails (Towards Data Science)](https://towardsdatascience.com/why-crewais-manager-worker-architecture-fails-and-how-to-fix-it/)
- CrewAI issues [#4783](https://github.com/crewAIInc/crewAI/issues/4783), [#2838](https://github.com/crewAIInc/crewAI/issues/2838)

**Confidence:** High on framework mechanics and defaults (read from source, not docs). High on the persona-skepticism evidence (multiple independent studies + a 1600-trace taxonomy). Medium on CrewAI hierarchical failure rates (community reports + one measured blog post, not a controlled study). Speculation marked **[inferred]**.

## The verdict up front

**Build the Role object — but it is a capability contract, not a persona.** The evidence is blunt: MAST annotated 1600+ real multi-agent traces and found "disobey role specification" causes **0.5%** of failures, while unaware-of-stopping-conditions (9.82%), step repetition (17.14%), disobey *task* specification (10.98%) and missing/incorrect verification (13.48%) dominate. Persona text is measurably near-worthless — arXiv:2311.10054 tested 162 personas across 4 model families and found no improvement over no persona at all, and automatic best-persona selection performed no better than random. CrewAI's own docs concede the point: "80% of your effort should go into designing tasks, and only 20% into defining agents." So the `role`/`goal`/`backstory` triple is a prompt template with delusions of grandeur — in CrewAI it literally expands to one templated sentence (`You are {role}. {backstory}\nYour personal goal is: {goal}`). AG2 reached the same conclusion the hard way and **deleted personas entirely in v1.0**: its `Agent` has no role/goal/backstory, just `name` + one freeform `prompt`, and its built-in subtask agent ships the persona-free prompt "You are a task agent. Complete the assigned task thoroughly and concisely. Return only the result." But the *reusable, versioned, per-project-overridable* wrapper the developer is asking for is still worth building — because the things that DO change behavior (tool allowlist, model choice, budget caps, output schema, stop conditions, delegation depth, escalation policy) are exactly the things you don't want to redefine per project. Build the container; put engineering in it, not prose.

## CrewAI

### Mechanisms that matter

**1. The Agent field set — 3 persona fields, ~30 machinery fields**

From `base_agent.py` + `agent/core.py` (defaults read from source):

| Field | Type | Default | Load-bearing? |
|---|---|---|---|
| `role` | `str` | required | **Yes — but as a routing key**, see #4 |
| `goal` | `str` | required | Prompt filler |
| `backstory` | `str` | required | Prompt filler |
| `llm` | `str \| LLM` | env `OPENAI_MODEL_NAME` | Yes |
| `tools` | `list[BaseTool]` | `None` | Yes |
| `function_calling_llm` | `Any \| None` | `None` | Yes |
| `max_iter` | `int` | `20` | Yes — loop cap |
| `max_rpm` | `int \| None` | `None` | Yes — rate cap |
| `max_execution_time` | `int \| None` | `None` | Yes — wall-clock cap |
| `max_tokens` | `int \| None` | `None` | Yes |
| `max_retry_limit` | `int` | `2` | Yes |
| `allow_delegation` | `bool` | `False` | Yes — injects delegation tools |
| `cache` | `bool` | `True` | Yes |
| `respect_context_window` | `bool` | `True` | Yes — auto-summarize on overflow |
| `guardrail` | `GuardrailType \| None` | `None` | **Yes — output validation** |
| `guardrail_max_retries` | `int` | `3` | Yes |
| `tool_failure_policy` | `ToolFailurePolicy \| None` | `None` | Yes |
| `reasoning` / `max_reasoning_attempts` | `bool` / `int \| None` | `False` / `None` | Yes — pre-plan step |
| `planning` / `planning_config` | `bool` / `PlanningConfig` | `False` / `None` | Yes |
| `allow_code_execution` / `code_execution_mode` | `bool` / `"safe"\|"unsafe"` | `False` / `"safe"` | Yes (both deprecated) |
| `knowledge_sources` / `embedder` / `knowledge_config` | — | `None` | Yes |
| `memory` (`Memory\|MemoryScope\|MemorySlice`) | discriminated | `None` | Yes |
| `mcps` | `list[str \| MCPServerConfig]` | `None` | Yes |
| `skills` | `list[Path \| Skill \| str]` | `None` | Yes |
| `from_repository` | `str \| None` | `None` | **Yes — the reuse hook**, see #5 |
| `a2a` | `A2AConfig \| ...` | `None` | Yes — remote delegation |
| `system_template` / `prompt_template` / `response_template` | `str \| None` | `None` | Prompt shaping |
| `use_system_prompt` | `bool \| None` | `True` | Prompt shaping |
| `multimodal` / `inject_date` / `date_format` | `bool`/`bool`/`str` | `False`/`False`/`"%Y-%m-%d"` | Minor |
| `verbose` / `step_callback` / `callbacks` | — | `False` / `None` | Observability |
| `security_config` | `SecurityConfig` | default | Yes |

The persona fields resolve to exactly one line. From `translations/en.json`, slice `role_playing`:

```
You are {role}. {backstory}
Your personal goal is: {goal}
```

That's the entire behavioral contribution of role+goal+backstory. Three required fields, one sentence.

**Verdict: ADAPT** — steal the machinery columns wholesale; collapse the three persona fields into one optional `prompt`.

**2. Crew vs Flow — the framework's own admission that autonomy underdelivers**

Crews are autonomous agent teams; Flows are event-driven, deterministic orchestration (`@start`, `@listen`, `@router`, `@persist`, `or_()`, `and_()`, structured Pydantic or dict state, `kickoff()`/`kickoff_async()`, `@human_feedback`). A Crew is stateless across runs and has no branching or error recovery at the orchestration level; Flows wrap Crews in an engine that owns execution order, state threading and persistence. The marketing framing is "collaborative intelligence of Crews with the precise control of Flows," but the operational reading is: **they shipped Crews, hit production, and had to add a deterministic layer to make it reliable.** Every serious CrewAI production guide now puts Flows on the outside and Crews on the inside — a controlled workflow first, agents operating within it.

This is the single most important architectural signal for sprout. AG2 made the identical move (v0.9 handoffs, v1.0 subagent tools). Two independent frameworks converged on "deterministic skeleton, autonomy in the leaves."

**Verdict: PORT the lesson.** sprout should be a deterministic orchestrator (typed task graph, explicit state, persistence, resumability) that spawns autonomous agents *as leaves*. Do not build a free-form agent conversation and hope it converges.

**3. Process types — `hierarchical` is the documented disaster area**

`Process.sequential` runs tasks in declared order, output chaining into `context`. `Process.hierarchical` requires either `manager_llm` (auto-builds a manager) or `manager_agent` (custom); the manager plans, delegates, reviews and validates, and task assignment is dynamic rather than pre-declared. The default manager persona ships in `en.json` as `hierarchical_manager_agent` ("Crew Manager" / "Manage the team to complete the task in the best way possible").

Docs list zero caveats. Reality does:
- Manager agents **cannot delegate to workers even with `allow_delegation=True`** (issue #4783).
- With `manager_agent` set, only the manager lands in `self.agents`; coworkers never register, so delegation lookups fail and the manager does the work itself (community report + issue #2838, "manager agent repeatedly performs tasks").
- Measured: auto-created manager on a single-domain query burned **38s and 15,759 tokens for a ~200-token output**, invoked an irrelevant agent, and let a later task's output overwrite the correct earlier one. A hand-written manager prompt with explicit step-by-step routing brought a technical-only query to 24s/10k tokens.

The fix that works is *removing* manager autonomy — spelling out "note category, conditionally call only required agents, synthesize, terminate."

**Verdict: SKIP.** Do not build an LLM manager that freely allocates work. sprout's parent should decide delegation via an explicit typed plan, not an unconstrained prose manager.

**4. Delegation routes on a natural-language string**

`allow_delegation=True` injects `DelegateWorkTool` and `AskQuestionTool`. Schema: `{task: str, context: str, coworker: str}`. Resolution in `base_agent_tools.py`:

```python
agent = [a for a in self.agents
         if self.sanitize_agent_name(a.role) == sanitized_name]
```

`sanitize_agent_name` lowercases, collapses whitespace, strips quotes. The source comment is an admission:

```python
# It is important to remove the quotes from the agent name.
# The reason we have to do this is because less-powerful LLM's
# have difficulty producing valid JSON.
```

`_get_coworker` additionally un-wraps `"[Researcher, Writer]"` by splitting on comma and taking the first element — i.e. papering over the LLM naming multiple agents.

What the delegate receives: a **freshly constructed `Task(description=task, agent=selected, expected_output=I18N.slice("manager_request"))`** plus `context`. No conversation history, and **no caller-specified success criterion** — `expected_output` is a canned generic string. What comes back: the raw string return of `execute_task`. No schema, no status, no cost accounting.

So: `role` IS load-bearing in CrewAI, but only accidentally — it doubles as the delegation address, which is why fuzzy string matching is needed at all.

**Verdict: ADAPT.** Keep task+context payload. **Replace prose-name routing with a stable `RoleId`.** Make `expected_output` caller-supplied and required. Return a structured result (status, value, error, usage), not a bare string.

**5. Reusability — `from_repository`, and it's Enterprise-only**

OSS CrewAI gives you `agents.yaml`/`tasks.yaml` (newer scaffolds use `crew.jsonc` + per-agent `agents/<name>.jsonc`), with `{placeholder}` interpolation from `kickoff(inputs=...)` into `role`, `goal`, `backstory`, `description`, `expected_output`, `output_file`. Binding is by **name-string matching** — `agents: ["researcher"]` must match `agents/researcher.jsonc`, and a task's `agent` must match an agent name. There is **no import, inheritance, or cross-project sharing mechanism in OSS.** Copy-paste is the sharing story.

Cross-project reuse exists only as **Agent Repositories, an Enterprise feature**: a centralized library storing complete agent configs (role, goal, tools, capabilities), loaded via `Agent(from_repository="market-research-agent")`. Field-level override works by merge — `agent/core.py` implements it as `load_agent_from_repository(from_repository) | v`, i.e. **repository dict first, local kwargs win**. So `Agent(from_repository="x", goal="...")` overrides just the goal.

This is precisely what the developer asked for, and CrewAI monetized it — which is decent evidence it's a real, wanted need, and also that nobody has solved it in the open. Note what the merge does *not* give you: no version pinning, no schema migration, no diffing, no local-first offline story.

**Verdict: PORT the shape (named library + shallow merge override), FIX the gaps** — sprout is machine-wide and single-binary, so a `~/.sprout/roles/*.yaml` library with a per-project override file gets Enterprise-tier capability for free. Add a `version` field CrewAI lacks.

**6. Task definition — where "done" actually lives**

`Task` fields that define completion: `description` (required), `expected_output` (required), `output_pydantic` / `output_json` / `response_model` (structured, validated), `output_file` + `create_directory`, `guardrail` (single) and `guardrails` (list, run sequentially, each feeding the next), `guardrail_max_retries: int = 3` (`max_retries` deprecated, removed in v1.0), `callback`, `markdown`, `human_input: bool`, `context: list[Task]`, `async_execution`, `tool_failure_policy`, `retry_count`, `start_time`/`end_time`.

Guardrails come in two flavors, and this is the good idea: a **function guardrail** takes `TaskOutput` and returns `(bool, Any)` — `(True, result)` or `(False, error_message)` — while a **string guardrail** is auto-wrapped into an `LLMGuardrail` using the agent's LLM (requires an assigned agent). Both can be mixed in one list. On failure the agent retries with the error message, up to `guardrail_max_retries`.

"Done" = agent produced output AND all guardrails returned `True`, within the retry budget. That's a real, checkable contract — unlike the persona fields.

**Verdict: PORT, and make it mandatory.** This is CrewAI's best idea. MAST puts 21.30% of all failures in task verification; a typed output + a cheap deterministic guardrail + a bounded retry directly attacks it.

## AG2

### Mechanisms that matter

**1. Agent identity — and the v1.0 amputation of persona**

v0.14 `ConversableAgent.__init__` (exact defaults from source):

```python
name: str
system_message: str | list | None = "You are a helpful AI Assistant."
is_termination_msg: Callable[[dict], bool] | None = None
max_consecutive_auto_reply: int | None = None   # falls back to MAX_CONSECUTIVE_AUTO_REPLY = 100
human_input_mode: Literal["ALWAYS","NEVER","TERMINATE"] = "TERMINATE"
function_map: dict[str, Callable] | None = None
code_execution_config: dict | Literal[False] = False
llm_config: LLMConfig | dict | Literal[False] | None = None
default_auto_reply: str | dict = ""
description: str | None = None
chat_messages: dict[Agent, list[dict]] | None = None
silent: bool | None = None
context_variables: ContextVariables | None = None
functions: list[Callable] | Callable = None
update_agent_state_before_reply: list[Callable|UpdateSystemMessage] | ... | None = None
handoffs: Handoffs | None = None
```

Note there is already no role/goal/backstory — just `system_message` (freeform persona) and `description` (**what other agents/the speaker-selector read to route to this agent** — load-bearing, distinct from the persona).

**v1.0 `Agent.__init__` dropped even that:**

```python
name: str
prompt: PromptType | Iterable[PromptType]
config: ModelConfig | None
hitl_hook: HumanHook | None
tools: Iterable[Callable | Tool]
middleware: Iterable[MiddlewareFactory]
observers: Iterable[Observer]
dependencies: dict | None
variables: dict | None
response_schema: type[TResult] | ResponseProto[TResult]
plugins: Iterable[Plugin]
knowledge: KnowledgeConfig | None
tasks: TaskConfig | Literal[False]
assembly: Iterable[AssemblyPolicy]
```

Every field except `prompt` is machinery. This is the strongest single piece of evidence in this document: the framework with the most multi-agent production mileage, on a clean-sheet v1.0 rewrite, kept **one** prose field and spent its entire API surface on tools, schema, budget, hooks and observability.

**Verdict: PORT the v1.0 field taxonomy almost literally.** It is the answer to "what should a Role contain."

**2. GroupChat speaker selection — the failure mode is in the source**

v0.14 `GroupChat` defaults: `max_round: int = 10`, `speaker_selection_method: "auto"|"manual"|"random"|"round_robin"|Callable = "auto"`, `max_retries_for_selecting_speaker: int = 2`, `allow_repeat_speaker: bool|list[Agent]|None = None` (coerced to `True` when no transition graph is set), `role_for_select_speaker_messages: str = "system"`, plus `allowed_or_disallowed_speaker_transitions` + `speaker_transitions_type` for an explicit transition graph (mutually exclusive with `allow_repeat_speaker`).

`"auto"` runs a hidden LLM "speaker select" agent. The class carries two dedicated re-query templates because that agent routinely fails:

- `select_speaker_auto_multiple_template` — "You provided more than one name in your text, please return just the name of the next speaker."
- `select_speaker_auto_none_template` — "You didn't choose a speaker."

A framework shipping two hard-coded retry prompts for its own router, plus a retry counter, is documenting that **LLM-chosen control flow is unreliable at a rate worth engineering around.** It also warns when the chat is "underpopulated."

**Verdict: SKIP `auto` speaker selection.** sprout must never ask an LLM "who goes next" over a shared transcript.

**3. Handoffs (v0.9+) — the deterministic replacement**

AG2 unified GroupChat and Swarm (Swarm now deprecated) into handoffs, split into: `OnCondition` (LLM-evaluated, e.g. `StringLLMCondition`), `OnContextCondition` (**evaluated on context variables, no LLM call**), and after-work. Targets: `AgentTarget`, `TerminateTarget`, `RevertToUserTarget`, `StayTarget`, `FunctionTarget`, `NestedChatTarget`. Set per-agent via `agent.handoffs.set_after_work(...)`, or pattern-wide via `group_after_work=...`; agent-level overrides pattern-level. Patterns: `AutoPattern`, `RoundRobinPattern`, `RandomPattern`, `ManualPattern`, `DefaultPattern`.

The ordering is the point: context conditions are checked before LLM conditions, so **deterministic routing pre-empts model judgement**, and after-work is a declared default rather than an emergent outcome.

**Verdict: PORT the tiering.** sprout routing should try (a) deterministic predicate on typed state, then (b) LLM judgement, then (c) a declared default that is usually `Terminate` or `EscalateToParent`.

**4. Human input modes and what `NEVER` really costs**

`ALWAYS` prompts every turn; `TERMINATE` (the **default**) prompts only when a termination condition fires; `NEVER` never prompts and relies entirely on termination conditions. AG2's own guidance is to develop with `ALWAYS`, and only move to `NEVER` "once confident with small-scale success."

The trap for an unattended harness: under `NEVER`, every human-shaped escape hatch closes and the *only* things that can stop the run are `is_termination_msg` and `max_consecutive_auto_reply` — whose fallback class constant is **100**. A hundred auto-replies at agent prices is a real bill. And `NEVER` converts "the agent needed to ask something" into silent drift — MAST's FM-2.2 *fail to ask for clarification* is **11.65%** of failures, the second-largest single mode.

**Verdict: ADAPT.** sprout is `NEVER` by construction, so it must compensate: a hard default budget (not 100), and an explicit *escalation* channel that queues a question and continues or parks rather than either blocking on a human or silently guessing.

**5. Termination**

Two mechanisms only: `is_termination_msg(msg) -> bool` (content predicate, commonly `msg["content"].rstrip().endswith("TERMINATE")`) and `max_consecutive_auto_reply` (counter per sender, checked as `self._consecutive_auto_reply_counter[recipient] >= recipient._max_consecutive_auto_reply`). GroupChat adds `max_round=10`. v1.0 targets add `TerminateTarget`.

Both classic mechanisms are weak: the content predicate is string-sniffing a model's prose, and the counter is a blunt cap that cannot distinguish "converged" from "stuck in a loop." MAST: *unaware of stopping conditions* 9.82%, *step repetition* 17.14%, *premature termination* 7.82%. **Roughly a third of all observed multi-agent failures are termination failures.** Stopping is the hardest problem in this space, and neither framework solves it well.

**Verdict: ADAPT — and over-invest here.** Terminate on *satisfied output schema + passed guardrail*, not on a magic string. Add loop detection (repeated tool-call signature / no state delta) for FM-1.3. Add budget caps on tokens, wall-clock and depth as backstops, all three.

**6. Nested chats — and v1.0's subagent tools, which are sprout's actual model**

`register_nested_chats(chat_queue, trigger=...)` gives an agent a private, sequential inner conversation that runs as a *reply function*: on trigger, the queue runs, each entry having `recipient`, `message` (string or `lambda sender, messages, config`), `max_turns`, `summary_method` (typically `"last_msg"`); each chat's summary feeds the next; the final summary becomes the outer agent's single reply. `trigger` gates activation and is the recursion guard — the docs' own example excludes internal agents from re-triggering.

v1.0 supersedes this with something cleaner and much closer to sprout. `subagent_tool(agent, *, description, name=None, stream=None, middleware=())` wraps an agent as a **tool** named `task_{agent.name}` with signature `(objective: str, context: str = "") -> str`, executing `run_task(...)` and returning a `TaskResult(task_id, objective, result, completed, stream, usage, error)`. Failure surfaces as text: `f"Sub-task '{agent.name}' failed: {result.error}"`. `background_agent_tool` is the fire-and-forget variant: returns `f"Background task started: {task_id}"` immediately, and on completion `parent_context.enqueue(...)` delivers the result to the parent LLM as a follow-up turn.

Three details worth stealing outright:

- **Fresh context by default.** `stream=None` → each delegation gets a new `MemoryStream`. Passing a shared `Stream` instance is explicitly flagged in the docstring: *"each delegation sees every earlier delegation's turns, and token cost grows with them."*
- **Per-call usage accounting.** The child's `UsageEvent`s stay on its private stream; the parent receives a single `UsageEvent(kind="subtask", label=agent_name)` rollup, so aggregation counts each delegation exactly once. `run_task` notes that concurrent delegations sharing one Stream cross-capture and cannot be attributed.
- **HITL bridging.** If the child has no `_hitl_hook`, `run_task` subscribes to `HumanInputRequest` on the child stream with `interrupt=True` and forwards it to the parent — a question raised at depth N propagates up rather than dying.

And the finding sprout must confront: **AG2 makes recursion structurally impossible.** `tasks=TaskConfig(...)` is opt-in (default `False`), and `_spawn_subtask` builds the child with `tasks=False`. From `TaskConfig`'s docstring:

> "Subtask Agents never receive the auto-injected `run_subtask` / `run_subtasks` tools, so **recursive delegation is structurally impossible — no depth limiting required.**"

`TaskConfig` is: `config: ModelConfig|None = None`, `prompt: str = "You are a task agent. Complete the assigned task thoroughly and concisely. Return only the result."`, `include_tools: Iterable[str]|None = None` (allowlist), `exclude_tools: Iterable[str] = ()` (blocklist), `extra_tools: Iterable[Callable|Tool] = ()`. Children inherit the parent's user-supplied tools filtered by that allow/block pair, never the auto-injected toolkit.

**Verdict: PORT the delegation-as-tool interface, the fresh-context default, the usage rollup and the HITL bridge. Consciously REJECT the depth-1 cap** — recursion is sprout's premise — **but replace it with an explicit, enforced `maxDepth` and per-subtree budget, since AG2 chose a hard cap precisely because unbounded recursion was not safely controllable.** [inferred: their choice reflects cost/loop risk, not a stated benchmark.]

## Evidence on whether personas/roles actually work

**Against — strong, direct, replicated:**

- **arXiv:2311.10054** — 162 personas × 6 relationship types × 8 expertise domains, 4 LLM families, 2410 factual questions. Finding: "adding personas in system prompts does not improve model performance across a range of questions compared to the control setting where no persona is added." Worse for anyone hoping to automate it: "while aggregating results from the best persona for each question significantly improves prediction accuracy, automatically identifying the best persona is challenging, with predictions often performing no better than random selection." So an oracle-selected persona helps, but no selector can find it — gains are circumstantial, not systematic.
- **MAST (arXiv:2503.13657)** — the strongest evidence, because it's observational on real systems rather than a prompt benchmark: 1600+ annotated traces across 7 frameworks including **AG2**. `FM-1.2 Disobey role specification` = **0.5%** of failures. Compare `FM-1.3 Step repetition` 17.14%, `FM-2.6 Reasoning-action mismatch` 13.98%, `FM-2.2 Fail to ask for clarification` 11.65%, `FM-1.1 Disobey task specification` 10.98%, `FM-1.5 Unaware of stopping conditions` 9.82%, `FM-3.1 Premature termination` 7.82%, `FM-3.2/3.3 verification` 13.48%. Category totals: Specification 41.77%, Inter-agent misalignment 36.94%, Task verification 21.30%. **Agents essentially never fail by breaking character. They fail by not stopping, not verifying, and not asking.**
- **arXiv:2603.18507 (PRISM)** — "Expert Personas Improve LLM Alignment but Damage Accuracy." Personas trade factual accuracy for value-alignment. For a coding harness this trade is strictly bad.
- **AG2 v1.0's API** — the strongest *revealed-preference* evidence. A clean-sheet rewrite removed persona structure entirely and shipped a deliberately flat default subtask prompt.
- **CrewAI's own docs** — "80% of your effort should go into designing tasks, and only 20% into defining agents… even perfectly-designed agents fail with poorly designed tasks, but well-designed tasks can elevate simple agents."

**For — weak:**

- CrewAI docs assert "Agents perform significantly better when given specialized roles rather than general ones" and prescribe "Technical Documentation Specialist" over "Writer". **No citation, no benchmark.** Treat as vendor guidance.
- **arXiv:2605.29420** finds persona prompting is context-dependent and helps in some domains — but specifically fails "where domain expertise isn't directly applicable or where the model already possesses sufficient capability." A frontier coding model on a coding task is exactly that exclusion.
- MAST's intervention experiments did get **+9.4%** success on ChatDev from improved role specification (and +15.6% from added verification) — the honest counterpoint. But the authors conclude "simple fixes are still insufficient," and note verification bought more than roles did.

**Honest read:** the evidence against persona *prose* improving task accuracy is consistent across a prompt benchmark, an observational trace taxonomy, and two independent framework redesigns. The evidence *for* is one uncited vendor claim and one context-dependent finding whose helpful conditions don't match sprout's workload. The MAST +9.4% is real but is best read as "role specification" ≈ clarifying scope and boundaries, which is a *contract*, not a backstory. Note also: nearly all persona research measures single-turn factual accuracy, not long-horizon agentic tool use — so this is inference by extension, and the specific claim "backstories don't help autonomous coding agents" is **[inferred]**, not directly measured.

## What a load-bearing Role should contain (recommendation for sprout)

Two tiers. Tier 1 must exist; Tier 2 should be one optional string, not three required ones.

### Tier 1 — changes behavior

| Field | Type | Default | Justified by |
|---|---|---|---|
| `id` | `RoleId` (stable slug) | required | CrewAI routes delegation by fuzzy-matched prose `role`, needing quote-stripping and list-unwrapping hacks. Never route on prose. |
| `version` | `SemVer` | required | Enterprise Agent Repositories offer no versioning; the developer explicitly wants "continuous updates/improvements per role" — that needs pinning + migration. |
| `description` | `String` | required | AG2 `description` / `subagent_tool(description=)` — this is what the *parent* reads to choose a delegate. The one piece of prose that is genuinely load-bearing. |
| `model` | `ModelConfig` | inherit parent | AG2 `config`, CrewAI `llm`. Cheap model for a scout, strong for an architect. |
| `tools.allow` / `tools.deny` | `Set<ToolId>` | allow=inherit | `TaskConfig.include_tools`/`exclude_tools`/`extra_tools`. The single biggest real behavior lever. |
| `outputSchema` | `Schema?` | `null` | CrewAI `output_pydantic`; AG2 `response_schema`. MAST FC3 = 21.30% of failures. |
| `guardrails` | `List<Guardrail>` (fn or LLM-string) | `[]` | CrewAI's best idea; sequential, each feeding the next. |
| `guardrailMaxRetries` | `int` | `3` | CrewAI default. |
| `budget.maxIterations` | `int` | `20` | CrewAI `max_iter=20`. Never AG2's 100. |
| `budget.maxTokens` / `maxCost` | `int?` / `Money?` | set a real default | 15,759 tokens for a 200-token answer is the measured downside. |
| `budget.maxWallClock` | `Duration?` | set a real default | CrewAI `max_execution_time`. |
| `delegation.enabled` | `bool` | `false` | CrewAI `allow_delegation=False`. Workers that can delegate produce infinite delegation loops. |
| `delegation.allowedRoles` | `Set<RoleId>?` | `null` | Turns the transition graph explicit (AG2 `allowed_or_disallowed_speaker_transitions`). |
| `delegation.maxDepth` | `int` | small, e.g. `3` | AG2 chose depth-1-by-construction. sprout needs recursion, so it needs an enforced counter instead. |
| `contextPolicy` | `fresh \| inherit` | `fresh` | AG2 default is a new `MemoryStream`; sharing state "grows token cost with every earlier delegation." |
| `stopConditions` | `List<Predicate>` | schema-satisfied | ~35% of MAST failures are termination-related. Do not string-sniff for "TERMINATE". |
| `loopDetection` | `on/off` | `on` | FM-1.3 step repetition, 17.14%, the largest single mode. |
| `escalation` | `EscalationPolicy` | `queueAndPark` | FM-2.2, 11.65%. Under maximum autonomy the ask-a-human path must exist and propagate up (AG2's HITL bridge). |
| `onFailure` | `retry \| escalate \| abort` | `escalate` | CrewAI `tool_failure_policy`, `max_retry_limit=2`. |

### Tier 2 — prompt flavor

| Field | Type | Default | Note |
|---|---|---|---|
| `prompt` | `String?` | `null` | **One** optional field. Not role+goal+backstory. AG2 v1.0 has exactly this. Its own default is persona-free: "You are a task agent. Complete the assigned task thoroughly and concisely. Return only the result." |

Explicitly **do not** add `goal` or `backstory`. CrewAI concatenates all three into one sentence anyway; three required fields buy nothing over one optional one, and requiring them makes every role definition longer for zero measured benefit — which is a terseness defect by sprout's own standard.

### Reuse model

`~/.sprout/roles/<id>@<version>.yaml` machine-wide, plus a per-project `sprout.yaml` that references roles and shallow-merges overrides — CrewAI's `load_agent_from_repository(name) | local_kwargs` semantics (library first, local wins), which is proven and one line. Add what CrewAI lacks: version pinning, `sprout roles diff`, and a lint that rejects a role whose Tier 1 is empty (i.e. a role that is *only* a persona — that's the abstraction not being worth it, caught mechanically).

## Anti-patterns

Specific to unattended autonomous runs:

1. **LLM-chosen control flow over a shared transcript.** AG2's `auto` selection ships two re-query templates and a retry counter for its own router. Uncoordinated multi-agent architectures amplify errors up to **17×**; centralized ones with validation bottlenecks hold it to ~**4.4×**.
2. **Prose as an addressing scheme.** CrewAI matches delegates by casefolded, quote-stripped, whitespace-collapsed `role`, with a hack to unwrap `"[A, B]"`. Renaming a role silently breaks routing.
3. **A manager agent with real autonomy.** Documented: managers that can't delegate (#4783), managers that do the work themselves (#2838), coworkers never registering in `self.agents`, later outputs overwriting correct earlier ones, 38s/15.7k tokens for a 200-token answer.
4. **Mutual delegation.** Multiple agents with `allow_delegation=True` pass work in cycles indefinitely. The community fix is `allow_delegation=False` on every worker — only one node may delegate.
5. **Counter-based termination as the primary stop.** `max_consecutive_auto_reply` fallback of **100** cannot tell "converged" from "looping," and `NEVER` removes the human backstop that made the default `TERMINATE` survivable.
6. **String-sniffing for termination.** `content.endswith("TERMINATE")` is a model behavior, not a guarantee.
7. **Delegating without a success criterion.** CrewAI's delegate gets a canned `expected_output`. An unattended run cannot afford "done" meaning "the model stopped typing."
8. **Shared context across sibling delegations.** Convenient, then quadratic: each delegation sees every prior one's turns, and concurrent delegations on one stream become unattributable for cost.
9. **Stateless orchestration.** A Crew remembers nothing between runs and has no orchestration-level error recovery. An hours-long unattended run that cannot resume from a checkpoint is a run that must restart from zero.
10. **Silent non-asking.** Under `NEVER`, "I should have asked" becomes a confident wrong guess — 11.65% of failures.

## Takeaways for sprout

1. **Build `Role`, but define it as a capability contract.** Tier 1 above. Reject any role definition that is only prose — lint it.
2. **One prose field (`prompt`), optional.** Not `role`+`goal`+`backstory`. Persona text is the least load-bearing thing in either framework, and three required strings violate terseness for no measured gain.
3. **`description` is the exception.** The prose the *parent* reads to pick a delegate genuinely affects routing. Invest there, not in backstory.
4. **Deterministic skeleton, autonomy in the leaves.** Both frameworks independently converged here (CrewAI Flows, AG2 handoffs + subagent tools). sprout = typed persisted task graph + autonomous leaves.
5. **Delegation is a typed tool call, not a conversation.** Steal `subagent_tool`: `(objective, context) -> TaskResult{taskId, result, completed, usage, error}`. Fresh context by default. No shared transcript.
6. **Never route on prose; route on `RoleId`.**
7. **Over-invest in stopping.** ~35% of observed failures. Terminate on satisfied schema + passed guardrail; add loop detection; make token/wall-clock/depth caps mandatory backstops, not optional.
8. **Ship guardrails on day one** — function and LLM-string, sequential, `maxRetries: 3`. Highest-leverage single import from CrewAI, and MAST says verification bought more than roles did (+15.6% vs +9.4%).
9. **Cap recursion explicitly.** AG2 made it structurally impossible; sprout can't, so `maxDepth` + per-subtree budget must be enforced in the runtime, not advisory.
10. **Roll up usage per delegation.** A single `subtask` usage event per child at the parent, so an hours-long tree has an attributable cost. Do not let concurrent siblings share a stream.
11. **Bridge escalation upward.** Copy the HITL interrupt bridge: a question at depth N reaches the top. Under maximum autonomy the default should be queue-and-park, never block and never silently guess.
12. **Machine-wide role library + shallow project override**, with the version field CrewAI's Enterprise product still lacks.
13. **No LLM manager allocating work.** Explicit typed plans only.

## Open questions

1. Does the persona-prompting evidence (single-turn factual QA) transfer to long-horizon agentic tool use? Nobody has measured it. sprout could — A/B the same Tier 1 with and without `prompt`.
2. Is `Role` distinct from `TaskSpec`, or the same object at different lifetimes? Tools/model/budget are role-ish; schema/guardrails/stop conditions are task-ish, and CrewAI splits them across `Agent` and `Task` with real duplication (`guardrail` and `guardrail_max_retries` exist on *both*). Possibly one type with defaults at the role layer.
3. What is the right `maxDepth` default? AG2 says 1, CrewAI is unbounded and loops. No data in between.
4. Do roles need capability *negotiation* (a role declares required tools; the runtime refuses to instantiate it where they're absent) or is a static allowlist enough?
5. Semver on a prompt: what counts as a breaking change to a role — schema change only, or a `prompt` edit that shifts behavior? What does `sprout roles diff` actually diff?
6. Does the 0.5% role-disobedience figure hold at high delegation depth, or is it low because MAST's traces were mostly shallow? [inferred: likely shallow; unverified.]
7. Should `escalation` wake the developer at all, or always park? "Consulted almost never" needs an operational threshold.
