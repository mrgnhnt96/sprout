/// `snapshot` — the whole world, in one call, at one cursor.
///
/// A snapshot is the picture that `watch --since <cursor>` sends deltas
/// against: *"an event saying `leaf.closed` is not a picture, it is a delta
/// against one"* (`docs/01-plan.md` §7). The two join on the [Cursor], so
/// everything in a snapshot has to be true at the *same* position — a
/// consumer applies the deltas from there and must arrive at the present with
/// no gap and no double-apply. How that is obtained over a store with no
/// transaction seam, and which way it deliberately errs, is documented on
/// [StoreSnapshotSource].
///
/// Start at [takeSnapshot]. It reads a [SnapshotSource] — [StoreSnapshotSource]
/// in production — and returns a [SproutSnapshot] carrying every node with its
/// depth, parent, status, `current_task`, `since` and `next_checkin`, the
/// cumulative spend of every subtree, everything held with its holder, and the
/// cursor it is all true at.
///
/// **Three fields survive any compression, and each is a rule about absence**
/// (`docs/01-plan.md` §7):
///
/// - `next check-in` prints [noCheckinText] — `NONE SCHEDULED` — and never a
///   blank, because absence must never look like presence. A blank column
///   reads as "fine".
/// - Every held resource appears **with its holder**: [HeldResource] refuses
///   to exist without one, since a lock with no named holder is not
///   information.
/// - [SproutSnapshot.journalUnreadable] says so *in the snapshot* when the
///   event feed could not be read. A snapshot that silently omitted what it
///   could not read is exactly the INV8 failure this phase exists to prevent.
///
/// And **no age is ever estimated.** A node with no `since` renders
/// `since ?` — not a guess, not `0`, not the process start time — because a
/// guessed age is indistinguishable from a measured one downstream. The same
/// [unknownValueText] stands in wherever else sprout genuinely does not know,
/// including a subtree whose spend nobody reported: [SubtreeSpend] answers
/// `spend ?` and never `$0.00`.
///
/// **The snapshot splits in two, and the seam is `dart:io`.** The *values* —
/// [SproutSnapshot], [SnapshotNode], [HeldResource], [SubtreeSpend] and the
/// renderings above — live in `package:sprout_protocol/snapshot.dart` and are
/// re-exported here, because [SnapshotFrame] carries a snapshot and the
/// browser therefore has to decode one (finding F-07). What is left in this
/// package is the half that *reads a store*: [SnapshotSource] and
/// [takeSnapshot]. Importers of `package:sproutd/snapshot.dart` see no
/// difference; the same declarations arrive from the same path.
///
/// **[readLedger] is the same read, stopped one step earlier.** A containment
/// decision needs the tree the store holds — depths from `parent_id`, live
/// counts from `status`, rolled-up dollars from the feed — which is precisely
/// what [takeSnapshot] assembles before it renders anything. So the ledger
/// `ContainmentGate` decides over is built by the same function as the picture
/// a developer reads, and the two cannot drift. It returns an [ObservedLedger]
/// rather than a bare `SpendLedger` because the dollars in it are a **floor**
/// and the count of what was not observed has to travel with them (INV7).
///
/// Implementation lives under `lib/src/snapshot/`, and under
/// `sprout_protocol/lib/src/snapshot/` for the pure half.
library;

export 'package:sprout_protocol/snapshot.dart';

export 'src/snapshot/source.dart' show SnapshotSource, StoreSnapshotSource;
export 'src/snapshot/take.dart'
    show
        ObservedLedger,
        readLedger,
        resultEventKind,
        takeSnapshot,
        totalCostUsdField;
