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
/// (The Phase 0 captures under `docs/research/fixtures/` do *not* contain
/// these strings — they are raw Claude Code stream JSON, whose kinds are
/// `assistant`, `user`, `result` and so on. sprout's own vocabulary is
/// written by `SproutStore`, not replayed from those files.)
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
