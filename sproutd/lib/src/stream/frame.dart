import 'content.dart';
import 'json.dart';
import 'spawn_tool.dart';

part 'frame_result.dart';
part 'frame_system.dart';

/// One frame of `claude -p --output-format stream-json`.
///
/// Sealed, so a `switch` over the observed frame types is exhaustive — but the
/// set is closed only in this file, never on the wire. [UnknownFrame] and
/// [MalformedFrame] are what make that safe: **this hierarchy never throws on
/// input.** The stream is an unstable API (INV10) and a parser that dies on an
/// unrecognised frame takes the daemon down with it, which is the one failure a
/// harness that watches from outside cannot afford.
///
/// Every field name here was copied out of a payload under
/// `docs/research/fixtures/phase0/streams/`, written up in
/// `docs/research/17-observed-schemas.md` §4.
/// `docs/research/06-claude-code-control-plane.md` is superseded.
sealed class StreamFrame {
  const StreamFrame(this.raw);

  /// Builds the typed frame for one decoded JSON object.
  ///
  /// Total: an object with no `type`, or with a `type` this file does not
  /// model, becomes an [UnknownFrame] that still carries the whole payload.
  factory StreamFrame.fromJson(Map<String, Object?> raw) =>
      switch (asString(raw['type'])) {
        'system' => SystemFrame.fromJson(raw),
        'stream_event' => StreamEventFrame(raw),
        'assistant' => AssistantFrame(raw),
        'user' => UserFrame(raw),
        'rate_limit_event' => RateLimitFrame(raw),
        'result' => ResultFrame(raw),
        _ => UnknownFrame(raw),
      };

  /// The frame exactly as it arrived, preserved on every variant.
  ///
  /// Empty on [MalformedFrame], whose payload was never valid JSON and is kept
  /// as text in [MalformedFrame.line] instead.
  final Map<String, Object?> raw;

  /// The wire `type`, or null if the frame carried none.
  String? get type => asString(raw['type']);

  /// The frame's unique id.
  ///
  /// **The dedupe key.** Unique across all 344 frames of the six phase-0
  /// captures, with none missing. Nullable anyway, because absence is a
  /// possible future and a null here must degrade to "cannot dedupe this one",
  /// not to a crash.
  String? get uuid => asString(raw['uuid']);

  /// The session id. One per `claude -p` process, **shared by every node in the
  /// tree** — a subagent does not get its own (`17` §2). It cannot identify a
  /// node; [SessionTree] exists because of that.
  String? get sessionId => asString(raw['session_id']);

  /// The frame as it arrived, for storage in the event feed.
  Map<String, Object?> toJson() => raw;
}

/// A frame that names the node that emitted it.
///
/// `parent_tool_use_id` is the single most misread field in the control plane.
/// It is **not** a per-frame parent pointer: it is the id of the `Agent` call
/// that spawned *whichever agent emitted this frame*. Read it as "who is
/// speaking", and the tree falls out of [SessionTree]'s one rule.
///
/// Declared without an `on StreamFrame` clause on purpose: a mixin constrained
/// to a sealed type is itself a possible subtype of it, which costs every
/// `switch` over [StreamFrame] its exhaustiveness. It supplies the abstract
/// [raw] it needs and the frame classes satisfy it.
mixin EmittedFrame {
  /// The frame exactly as it arrived, supplied by [StreamFrame].
  Map<String, Object?> get raw;

  /// The `toolu_…` id of the spawn call that created the emitting node, or null
  /// when the root emitted the frame.
  String? get parentToolUseId => asString(raw['parent_tool_use_id']);

  /// Whether the root session emitted this frame.
  bool get isFromRoot => parentToolUseId == null;

  /// The subagent type of the emitter, when it is a subagent.
  ///
  /// Present on subagent `assistant` and `user` frames only, as a free label
  /// for the tree — no lookup needed (`17` §2).
  String? get subagentType => asString(raw['subagent_type']);

  /// The emitting subagent's task description, when it is a subagent.
  String? get taskDescription => asString(raw['task_description']);
}

/// A raw API passthrough frame, gated on `--include-partial-messages`.
///
/// `event.type` is one of `message_start`, `content_block_start`,
/// `content_block_delta`, `content_block_stop`, `message_delta`,
/// `message_stop`. Left as an untyped [event] map: these are the Anthropic
/// streaming events verbatim, they are already typed by that API, and sprout
/// reads only [eventType] and the usage that rides on `message_start` /
/// `message_delta`.
final class StreamEventFrame extends StreamFrame with EmittedFrame {
  /// Wraps a `stream_event` frame.
  const StreamEventFrame(super.raw);

  /// The passthrough event body.
  Map<String, Object?> get event => mapAt(raw, 'event') ?? const {};

  /// The passthrough event's own `type`.
  String? get eventType => asString(event['type']);

  /// Time to first token, on `message_start`.
  int? get ttftMs => asInt(raw['ttft_ms']);
}

/// An assembled assistant message.
///
/// The frame the tree is built from: an `assistant` frame whose
/// [EmittedFrame.parentToolUseId] is `P`, carrying a `tool_use` block
/// `{name: "Agent", id: C}`, means node `P` is the parent of node `C`.
final class AssistantFrame extends StreamFrame with EmittedFrame {
  /// Wraps an `assistant` frame.
  const AssistantFrame(super.raw);

  /// The message body.
  AgentMessage get message => AgentMessage(mapAt(raw, 'message') ?? const {});

  /// The API request that produced it.
  String? get requestId => asString(raw['request_id']);

  /// The frame's timestamp, as it arrived.
  String? get timestamp => asString(raw['timestamp']);

  /// Every spawn call in this message, under either name of the spawn tool.
  ///
  /// Each element's [ToolUseBlock.id] is the id of a node this frame's emitter
  /// is the parent of.
  List<ToolUseBlock> get spawns =>
      message.toolUses.where((t) => t.isSpawn).toList();
}

/// An assembled user message: a prompt, a tool result, or a replayed steer.
final class UserFrame extends StreamFrame with EmittedFrame {
  /// Wraps a `user` frame.
  const UserFrame(super.raw);

  /// The message body.
  AgentMessage get message => AgentMessage(mapAt(raw, 'message') ?? const {});

  /// A structured mirror of the tool result, when this frame carries one.
  Map<String, Object?>? get toolUseResult => mapAt(raw, 'tool_use_result');

  /// Whether this is `--replay-user-messages` echoing back a steer sprout sent.
  ///
  /// **Delivery, not compliance (INV11).** A replayed steer proves the bytes
  /// arrived and nothing more: the same steer, phrased as an override, was
  /// replayed exactly like this and then refused by the model as prompt
  /// injection, with `result.is_error` still `false`
  /// (`fixtures/phase0/streams/C.ndjson`).
  bool get isReplay => asBool(raw['isReplay']) ?? false;

  /// Whether the harness generated this message rather than a human.
  bool get isSynthetic => asBool(raw['isSynthetic']) ?? false;

  /// The frame's timestamp, as it arrived.
  String? get timestamp => asString(raw['timestamp']);
}

/// The current state of the account's rate-limit windows.
final class RateLimitFrame extends StreamFrame {
  /// Wraps a `rate_limit_event` frame.
  const RateLimitFrame(super.raw);

  /// The `rate_limit_info` body.
  Map<String, Object?> get rateLimitInfo =>
      mapAt(raw, 'rate_limit_info') ?? const {};

  /// e.g. `allowed`.
  String? get status => asString(rateLimitInfo['status']);

  /// e.g. `unified`.
  String? get rateLimitType => asString(rateLimitInfo['rateLimitType']);

  /// When the current window resets.
  String? get resetsAt => asString(rateLimitInfo['resetsAt']);

  /// Fraction of the five-hour window consumed, if reported.
  double? get fiveHourUtilization => _utilization('five_hour');

  /// Fraction of the seven-day window consumed, if reported.
  double? get sevenDayUtilization => _utilization('seven_day');

  double? _utilization(String window) => asDouble(
    mapAt(mapAt(rateLimitInfo, 'unifiedWindows'), window)?['utilization'],
  );
}

/// A frame whose `type` this parser does not model.
///
/// Not an error and not a dropped frame: [StreamFrame.raw] round-trips the
/// whole payload, so a caller can persist it and a later sprout can promote it
/// to a typed variant once a fixture exists for it.
final class UnknownFrame extends StreamFrame {
  /// Wraps an unrecognised frame.
  const UnknownFrame(super.raw);
}

/// A line that was not a JSON object.
///
/// Two causes, both real. A corrupt line, and a **truncated final line** —
/// `claude` was killed mid-write, so the last line of the file is half a frame.
/// Neither is allowed to end the parse: the frames before it are still true.
final class MalformedFrame extends StreamFrame {
  /// Records a line that could not be decoded.
  const MalformedFrame(this.line, this.error) : super(const {});

  /// The line exactly as it arrived, so nothing is lost.
  final String line;

  /// What went wrong. A [FormatException] for invalid JSON, or a message
  /// saying the line decoded to something that was not a JSON object.
  final Object error;

  @override
  String toString() => 'MalformedFrame(${line.length} bytes: $error)';
}
