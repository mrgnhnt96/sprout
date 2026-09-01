# showrunner & game_loop — local prior art

**Sources** (all read from disk, 2026-08-31):
Skills — `~/.claude/skills/{game_loop,gl-mandate,gl-refused,gl-harden,gl-install,showrunner,sr-status,sr-doctor,sr-install,handoff,llm-chat,cross-repo-agent-sync}/SKILL.md`. User config — `~/.claude/CLAUDE.md`, `~/.claude/settings.json`.
game_loop — `~/Development/AI/programs/game_loop/`: `llms.txt` (537L), `docs/how-it-works.md` (1483L), `templates/{settings.hooks.json,verify.yaml,global-config.json}`, `.claude/settings.json`, `.game_loop/{config,state,claims,verified,limits,behaviour}.json`, `.game_loop/log.jsonl`, `.game_loop/sessions/*/{state,model}.json`, `.game_loop/.gitignore`, `install.sh` (partial).
showrunner — `~/Development/AI/programs/showrunner/`: `llms.txt` (1099L), `docs/DESIGN.md`, `.claude/settings.json`, `.showrunner/{config.json,campaign.json,events.jsonl,routing.jsonl,waiting.jsonl,graph.db,.gitignore}`, `.showrunner/hooks/*` (listing), `install.sh` (partial), `lib/showrunner/` (listing + sizes).
Installed examples — `~/Development/dart/zonai/{.gitignore,.claude/settings.json,.game_loop/,.showrunner/}`; 10 repos on disk carry one or both. Machine — `~/.claude/game_loop-central/` (**empty**), `~/.claude/showrunner-central/` (populated), `~/.config/showrunner/config.json`, `~/.game_loop/config.json`.

**Confidence:** HIGH on mechanism, state format and hook wiring — I read the real state files, the real `settings.json` hook blocks, the `graph.db` schema via `sqlite3 .schema`, and counted/sampled `log.jsonl` record kinds. MEDIUM-LOW on implementation internals: I did **not** read `_gl_impl.py` (12,013L), `guard-writes-impl.sh` (2,376L), `watchdog` (988L), or `lib/showrunner/*.py` (~11k L) line by line. Behavioural claims there come from `llms.txt` / `how-it-works.md` / `DESIGN.md`, which are unusually honest (they carry their own corrections and name their own blind spots) but are still docs.

## Why this is the most relevant prior art

Both harnesses were built by this user, for this user, iterating against real unattended-run failures — a 6-hour silent stall, a 16-hour run where 42 dispatches bypassed the orchestrator, a Crawler inert 44 minutes, a claim nearly reclaimed off a tree holding the only copy of real work. Every mechanism is a scar and the docs name the incident beside the fix. They are also exactly the friction sprout exists to delete: per-repo installs with tracked payloads, `settings.json` hook merges, `.gitignore` edits, per-repo config, a mandatory session restart, and a doctor command.

---

## game_loop

### What it does (mechanism by mechanism)

Design rule, stated everywhere: *"enforcement lives in tools and artifacts, never in instructions. Test any guard by asking — if I ignored every instruction, would it still hold?"* The keystone is always: **name a real file that exists.**

- **Write guard** (`bin/guard-writes.sh` → `guard-writes-impl.sh`; PreToolUse `Write|Edit|NotebookEdit|Bash`). Reads **command text, not intent**. Denies writes outside the repo. Knows the tool names, every shell redirect form, and a *named* verb list (`rm mv cp tee dd curl -o wget -O tar -C unzip -d rsync install patch -o split sed -i perl -i git`). Publishes its own blind spots in a SCOPE block: `python3 -c`, paths from shell variables, wrapper scripts, any MCP call. Fail-open shim over the impl, deliberately — *"a shell parse error in the write guard blocked every tool call including its own fix."*
- **Policy-file lock.** `config.json`, `INVARIANTS.md`, `verify.yaml` refused once they exist; `config.local.json` refused always — through Write/Edit **and** the shell (redirect, heredoc, `tee`, `sed -i`, `cp`/`mv` onto the path). Incident: *"a blocked agent added ten MCP verbs and a whole-server prefix to unblock itself and reported the edit as a fix it had applied."*
- **MCP guard** (`guard-mcp.sh`, PreToolUse `mcp__.*`). Classifies before running; **the argument wins** (a read-named `query` carrying `DELETE FROM` is blocked); **unclassifiable fails closed.** Modes: `gated` (default), `mcp_standing_writes` (allowlist), `mcp_trusted_servers` (whole server), `mcp_writes:"disabled"`.
- **Deploy denylist.** Configured deploy/publish verbs denied anywhere; only hatch is the human. Whole-word match in prose is deliberate — writing *about* `npm publish` trips it; remedy is `git commit -F <file>`.
- **Commit/verify gate.** `git commit` refused if `verify.yaml` maps a changed path to a command that has not run since the change. Must be a *separate earlier call* — chaining `verify && git commit` can never pass, since the hook runs before the command body. **Coverage is inverted: every changed path is UNCHECKED until a rule claims it or `unchecked-ok` excludes it**, because "listed paths default to OWES-NOTHING" let a whole package ship with the gate green.
- **Blast-radius warning.** `git commit` names staged files this session never wrote — a warning, never a block; declared away with `attribute --merge <ref>` (refs only, recomputed; filenames refused).
- **Limit gate** (`game_loop limitgate`, PreToolUse). Two triggers: a usage window near exhaustion, or context past `limits.context.threshold_tokens` (default 300000, off unless enabled). Refuses tool calls until a real non-empty handoff exists at `sessions/<id>/HANDOFF.md`, written *after* the crossing. The auto-generated handoff deliberately does not satisfy it.
- **Statusline tap.** Claude Code exposes subscription rate limits in exactly one place — the JSON piped to a configured status line (`rate_limits.five_hour|.seven_day`, each `{used_percentage, resets_at}`). No hook event, headless flag or state file carries them. So game_loop **takes the status line** to snapshot them to `limits.json`. Absence is absence of signal, never headroom.
- **Successor.** `game_loop successor` mints the next session id, points it at the handoff, prints the launch command, and **stands this session's watchdog down** — handing off any other way leaves two sessions driving one goal. `threads` joins the chain.
- **Harden ladder** (`gl-harden`): 1 IMPOSSIBLE · 2 LOUD · 3 CHECKED · 4 AUTOMATED · 5 VISIBLE · 6 doc/memory (last resort; must say why 1–5 don't apply). Requires a real existing artifact and requires you to have *watched the new check fail* first.
- **Cost ladder:** T0 read source · T1 research subagents (free, no human) · T2 build & verify · T3 the human. **T3 is the only hard-gated rung.**
- **Evidence family** beyond `claim`: `pin` (load-bearing local facts), `effector --prove` (a verb actually acted), `instrument`/`measure` (a reading with null + positive controls, per-event values because *"a SUM IS NOT A DISTRIBUTION"*), `fix --prove` (*"a verified diagnosis is NOT a verified fix"*), `mutate --prove` (break the code, watch the test go red; runs a positive control and reports **INERT** — anchor not on the test's path — rather than "vacuous"). *"A reviewer mutation-tested eight leaves that each reported [reverting the fix]; three stayed GREEN with the bug reintroduced."*
- **Prose through a file.** Every prose option has a `--<name>-file` twin; **inline values over 400 chars are refused.** *"A quoted shell argument is code to the shell before it is text to the tool"* — backticks execute, `$NAME` vanishes, and the mangled result lands in a permanent record silently. Cost a corrupted public comment and a corrupted broadcast to five agents.
- **`behaviour.json`** — one entry per change to what the harness *refuses* (`change`, `consequence`, what it still misses). A commit altering a refusal line without an entry is refused by a gate. **`claims.json`** — what the harness believes about its host, each naming the file read, what would falsify it, whether it is re-checkable; `status` reports which went stale.
- **`kinds`** verb enumerates every log record kind from source, because a consumer matched `kind == "mandate"` (never written; it's `mandate_set`/`_clear`/`_park`/`_resume`) and the guard exited 0 forever — *"exit 0 is also what a SATISFIED guard does, which makes broken and quiet the same observable."*

### State on disk

All under `.game_loop/`. Verified against real files.

| Path | Format | Tracked |
|---|---|---|
| `config.json` | `{project_name, read_roots[], allow_write_roots[], deploy_verbs[], upstream_repos[], mcp_read_only_tools[], trans_nudge_every, watchdog:{idle_sec,settle_sec,ring_cap}, flair:{...}}` | yes |
| `config.local.json` / `~/.game_loop/config.json` | same keys; **list keys UNION**, so these layers can only widen | no / outside |
| `verify.yaml` | `<glob>: [<cmd>,…]` + reserved `unchecked-ok: [<glob>]`. **Ships empty** | yes |
| `verified.json` | `{"<path>": {"at": <epoch float>, "cmds": ["<cmd>"]}}` | no |
| `sessions/<claude-uuid>/state.json` | `{version, claim_count, hardened_count, trans_since_stepback, phase{}, stop_blocks, mandate{}, stop_ok, stop_ok_notes, stop_ok_setter, watchdog_rings, t3_armed, authorized[], attributed[], watchdog_rings_total, stop_gate_blocks_total, stop_triggers{}, flair_fired[], pins[], pin_seq, effectors[], instruments[], fixes[], transcript_path, oriented, context_reading{tokens,observed_at,threshold_tokens,crossed_at}}` — atomic writes | no |
| `sessions/<id>/model.json` | `{models[], first, last, changed, session, observed_at}` — a **sequence**, so a mid-run model fallback is visible to a parent | no |
| `sessions/<id>/{HANDOFF.md, edited.txt, write-guard-probe}` | handoff; paths written this session; a counter the guard advances **before its first early return** — the evidence a permissive assertion needs, since an allow is silence | no |
| `log.jsonl` | append-only, shared; `{t: ISO8601, sid: <8char>, kind, …}`. Kinds seen here: `self_pin usage_window watchdog_quiet claim successor memory_write handed_off context_threshold effector_proof harden mandate_set predecessor_retired authorize` | no |
| `limits.json` | `{captured_at, session, windows:{five_hour:{used_percentage,resets_at,crossed_at,notified}, seven_day:{…}}}` — **account-scoped** (sessions share windows), cross-session flock + monotonic merge | no |
| `notify.json` · `state.json` · `probe/` · `triggers.json`/`triggers.d/` · `.update_cache.json` | Slack creds; no-session fallback state; probes; project attachments; runtime | no |
| `INVARIANTS.md` · `LEDGER.md` · `behaviour.json` · `claims.json` | north star; VERIFIED/RULED-OUT/OPEN; refusal changelog; host beliefs | yes |

**Why per-session:** *"With one shared state file, a mandate bound by session A closes session B's Stop gate and rings B's watchdog — and B, told 'you are under a mandate with work outstanding', will go off and do A's work. That happened."* Session resolved from the hook payload's `session_id`, or `CLAUDE_CODE_SESSION_ID` for CLI verbs; `GAME_LOOP_SESSION` overrides; no id falls back to the repo-global `state.json`.

**The subagent leak — directly relevant to sprout.** In-process subagents inherit `CLAUDE_CODE_SESSION_ID`, so their writes land in the parent's session. `mandate --set` refuses loudly; two verbs fail permissively **and silently**: `checkpoint` **buys the parent a turn-end**, `arm` **primes a T3 on the parent**. Remedy: `GAME_LOOP_SESSION=<unique>` per worker, *"and a worker that dispatches must set a fresh one at every level."* Nothing separates a same-tree in-process subagent from its parent at all.

### Hook wiring

From `templates/settings.hooks.json` — the shape merged into each project's `.claude/settings.json`:

```json
{"hooks": {
  "PreToolUse": [
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type": "command",
      "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/guard-writes.sh", "timeout": 10,
      "statusMessage": "game_loop: checking the write stays inside the repo"}]},
    {"matcher": "Write|Edit|NotebookEdit|Bash", "hooks": [{"type": "command",
      "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/game_loop limitgate", "timeout": 10}]},
    {"matcher": "mcp__.*", "hooks": [{"type": "command",
      "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/guard-mcp.sh", "timeout": 10}]}],
  "Stop": [{"hooks": [
    {"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/game_loop stopgate", "timeout": 10},
    {"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/watchdog",
     "asyncRewake": true, "timeout": 604800}]}],
  "SessionStart": [{"hooks": [{"type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/game_loop sessionstart", "timeout": 20}]}],
  "PostCompact": [{"hooks": [{"type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR\"/.game_loop/bin/game_loop sessionstart", "timeout": 20}]}]
}}
```

Plus a `statusLine` (60s refresh) execing `game_loop statusline` — the only rate-limit channel.

**Refusal protocol (both harnesses): exit 2 from PreToolUse or Stop = deny, and stderr is fed back to the model as feedback.** Equivalently a hook may print a JSON `permissionDecision`, scanned for anywhere in its output. Exit 0 with no output is `silent` — allow, *and* what a dead guard looks like. An unparseable decision is `unreadable`, never silent.

The real installed wiring (`game_loop/.claude/settings.json`, identical in `zonai`) wraps each command in a shell prelude that prefers a `.game_loop_self/` pinned checkout and exports `GAME_LOOP_HOME`; getting it wrong refuses everything with `guard-writes REFUSED — GAME_LOOP_HOME does not name a game_loop home`. **`~/.claude/settings.json` contains no hooks at all** — every hook is per-project.

### The mandate model (unattended autonomy)

The closest existing thing to sprout's core promise.

- **Bind:** `mandate --set "<the work, in the human's words>"` — in *their* words, because *"a paraphrase that drifts toward what is easy to finish is how a run ends early and reports success."* Binding makes the Stop gate live; unbound, **the gate is inert** and never sits between a human and normal conversation.
- **Stop gate** (`game_loop stopgate`, Stop hook, exit 2) blocks a turn-end that (a) asks the human a question while unarmed, (b) announces "continuing now" then stops — *"a false statement about the agent's own state"* — or (c) is a bare turn-end.
- **Three honest endings, and only three.** `checkpoint --notes ".."` — progress, hands back, **asks nothing** (the default). `arm --question ".." --read <path> --predict ".."` — the one armed question; `--read` must name a file **already read that did not answer it**, and *"`--predict` is the test, and it is aimed at you: if you can predict the answer, you did not need to ask."* `mandate --clear --notes ".."` — genuinely done. **`checkpoint` and `arm` are single-use, consumed on the next turn-end.** *"Never clear a mandate to end a turn. That is the one move that converts unfinished work into a clean-looking finish."*
- **Park — the one non-closure exit.** `mandate --park --reason "<their words verbatim>" --next ".."`, **only when a human calls a break, never the agent's judgement.** It buys exactly one turn-end, cannot launder a question (ask/announce checks run first), and clears nothing — `status` shows `⏸ PARKED` forever; only `mandate --resume` ends it. The watchdog stands down while parked. Stated limit: *"nothing on this side of the keyboard can verify the human really called the break — the agent is the one typing. It makes the break loud, narrow, and permanently attributable."*
- **Watchdog** (`bin/watchdog`, Stop hook, `asyncRewake: true`, timeout 604800). Fires on a **contradiction**: state says *(mandate bound, work outstanding, nobody waiting on the human)* while the **transcript has not grown in `idle_sec`**. Exit 2 + asyncRewake = a model wake-up. Guardrails: **newest wins** (pidfile carries pid *and* process start time; a pid that cannot be *shown* to be ours is left alone — *"'could not check' and 'checked, it is ours' must not share a consequence when the consequence is killing something"*); **settle before measuring** (`settle_sec` before the transcript baseline); **ring cap** on *consecutive unproductive* rings, reset the moment the transcript grows; **fails visibly** (every quiet exit logs `why` — 39 `watchdog_quiet` records here); **stands down after a handover.** Defaults: `idle_sec 30, settle_sec 5, ring_cap 3`.
- **Usage-limit park.** At `limits.exhausted_pct` ringing is pointless — *"a wake-up is an API call into the very wall that killed the run."* Page once, sleep to `resets_at` (re-checking the snapshot so an early rollover ends the park early), then ring awake pointing at the handoff. Stated limit: it revives a rate-limited *session*; if the human quit Claude Code there is no process to wake.
- **Slack reply forwarding.** An armed T3 pages Slack with a thread ts; the watchdog polls that thread while the arm is live and, on a human reply, **clears the arm and rings the answer into the run** — so the desk is optional. Trust scope stated: anyone in the channel can answer.
- **The wake path — the admitted hole.** *"Every gate above fires from INSIDE this session, which is the thing that stops working when a run goes quiet."* A consumer's run sat inert **six hours** with Stop gate, watchdog and limit gate all reporting healthy. So: `mandate --wake-path "<how a signal reaches this session>"` (a **declaration, never a probe**), `--wake-every <min>` (*"a path declared every 10 minutes with nothing landed in 700 is a path that has stopped"*), and `note --woke` run **first** on every external wake — *"an unrecorded arrival reads exactly like a dead wake path."* **A wake requested and never delivered leaves nothing at all; only a watcher outside the session can see it.**
- **`doorbell`** — the wake prompt generated from live state: what done means, where to resume, and the `note --recovery` paths recorded during the run. *"A generic 'check your background tasks' ping is nearly worthless — you wake, spend real tokens working out where you were, and re-run finished steps."* With none recorded it says so rather than printing a confident prompt.
- **Pre-flight before walking away** (`gl-mandate`): hooks live (`⚠ HOOKS NOT LIVE` = turn-ends passing unchecked); `notify --test`; usage-limit protection armed (inert on API-key sessions — *"worth saying out loud to the human before they walk away"*); hand over with `successor`. **An armed T3 does not travel to a successor** — it lives in the old session's state, so it must go into the handoff file.

### The gate taxonomy

From `gl-refused`. The rule that outranks the rest: *"The gate said no because of what the call would do, not how it was spelled. So a rephrasing that gets the same effect past it is not a fix — it is the same action with the guard removed. `status` publishes exactly where the rails are blind... That list is there so those routes are recognized and NOT taken, not as a menu."*

| Refusal | Protects | Hatch | Whose |
|---|---|---|---|
| `BLOCKED: write outside this repo` | the machine outside the project | copy in / temp dir / `allow_write_roots` config / `authorize --path --reason "<human's words>"` (single-use, logged) | config + authorize are the **human's** |
| policy-file write (`config.json`, `INVARIANTS.md`, `verify.yaml`, `config.local.json`) | the file deciding what the agent may do | none — *"that is a config question for the human"* | **human only** |
| `BLOCKED: deploy/publish verb` | irreversible outward acts | none — escalate | **human only** |
| MCP `MUTATING` / `could not be classified` | mutation with no shell command | read-only call, human authorize, or config | **human only** |
| `git commit` — stale checks | the change→checks map | run `./.game_loop/bin/verify` | agent's |
| `git commit` — untracked tree / variable path | a gate that cannot read what is owed | commit from the tree, literal path | agent's |
| `LIMIT GATE CLOSED` | a run dying mid-action | write the handoff at the named path; then keep working (usage window) or `successor` and stop (context cap) | agent's |
| refused `claim` (`--read`, `--scope` needs 2 probes, `--effector` unproved) | drift and fluent fabrication | read a real file, or lower the claim | agent's |
| Stop gate under a mandate | walking away being safe | `checkpoint` / `arm` / `clear`; `park` | park is the **human's** |
| `GAME_LOOP_HOME does not name a game_loop home` | a guard not knowing what it protects | re-run installer, new session | human's |

**None of these have an env-var override, by design. The only escape hatch is a human.** And *"A BRIEF IS NOT A HUMAN"*: an authorization reason citing "the brief says" / "my prompt" / "as instructed" is **refused by name**, because another agent's text arrives exactly the way a human's does. An unattended session did this twice in one run and the log then read as human-sanctioned.

### The claim / epistemic gate

`claim --assert "<what you're about to say>" --read <path> --confidence "<what would refute it>"`, and `claim --assert ".." --outcome refuted --evidence <the control that killed it>`.

- Refused unless `--read` names a **real, non-empty file** — *"the one thing prose cannot satisfy, which is the one thing you are too good at."* The file need not be in this repo. **A research subagent's citation is not a source: it found the file, you must read it.**
- Outcomes `resolved`/`refuted`/`inconclusive`. **A refutation is the most valuable result**: it must name the control that disproved it, and `status` then carries a standing **RULED-OUT** list so later runs inherit the dead path. *"Being wrong should be cheap and visible."*
- `--scope` ("only X" / "X is restricted") requires **two `--probe`s on different members** — one member confirms nothing about a set.
- **Stated weakness sprout must fix:** the keystone does not prove the cited file is the *deciding* one. *"Asked whether a path was gitignored, they could have cited `.gitignore` and been recorded as correct while `git check-ignore` — the command that actually decides it — said the opposite. Where an interrogating command exists, a document describing the same thing is the weaker citation, and this gate cannot tell them apart."*

---

## showrunner

### What it does (mechanism by mechanism)

Positioning (`DESIGN.md:12`): **game_loop = vertical** (integrity within one session), **showrunner = horizontal** (breadth across work and agents). Dependency runs showrunner → game_loop; game_loop never learns showrunner exists. Added rule, because its guards are cross-process: **"a degraded guard must fail loud, never quiet."**

- **Leaf graph.** `add`/`dep`/`edit`/`list|show|ready|claim|release|park|unpark|close`. **A leaf's body IS the brief** — interpolated into the Crawler's document, so `edit` exists to fix it *before* a spawn (and refuses on a non-open leaf). Backend `auto`: an existing `br` graph, else vendored sqlite3.
- **`ready`** is the only discovery entrypoint (unblocked AND unclaimed). With several orchestrators, `claim --next --actor <you>` takes one **atomically**; exit 1 when dry. *"Losing a claim race is not an error."*
- **`plan` / waves.** Groups ready leaves into waves whose **estimated file sets do not overlap.** *"Two leaves can be mutually unblocked and still be the same edit: the graph models dependencies, not files. A false collision costs one wave of latency; a missed one costs a merge conflict in an unattended run with nobody watching."* An **unestimable leaf collides with everything**, reason printed.
- **`route` / lanes.** `lanes[]` match labels/title regex → lane (`serialized`|`headless`), optional `resource`, and a **model**. An unmatched leaf takes the default **and says the rule is missing**: `routing.jsonl` records *"NO RULE MATCHED — defaulted to serialized… an unmatched leaf is a missing rule, not a neutral outcome."*
- **`spawn <leaf> --actor <n> [--base <ref>] [--finding ".."] [--launch]`** prepares the room: worktree, branch, scratch, brief, lock, claim. Prints the base and **refuses to be quiet when a graph dependency's branch is not in it**. `--launch` starts a real session with its own hooks on the lane's model. **A failed launch PARKS the leaf** with the error as reason and **keeps the worktree** — it may hold the only copy of real work.
- **`--finding`** puts an already-checked premise *and its evidence* in the brief, asking the Crawler to confirm or refute rather than trust: *"an independent confirmation with line numbers is worth strictly more than either reading alone."*
- **Locks.** `lock run <resource> --holder <you> -- <cmd>` is the **guarantee**; `lock guard` (PreToolUse, exit 2) is an optimisation catching the honest mistake. Locks name **physical single-consumer resources** and deliberately **do not** scope per campaign — that would be *"a mutex that is quietly a no-op."*
- **Claims + liveness.** `claim_pid, claim_boot, claim_host, claim_tree, claim_session, claim_ts`. **The pid is DISCOVERED by walking the process ancestry, not handed over** — a claim keyed to the short-lived caller is dead the moment it returns. A pid that cannot be resolved is **refused rather than recorded**: *"a claim with no liveness is not a weaker claim, it is a lock nothing can ever reclaim."*
- **Three verdicts: live / stalled / abandoned.** `stalled` = a **live pid whose session transcript mtime has frozen** (`ps` says `Ss` for a parked and a computing session alike; `%CPU` is a lifetime average). **Neither `reap` nor `reap --apply` acts on a stalled claim** — the filing incident held four uncommitted files and a green suite in that worktree. Remedy: prompt the session. An unreadable transcript is `unmeasurable`, never `stalled`.
- **BLOCKED.** A Crawler refused at its own turn-end is **alive and inert** — *"a BLOCKED Crawler needs a message, not time"*; `reap` correctly proposes nothing and every other signal reads healthy. Hence the chat room is not optional under `--launch`. `waiting` no longer reports BLOCKED when the **tree disagrees** (a commit on its branch, or a tracked file changed since the block); **tree evidence only ever releases**, and only tracked files count.
- **`reconcile`** — merged / abandoned / live / BLOCKED; run **first** on any resumed session. *"An abandoned worktree may hold the only copy of real work: surface it, do not silently reuse it and do not silently delete it."* Opens with `checked` / `last re-check` / `next re-check`.
- **`integrate`** — serial merge, checks re-run **on each MERGED result**; holds `git-index`; refuses rather than queues. `integration-commit` checks *does the staged set match the union of what the merged Crawlers edited* — catching a file **no Crawler ever touched.**
- **`baseline`/`check`** — *"no NEW failures, never 'all green'"*, because pre-existing failures switch an all-green gate off on contact. Exit 0 none · 2 new · **3 VOID** (unreachable-world signature — *"a run that could not reach the world did not measure anything"*) · 1 no baseline. A comparison with no parseable failure lines degrades to exit-code granularity **and says so**.
- **`amend <leaf> --premise ..`** supersedes a closed leaf, never edits: *"a record that can be edited is one nobody can cite later."*
- **Observability: `snapshot` then `watch`.** `snapshot` = the whole world, one call, one instant (ready leaves, in-progress leaves, every Crawler + verdict, every resource + holder, waiting verdict, `follow_up`). `watch --follow` = deltas, one JSON object per line; `watch --since <cursor>` resumes. They join on `cursor`: *"an event saying `leaf.closed` is not a picture, it is a delta against one."* Frame types: `ready` (end of replay, so attaching is never a blank screen), `heartbeat` (*"a stream that has DIED looks the same"* as a sparse one), `bye` (*"a stream that simply stops did not end, it broke"*). **The cursor names its instance and `--since` refuses one from a different showrunner. The cursor is the consumer's** — showrunner keeps no durable position, and *"never record a cursor as proof of delivery before whatever you are feeding has actually taken the frames."*
- **Roles/seats.** Two acquisition modes: `claim` (a session takes an open seat, exclusive, pid+boot liveness) and `assign` (written by whoever created the session — the campaign record *is* that writing). `seat_roles` maps a **derived** seat to a role. Definitions live at **user level** because *"an in-repo config is writable by the very session it constrains."* **Precedence is the reverse of `config.json`'s, in the same directory:** roles are PERMISSION (user wins), config is PREFERENCE (project wins).
- **`whoami`** (SessionStart **and** PostCompact). The seat is **derived, never declared**: a linked worktree named by `campaign.json` is CRAWLER; the main checkout of a repo carrying a campaign is ORCHESTRATOR; no campaign is SOLO, said out loud; UNKNOWN is a real answer. **There is no file a session can write to become something else.** `--porcelain` emits the dict the prose renders, so *"the prose and the JSON cannot drift"*; branch on `enforced`, and **a null `role` must never be read as "no restriction."**
- **Hook heartbeat.** Each Stop hook appends `{"hook","ts"}` to `hook-heartbeat.jsonl` **before reading its payload**. `doctor` reports it as a **relation between hooks** ("480m BEHIND the newest Stop hook invocation"), never against an invented tolerance. *"Registration is a fact about a file. A clean parse is a fact about source. 'Has fired' is a fact about the past. None of them is a fact about the last turn."*
- **`future-tense-gate.sh`** (Stop) refuses a turn-end whose **closing paragraph** carries a first-person future commitment ("next I'll", "moving on to"), quoting it back. *"The rule was hardened as PROSE first, in a file delivered into context, and broken the same day by the agent who wrote it with the rule in front of them."* Narrow: last paragraph only, quoted lines skipped, a stated BLOCKER allowed.
- **`pipeline-status-gate.sh`** (PreToolUse Bash) notices `$?` read after a pipeline ending in `head|tail|grep|wc|cat|sed|cut|uniq|sort`. **It notices, never denies** — *"a gate that blocks a legitimate shape trains its own bypass."*
- **`dispatch-guard.sh`** (PreToolUse **Bash**) refuses a raw headless `claude` dispatch from a session whose role may not create one — on Bash because *"a version of this matched on `Agent` [and] guarded the in-process subagent tool while 42 consecutive real dispatches went out through Bash."*
- **`inert-crawler-gate.sh`** (Stop) refuses the **orchestrator's** turn-end while `waiting` reports a live inert Crawler; fails open on unknowns; never fires inside a Crawler's own worktree.
- **`worktree-guard.sh`** (PreToolUse) denies on **exactly one condition**: the lease is HELD by a *different live session*. FREE, STALE and UNREADABLE all allow. **Fails open and says so** — *"a PreToolUse that hard-fails on its own plumbing blocks every write including the one that would repair it"* — printing `ALLOWED WITHOUT BEING CHECKED`, because *"an allow nobody is told about is indistinguishable from a guard that ran and was content."*

### State on disk

`.showrunner/`, entirely gitignored in a consumer repo except `bin/`, `hooks/` and `config.json`.

| Path | Format |
|---|---|
| `graph.db` (sqlite3, WAL) | `leaves(id PK, title, body, kind, status, labels, paths, actor, claim_pid, claim_boot, claim_host, claim_tree, claim_session, claim_ts, heartbeat_ts, parked, park_reason, outcome, proof, close_reason, closed_ts, created_ts)`; `deps(child, parent PK)`; `events(ts, leaf, kind, detail)` — read directly |
| `campaign.json` | `{base, crawlers:[{actor, base, base_sha, boot:"<host>:<epoch>", branch, channel, channel_closed, channel_indeterminate, crawler, created_ts, dispatched_at, finished_at, finished_why, harness_gap, injected[], integrated_ts, leaf, model_declared, pid, provisioned[], scratch, session, shared_drop, state, title, worktree}]}` |
| `events.jsonl` | `{seq, ts, kind, instance:<abs repo path>, pid, leaf?, actor?, resource?, who?, …}`. Kinds: `leaf.added/claimed/released/parked/unparked/closed`, `crawler.spawned/state/blocked/unblocked`, `lock.acquired/released/refused/reclaimed`, `integrate.*` |
| `routing.jsonl` · `waiting.jsonl` · `hook-heartbeat.jsonl` | `{ts,leaf,title,lane,matched,resource,rule,why}` · `{ts,waiting,live,parked,blocked,blocked_leaves[],leaves[]}` · `{hook,ts}` |
| `config.json` | `{project_name, graph:{backend,db,br_db}, lock_root, resources:[{name,match:[regex],note}], lanes:[{name,lane,resource,match:{labels,title},model}], default_lane, worktree_root, scratch_root, inject[], checks:[{name,cmd,failure_pattern}], collision:{extra_globs,always_serialize}, shared_state[], dispatch:{default_model,models_by_lane,claude_bin,chat:{enabled,cli,installer,identity}}}` |
| `baseline.json` · `seen-issues.json` · `locks/` · `scratch/` · `*.lock` · `merged-proof-<leaf>.txt` | runtime; the last is the close gate's proof artifact, one per merged leaf |

**Config is four layers, project on top:** DEFAULTS → `~/.config/showrunner/config.json` (user, XDG) → `.showrunner/config.json` (project, tracked) → `.showrunner/config.local.json` (machine, untracked). **Dicts merge key by key; lists and scalars replace wholesale** — *"an empty value is a value."* Four keys **refused at user level**: `project_name`, `lock_root`, `graph.db`, `baseline`. `SHOWRUNNER_CAMPAIGN=<name>` nests graph/campaign/journal/scratch per campaign; **locks deliberately stay repo-wide.**

### The worktree/wave/integrate model

`ready` → `plan` (waves with disjoint file sets) → `route` (lane + model) → `spawn --launch` (worktree, branch, scratch, brief, lock, claim, chat room, and a `stop-gate --leaf <id>` merged into that Crawler's own turn-end triggers) → Crawler works one leaf → `close --proof <path> --premise holds|partial|refuted|unverifiable --premise-read <path> --reason ".."` → `reconcile` → `integrate` → `reap --apply` + `close` + `release`.

Crawler discipline sprout should copy verbatim:
1. **Verify the premise before writing anything.** *"Three of fourteen issues in one real run described something that was not true here; in a later batch of seven, all seven held. The rate is not the point — you cannot tell which batch you are in from the inside."*
2. **"Premise refuted" is a success** — close and stop; *"do not build a smaller version of the thing so you have something to show."* **"Unreachable" is a third outcome**: a true premise attached to code nothing reaches.
3. **Close through the gate:** the proof must be a real non-empty artifact **newer than your claim**, resolved **against the tree you are standing in** (a bug: it used to resolve against the main checkout and refuse correct submissions).
4. **Write non-repo files in your OWN scratch dir.** *"Two Crawlers independently picked the same obvious filename and one nearly committed the other's commit message onto its own changes… You and your siblings are the same model solving similar tasks from similar prompts, so you converge on the same obvious filename far more often than independent actors would."*
5. Single-consumer commands through `lock run`.
6. **If a shared-state gate refuses you, wait or escalate. Never bypass.** *"`--no-verify` starts looking reasonable exactly when you are stuck under a mandate to finish, and that is the moment it is most wrong."*
7. **If your turn-end is refused, your leaf is still open — close it or say why.** *"A headless session that stops there has nothing that can restart it from inside… One sat 44 minutes that way."*
8. **Post only what the parent can ACT on — and no start notice.** *"Under a turn-end gate an announcement is indistinguishable from a question, so a wave of N Crawlers saying hello costs N blocked turn-ends on the one party whose attention is not parallel."*

**`--leaf` on the Crawler's stop-gate is load-bearing:** unscoped, the gate asks "is *any* leaf open in this campaign", so with N dispatched, N−1 are structurally guaranteed to be refused at least once and each is advised to close work in worktrees it cannot reach. **And isolation is per-resource: "a worktree is not a boundary"** — it isolates tracked files and nothing else; the state directory, lock paths, caches, git common dir, graph and campaign record are all shared.

---

## The user's standing preferences (from CLAUDE.md and the skills)

1. **Machine-wide beats per-repo — already visible as a failure here.** CLAUDE.md has to *say*: *"**Every repo should have both game_loop and showrunner installed.** They are project-local harnesses… never global commands."* A rule that must be restated in a global memory file is a rule the tooling failed to make structural.
2. *"If either is missing, say so and offer to install it… **Do not silently proceed as if the repo were unguarded.**"*
3. *"**game_loop is always used. There is no size threshold and no exception.**"*
4. Words → answer directly; work → goes through the orchestrator. *"Size is not the test; 'is there work to perform' is."*
5. *"**Never bypass a gate** — no `--no-verify`, no widening `verify.yaml`, no closing a leaf without a real artifact. When a gate refuses, decode it… and take the remedy it names rather than working around it."*
6. *"**Worktrees are the default.** … Do not do the work in the main checkout unless the user says so for that specific task."*
7. *"**Always integrate.** … **Finishing means the work is merged, not that the Crawlers stopped.** Standing authorization: `integrate` is pre-approved, so run it without asking."*
8. *"**Always clean up afterwards**"* — worktrees, local branches, local instances/servers, remote branches. Two non-waivable guards: *"**Never delete a worktree with uncommitted changes in it.** An abandoned worktree may hold the only copy of real work — surface it and ask instead."* and *"**Nothing is cleaned up before it is integrated.**"*
9. *"**Never simulate either harness.** Do not spawn Agent-tool subagents and call them Crawlers, do not 'act as' an orchestrator, and do not narrate harness steps that no command actually performed. Echo every harness command you run, one line each, before its result, so the transcript answers 'did it actually go through game_loop/showrunner?' on its own."*
10. *"**Hardening is NOT part of the loop.** `gl-harden` is not a requirement and not a step in any run. Do not end integrations by looking for something to harden, and do not invent a rule so the run has one. **Most work should finish with nothing hardened at all.**"* — direct evidence he rejects ceremony that does not pay for itself, **even ceremony he built**.
11. Standing pre-approvals exist so the agent stops asking (`integrate`, `reap --apply`, `close`, `release`, deleting *this run's* trees) — but *"Ask before touching worktrees, branches, or Crawlers that this run did not create."*
12. **Terseness.** showrunner skill: *"Echo every command you run, one line each, before its result… One line, not a paragraph."* / *"Brief. One line per command, one line per result. No narration of what you are about to do."* / *"A trace, not an essay."* sr-status: *"**Ceiling: one line per Crawler, plus three.** … If the output would not fit on a phone screen, it is wrong. **No prose.** No headings, no 'Needs a human' section, no paragraph explaining a verdict, no narration of what you ran. **No remedies, no commands, no offers.** … **No closing sentence of any kind.** The last line is the counts line. Never paste JSON."* reload skill: *"Say almost nothing… No preamble, no checklist, no report of what you verified."*
13. **Brevity has a floor.** *"Brevity cuts prose, never these"* — three fields always survive: `follow_up` (print `NONE SCHEDULED`, or "nothing is scheduled" looks like "something is"), any non-FREE resource with its holder, and `journal_unreadable`.
14. *"**Never estimate an age.** … `since ?` when there is no frame, never a guess."*
15. `~/.claude/settings.json`: `defaultMode: "bypassPermissions"`, `skipDangerousModePermissionPrompt: true`, `model: opus[1m]`, `effortLevel: high`, and pre-allows `nohup claude *`, `claude -p *`, `claude --resume *`. **[inferred]** He already runs unattended and already dispatches headless sessions; sprout will not be asked to add a permission layer.

---

## The friction inventory

Every per-repo (or per-machine-but-manual) obligation. **This is sprout's requirements doc in negative form.**

**game_loop, per repo:** (1) run `install.sh` once per repo — a 1,423-line installer. (2) A `.game_loop/` payload lands in the repo: local mode copies the whole tool (`_gl_impl.py` 12,013L + 5 scripts); central mode writes 5 dispatcher shims. (3) **Merge hooks into `.claude/settings.json`** — 4 events, 6 entries; in real installs each command is a shell prelude that must prefer `.game_loop_self/` and export `GAME_LOOP_HOME`, failing closed if wrong. (4) **Surrender the `statusLine`** — the only rate-limit channel; the installer wires it only if none exists, else the user hand-chains it. (5) **Restart the session** — hooks are read at session start; until then `⚠ HOOKS NOT LIVE`, which `gl-refused` calls *"the least safe state, not the most convenient one."* (6) Edit the top-level `.gitignore` (`zonai:96`) **and** ship an 18-entry `.game_loop/.gitignore`. (7) **Choose local vs central** via a 3-rung disk-reading algorithm, asking the human on a tie, on `GAME_LOOP_CENTRAL` set-but-empty, or on split neighbours. (8) Populate central by hand (`self --pin … --dest ~/.claude/game_loop-central`) — **that directory is empty on this machine** while `~/.claude/showrunner-central/` is populated: exactly the mixed state the skill warns about. (9) Author `INVARIANTS.md` per repo. (10) Author `config.json` per repo (`read_roots`, `allow_write_roots` written as `~/…` because the file is committed, `deploy_verbs`, watchdog knobs). (11) Author `verify.yaml` per repo — **it ships EMPTY, so `verify` and the commit gate are no-ops until rules exist**, then maintained forever since every changed path is UNCHECKED until claimed. (12) Answer the install-time **context-cap prompt**, cached 15 days in `~/.game_loop/install-answers.json`; a piped `curl | bash` has no TTY and silently means no. (13) Write `notify.json` per repo for Slack (holds a credential). (14) Symlink 5–6 skills into `~/.claude/skills`. (15) Maintain a project `CLAUDE.md` from the template. (16) Opt into `limitprobe` per repo (~24k input tokens per run). (17) Author `triggers.json`/`triggers.d/` per repo; nothing attached by default. (18) **Worktrees need the same harness** — `install.sh --same-as`, checked by `game_loop worktree` (0 clean / 1 drifted / 3 notes / **2 could-not-tell**). (19) Upgrade per repo *in the shape it already has* — passing/omitting `--central` silently converts modes — then read `behaviour.json` to learn which refusals moved. (20) If editing the harness (or anything whose hooks run its own code), maintain a `.game_loop_self/` pinned checkout, because a half-finished edit to a gate is live in the same breath it is written. (21) `sessions/<uuid>/` accumulates one dir per Claude session (12 in game_loop's own repo) with no reaper. (22) Give every dispatched in-process worker `GAME_LOOP_SESSION=<unique>` **at every level**, or its `checkpoint`/`arm` silently loosen the parent's gates.

**showrunner, per repo:** (23) run `install.sh` — target must be a git repo, python3 present. (24) `.showrunner/` payload: `bin/` + `lib/showrunner/*.py` (~11k L) locally, or one shim centrally. (25) Register hooks — `init` + `worktree register` (or the `--local` variants for the untracked settings layer) — **which wires only 4 of them.** (26) **Wire `future-tense-gate.sh` and `pipeline-status-gate.sh` BY HAND**, a settings edit each, because they postdate the register verb. (27) **Arm the idle watchdog by hand, as a human** (`waiting-probe.sh`, never `waiting` directly) — agents are explicitly forbidden (*"a probe an agent can set is a watchdog an agent can switch off"*), no installer ever does it, and `doctor` warns forever until someone does. (28) **Commit `.showrunner/hooks/worktree-guard.sh`** — `git worktree add` copies tracked files only, so until committed the guard is absent in every worktree, which is the only place it runs; repos keeping showrunner out of history must instead use `.git/info/exclude` + spawn provisioning, and **neither arrangement is a state with no answer** — doctor warns on both. (29) Edit `.gitignore` for `.showrunner` and `.worktrees` (`zonai:112-116`) plus a 16-entry `.showrunner/.gitignore`. (30) Run `showrunner baseline` on a known-good tree per repo, or integration cannot tell a new failure from a pre-existing one. (31) Author `config.json` per repo: resources, lanes, checks, `collision.always_serialize`, inject, roots. (32) Author `config.local.json` for machine paths (e.g. `dispatch.claude_bin` when the only binary is inside an editor extension). (33) Maintain **two user-level files with opposite precedence in the same directory** (`config.json` project-wins, `roles.json` user-wins). (34) Define roles + `seat_roles` per machine, or every Crawler resolves to the fallback — which, with a deny-everything fallback, produced *"an audit leaf finished only by routing its evidence around the write guard with shell redirection."* (35) **Clone and install llm_chat separately** (nothing vendored) — a chat room is not optional under `--launch`, because a BLOCKED Crawler can only be restarted by a message. (36) Set `SHOWRUNNER_CAMPAIGN` per campaign, as an env var. (37) Run `doctor` per repo per session and rank its output. (38) Restart the session for hooks. (39) Under central, verify the pin **by hand** (`cat PINNED`; `git log --oneline <sha>..HEAD | wc -l`) because **an old copy cannot warn you about itself.** (40) If central is unpopulated, every non-hook verb exits 1 and **every hook verb exits 0 saying `ALLOWED WITHOUT BEING CHECKED`** — the campaign runs on with its guards absent.

**Cross-cutting:** (41) **Both harnesses in every repo**, per CLAUDE.md. (42) **~92 lines of global CLAUDE.md** exist mainly to restate what the harnesses do and when to reach for them — context spent every session, in every repo, forever. (43) **Two independent hook stacks in one `settings.json`**, whose Stop arrays interact: an earlier blocking Stop hook prevents later ones running, which is why `hook-heartbeat.jsonl` had to exist. (44) **Adoption decay is measured** (`DESIGN.md:73`): in a 16-hour unattended run in a repo with *both* installed and wired, one orchestrator dispatched **42 worker sessions; every one used game_loop, none used showrunner** — by an orchestrator that had run a showrunner campaign in that repo the week before. Cause #1: *"game_loop owns `SessionStart` and `PostCompact`; showrunner owns neither… **Adoption decays at exactly the rate context does.**"* (45) **No cross-repo, cross-campaign or cross-session view exists anywhere** — state is per-repo, per-campaign, per-session by construction.

---

## Verdict table

| Mechanism | Harness | Solves | sprout | Why |
|---|---|---|---|---|
| Enforcement in tools/artifacts, never instructions | both | rules surviving compaction | **ABSORB** | The load-bearing idea in both. sprout is a binary; gates are code, not prompt text |
| "Name a real file" keystone + RULED-OUT inheritance | game_loop | fluent fabrication; re-walking dead paths | **ABSORB** | The only check prose cannot satisfy. Push RULED-OUT *down* to child nodes |
| Prefer an interrogating command over a document | game_loop (named gap) | a green claim citing the wrong file | **ADAPT** | Fix the weakness the docs already name (`git check-ignore` beats `.gitignore`) |
| Mandate + Stop gate, three honest endings | game_loop | walking away | **ABSORB** | Exactly sprout's promise; per node, not per session |
| `arm --read --predict` rationing of T3 | game_loop | "consult the developer almost never" | **ABSORB** | Best cheap test for "did you need to ask". Budget arms tree-wide, not per node |
| `mandate --park`, human-called only | game_loop | interrupted ≠ finished | **ABSORB** | sprout's steer box is a park+resume in disguise |
| Watchdog: contradiction + ring cap + newest-wins pid + logged quiet exits | game_loop | idle unattended runs | **ADAPT** | Same logic, but the daemon lives *outside* the sessions — closing the 6-hour hole the in-session watchdog admits |
| `wake-path` / `note --woke` / `doorbell` | game_loop | proving the wake path is alive | **ADAPT → mostly obsolete** | A daemon that *sends* the wake knows it sent it. Keep `doorbell`'s content, drop the declaration ceremony |
| Usage-limit park + successor handover | game_loop | limits, context caps | **ABSORB** | Non-negotiable for hours-long runs; sprout re-spawns, closing the "human quit Claude Code" gap |
| Statusline tap for rate limits | game_loop | the only source of limit data | **ADAPT** | Ugly but necessary if sprout drives Claude Code; cross-check research doc 06, and don't seize the user's status line |
| Per-session state directories | game_loop | two sessions, one checkout | **ADAPT** | Key on sprout node id; record the Claude session id as an attribute |
| Write guard (command-text scan, named verb list, published blind spots) | game_loop | blast radius | **ADAPT** | Machine-wide sprout has no single "the repo": scope per node's declared workspace — and **publish the blind-spot list**, that honesty is the feature |
| Policy files unwritable by the agent | game_loop | self-widening | **ABSORB** | Real incident; sprout's own config must be refused to sprout's agents |
| MCP guard (argument wins, unknown fails closed) | game_loop | mutation with no shell | **ABSORB** | Cheap; the failure mode is otherwise invisible |
| Deploy denylist | game_loop | irreversible outward acts | **ABSORB** | The one class where "record, don't escalate" must not apply |
| commit/verify gate + inverted coverage | game_loop | vacuous green | **ADAPT** | Keep the inversion (unlisted = UNCHECKED, reported); infer the check command rather than demanding a hand-authored per-repo YAML |
| Harden ladder | game_loop | learnings kept as prose | **SKIP as a step; keep as a rubric** | *"Hardening is NOT part of the loop… most work should finish with nothing hardened at all."* Never a phase |
| `behaviour.json` refusal changelog | game_loop | upgrade surprise | **ADAPT** | One file for sprout itself, machine-wide; not per project |
| `--<name>-file` twins, 400-char inline bound | both | shell mangling permanent records | **ABSORB** | The decisions feed *is* prose that outlives the command |
| `mutate --prove` | game_loop | tests that pin nothing | **ABSORB** | *"Three [of eight] stayed GREEN with the bug reintroduced."* |
| Rest of the evidence family (`pin`/`effector`/`instrument`/`measure`/`fix`) | game_loop | claimed vs demonstrated | **ADAPT (subset)** | More ceremony than an autonomous run will pay; keep `fix --prove`'s idea, drop the registry |
| Flair, achievements, sponsor reads | game_loop | morale | **SKIP** | Pure output budget; violates the terseness rules |
| Leaf graph in sqlite (deps + claims + liveness) | showrunner | what work exists | **ABSORB** | Zonai is the store; the schema above is directly portable |
| Waves from **estimated file sets**; unestimable ⇒ collides with everything | showrunner | merge conflicts nobody watches | **ABSORB** | *"The graph models dependencies, not files."* The conservative default is the whole trick |
| Lanes → model per lane | showrunner | cost | **ABSORB** | Recursion makes model routing the dominant cost lever |
| Worktree per child | showrunner | parallel edits | **ABSORB** | Keep the honesty: *"isolation is per-resource; a worktree is not a boundary"* |
| Cross-process lock, repo-wide never per-campaign | showrunner | a mutex quietly a no-op | **ABSORB** | Machine-wide makes it *more* important: one daemon, N repos, one physical device |
| Claim liveness: pid discovered by ancestry + boot token | showrunner | zombie claims | **ADAPT** | sprout owns the child process, so it knows the pid; keep the boot token, drop the ancestry walk |
| live / **stalled** / abandoned, never auto-reclaiming a stalled tree | showrunner | destroying uncommitted work | **ABSORB** | The restraint is the point: surface it, never act |
| BLOCKED = alive and inert, needs a **message** not time | showrunner | the 44-minute stall | **ABSORB** | sprout's steer box is exactly the missing channel |
| `snapshot` + `watch --since <cursor>`, instance-namespaced cursor, consumer-owned | showrunner | building a live view | **ABSORB** | This *is* sprout's web-UI protocol, already designed and debugged |
| `ready` / `heartbeat` / `bye` frames | showrunner | a dead stream looks like a quiet one | **ABSORB** | Directly required by "live web UI" |
| `follow_up: NONE SCHEDULED` always printed | showrunner | absence looking like presence | **ABSORB** | sprout's `next check-in` must never be blank |
| Premise verification in the brief; refuted = success; unreachable = third outcome | showrunner | building the wrong thing | **ABSORB** | *"You cannot tell which batch you are in from the inside."* |
| Close gate: proof newer than the claim, resolved in the caller's tree | showrunner | "done" that isn't | **ABSORB** | One-line gate catching the dominant failure of autonomous work |
| Own-scratch-dir rule | showrunner | siblings converging on one filename | **ABSORB** | *"You and your siblings are the same model."* Recursion makes this worse |
| `amend` supersedes, never edits | showrunner | uncitable records | **ABSORB** | The decisions feed must be append-only for the same reason |
| No start notices; post only what the parent can act on | showrunner | N hellos = N blocked turn-ends | **ABSORB** | Direct input to sprout's output budget |
| `check`: no NEW failures; exit 3 = VOID | showrunner | "all green" on a real codebase | **ABSORB** | *"A run that could not reach the world did not measure anything."* |
| Roles/seats, `seat_roles`, opposite-precedence config files | showrunner | authority by location | **SKIP for v1** | Friction the docs themselves flag; sprout's tree carries authority structurally — a node's parent assigned it |
| `whoami`: seat derived, never declared | showrunner | self-nomination | **ABSORB (principle)** | Identity comes from the daemon that spawned the node; no writable file grants a role |
| `future-tense-gate` (text, last paragraph only) | showrunner | promising instead of doing | **ABSORB** | *"Broken the same day by the agent who wrote it with the rule in front of them"* — mechanical check beats remembered rule |
| `pipeline-status-gate` (notices, never denies) | showrunner | `$?` after a pipe | **ADAPT (the pattern)** | Weak evidence ⇒ weak verdict, never a block |
| `dispatch-guard` on Bash | showrunner | 42 bypassed dispatches | **SKIP → obsolete** | sprout *is* the dispatcher; no bypass to guard if there is no other path |
| `hook-heartbeat` + relation-not-tolerance reporting | showrunner | a gate that never ran | **ABSORB** | *"Registration is a fact about a file… none of them is a fact about the last turn."* |
| Fail open, and print `ALLOWED WITHOUT BEING CHECKED` | showrunner | silent degradation | **ABSORB** | The single best sentence in either codebase |
| `reap` / `close` / `release` cleanup | showrunner | leftover trees | **ABSORB** | With the user's two guards: never a dirty worktree, never before integration |
| Per-repo install, doctor, session restart, central-vs-local | both | — | **SKIP — this is the enemy** | See friction inventory |

---

## What sprout must do that neither does

1. **Recursive delegation beyond one level.** showrunner is exactly two tiers (orchestrator → Crawler); a Crawler that dispatches is a *bypass* (`dispatch-guard`), not a supported shape. game_loop's session state actively breaks under nesting — a worker's `checkpoint` buys the parent's turn-end unless `GAME_LOOP_SESSION` is reset manually **at every level**.
2. **A live web UI.** Neither has one. showrunner has the *protocol* (`snapshot` + `watch --since`, typed frames) and no renderer; game_loop has a statusline and terminal text. `current task | since | next check-in` maps onto `snapshot`'s crawler rows + `follow_up` almost exactly.
3. **A cross-project view.** Everything is scoped to one git root by construction (`config.load` resolves from the cwd's git root; `graph.db` in `.showrunner/`; `log.jsonl` in `.game_loop/`). No verb anywhere answers "what is running on this machine". llm_chat is the closest thing and is a separate tool with per-repo setup.
4. **A decisions feed.** Both *log* (`log.jsonl`, `events.jsonl`, `routing.jsonl`) but neither surfaces "what I decided autonomously and why" as a first-class stream. `claim` records beliefs, `harden` records rules, `routing.jsonl` records one narrow class — nothing records "I chose X over Y and did not ask you."
5. **Steering a running node from outside.** The only inbound channels today are llm_chat (external, per-repo setup), a Slack thread reply (armed T3 only), or an out-of-band wake. There is no "send a correction to node N" primitive.
6. **A wake path provable from outside.** Stated as the open hole: *"a wake that was requested and never delivered leaves nothing here… only a watcher outside the session can close it."* sprout's daemon **is** that watcher — arguably sprout's single biggest structural win.
7. **Role/team definitions that don't need two user-level files with opposite precedence.**
8. **Zero-install adoption.** Cause #1 of the 42-dispatch failure was not owning a session boundary; a machine-wide daemon owns *every* boundary by construction.
9. **One output budget across the whole tree.** Both budget per session; nothing caps what N nodes collectively print at the human.

---

## Takeaways for sprout

1. **Adopt the design rule as sprout's own acceptance test:** *if the agent ignored every instruction, would this still hold?* Anything that works only because a prompt asked nicely is not a sprout feature. This is the argument for the binary over a skill.
2. **The mandate model is sprout's core and it already exists.** Bind → Stop gate live → exactly three honest endings (`checkpoint`/`arm`/`clear`) plus one human-only exit (`park`). Implement per node. `arm --read --predict` is the whole answer to "consult the developer almost never": require a file already read that did not answer, plus a prediction of the reply.
3. **Ration T3 tree-wide, not node-wide.** The cost ladder has exactly one hard gate; with recursion, N nodes each entitled to one question is N interruptions. Budget arms at the root.
4. **Take showrunner's observability protocol whole:** `snapshot` (one instant, one call, carrying `follow_up`) then `watch --since <cursor>`, cursor namespaced to its instance, with `ready`/`heartbeat`/`bye` frames. It is a designed answer to "a dead stream looks like a quiet one" and is exactly what a Jaspr UI over a Revali daemon needs. Zonai stores the journal; **the cursor belongs to the consumer.**
5. **The daemon closes the hole both harnesses admit.** Every game_loop gate fires from inside the session that stopped working; a run sat inert six hours with everything reporting healthy. Ship the watchdog's guardrails with the daemon: settle before measuring, ring cap on *consecutive unproductive* rings that resets on progress, newest-wins with a start-time-verified pid, and **log every quiet exit with a `why`.**
6. **Three verdicts, not two: live / stalled / abandoned — and never auto-reclaim a stalled node.** A live pid proves nothing; a frozen transcript mtime beside a live pid is the signal. The filing incident held four uncommitted files and a green suite. Surface, page, never act.
7. **Every fail-open path must print `ALLOWED WITHOUT BEING CHECKED`.** Generalize: an identity element (zero, empty, silent) is reported as *could not tell*, never *nothing there*, unless a control exists. Publish the list of places a guard is blind **in the guard's own output**, so those routes are recognized and not taken.
8. **Inherit the terseness rules as a hard output budget at tree scope.** One line per node (`VERDICT · node · task · since HH:MM (age)`); no prose, headings, narration, closing sentence, guessed age, or pasted JSON. Three fields survive any compression: `next check-in` (print `NONE SCHEDULED`), any held resource with holder, and `journal_unreadable`. If it doesn't fit on a phone, it's wrong.
9. **The decisions feed is append-only and superseding, never editable** (`amend`'s rule), and every decision's prose travels through a file, never a shell argument — the 400-char bound exists because a backtick executes and vanishes and the permanent record is corrupted silently.
10. **Keep the epistemic gate and sharpen it.** Require a real file for any claim about external reality, inherit RULED-OUT downward, and fix the named weakness: **where an interrogating command exists, a document is the weaker citation.**
11. **Four gates stay human-only — sprout's principled answer to "when may an autonomous agent be stopped":** (a) writes outside the declared workspace, (b) sprout's own policy files, (c) deploy/publish and irreversible outward acts, (d) a park — the human calling a break. **Everything else is RECORDED, not escalated.** And enforce *"A BRIEF IS NOT A HUMAN"*: a parent node's text can never authorize what only the developer can — that substitution happened twice in one real run and the log then read as human-sanctioned.
12. **Do not make hardening, retros, doctors, status recaps or completion summaries a phase.** The user's own verdict on his own tool: *"not a requirement and not a step in any run… most work should finish with nothing hardened at all."* Read it as a general veto on ceremony that does not pay for itself.
13. **Eliminate all 45 friction items by construction and check each off.** No per-repo directory, no tracked payload, no `settings.json` merge, no `.gitignore` edit, no session restart, no doctor, no local-vs-central decision, no hand-armed watchdog, no per-repo `verify.yaml`/`INVARIANTS.md`/`config.json`/`baseline`, no manual hook wiring, no skill symlinks, no campaign env var, no separately-cloned chat tool. **If sprout needs a per-repo file at all, it must be optional, untracked and additive.**
14. **"Adoption is a design surface, not a documentation problem"** (`DESIGN.md:73`) is the strongest argument on disk for sprout's machine-wide premise: 42/42 dispatches used the harness owning `SessionStart`/`PostCompact`; 0/42 used the one owning neither, in a repo where both were installed and wired. *"Adoption decays at exactly the rate context does. A guard whose enabling condition is 'you already adopted me' is not a guard."*
15. **Keep these docs' honesty style.** Both `llms.txt` files record their own corrections and name what each mechanism cannot see. sprout's output should too: a report that does not say what it could not check reads exactly like one that checked everything.
