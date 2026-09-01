import 'dart:convert';

/// One entry in the append-only feed.
///
/// The feed is the only durable record of what a session did, so it is written
/// once and never touched again: there is no update or delete path on this
/// class, and the schema backs that with triggers rather than with this
/// sentence (INV1 — enforcement lives in tools, never in instructions).
class SproutEvent {
  /// Creates an event as it was read back out of the store.
  const SproutEvent({
    required this.seq,
    required this.nodeId,
    required this.ts,
    required this.kind,
    required this.payload,
  });

  /// The cursor. Monotonic and gapless per database, assigned by SQLite.
  ///
  /// Phase 2's `watch --since <cursor>` resumes from this value, so it must
  /// never be reused and never run backwards.
  final int seq;

  /// The node this event is about.
  final String nodeId;

  /// When the event happened. UTC.
  final DateTime ts;

  /// A short discriminator, e.g. `spawned`, `tool_use`, `checkpoint`.
  ///
  /// Deliberately an open string rather than an enum: the kinds that matter
  /// come from the observed stream schemas, and closing the set here would
  /// force a migration every time a new frame type is captured.
  final String kind;

  /// The event body, stored as JSON in a `payload` column.
  final Map<String, Object?> payload;

  /// Renders [payload] for storage.
  String get payloadJson => jsonEncode(payload);

  @override
  String toString() => 'SproutEvent(#$seq, $nodeId, $kind)';
}
