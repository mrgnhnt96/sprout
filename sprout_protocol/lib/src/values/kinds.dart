/// The `kind` strings sproutd writes into the feed and a board branches on.
///
/// These are **wire vocabulary**, not an implementation detail of the store.
/// The producer puts them in the `kind` column of an `event` row, that row
/// travels over the socket inside a `DeltaFrame`, and the browser switches on
/// the string it reads back. Both ends therefore need one declaration, and
/// only one end has a database — the same reasoning that moved [SproutEvent]
/// and [SproutNode] here for F-07, applied to the strings those events carry.
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
/// **Renaming either value is a protocol break, and an unusually unfixable
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
