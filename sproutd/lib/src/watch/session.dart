import 'dart:async';

import '../../protocol.dart';
import '../../store.dart';
import 'signals.dart';
import 'source.dart';

/// The most events one `delta` frame carries.
///
/// A cap, not a rate limit: replaying a long feed in one frame would build one
/// enormous JSON line that a consumer must hold entire before it can apply any
/// of it. Each frame still ends at a real event seq, so a consumer that stops
/// reading half way through a replay holds a position it was genuinely fed to.
const int defaultBatchSize = 500;

/// `watch --since <cursor>` as a stream of frames: replay, `ready`, then live.
///
/// The shape is fixed by `docs/01-plan.md` §7 and every part of it defends the
/// same failure — that a producer which has stopped working is
/// indistinguishable from a quiet one (INV8):
///
/// 1. **Replay.** Every event after [since], oldest first, in `delta` frames.
///    Strictly after: the consumer already holds the event at that seq.
/// 2. **[ReadyFrame].** Once, when the backlog is drained — *"so attaching is
///    never a blank screen"*. It is emitted even when the backlog was empty,
///    and it is never stood in for by a `delta` carrying no events; those are
///    different statements and `ProtocolFrame.marksEndOfReplay` is the one a
///    consumer branches on.
/// 3. **Live.** `delta` frames as the feed grows, [HeartbeatFrame] at a fixed
///    interval whether or not anything is happening, and a [ByeFrame] with a
///    reason when the stream ends.
///
/// [since] is the consumer's cursor, and it is **refused** rather than resumed
/// when it names another sproutd or is not a cursor at all: the stream is then
/// one [ByeFrame] and nothing else, carrying the refusal's own words and
/// *this* daemon's position, which is what the consumer needs in order to
/// start again. Passing null means "start from the head": no replay, an
/// immediate `ready`, then live deltas only.
///
/// sproutd records nothing about what it sent. Watching twice from the same
/// cursor replays the same events both times — the cursor belongs to the
/// consumer, and having emitted a frame is not proof anyone took it.
///
/// The clock and the timers are injected ([now], [signals]) so that a test
/// drives fake time rather than sleeping. The returned stream is
/// single-subscription and does nothing until it is listened to; cancelling it
/// drops the signal subscriptions and emits no `bye`, because a consumer that
/// hung up is not something the producer can narrate.
Stream<ProtocolFrame> watchFrames({
  required WatchSource source,
  required WatchSignals signals,
  String? since,
  SproutInstance? instance,
  DateTime Function()? now,
  int batchSize = defaultBatchSize,
}) => _WatchSession(
  source: source,
  signals: signals,
  since: since,
  instance: instance ?? SproutInstance.current,
  now: now ?? DateTime.now,
  batchSize: batchSize,
).frames;

/// One live `watch`, driven by a [StreamController] rather than by `async*`.
///
/// The controller is not decoration. An `async*` generator suspended in an
/// `await for` over its signals does not finish cancelling until that inner
/// stream produces something (dart-lang/sdk#26686), so a consumer that hangs
/// up on an idle tree would leave the session — and its timers — alive until
/// the next tick, and a test's `cancel()` would simply never return. Here
/// cancellation is a method call: the signal subscriptions are dropped at
/// once, deterministically.
final class _WatchSession {
  _WatchSession({
    required this.source,
    required this.signals,
    required this.since,
    required this.instance,
    required this.now,
    required this.batchSize,
  }) {
    _out = StreamController<ProtocolFrame>(onListen: _start, onCancel: _stop);
  }

  final WatchSource source;
  final WatchSignals signals;
  final String? since;
  final SproutInstance instance;
  final DateTime Function() now;
  final int batchSize;

  late final StreamController<ProtocolFrame> _out;
  final List<StreamSubscription<void>> _subscriptions = [];

  /// The position the consumer has been fed to. Held in memory for this
  /// stream only, and never written anywhere: sproutd keeps no durable read
  /// position (`docs/01-plan.md` §7).
  int _position = 0;

  /// True once this session has said its last frame. Guards the callbacks
  /// that can still fire after a `bye` — a shutdown future in particular.
  bool _ended = false;

  Stream<ProtocolFrame> get frames => _out.stream;

  /// The `--since` gate, the replay, and the `ready`, in that order.
  void _start() {
    final int start;
    if (since case final String offered) {
      final offer = instance.accept(offered);
      switch (offer) {
        case CursorRefused():
          // A refusal still owes the consumer a position to start again from.
          // When the feed cannot be read either, 0 is the honest answer for
          // the same reason `takeSnapshot` uses it: any other number would be
          // a claim about a feed nobody managed to read.
          _emit(ByeFrame.refusing(offer, at: instance.cursorAt(_head() ?? 0)));
          _finish();
          return;
        case CursorAccepted(:final cursor):
          start = cursor.position;
      }
    } else {
      final head = _head();
      if (head == null) {
        _emit(_feedUnreadableBye(at: 0));
        _finish();
        return;
      }
      start = head;
    }

    _position = start;
    if (!_drain()) return;
    _emit(ReadyFrame(cursor: instance.cursorAt(_position)));
    _listen();
  }

  /// Subscribes to the signals — and not a moment earlier, which is why no
  /// heartbeat can ever be emitted before the `ready`.
  void _listen() {
    _subscriptions
      ..add(
        signals.wakeups.listen((_) {
          if (!_ended) _drain();
        }),
      )
      ..add(
        signals.heartbeats.listen((_) {
          if (_ended) return;
          _emit(
            HeartbeatFrame(cursor: instance.cursorAt(_position), sentAt: now()),
          );
        }),
      );
    signals.shutdown.then((detail) {
      if (_ended) return;
      _emit(
        ByeFrame(
          cursor: instance.cursorAt(_position),
          reason: ByeReason.shutdown,
          detail: detail,
        ),
      );
      _finish();
    });
  }

  /// Sends every event after [_position] in frames of at most [batchSize],
  /// and returns whether the stream is still healthy.
  ///
  /// Emits nothing at all when there is nothing new: an empty `delta` is a
  /// position update carrying no position change, and a consumer that saw one
  /// could reasonably read it as the end of something.
  ///
  /// A read that throws ends the stream with a [ByeReason.error] bye rather
  /// than propagating. A consumer holding an exception has no picture and no
  /// cursor; one holding a bye knows the stream broke, knows why, and knows
  /// where the daemon stood when it did.
  bool _drain() {
    while (true) {
      final List<SproutEvent> batch;
      try {
        batch = source.eventsAfter(_position, limit: batchSize);
      } on Object catch (error) {
        _emit(_feedUnreadableBye(at: _position, error: error));
        _finish();
        return false;
      }
      if (batch.isEmpty) return true;
      _position = batch.last.seq;
      _emit(DeltaFrame(cursor: instance.cursorAt(_position), events: batch));
    }
  }

  /// The feed head, or null when it cannot be read.
  ///
  /// Null rather than a fallback number: "I could not look" and "there is
  /// nothing there" are one observation to a caller that gets 0 for both, and
  /// the caller here has to say which happened.
  int? _head() {
    try {
      return source.feedPosition();
    } on Object {
      return null;
    }
  }

  /// The bye that says the feed itself failed.
  ///
  /// [ByeReason.error] rather than [ByeReason.shutdown], because a consumer
  /// must not treat a broken stream as an orderly end — the two call for a
  /// reconnect and a stop respectively.
  ByeFrame _feedUnreadableBye({required int at, Object? error}) => ByeFrame(
    cursor: instance.cursorAt(at),
    reason: ByeReason.error,
    detail: error == null
        ? 'the event feed could not be read'
        : 'the event feed could not be read: $error',
  );

  void _emit(ProtocolFrame frame) {
    if (_ended || _out.isClosed) return;
    _out.add(frame);
  }

  /// Says the last frame has been said. Closing the controller cancels the
  /// consumer's subscription once the done event lands, which calls [_stop].
  void _finish() {
    _ended = true;
    _out.close();
  }

  /// Drops the signal subscriptions. Idempotent, because it is reached both
  /// from a consumer's `cancel()` and from the controller closing itself.
  Future<void> _stop() async {
    _ended = true;
    final subscriptions = [..._subscriptions];
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
