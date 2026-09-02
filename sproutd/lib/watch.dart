/// `watch --since <cursor>` — deltas as a stream, resumable from a cursor.
///
/// A snapshot is the picture; this is the deltas against it. *"An event saying
/// `leaf.closed` is not a picture, it is a delta against one"*
/// (`docs/01-plan.md` §7). The two join on the `Cursor` from
/// `lib/protocol.dart`, and `lib/snapshot.dart` hands out the very cursor a
/// consumer passes back here as `--since`.
///
/// Start at [watchFrames]. It emits, in this order: the backlog after the
/// given cursor as `delta` frames, one `ready`, then live `delta` frames,
/// `heartbeat` at a fixed interval, and a `bye` with a reason when the stream
/// ends. Each of those exists because a stream that has died and a stream with
/// nothing to say emit the same bytes — none (INV8):
///
/// - **`ready`** is the end of replay, so attaching is never a blank screen.
///   It is emitted even when the backlog was empty, and a `delta` carrying no
///   events is never sent in its place.
/// - **`heartbeat`** fires on a fixed interval whether the tree is busy or
///   idle. It is not reset by traffic: a heartbeat that a busy stream can
///   starve is not a liveness signal, it is a coincidence.
/// - **`bye`** says the stream ended and why, because *"a stream that simply
///   stops did not end, it broke."*
/// - A `--since` from **another sproutd instance** is refused with a bye
///   naming both instance ids, and a malformed one is refused differently.
///   Silently resuming at a seq that now means something else is the failure
///   the instance namespace exists to prevent.
///
/// **The cursor belongs to the consumer.** sproutd keeps no durable read
/// position: [WatchSource] has no method that could record one, watching twice
/// from the same cursor replays the same events, and emitting a frame is never
/// taken as proof the consumer took it.
///
/// The session owns no clock and no timer — [WatchSignals] injects both — so a
/// test drives fake time instead of sleeping, and "an idle stream still
/// heartbeats" is an assertion rather than a race.
///
/// Implementation lives under `lib/src/watch/`.
library;

export 'src/watch/session.dart' show defaultBatchSize, watchFrames;
export 'src/watch/signals.dart'
    show WatchSignals, defaultHeartbeatInterval, defaultPollInterval;
export 'src/watch/source.dart' show StoreWatchSource, WatchSource;
