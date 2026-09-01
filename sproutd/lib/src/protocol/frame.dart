import 'dart:convert';

import '../../store.dart';
import 'cursor.dart';

/// Thrown when a line on the wire is not a frame this build understands.
///
/// The stream parser in `lib/stream.dart` deliberately **never** throws, and
/// the asymmetry is on purpose. That parser reads Claude Code's control plane:
/// a foreign, unstable API where an unrecognised frame is expected and dying
/// on one would take the daemon down (INV10). This one reads sprout's *own*
/// protocol, where both ends are written in this package, so an unrecognised
/// frame means the two ends are different builds. Swallowing it would drop
/// deltas silently — a consumer that quietly ignores what it cannot read shows
/// a stale tree and never says why.
class ProtocolFormatException implements Exception {
  /// Creates the error.
  const ProtocolFormatException(this.message, [this.text]);

  /// What was wrong.
  final String message;

  /// The offending line or value, when there is one worth printing.
  final String? text;

  @override
  String toString() => text == null
      ? 'ProtocolFormatException: $message'
      : 'ProtocolFormatException: $message: "$text"';
}

/// Why a stream ended.
///
/// These are sprout's own states, not control-plane facts, so INV10 does not
/// apply — nothing here is read off a Claude Code frame. The set is small and
/// each member has a caller in Phase 2; a reason nobody can emit is a reason
/// nobody can trust.
enum ByeReason {
  /// The daemon is going away. The consumer may reconnect and will find a new
  /// instance id.
  shutdown('shutdown'),

  /// The request could not be served at all — most often a `--since` cursor
  /// this instance refuses. The refusal text travels in [ByeFrame.detail].
  refused('refused'),

  /// The stream broke mid-flight: the store became unreadable, or an event
  /// could not be encoded. Distinct from [shutdown] because a consumer should
  /// not treat it as an orderly end.
  error('error');

  const ByeReason(this.wire);

  /// The string that appears in JSON.
  ///
  /// Written out rather than derived from [name] so renaming a Dart identifier
  /// cannot silently change the wire.
  final String wire;

  /// Parses a value off the wire.
  ///
  /// Throws rather than defaulting: a bye whose reason was quietly rewritten
  /// to `shutdown` would turn a broken stream into an orderly one, which is
  /// the exact confusion `bye` exists to remove.
  static ByeReason fromWire(String value) {
    for (final reason in ByeReason.values) {
      if (reason.wire == value) return reason;
    }
    throw ProtocolFormatException('unknown bye reason', value);
  }
}

/// One line of the `watch` stream.
///
/// Sealed: a consumer's `switch` over the frame types is exhaustive, and
/// adding a type is a compile error at every consumer rather than a frame that
/// falls through a default branch into nothing.
///
/// Every frame carries the [cursor] it is at, because a delta is only
/// meaningful against a position — *"an event saying `leaf.closed` is not a
/// picture, it is a delta against one"* (`docs/01-plan.md` §7). The frames
/// that carry no events carry a cursor too: that is what lets a consumer
/// resume after a quiet stretch without replaying it.
sealed class ProtocolFrame {
  const ProtocolFrame({required this.cursor});

  /// Decodes one JSON object into its frame.
  ///
  /// Total in the sense that it either returns a frame or throws
  /// [ProtocolFormatException]; it never returns a placeholder.
  factory ProtocolFrame.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type is! String) {
      throw ProtocolFormatException('frame has no "type"', jsonEncode(json));
    }
    return switch (type) {
      ReadyFrame.wireType => ReadyFrame.fromJson(json),
      HeartbeatFrame.wireType => HeartbeatFrame.fromJson(json),
      ByeFrame.wireType => ByeFrame.fromJson(json),
      DeltaFrame.wireType => DeltaFrame.fromJson(json),
      _ => throw ProtocolFormatException('unknown frame type', type),
    };
  }

  /// Decodes one NDJSON line.
  ///
  /// The stream is one JSON object per line, so this and [encodeLine] are the
  /// pair a transport actually uses.
  factory ProtocolFrame.decodeLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      throw ProtocolFormatException(
        'line is not JSON (${error.message})',
        line,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ProtocolFormatException('line is not a JSON object', line);
    }
    return ProtocolFrame.fromJson(decoded);
  }

  /// Where the stream stands as of this frame.
  final Cursor cursor;

  /// The `type` string this frame carries on the wire.
  String get type;

  /// Whether this frame marks the end of replay.
  ///
  /// True only on [ReadyFrame]. This is the property a consumer must branch on
  /// instead of "did that delta have any events", because **a delta carrying
  /// zero events is not the end of replay** — it is a position update with
  /// nothing in it. A consumer that treats the two alike either shows a blank
  /// screen forever (waiting for a `ready` it decided it already saw) or
  /// declares itself live while replay is still running.
  bool get marksEndOfReplay => false;

  /// This frame as a JSON object.
  Map<String, Object?> toJson();

  /// This frame as one NDJSON line, with no trailing newline.
  String encodeLine() => jsonEncode(toJson());

  @override
  String toString() => encodeLine();
}

/// End of replay: everything the consumer asked to catch up on has been sent.
///
/// Emitted once per `watch`, after the backlog and before the live deltas —
/// *"so attaching is never a blank screen"* (`docs/01-plan.md` §7). Its
/// [cursor] is the position the backlog ended at, which is also the position a
/// consumer that reconnects immediately should resume from.
final class ReadyFrame extends ProtocolFrame {
  /// Creates the frame at [cursor].
  const ReadyFrame({required super.cursor});

  /// The `type` string.
  static const String wireType = 'ready';

  /// Decodes a `ready` object.
  factory ReadyFrame.fromJson(Map<String, Object?> json) =>
      ReadyFrame(cursor: _cursorOf(json));

  @override
  String get type => wireType;

  @override
  bool get marksEndOfReplay => true;

  @override
  Map<String, Object?> toJson() => {
    'type': wireType,
    'cursor': cursor.encode(),
  };
}

/// Proof of life on a stream with nothing to say.
///
/// *"A stream that has DIED looks the same"* as a sparse one — a tree where
/// nothing happens for ten minutes and a socket whose far end was killed emit
/// exactly the same bytes, which is none. The heartbeat is the second bit that
/// tells them apart (INV8).
///
/// It carries [sentAt] and the other frames do not, because a tick with no
/// time on it cannot distinguish "the daemon is alive now" from "this was
/// buffered three minutes ago and the daemon has since died". The consumer
/// computes staleness from this instant; it must never estimate one
/// (`docs/01-plan.md` §7 — *never estimate an age*).
final class HeartbeatFrame extends ProtocolFrame {
  /// Creates a heartbeat stamped [sentAt], which is stored in UTC.
  HeartbeatFrame({required super.cursor, required DateTime sentAt})
    : sentAt = sentAt.toUtc();

  /// The `type` string.
  static const String wireType = 'heartbeat';

  /// Decodes a `heartbeat` object.
  factory HeartbeatFrame.fromJson(Map<String, Object?> json) =>
      HeartbeatFrame(cursor: _cursorOf(json), sentAt: _instantOf(json, 'at'));

  /// When the daemon emitted this frame. UTC.
  final DateTime sentAt;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': wireType,
    'cursor': cursor.encode(),
    'at': sentAt.toIso8601String(),
  };
}

/// The stream is ending, and this is why.
///
/// *"A stream that simply stops did not end, it broke."* Without a `bye` the
/// consumer cannot tell an orderly daemon shutdown from a killed socket, and
/// the safe reading of that ambiguity — assume it broke, reconnect — is wrong
/// half the time and costs a reconnect storm the other half.
///
/// The [cursor] is **this instance's** position, not the consumer's. On a
/// [ByeReason.refused] bye that is the whole point: the consumer's cursor was
/// rejected, and what it needs next is where this daemon actually stands.
final class ByeFrame extends ProtocolFrame {
  /// Creates a bye at [cursor] with [reason] and an optional [detail].
  const ByeFrame({required super.cursor, required this.reason, this.detail});

  /// The `type` string.
  static const String wireType = 'bye';

  /// Decodes a `bye` object.
  factory ByeFrame.fromJson(Map<String, Object?> json) {
    final reason = json['reason'];
    if (reason is! String) {
      throw ProtocolFormatException('bye has no "reason"', jsonEncode(json));
    }
    final detail = json['detail'];
    if (detail != null && detail is! String) {
      throw ProtocolFormatException('bye "detail" is not a string');
    }
    return ByeFrame(
      cursor: _cursorOf(json),
      reason: ByeReason.fromWire(reason),
      detail: detail as String?,
    );
  }

  /// Builds the bye that answers a refused `--since`, carrying the refusal's
  /// own words rather than a second wording of them.
  ///
  /// [at] is where this daemon stands, which is what the consumer needs in
  /// order to start again.
  factory ByeFrame.refusing(CursorRefused refusal, {required Cursor at}) =>
      ByeFrame(cursor: at, reason: ByeReason.refused, detail: refusal.reason);

  /// Why the stream ended.
  final ByeReason reason;

  /// Free text expanding on [reason]. Omitted from JSON when null.
  final String? detail;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': wireType,
    'cursor': cursor.encode(),
    'reason': reason.wire,
    if (detail != null) 'detail': detail,
  };
}

/// A batch of feed events, and the position they carry the consumer to.
///
/// The events are the deltas; the cursor is the picture they are deltas
/// against. [cursor] must equal the `seq` of the last event, so a consumer
/// that stores the cursor after handling the batch can never end up claiming a
/// position it was not actually fed to.
final class DeltaFrame extends ProtocolFrame {
  /// Creates a delta carrying [events] and ending at [cursor].
  ///
  /// Refuses, rather than repairs, three shapes that would each corrupt a
  /// consumer's position silently: events out of order, a repeated `seq`, and
  /// a cursor that disagrees with the last event. The feed's `seq` is
  /// monotonic and gapless by construction (the schema's append-only triggers
  /// in `lib/src/store/schema.dart`), so any of these means a caller assembled
  /// the batch wrongly — and a batch whose cursor runs ahead of its own
  /// contents makes the consumer skip the difference forever.
  ///
  /// An **empty** batch is allowed. It is a position update with nothing in
  /// it, which is a different thing from the end of replay: see
  /// [ProtocolFrame.marksEndOfReplay].
  DeltaFrame({required super.cursor, required List<SproutEvent> events})
    : events = List.unmodifiable(events) {
    for (var i = 1; i < events.length; i++) {
      if (events[i].seq <= events[i - 1].seq) {
        throw ArgumentError.value(
          events[i].seq,
          'events',
          'seq must strictly increase (after ${events[i - 1].seq})',
        );
      }
    }
    if (events.isNotEmpty && events.last.seq != cursor.position) {
      throw ArgumentError.value(
        cursor.position,
        'cursor',
        'must be the last event seq (${events.last.seq})',
      );
    }
  }

  /// The `type` string.
  static const String wireType = 'delta';

  /// Decodes a `delta` object.
  factory DeltaFrame.fromJson(Map<String, Object?> json) {
    final events = json['events'];
    if (events is! List) {
      throw ProtocolFormatException('delta has no "events"', jsonEncode(json));
    }
    return DeltaFrame(
      cursor: _cursorOf(json),
      events: [for (final event in events) eventFromJson(_objectOf(event))],
    );
  }

  /// The events, oldest first. Unmodifiable.
  final List<SproutEvent> events;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': wireType,
    'cursor': cursor.encode(),
    'events': [for (final event in events) eventToJson(event)],
  };
}

/// One feed event on the wire.
///
/// The mapping lives here rather than on [SproutEvent] on purpose: the store's
/// column names are a fact about a file on disk and the protocol's field names
/// are a fact about a wire, and one type owning both would make a rename in
/// either place silently a breaking change in the other. They happen to agree
/// today, and this function is where that stays a choice.
Map<String, Object?> eventToJson(SproutEvent event) => {
  'seq': event.seq,
  'node_id': event.nodeId,
  'ts': event.ts.toUtc().toIso8601String(),
  'kind': event.kind,
  'payload': event.payload,
};

/// Reads back what [eventToJson] wrote.
SproutEvent eventFromJson(Map<String, Object?> json) {
  final seq = json['seq'];
  if (seq is! int) {
    throw ProtocolFormatException('event "seq" is not an integer');
  }
  final nodeId = json['node_id'];
  if (nodeId is! String) {
    throw ProtocolFormatException('event "node_id" is not a string');
  }
  final kind = json['kind'];
  if (kind is! String) {
    throw ProtocolFormatException('event "kind" is not a string');
  }
  final ts = json['ts'];
  if (ts is! String) {
    throw ProtocolFormatException('event "ts" is not a string');
  }
  final DateTime parsed;
  try {
    parsed = DateTime.parse(ts).toUtc();
  } on FormatException {
    throw ProtocolFormatException('event "ts" is not an instant', ts);
  }
  return SproutEvent(
    seq: seq,
    nodeId: nodeId,
    ts: parsed,
    kind: kind,
    payload: _objectOf(json['payload']),
  );
}

Cursor _cursorOf(Map<String, Object?> json) {
  final value = json['cursor'];
  if (value is! String) {
    throw ProtocolFormatException('frame has no "cursor"', jsonEncode(json));
  }
  final cursor = Cursor.tryParse(value);
  if (cursor == null) {
    throw ProtocolFormatException('frame cursor is not a cursor', value);
  }
  return cursor;
}

Map<String, Object?> _objectOf(Object? value) {
  if (value is! Map) {
    throw ProtocolFormatException('expected a JSON object', '$value');
  }
  return {for (final entry in value.entries) '${entry.key}': entry.value};
}

DateTime _instantOf(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw ProtocolFormatException('frame has no "$key"', jsonEncode(json));
  }
  try {
    return DateTime.parse(value).toUtc();
  } on FormatException {
    throw ProtocolFormatException('frame "$key" is not an instant', value);
  }
}
