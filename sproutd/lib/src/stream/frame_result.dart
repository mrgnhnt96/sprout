part of 'frame.dart';

/// The end of a turn — **not the end of the process**, and not necessarily the
/// last one.
///
/// Two traps, both captured in `B.ndjson` and both silent (INV12):
///
/// 1. **A run can emit more than one `result`.** The second there carries
///    `origin: {"kind": "task-notification"}` — the root waking up to a
///    background child that finished after the root had already answered — and
///    `total_cost_usd` is cumulative across them (`0.2316953` → `0.2415507`).
///    Take the **last** result; stopping at the first understates the run.
/// 2. **The process stays alive afterwards.** In `C`/`C2` it ran for the full
///    90 s the probe waited and exited only on stdin EOF. That is the
///    long-lived steerable session sprout needs, and it is why "a result
///    arrived" must never be wired to "the session ended".
final class ResultFrame extends StreamFrame {
  /// Wraps a `result` frame.
  const ResultFrame(super.raw);

  /// e.g. `success`, `error_max_turns`.
  String? get subtype => asString(raw['subtype']);

  /// The final assistant text.
  String? get result => asString(raw['result']);

  /// Whether the turn ended in error.
  ///
  /// **A weak signal.** A steer the model refused as prompt injection produced
  /// `is_error: false` and `subtype: "success"`, with nothing anywhere in the
  /// frame marking the refusal (INV11, `C.ndjson`).
  bool get isError => asBool(raw['is_error']) ?? false;

  /// Turns in this result's span.
  int? get numTurns => asInt(raw['num_turns']);

  /// Wall-clock milliseconds.
  int? get durationMs => asInt(raw['duration_ms']);

  /// Milliseconds spent in API calls.
  int? get durationApiMs => asInt(raw['duration_api_ms']);

  /// Time to first token.
  int? get ttftMs => asInt(raw['ttft_ms']);

  /// Why generation stopped, e.g. `end_turn`.
  String? get stopReason => asString(raw['stop_reason']);

  /// Why the turn ended, as the CLI describes it.
  String? get terminalReason => asString(raw['terminal_reason']);

  /// **Cumulative** dollars for the whole run so far, not for this turn.
  double? get totalCostUsd => asDouble(raw['total_cost_usd']);

  /// Token counts for this result.
  Usage? get usage {
    final usage = mapAt(raw, 'usage');
    return usage == null ? null : Usage(usage);
  }

  /// Per-model breakdown, keyed by model id.
  Map<String, Object?> get modelUsage => mapAt(raw, 'modelUsage') ?? const {};

  /// What woke the session up for this turn.
  ///
  /// **Absent, not null, on a normal turn end** — the key is missing entirely
  /// from all five single-result fixtures and from `B.ndjson`'s first result,
  /// which is why [originKind] answers null for both cases and [isTaskNotified]
  /// is the question to ask instead.
  Map<String, Object?>? get origin => mapAt(raw, 'origin');

  /// `task-notification` when a background child's completion drove this turn,
  /// else null.
  String? get originKind => asString(origin?['kind']);

  /// Whether a background child's completion drove this turn.
  bool get isTaskNotified => originKind == 'task-notification';

  /// Whether this is the ordinary end of a user turn.
  bool get isEndOfUserTurn => originKind == null;

  /// Tool calls that were refused.
  ///
  /// The **only** place a sprout gate's own denial is visible in the stream:
  /// [SubagentStats.refused] counts Claude Code's refusals and stayed at zero
  /// while a hook-denied spawn landed here (INV14, `E.ndjson`). Even so, sprout
  /// must keep its own count — a denial it issued before a launch may never
  /// reach the model at all.
  List<PermissionDenial> get permissionDenials => [
    for (final denial in objectsIn(raw['permission_denials']))
      PermissionDenial(denial),
  ];

  /// Denials of the spawn tool, under either of its names.
  List<PermissionDenial> get spawnDenials =>
      permissionDenials.where((d) => d.isSpawnDenial).toList();

  /// Whole-run subagent counters, or null if the frame carried none.
  SubagentStats? get subagentStats {
    final stats = mapAt(raw, 'subagent_stats');
    return stats == null ? null : SubagentStats(stats);
  }
}

/// One refused tool call.
class PermissionDenial {
  /// Wraps one `permission_denials` entry.
  const PermissionDenial(this.raw);

  /// The entry as it arrived.
  final Map<String, Object?> raw;

  /// The tool that was refused.
  ///
  /// **Spelled `Task` here** while the same tool is `Agent` in `system/init`,
  /// in `PreToolUse.tool_name` and in the assistant `tool_use` block. Compare
  /// through [isSpawnDenial], never against one literal.
  String? get toolName => asString(raw['tool_name']);

  /// The `toolu_…` id of the refused call.
  String? get toolUseId => asString(raw['tool_use_id']);

  /// The arguments the call would have had.
  Map<String, Object?> get toolInput => mapAt(raw, 'tool_input') ?? const {};

  /// Whether the refused call was a spawn, under either spelling.
  bool get isSpawnDenial => isSpawnTool(toolName);
}

/// Whole-run counters for the subagents a session created.
///
/// A gift for the UI and for budget logic — with one hole, stated here rather
/// than discovered later: **[refused] counts only Claude Code's own
/// refusals.** A hook-denied spawn left all three counters at zero (INV14).
class SubagentStats {
  /// Wraps a `subagent_stats` object.
  const SubagentStats(this.raw);

  /// The object as it arrived.
  final Map<String, Object?> raw;

  /// Nodes created.
  int? get spawned => asInt(raw['spawned']);

  /// The deepest node in the run.
  int? get maxDepth => asInt(raw['max_depth']);

  /// Nodes created by a subagent rather than by the root.
  int? get spawnedBySubagents => asInt(raw['spawned_by_subagents']);

  /// Nodes that finished.
  int? get completed => asInt(raw['completed']);

  /// Nodes that failed.
  int? get failed => asInt(raw['failed']);

  /// Nodes launched in the background.
  int? get startedInBackground => asInt(raw['started_in_background']);

  /// `background` / `foreground` / `unset` request counts.
  Map<String, Object?> get requested => mapAt(raw, 'requested') ?? const {};

  /// `parent` / `user` / `system` kill counts.
  Map<String, Object?> get killed => mapAt(raw, 'killed') ?? const {};

  /// `depth_limit` / `concurrency_limit` / `budget` refusal counts, **as
  /// Claude Code counts them.** Sprout's own refusals are not in here.
  Map<String, Object?> get refused => mapAt(raw, 'refused') ?? const {};

  /// Nodes per subagent type.
  Map<String, Object?> get byType => mapAt(raw, 'by_type') ?? const {};
}
