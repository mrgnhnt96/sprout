# sprout — Vision

**Status:** draft, pre-research. Written before any research so the research has something to
argue with. Nothing here is committed to; the plan doc supersedes it where they disagree.

---

## 1. The one-sentence version

> Give sprout a task with minimal explanation, walk away, come back in a few hours, and find it
> either done or visibly in progress — with a web UI that shows every agent, from the top-level
> down to the deepest nested one, and what each is doing right now.

---

## 2. The problems being solved

These are the actual complaints driving the project, stated as problems rather than features.

**P1 — Deviation.** Agents drift off-target. The task at minute 90 is not the task that was
given at minute 0, and nobody noticed the turn.

**P2 — Noise.** Long recaps, intermixed signals, and narration make it hard to answer the only
two questions that matter: *what is happening now* and *what is next*. Verbosity is a defect,
not a style preference.

**P3 — Interruption.** The developer is consulted far too often, for decisions the AI is
usually right about. Consultation should be the rare exception, requested explicitly
(e.g. "check with me on the design"), not the default posture.

**P4 — Blindness.** With nested delegation there is no way to see the shape of the work.
Which agent is stuck? What was decided three levels down and why?

**P5 — No steering wheel.** When something *has* taken a wrong turn, there is no way to say so
to the top-level agent and have that correction propagate down to the subordinates already
working under the old assumption.

**P6 — Friction.** Per-repo installation, per-repo config, per-repo role definitions. Anything
that must be maintained in N places will rot in N places.

---

## 3. What sprout is

A single compiled Dart binary, machine-wide, that:

1. **Takes a task** ("fix the flaky checkout test", "add dark mode to settings") with minimal
   explanation.
2. **Decomposes it** into a tree of work, assigning each node a **role** from a shared, editable
   team definition.
3. **Runs real agent sessions** (Claude Code sessions, not simulated sub-personas) recursively —
   an agent may itself decompose and delegate.
4. **Streams what is happening** into a local daemon via hooks, so the state is observed rather
   than self-reported.
5. **Serves a web UI** showing the whole tree live: every node, its role, its current task, how
   long it has been on it, and when it will next check in.
6. **Escalates only what was pre-declared as escalation-worthy**, records the question *and the
   decision it made anyway*, and keeps going.
7. **Accepts a correction from the developer at any level** and propagates it down to the
   subordinates that need it.
8. **Reports once, at the end**, short.

## 4. What sprout is not

- Not a logging or tracing product. Traces are a debugging affordance, not the interface.
- Not a chat UI. The UI is a *board*, not a transcript. You read state, not conversation.
- Not a per-repo harness. It is installed once per machine; repos may add config, never
  installation.
- Not a replacement for local skills, tools, or MCPs — it **drives** the ones already installed.
- Not an approval queue. If sprout is asking, something has gone wrong with its priors.

---

## 5. Design principles

**Autonomy is the default; consultation is opt-in.** The developer declares up front which
decisions need them (`--consult design`), and everything else the agent decides and records.
A recorded decision the developer can later disagree with beats a blocking question.

**Terse or it didn't happen.** Every surface — CLI output, UI cards, the final report — is
budgeted. A status line is a line. The final report fits on a screen. Recaps are banned; the
UI is the recap.

**Observed, not narrated.** State comes from hooks firing on real tool calls and real session
lifecycle events. An agent claiming it is 80% done is not evidence. What it actually ran is.

**One definition, everywhere.** Roles, teams, and policies live in one machine-wide place and
are edited once. Projects override, never redefine.

**Recursive but bounded.** Delegation is recursive by design, with hard limits on depth,
fan-out, and budget, because unbounded recursion is how an autonomous system burns a night.

**Fast, reliable, simple.** A single compiled binary. No runtime toolchain, no service to babysit,
no cloud dependency. Starting sprout should feel like running `ls`.

---

## 6. The core concepts (first draft — research will revise these)

**Task** — what the developer gave sprout. The root of everything.

**Node** — one unit of work in the tree. Has a role, a brief, a state, a parent, and children.
A node maps to a real agent session when it is being worked.

**Role** — a reusable definition of *how to see a task*: a system prompt, an allowed toolset,
an escalation policy, and a definition of done. Roles are machine-wide.

**Team** — a named set of roles that work together (e.g. `dart-feature`: architect → implementer
→ reviewer → verifier). Teams are how a task gets staffed without the developer choosing roles.

**Brief** — the self-contained instruction a node hands its child. It must stand alone; a child
never sees its parent's conversation.

**Heartbeat** — a periodic, structured, one-line self-report from every live node:
`current task | since | next check-in`. This is what the UI renders. It is emitted mechanically,
not composed by the agent.

**Decision** — a fork the node took on its own, recorded with the question, the options, the
choice, and the reason. Marked `notable` when it crosses the threshold the developer set. The
UI's "questions I decided for you" feed is a list of these.

**Steer** — a message the developer sends to any node, which that node applies and propagates
to the subordinates it affects. The one interactive path in the system.

**Report** — the terminal artifact. Short. What was asked, what was done, what was decided,
what was left.

---

## 7. Architecture sketch (to be validated by research)

```
  sprout CLI  ──────────────┐
  (task entry, status)      │
                            ▼
              ┌──────────────────────────┐        ┌──────────────────┐
              │   sproutd  (Revali)      │◀──────▶│  Zonai store     │
              │   - task graph           │        │  tasks, nodes,   │
              │   - scheduler / budgets  │        │  decisions,      │
              │   - hook ingest endpoint │        │  heartbeats      │
              │   - SSE/WS event stream  │        └──────────────────┘
              └────────┬────────┬────────┘
                       │        │
             spawns    │        │  serves
                       ▼        ▼
     ┌──────────────────────┐   ┌────────────────────────┐
     │ agent sessions       │   │  web UI (Jaspr)        │
     │ (recursive; each     │   │  live tree, heartbeats,│
     │  reports via hooks)  │   │  decisions, steer box  │
     └──────────────────────┘   └────────────────────────┘
```

**Stack (given):** Dart everywhere. Revali for the daemon, Zonai for persistence, Jaspr for the
web UI, compiled to a single binary.

---

## 8. Open questions research must answer

1. **Delegation model.** ReDel distinguishes delegation schemes (delegate-and-wait vs.
   delegate-and-continue). Which fits an unattended overnight run, and does the choice need to
   be per-role?
2. **Recursion control.** What actually stops runaway recursion in the prior art — depth caps,
   token budgets, a root-level supervisor, or something better?
3. **State & resumability.** LangGraph's checkpointing exists because agents die mid-run. What
   is the minimum checkpoint that lets a killed node resume without redoing work?
4. **Human-in-the-loop.** LangGraph's `interrupt`/resume is the closest prior art to *steer*.
   What does it get right, and can it be made non-blocking?
5. **Roles.** CrewAI and AG2 both do roles. Is a role worth being a first-class persisted object,
   or is it a prompt template with delusions of grandeur? What is the actual reuse win?
6. **Observability.** ReDel ships a web visualization of a recursive run. What does it show that
   we would not have thought to show?
7. **Hooks.** Exactly which Claude Code hook events give us the state the UI needs, and what is
   the cheapest way to get a heartbeat without the agent having to remember to emit one?
8. **Prior art on this machine.** showrunner (leaf graph, waves, worktrees, reconcile/integrate)
   and game_loop (write guard, claim gate, verify gate, mandate, watchdog) already solve real
   parts of this. What should sprout absorb, and what should it deliberately leave alone?
9. **The Dart stack.** Can Revali + Zonai + Jaspr actually compile into one binary with the web
   UI embedded? What are the sharp edges?

---

## 9. Success criteria

sprout is working when:

- A task can be given in one sentence and finished without a single question.
- The developer can open the UI cold and know, in under ten seconds, what is happening and
  whether it is on track.
- A wrong turn can be corrected with one message, without restarting anything.
- The final report is read in full, because it is short enough to read in full.
- Nothing had to be installed in the repo for any of this to work.
