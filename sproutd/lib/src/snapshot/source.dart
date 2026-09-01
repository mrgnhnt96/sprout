import '../../store.dart';

/// The three reads a snapshot is assembled from.
///
/// An interface rather than a direct [SproutStore] call for the same reason
/// `SessionLauncher` is one in `lib/runner.dart`: the failure that matters
/// here — *the event feed could not be read* — cannot be provoked through
/// [SproutStore]'s public API, and a branch no test can reach is a branch that
/// is not defended. [StoreSnapshotSource] is the real one; a test supplies a
/// feed that throws.
///
/// The split into three reads is not decoration. It is what makes the order
/// they happen in visible, and that order is the whole of the snapshot's
/// internal-consistency argument — see [StoreSnapshotSource].
abstract interface class SnapshotSource {
  /// The highest `event.seq` written, or 0 for an empty feed.
  int feedPosition();

  /// Every event with `seq <= position`, oldest first.
  List<SproutEvent> eventsUpTo(int position);

  /// The whole forest, each node tagged with its depth.
  List<TreeNode> tree();
}

/// A [SnapshotSource] backed by the real store.
///
/// **On reading the whole world at one instant.** [SproutStore] exposes no
/// transaction seam, so the three reads are three statements and something can
/// land between them. They are therefore ordered so that the picture can only
/// ever run *ahead* of its cursor, never behind it:
///
/// 1. `feedPosition()` fixes the cursor.
/// 2. `eventsUpTo(position)` is exact at that cursor whenever it runs — the
///    feed is append-only (the triggers in `lib/src/store/schema.dart`), so
///    rows at or below `position` can never change afterwards.
/// 3. `tree()` runs last, so the nodes reflect everything at `position` and
///    possibly a little more. `StoreProjection.observe` writes the node row
///    *before* it appends the event (`lib/src/runner/projection.dart`), so
///    every event at or below `position` already had its node write applied.
///
/// A consumer that resumes `watch --since <cursor>` may therefore re-apply an
/// event whose effect it can already see. It can never miss one, which is the
/// asymmetry that matters: a double-apply is a repeated truth and a gap is a
/// permanent lie. A `readTransaction` seam on [SproutStore] would make this
/// exact instead of merely safe, and that is a change to a file this leaf does
/// not own.
final class StoreSnapshotSource implements SnapshotSource {
  /// Reads from [store].
  const StoreSnapshotSource(this.store);

  /// The open store.
  final SproutStore store;

  @override
  int feedPosition() => store.cursor;

  /// Reads the feed and drops anything past [position].
  ///
  /// The whole feed is read because the store offers no query for "the last
  /// event of kind X per node", which is what the spend fold actually wants.
  /// That is a real cost on a long run and a finding for whoever owns
  /// `lib/store.dart`, not something to fix from here.
  @override
  List<SproutEvent> eventsUpTo(int position) => [
    for (final event in store.eventsSince(0))
      if (event.seq <= position) event,
  ];

  @override
  List<TreeNode> tree() => store.tree();
}
