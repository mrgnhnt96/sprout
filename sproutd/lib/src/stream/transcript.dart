import 'content.dart';
import 'frame.dart';
import 'lifecycle.dart';
import 'parser.dart';
import 'tree.dart';

/// Everything one session's stream says, folded into one object.
///
/// Incremental, so the runner can [observe] frames as they arrive and read the
/// same view a completed parse would give. Three of its answers are the ones
/// most easily got wrong, and each is a getter here so a caller cannot get them
/// wrong by hand:
///
/// - [result] is the **last** `result` frame, not the first (INV12).
/// - [usageByMessageId] deduplicates by `message.id`, without which every token
///   figure inflates 2.02× (INV13).
/// - [tree] reconstructs the agent tree from `parent_tool_use_id`, which is not
///   a per-frame parent pointer.
class StreamTranscript {
  /// Creates an empty transcript.
  StreamTranscript();

  /// Folds [frames] in one call.
  factory StreamTranscript.from(Iterable<StreamFrame> frames) {
    final transcript = StreamTranscript();
    for (final frame in frames) {
      transcript.observe(frame);
    }
    return transcript;
  }

  /// Parses a whole NDJSON document and folds it in one call.
  ///
  /// [duplicatesDropped] and [framesWithoutUuid] carry the parser's dedupe
  /// counters through, so a caller that takes this shortcut still sees them.
  factory StreamTranscript.parse(String ndjson) {
    final parser = StreamParser();
    final transcript = StreamTranscript.from(parser.parseAll(ndjson))
      ..duplicatesDropped = parser.duplicatesDropped
      ..framesWithoutUuid = parser.framesWithoutUuid;
    return transcript;
  }

  final List<StreamFrame> _frames = [];
  final List<ResultFrame> _results = [];
  final Map<String, Usage> _usageByMessageId = {};

  /// The agent tree.
  final SessionTree tree = SessionTree();

  /// Every node's lifecycle, from the `system/task_*` family.
  final TaskLifecycles tasks = TaskLifecycles();

  /// Frames the parser dropped as duplicate `uuid`s, when known.
  int duplicatesDropped = 0;

  /// Frames the parser passed through without a `uuid`, when known.
  int framesWithoutUuid = 0;

  /// Every frame folded in, in order.
  List<StreamFrame> get frames => List.unmodifiable(_frames);

  /// The session id, from the first frame that carried one.
  ///
  /// **One per process, shared by every node in the tree** — a subagent does
  /// not get its own (`17` §2), so this identifies the run and never a node.
  String? sessionId;

  /// The `system/init` frames, one **per turn** rather than per process:
  /// `B.ndjson` has two.
  final List<SystemInitFrame> inits = [];

  /// Lines that were not valid JSON objects, including a truncated final line.
  final List<MalformedFrame> malformed = [];

  /// Frames whose `type` this parser does not model.
  final List<UnknownFrame> unknownFrames = [];

  /// `system` frames whose `subtype` this parser does not model.
  final List<SystemUnknownFrame> unknownSystemFrames = [];

  /// Every `result` frame, in order.
  List<ResultFrame> get results => List.unmodifiable(_results);

  /// The **last** `result`, which is the one that is true.
  ///
  /// A run can emit more than one: `B.ndjson`'s second carries
  /// `origin: {"kind": "task-notification"}` and a `total_cost_usd` that is
  /// cumulative across both (`0.2316953` → `0.2415507`). Stopping at the first
  /// understates the run, and nothing about the first frame says it is not the
  /// last one. Null until a result arrives, which is also the answer for a run
  /// that was killed before finishing.
  ResultFrame? get result => _results.isEmpty ? null : _results.last;

  /// Whether a `result` arrived at all. **Not whether the process exited** —
  /// the process stays alive after a result and ends on stdin EOF.
  bool get hasResult => _results.isNotEmpty;

  /// The run's cumulative cost, from [result].
  double? get totalCostUsd => result?.totalCostUsd;

  /// Every refused tool call, from [result].
  List<PermissionDenial> get permissionDenials =>
      result?.permissionDenials ?? const [];

  /// Refused spawns, matched under **both** names of the spawn tool.
  ///
  /// The denial record spells it `Task` where every other surface spells it
  /// `Agent`. Matching one spelling silently miscounts refusals, and a
  /// containment count that is silently zero is the failure INV14 exists to
  /// prevent.
  List<PermissionDenial> get spawnDenials => result?.spawnDenials ?? const [];

  /// Usage per assistant message, deduplicated by `message.id`.
  ///
  /// One message spans several `assistant` frames carrying identical `usage`;
  /// summing frames instead of messages inflates every figure 2.02× (INV13),
  /// and a number that is exactly twice right looks plausible in every
  /// direction.
  Map<String, Usage> get usageByMessageId =>
      Map.unmodifiable(_usageByMessageId);

  /// The four token components summed over [usageByMessageId].
  ///
  /// A headline number. The per-message values stay available above, because a
  /// sum is not a distribution (INV7) and here the distribution is the story:
  /// cache reads dwarf fresh input.
  int get totalMessageTokens =>
      _usageByMessageId.values.fold(0, (sum, usage) => sum + usage.totalTokens);

  /// Folds one frame in.
  void observe(StreamFrame frame) {
    _frames.add(frame);
    sessionId ??= frame.sessionId;
    tree.observe(frame);
    tasks.observe(frame);
    switch (frame) {
      case ResultFrame():
        _results.add(frame);
      case SystemInitFrame():
        inits.add(frame);
      case MalformedFrame():
        malformed.add(frame);
      case UnknownFrame():
        unknownFrames.add(frame);
      case SystemUnknownFrame():
        unknownSystemFrames.add(frame);
      case AssistantFrame(:final message):
        final id = message.id;
        final usage = message.usage;
        if (id != null && usage != null) _usageByMessageId[id] ??= usage;
      case _:
        return;
    }
  }
}
