/// The `kind` strings sproutd writes into the feed and a board branches on.
///
/// These are **wire vocabulary**, not an implementation detail of the store.
/// The producer puts them in the `kind` column of an `event` row, that row
/// travels over the socket inside a `DeltaFrame`, and the browser switches on
/// the string it reads back. Both ends therefore need one declaration, and
/// only one end has a database — the same reasoning that moved [SproutEvent]
/// and [SproutNode] here for F-07, applied to the strings those events carry.
///
/// The same argument brought the `runner.*` launch and lifecycle kinds here
/// for F-12. `SessionRunner` wrote four of them as bare literals at the call
/// site and `StoreProjection` a fifth, so the moment `LivenessMeasure` needed
/// three of them it had to spell them a second time — the same two-derivations
/// shape, one library later.
///
/// That is why they are here rather than in `package:sproutd`: `sprout_ui`
/// cannot import `package:sproutd` at all, because the daemon reaches the
/// filesystem and its SQLite bindings reach native code, and
/// `build_web_compilers` refuses an entrypoint on its transitive library
/// import graph. Until this move, the two packages spelled the strings twice
/// and `sprout_ui/test/kinds_test.dart` read the producer's source to compare
/// them. That was finding F-11, and keeping two derivations equal by comparing
/// them is F-01's shape; one declaration is the repair.
///
/// (Naming those two offending packages in prose is avoided on purpose.
/// `sproutd/test/scaffold_test.dart` and `sprout_ui/test/scaffold_test.dart`
/// enforce the web-safety rule by scanning these files as TEXT, so a doc
/// comment that quotes the banned import fails the guard. The bluntness is
/// deliberate — a scanner that tried to skip comments would be a scanner that
/// could be fooled — so the wording moves, not the guard.)
///
/// **Renaming any value here is a protocol break, and an unusually unfixable
/// one.** These strings are in the `kind` column of every `~/.sprout/*.db`
/// sprout has ever written, and the feed is append-only by schema trigger —
/// there is no update path, so old rows cannot be rewritten to a new spelling.
/// A renamed consumer would silently stop recognising history it already
/// holds. `sproutd/test/protocol_test.dart` pins the literal text for that
/// reason; changing it there is meant to be a deliberate act.
///
/// The `hook.*` kinds arrived for P8-01 and are the same argument reaching the
/// second observation path. sprout can only parse the stream of a process it
/// launched; a machine-wide hook config is the only way it sees the session a
/// developer starts by hand. Those payloads fold into the same feed, the
/// browser branches on their `kind` too, and so the vocabulary belongs here
/// with the rest — declared once, before the first producer exists, rather
/// than as literals at whatever call site writes them first. That is what
/// F-11 and F-12 each cost a leaf to undo.
///
/// (The Phase 0 captures under `docs/research/fixtures/` do *not* contain
/// these strings — the stream captures are raw Claude Code stream JSON, whose
/// kinds are `assistant`, `user`, `result` and so on, and the hook captures
/// carry a bare `hook_event_name` such as `SessionStart` with no prefix on it.
/// sprout's own vocabulary is written by `SproutStore`, not replayed from
/// those files.)
library;

import 'event.dart';
import 'node.dart';

/// The event appended when a node row is written for the first time.
///
/// Attributed to the node's own id and carrying the whole row, so that a
/// consumer holding a snapshot plus every delta since learns the node exists
/// without taking a fresh snapshot. `SproutStore.putNode` appends it beside
/// the row it writes, which is what makes "a node cannot enter the graph
/// without the feed saying so" a property of the store rather than a habit its
/// callers have to keep. F-02 and F-10 were each one caller that did not.
///
/// The payload is the whole [SproutNode] as JSON. A consumer that has applied
/// this event holds the node without needing a snapshot for it.
const String nodeObservedKind = 'runner.observed';

/// The event appended when a node already in the feed really changes.
///
/// A node's [NodeStatus], `current_task` and `parent_id` all move while it
/// runs, and a feed that announced the node once and then went quiet would
/// leave a live tree showing it frozen on its first label. Separate from
/// [nodeObservedKind] so that a change is never mistaken for a second creation
/// of the same node.
///
/// **Only a change a board renders counts.** A write that moves none of those
/// three fields appends nothing at all — otherwise a status poll would flood
/// the feed a UI reads.
///
/// **This is the kind the board actually depends on**, and not merely a
/// refinement of [nodeObservedKind]. In the Phase 0 `B.ndjson` capture both
/// subagents are announced with a **null** `current_task` and given one
/// several seconds later by this event, so a client that handled creation and
/// ignored updates would render two permanently blank tasks and look entirely
/// healthy doing it. The payload carries only what moved, as `{from, to}` per
/// field.
const String nodeUpdatedKind = 'runner.updated';

/// The event appended when the containment gate refused a launch.
///
/// No process was started and none ever will be for this node, so a reader
/// that finds this and no [runnerSpawnedKind] has its answer: the node is not
/// missing, it was declined. That is what lets a liveness measurement say why
/// a node never began, in the feed's own words, instead of reporting it as
/// abandoned.
///
/// The payload carries the refusal's `reason` and `explanation` and the
/// running `refusals` tally — the gate counting its own refusals is an
/// invariant, so the count travels with the event that caused it.
const String runnerRefusedKind = 'runner.refused';

/// The event appended when the gate allowed a launch and the process still
/// could not be started.
///
/// Deliberately distinct from [runnerRefusedKind]: one is sprout deciding no,
/// the other is the machine — a missing executable, an unreadable working
/// directory — and a single kind for both would hide which of the two a run
/// hit. The payload carries `error` and the whole `launch` that was attempted.
const String runnerLaunchFailedKind = 'runner.launch_failed';

/// The event appended when a process really started, carrying its `pid`.
///
/// **The anchor of every liveness measurement.** A measurement reads the
/// newest event of this kind for a node to learn the pid to probe, the
/// `raw_log` transcript path to time, and the moment the spawn was recorded —
/// and that last field is what catches a recycled pid, because a process whose
/// start time is *after* this event is not the process this event is about.
///
/// The payload also carries the whole `launch`, the `max_budget_usd` it was
/// given, the `permit` the gate issued, and the `stderr_log` path.
const String runnerSpawnedKind = 'runner.spawned';

/// The event appended once per session, when the CLI first says who it is.
///
/// Recorded on the first `system/init` frame and never again: the session id,
/// model and CLI version do not change mid-run, so a second record would be
/// the same facts with a later timestamp. It is not simply taken from the
/// first frame of the stream because a hook frame can arrive before that init,
/// and a record taken then would have every field but the id empty.
const String runnerSessionKind = 'runner.session';

/// The event appended when a session's process is gone and its stream is
/// closed, carrying the whole ended session as JSON.
///
/// **Not an ending in the sense liveness means.** sprout refuses to infer
/// completion from process exit (INV12), so a node whose process died while
/// still working is abandoned rather than finished. This event records what
/// the stream said; whether the run ended honestly is the node's status, and
/// the two are separate on purpose.
const String runnerExitedKind = 'runner.exited';

/// The event appended when sprout learned the process behind a session it did
/// **not** launch.
///
/// **The same measurement, from the other door.** [runnerSpawnedKind] is the
/// anchor of every liveness measurement, and its two load-bearing fields are
/// `pid` and `raw_log`. This kind carries those two fields under the same two
/// names, because timing a transcript beside a live pid is genuinely the same
/// question whichever path learned the pid — a measurement that forked here
/// would be two derivations of one rule, which is F-01's shape.
///
/// **A distinct kind, because sprout did not spawn this process.** A feed that
/// recorded a developer's own terminal as `runner.spawned` would be claiming a
/// launch that never happened, and the two paths are separate sources of truth
/// on purpose — the same argument [hookKindPrefix] makes for the payload kinds.
///
/// It is not itself prefixed `hook.`, and that is deliberate too. Every
/// `hook.*` kind is one delivered payload stored verbatim; this is sprout's own
/// record, derived from a payload and from the hook process's environment
/// (`CLAUDE_PID`), and a consumer that reads the `hook.` prefix as *"the raw
/// bytes Claude Code sent"* would be wrong about this row. Nor is it `runner.*`
/// or `frame.*`, for the reason above.
///
/// The payload carries, in order of what a measurement needs:
///
/// - `pid` — the session's own OS process, from `CLAUDE_PID`. **Absent when it
///   could not be established**, and absent on every subagent, because there is
///   one process per `claude -p` however deep the tree goes: recording the
///   root's pid on a child would make every child inherit the root's liveness.
/// - `raw_log` — the transcript to time. Absent on a subagent for the same
///   family of reason: `transcript_path` is always the *root* session's, so
///   timing it to decide whether a child is frozen reports the parent's pulse.
/// - `why` — one sentence naming what could not be looked at, when something
///   could not be. It reaches the human verbatim in a liveness verdict's
///   `because`.
/// - `session_id`, and `agent_id` on a subagent — the identity this row is
///   about, so the event is readable without joining it to a node row.
///
/// A record carrying no `pid` is what makes a hook-observed subagent
/// `unmeasured` rather than `abandoned`. That distinction is the whole reason
/// this kind is written for a node whose process sprout cannot name at all: a
/// node with no record of any kind reads as *never started*, which pages.
const String observedProcessKind = 'process.observed';

/// The prefix on every kind that records what a **hook** delivered.
///
/// Deliberately parallel to `frame.`, and deliberately not the same as it. The
/// two observation paths of `docs/01-plan.md` §4 are different sources of truth
/// about the same session: the stream path only ever sees a session sprout
/// launched and owns the pipe for, while a machine-wide hook config is the only
/// way a session a developer started by hand is visible at all. A reader of the
/// feed has to be able to tell which path a row came from, because what the two
/// can be trusted for differs — so they do not share a prefix.
const String hookKindPrefix = 'hook.';

/// The kind for a `SessionStart` hook payload.
///
/// **The wire's own spelling, verbatim, after the prefix.** Not
/// `hook.session_start`: a case mapping between what Claude Code sends and what
/// sprout stores is a second derivation that can drift from the first, and it
/// cannot be checked by reading one line. `frame.assistant` and
/// `frame.system.init` already carry the wire's spelling for the same reason —
/// those happen to be lower case because the stream's `type` values are, and
/// hook event names are `PascalCase` because the hook API's are. The rule is
/// the same rule; only the source alphabet differs.
///
/// Everything [nodeObservedKind]'s doc says about renaming applies here in
/// full: these strings go in an append-only `kind` column with no rewrite path.
const String hookSessionStartKind = '${hookKindPrefix}SessionStart';

/// The kind for a `SessionEnd` hook payload.
const String hookSessionEndKind = '${hookKindPrefix}SessionEnd';

/// The kind for a `UserPromptSubmit` hook payload.
///
/// **Not proof a human typed anything.** A background node's result is
/// delivered to the root as a fresh `UserPromptSubmit` whose `prompt` is a
/// `<task-notification>` block, byte-for-byte the shape of a person starting a
/// new task. Telling the two apart is a property of the payload, not of the
/// kind.
const String hookUserPromptSubmitKind = '${hookKindPrefix}UserPromptSubmit';

/// The kind for a `PreToolUse` hook payload.
const String hookPreToolUseKind = '${hookKindPrefix}PreToolUse';

/// The kind for a `PostToolUse` hook payload.
///
/// **The kind the hook-path tree is built from.** A `PostToolUse` of the spawn
/// tool is the only record that carries the caller's `agent_id` and the
/// callee's `tool_response.agentId` together, and `agent_id` is the only
/// identifier that distinguishes nodes on this path at all — every node in a
/// tree shares one `session_id`.
const String hookPostToolUseKind = '${hookKindPrefix}PostToolUse';

/// The kind for a `SubagentStart` hook payload.
const String hookSubagentStartKind = '${hookKindPrefix}SubagentStart';

/// The kind for a `SubagentStop` hook payload.
///
/// The only event observed to carry `agent_transcript_path`, which is the
/// subagent's *own* transcript. Every other payload's `transcript_path` is the
/// root session's, even inside a subagent.
const String hookSubagentStopKind = '${hookKindPrefix}SubagentStop';

/// The kind for a `Stop` hook payload.
const String hookStopKind = '${hookKindPrefix}Stop';

/// The kind for a `Notification` hook payload.
///
/// Registered in the Phase 0 probes and **never fired**, so no payload of it
/// has ever been seen. It has a kind anyway, because a name that is known and
/// unfired is a different thing from a name that is unknown, and folding the
/// two together would make the first payload that ever arrives look like a
/// schema change.
const String hookNotificationKind = '${hookKindPrefix}Notification';

/// The kind for a `PreCompact` hook payload. Never observed firing; see
/// [hookNotificationKind].
const String hookPreCompactKind = '${hookKindPrefix}PreCompact';

/// The kind for a `PostCompact` hook payload. Never observed firing; see
/// [hookNotificationKind].
const String hookPostCompactKind = '${hookKindPrefix}PostCompact';

/// The kind for a payload whose `hook_event_name` this build does not know.
///
/// **Recording it is not optional.** The hook API is an unstable external
/// surface (INV10) and a payload sprout cannot name is still evidence a session
/// exists and is doing something — dropping it would make a live session look
/// idle. The original name survives verbatim inside the stored payload, so a
/// later sprout that learns the name can find every row it already holds.
///
/// Lower case on purpose: every real event name is `PascalCase`, so this can
/// never collide with one the wire later introduces.
const String hookUnknownKind = '${hookKindPrefix}unknown';

/// The kind for hook input that was not a JSON object at all.
///
/// Distinct from [hookUnknownKind] the way [runnerLaunchFailedKind] is distinct
/// from [runnerRefusedKind]: one says sprout does not recognise the event, the
/// other says there was no event to recognise — truncated input, a crash
/// mid-write, something that is not JSON. A single kind for both would hide
/// which of the two a run hit. The stream path already draws this exact line at
/// `frame.malformed`.
const String hookMalformedKind = '${hookKindPrefix}malformed';

/// Every `hook_event_name` this build knows, mapped to the kind it records as.
///
/// The eleven names confirmed present in the `claude` v2.1.252 binary
/// (`docs/research/17-observed-schemas.md` §1). All eleven were registered at
/// once in the Phase 0 probes and eight of them fired; the three that did not
/// are here for the reason [hookNotificationKind] gives.
///
/// A map rather than a `switch` so that the set is enumerable: a consumer can
/// ask what sprout knows without reading this file, and a test can assert the
/// eleven keys against the event names a capture corpus actually contains.
const Map<String, String> hookKindsByEventName = {
  'SessionStart': hookSessionStartKind,
  'SessionEnd': hookSessionEndKind,
  'UserPromptSubmit': hookUserPromptSubmitKind,
  'PreToolUse': hookPreToolUseKind,
  'PostToolUse': hookPostToolUseKind,
  'SubagentStart': hookSubagentStartKind,
  'SubagentStop': hookSubagentStopKind,
  'Stop': hookStopKind,
  'Notification': hookNotificationKind,
  'PreCompact': hookPreCompactKind,
  'PostCompact': hookPostCompactKind,
};

/// The kind for [eventName], or [hookUnknownKind] when this build does not know
/// it.
///
/// Total by construction, including for a null name — a payload that carried no
/// `hook_event_name` is exactly the unknown case, and there is no input for
/// which this returns nothing.
String hookKindForEventName(String? eventName) =>
    hookKindsByEventName[eventName] ?? hookUnknownKind;

/// The prefix on every kind recording what sprout did to a **git worktree**.
///
/// Its own prefix rather than a `runner.*` kind, on [hookKindPrefix]'s
/// argument: these rows are about the *room* a session works in, not about the
/// session. The room outlives the process on purpose — the whole point of
/// [worktreeKeptKind] is that a worktree survives the node that filled it — so
/// a reader that took a `runner.*` row as "something happened to the process"
/// would be wrong about every one of them.
const String worktreeKindPrefix = 'worktree.';

/// The event appended when a git worktree was created for a node.
///
/// The payload carries `path` and `branch` — where the session's files really
/// are and the branch its commits land on — plus `base` and `base_sha`, the ref
/// it was cut from and what that ref resolved to at the time. `base_sha` is the
/// field a later teardown needs and the only one that cannot be recovered
/// afterwards: the ref will have moved.
///
/// It also carries `repository`, the repository root. That is where the row
/// records it, because the node's own `project` column holds the **worktree**
/// path instead — the session's files are genuinely there, and a snapshot
/// saying otherwise would be a lie about the filesystem that `heldResourcesOf`
/// then reads as contention between a parent and its child.
///
/// **There is deliberately no `worktree.refused` kind.** A creation sprout
/// declines — the path is taken, the branch is taken — happens before any node
/// row exists, and `event.node_id` carries a foreign key onto `node (id)` with
/// `PRAGMA foreign_keys=ON`. Such a row could not be inserted, so declaring a
/// kind for it would be declaring wire vocabulary nothing can ever write. The
/// refusal reaches the operator on stderr and through a distinct exit code.
const String worktreeCreatedKind = '${worktreeKindPrefix}created';

/// The event appended when a worktree was torn down and its files are gone.
///
/// Only ever written after sprout looked and found nothing to lose: a clean
/// `git status --porcelain` — **untracked files included** — and no commit on
/// the branch that the base does not already reach. The payload carries `path`,
/// `branch`, and `branch_deleted`, since the branch is removed separately and
/// only by `git branch -d`, which refuses on its own if it disagrees.
const String worktreeRemovedKind = '${worktreeKindPrefix}removed';

/// The event appended when sprout **refused** to tear a worktree down.
///
/// The kind that carries this area's whole point, and the one that fires most:
/// a child session's entire job is to leave changes behind, so the safe
/// teardown declines far more often than it succeeds. That is the correct shape
/// and not a defect in it. From `docs/research/07-local-harnesses.md`: *"an
/// abandoned worktree may hold the only copy of real work: surface it, do not
/// silently reuse it and do not silently delete it."*
///
/// The payload carries `reason` — one of the wire strings on the teardown's
/// keep-reason enum — an `explanation` a human can act on, and `evidence`: the
/// counts that were measured, or the text of the look that failed.
///
/// **A look that failed keeps the worktree and says so.** An unreadable
/// `git status` is not evidence of a clean tree, and folding the two together
/// is how a check whose pass is silence deletes somebody's only copy (INV8).
const String worktreeKeptKind = '${worktreeKindPrefix}kept';

/// The prefix on every kind recording a **parent's acceptance check** of what
/// one child returned.
///
/// Its own prefix rather than a `runner.*` kind, on [worktreeKindPrefix]'s
/// argument: a `runner.*` row is about the process — it started, it was
/// refused, it exited — and none of those say whether the work was any good.
/// This is the judgement made *after* the process is gone, against the
/// machine-checkable condition the brief carried, and a reader that took it
/// for a lifecycle row would be wrong about all three.
///
/// `docs/01-plan.md` §2.5 is why there are three kinds and no fourth carrying a
/// number: DELEGATE-52 measured degradation as **sparse and catastrophic**
/// rather than diffuse — near-perfect reconstruction, then 10–30 points lost in
/// a single round trip, with those sparse failures explaining ~80% of total
/// degradation — so the decision was *"no trend gauge. A per-return acceptance
/// check by the parent, against the brief it wrote."* There is deliberately no
/// score, no rolling average and nothing a board could plot over time.
const String acceptanceKindPrefix = 'acceptance.';

/// The event appended when every declared success condition passed and the
/// child's subtree had drained.
///
/// The **positive control** INV8 asks for, and the reason acceptance is on the
/// feed at all rather than only its refusals: a check that wrote a row only
/// when it said no could not be told from one that never ran. The payload
/// carries every condition that was run with the exit code it produced, plus
/// the running `counts`.
///
/// **Not a claim that the child's process succeeded.** sprout does not decide
/// this on an exit code (INV12) — a zero exit with no result is a session that
/// died before answering, and a non-zero exit after a real answer is not a
/// failure of the work. The exit code is in the payload and decides nothing.
const String acceptanceAcceptedKind = '${acceptanceKindPrefix}accepted';

/// The event appended when sprout looked, and the answer was no.
///
/// A definite finding: a condition ran and exited non-zero, the child never
/// produced a result, or its subtree had not drained. The payload carries
/// `reason` — one of the wire strings on the rejection enum — an `explanation`
/// a human can act on, and the conditions that were run.
///
/// Distinct from [acceptanceUndecidableKind] the way [worktreeKeptKind]'s
/// `unreadable` is distinct from its `uncommittedChanges`: one is an
/// observation, the other is a failure to observe, and folding them together is
/// how a check whose pass is silence starts deciding things (INV8).
const String acceptanceRejectedKind = '${acceptanceKindPrefix}rejected';

/// The event appended when sprout **could not evaluate** the condition it was
/// given.
///
/// The executable was not there, the working directory was gone, the process
/// could not be forked. That is not a pass and it is not a failure — *"a pass
/// that is silence proves nothing on its own"* (INV8) — and a run that folded
/// it into either would be reporting a judgement it never made. The payload
/// carries `reason`, an `explanation` naming the command and what went wrong,
/// and the conditions that were attempted.
///
/// A child whose acceptance is undecidable keeps its worktree, exactly as a
/// rejected one does. The two are different rows because they are different
/// facts, and only one of them means the work was looked at.
const String acceptanceUndecidableKind = '${acceptanceKindPrefix}undecidable';
