import 'dart:async';

/// The default gap between heartbeats on a `watch` stream.
///
/// A knob, not a finding: nothing in `docs/01-plan.md` fixes an interval. It
/// is short enough that a consumer notices a dead daemon inside one screenful
/// of attention and long enough that an idle tree does not scroll.
const Duration defaultHeartbeatInterval = Duration(seconds: 15);

/// How often the live loop looks for new events when nobody pushes.
///
/// Polling is what [WatchSignals.live] does today, because the store has no
/// change notification to subscribe to. A future writer-side signal replaces
/// [WatchSignals.wakeups] without touching the session: that is the whole
/// reason the wake-ups arrive as a [Stream] rather than a [Timer] the session
/// owns.
const Duration defaultPollInterval = Duration(milliseconds: 250);

/// Everything that makes a `watch` stream *move*, as three injected streams.
///
/// The session has no clock and no timer of its own. That is what lets the
/// tests drive fake time — a [StreamController] per signal, ticked exactly
/// when the test says so — instead of sleeping, and it is why "an idle stream
/// still heartbeats" is a deterministic assertion here rather than a race.
///
/// The three are kept apart on purpose. A wake-up says *the feed may have
/// grown*; a heartbeat says *the daemon is alive*; a shutdown says *this
/// stream is ending, and here is why*. Folding the first two together would
/// make the heartbeat interval depend on how busy the tree is, which is
/// exactly the starvation the heartbeat exists to rule out.
final class WatchSignals {
  /// Wires a session to [wakeups] and [heartbeats], ending when [shutdown]
  /// completes with the detail that goes in the `bye`.
  ///
  /// [shutdown] defaults to a future that never completes: a session with no
  /// shutdown wired runs until its consumer cancels, and a consumer that
  /// cancels gets no `bye` because it is the one that ended the stream.
  WatchSignals({
    required this.wakeups,
    required this.heartbeats,
    Future<String>? shutdown,
  }) : shutdown = shutdown ?? Completer<String>().future;

  /// The real one: poll the feed on a timer, beat on a timer.
  ///
  /// Both streams are created here and start when the session listens, so an
  /// unlistened [WatchSignals] holds no timer.
  factory WatchSignals.live({
    Duration heartbeatInterval = defaultHeartbeatInterval,
    Duration pollInterval = defaultPollInterval,
    Future<String>? shutdown,
  }) => WatchSignals(
    wakeups: Stream<void>.periodic(pollInterval),
    heartbeats: Stream<void>.periodic(heartbeatInterval),
    shutdown: shutdown,
  );

  /// Ticks when the feed may have grown. A tick with no new events emits no
  /// frame — an empty `delta` would be a position update saying nothing,
  /// and the liveness answer is the heartbeat's job.
  final Stream<void> wakeups;

  /// Ticks at a fixed interval, whatever else the stream is doing.
  final Stream<void> heartbeats;

  /// Completes with the `bye` detail when the daemon is going away.
  final Future<String> shutdown;
}
