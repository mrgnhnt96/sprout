/// The picture `watch --since <cursor>` sends deltas against, as a value.
///
/// A snapshot is *"the whole world at one instant"*, and a delta is only
/// meaningful against one: *"an event saying `leaf.closed` is not a picture,
/// it is a delta against one"* (`docs/01-plan.md` §7). The two join on the
/// `Cursor`, which is why this library and `protocol.dart` ship together —
/// `SnapshotFrame` carries a [SproutSnapshot] rather than a second description
/// of one, so **one decoder reads every line on the wire**.
///
/// **This half is pure.** Taking a snapshot needs a store and lives in
/// `package:sproutd/snapshot.dart` ([takeSnapshot] and `SnapshotSource`);
/// what it returns is already just data, `takenAt` included, and that is what
/// is here. The browser decodes these types and never links a database.
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
///   could not read is exactly the INV8 failure Phase 2 exists to prevent.
///
/// And **no age is ever estimated.** A node with no `since` renders
/// `since ?` — not a guess, not `0`, not the process start time — because a
/// guessed age is indistinguishable from a measured one downstream. The same
/// [unknownValueText] stands in wherever else sprout genuinely does not know,
/// including a subtree whose spend nobody reported: [SubtreeSpend] answers
/// `spend ?` and never `$0.00`.
///
/// Implementation lives under `lib/src/snapshot/`.
library;

export 'src/snapshot/resource.dart'
    show HeldResource, heldResourcesOf, isHoldingStatus, nothingHeldText;
export 'src/snapshot/snapshot.dart'
    show
        SnapshotNode,
        SproutSnapshot,
        formatAge,
        formatClock,
        journalReadableText,
        journalUnreadableKey,
        noNodesText;
export 'src/snapshot/spend.dart'
    show SubtreeSpend, noCheckinText, unknownValueText;
