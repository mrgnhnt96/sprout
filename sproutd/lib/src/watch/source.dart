import '../../store.dart';

/// The two reads `watch` makes, and nothing else.
///
/// The interface is deliberately **read-only, with no method that records a
/// position**. sproutd keeps no durable read cursor: the cursor belongs to the
/// consumer, is handed back on `--since`, and is never written down here as
/// proof of delivery before the consumer has actually taken the frames
/// (`docs/01-plan.md` §7). There is no `markDelivered` to call by accident,
/// which is the difference between a rule and a sentence about a rule (INV1).
///
/// An interface rather than a direct [SproutStore] call for the same reason
/// `SnapshotSource` is one in `lib/snapshot.dart`: *the feed could not be
/// read* is the branch that matters most on a long-lived stream, and it cannot
/// be provoked through [SproutStore]'s public API. [StoreWatchSource] is the
/// real one; a test supplies a feed that throws.
abstract interface class WatchSource {
  /// The highest `event.seq` written, or 0 for an empty feed.
  int feedPosition();

  /// Events with `seq > position`, oldest first, at most [limit] of them.
  ///
  /// Strictly after [position]: the consumer has already been fed the event at
  /// that seq, so returning it again would be a duplicate the protocol does
  /// not need. Missing one is the failure that cannot be recovered from.
  List<SproutEvent> eventsAfter(int position, {int? limit});
}

/// A [WatchSource] backed by the real store.
///
/// Both calls are single statements against an append-only table, so the two
/// of them cannot disagree the way a snapshot's three reads can: rows at or
/// below a position can never change afterwards (the triggers in
/// `lib/src/store/schema.dart`). A feed that grows between the two calls is
/// simply read on the next drain.
final class StoreWatchSource implements WatchSource {
  /// Reads from [store].
  const StoreWatchSource(this.store);

  /// The open store. Never written to from here.
  final SproutStore store;

  @override
  int feedPosition() => store.cursor;

  @override
  List<SproutEvent> eventsAfter(int position, {int? limit}) =>
      store.eventsSince(position, limit: limit);
}
