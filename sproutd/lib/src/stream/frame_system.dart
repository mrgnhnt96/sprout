part of 'frame.dart';

/// A `system` frame, discriminated by `subtype`.
///
/// Sealed for the same reason and with the same escape hatch as
/// [StreamFrame]: [SystemUnknownFrame] absorbs any subtype this file does not
/// model, and two such subtypes are already sitting in the phase-0 fixtures —
/// `notification` (`D.ndjson`) and `commands_changed` (`C2.ndjson`), neither of
/// which `docs/research/17-observed-schemas.md` §4 describes. They are the
/// proof that closing this set would have been wrong, and they are left untyped
/// on purpose: the frames were captured, their field semantics were not written
/// up, and INV10 does not let this file invent the difference.
sealed class SystemFrame extends StreamFrame {
  const SystemFrame(super.raw);

  /// Builds the typed system frame for one decoded `system` object.
  factory SystemFrame.fromJson(Map<String, Object?> raw) =>
      switch (asString(raw['subtype'])) {
        'init' => SystemInitFrame(raw),
        'status' => SystemStatusFrame(raw),
        'thinking_tokens' => SystemThinkingTokensFrame(raw),
        'hook_started' => HookStartedFrame(raw),
        'hook_response' => HookResponseFrame(raw),
        'task_started' => TaskStartedFrame(raw),
        'task_progress' => TaskProgressFrame(raw),
        'task_updated' => TaskUpdatedFrame(raw),
        'task_notification' => TaskNotificationFrame(raw),
        'background_tasks_changed' => BackgroundTasksChangedFrame(raw),
        _ => SystemUnknownFrame(raw),
      };

  /// The wire `subtype`, or null if the frame carried none.
  String? get subtype => asString(raw['subtype']);
}

/// Session provenance: what this process is, where, and with what tools.
///
/// **Emitted once per turn, not once per process** — `B.ndjson` has two,
/// because the root woke up a second time for a background child's result. Any
/// code that treats an `init` as "the session started" will double-count.
final class SystemInitFrame extends SystemFrame {
  /// Wraps a `system/init` frame.
  const SystemInitFrame(super.raw);

  /// The working directory the session was launched in.
  String? get cwd => asString(raw['cwd']);

  /// The model, e.g. `claude-haiku-4-5-20251001`.
  String? get model => asString(raw['model']);

  /// The CLI version, e.g. `2.1.252`. The only in-band version signal there is,
  /// and the thing to check when a frame stops looking like its fixture.
  String? get claudeCodeVersion => asString(raw['claude_code_version']);

  /// One of `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`,
  /// `plan`. There is no `default` in v2.1.252 (`17` §9).
  String? get permissionMode => asString(raw['permissionMode']);

  /// The tools available to the session.
  ///
  /// Where the spawn tool is spelled `Agent`; see [spawnToolNames] for why that
  /// matters.
  List<String> get tools => [
    for (final tool in asList(raw['tools']) ?? const <Object?>[])
      ?asString(tool),
  ];

  /// Whether the session can spawn nodes at all.
  bool get canSpawn => tools.any(isSpawnTool);

  /// The `~/.claude` files loaded as ambient context.
  List<String> get memoryPaths => [
    for (final path in asList(raw['memory_paths']) ?? const <Object?>[])
      ?asString(path),
  ];
}

/// Liveness. `status` was observed as `requesting`.
final class SystemStatusFrame extends SystemFrame {
  /// Wraps a `system/status` frame.
  const SystemStatusFrame(super.raw);

  /// The reported status.
  String? get status => asString(raw['status']);
}

/// Progress while the model is thinking.
final class SystemThinkingTokensFrame extends SystemFrame {
  /// Wraps a `system/thinking_tokens` frame.
  const SystemThinkingTokensFrame(super.raw);

  /// Running estimate of thinking tokens spent this turn.
  int? get estimatedTokens => asInt(raw['estimated_tokens']);

  /// The change since the previous such frame.
  int? get estimatedTokensDelta => asInt(raw['estimated_tokens_delta']);
}

/// A hook has begun running.
final class HookStartedFrame extends SystemFrame {
  /// Wraps a `system/hook_started` frame.
  const HookStartedFrame(super.raw);

  /// Unique per invocation, but not stable across runs.
  String? get hookId => asString(raw['hook_id']);

  /// **The event name, not the script.** Sprout cannot identify its own hook
  /// from the stream alone (`17` §7): `--settings` is additive, so plugin- and
  /// user-level hooks keep firing alongside sprout's.
  String? get hookName => asString(raw['hook_name']);

  /// The hook event, e.g. `PreToolUse`, `Stop`.
  String? get hookEvent => asString(raw['hook_event']);
}

/// A hook has finished, with its outcome.
///
/// The live view of every gate decision. **Exit 2 blocks and exit 0 allows** on
/// a `Stop` hook — `06` had this exactly inverted, and built as written every
/// sprout gate would have failed open (INV10; verified in `D.ndjson`).
final class HookResponseFrame extends SystemFrame {
  /// Wraps a `system/hook_response` frame.
  const HookResponseFrame(super.raw);

  /// Matches the [HookStartedFrame.hookId] of the invocation this answers.
  String? get hookId => asString(raw['hook_id']);

  /// The event name, not the script. See [HookStartedFrame.hookName].
  String? get hookName => asString(raw['hook_name']);

  /// The hook event, e.g. `PreToolUse`, `Stop`.
  String? get hookEvent => asString(raw['hook_event']);

  /// The process exit code.
  int? get exitCode => asInt(raw['exit_code']);

  /// e.g. `success`, `error`.
  String? get outcome => asString(raw['outcome']);

  /// Whatever the hook wrote to stdout — the JSON channel a `PreToolUse` deny
  /// travels on.
  String? get stdout => asString(raw['stdout']);

  /// Whatever the hook wrote to stderr — **the steering channel** for a `Stop`
  /// gate, injected into the conversation verbatim. A gate that blocks without
  /// explaining wastes the turn.
  String? get stderr => asString(raw['stderr']);

  /// Whether this hook blocked. True only for a `Stop`-family exit 2.
  bool get blocked => exitCode == 2;
}

/// A `system` frame that is about one task (one node).
mixin TaskFrame on SystemFrame {
  /// The node's `agent_id`-namespace id, e.g. `aab408509339890dd`.
  ///
  /// A different namespace from the `toolu_…` id the same node reports as its
  /// `parent_tool_use_id`; [toolUseId] is the join between the two.
  String? get taskId => asString(raw['task_id']);

  /// The `toolu_…` id of the spawn call that created this node.
  String? get toolUseId => asString(raw['tool_use_id']);
}

/// A node was created. The start of the lifecycle.
final class TaskStartedFrame extends SystemFrame with TaskFrame {
  /// Wraps a `system/task_started` frame.
  const TaskStartedFrame(super.raw);

  /// The node's one-line description.
  String? get description => asString(raw['description']);

  /// The subagent type, e.g. `general-purpose`.
  String? get subagentType => asString(raw['subagent_type']);

  /// Whether the node was launched in the background.
  bool? get isBackgrounded => asBool(raw['is_backgrounded']);

  /// **Depth, reported directly.** Observed `1` for a root's child and `2` for
  /// its grandchild. `06` listed depth as not queryable from inside a session;
  /// it is, and this is the field.
  int? get spawnDepth => asInt(raw['spawn_depth']);

  /// e.g. `local_agent`.
  String? get taskType => asString(raw['task_type']);

  /// The prompt the node was given.
  String? get prompt => asString(raw['prompt']);
}

/// Live per-node cost and current activity, mid-run.
///
/// **This is the control-plane number (INV13.)** Per-node spend comes from
/// here, never from a heuristic: `isSidechain` misses 98% of multi-agent spend
/// on this CLI version.
final class TaskProgressFrame extends SystemFrame with TaskFrame {
  /// Wraps a `system/task_progress` frame.
  const TaskProgressFrame(super.raw);

  /// The node's one-line description.
  String? get description => asString(raw['description']);

  /// The subagent type, e.g. `general-purpose`.
  String? get subagentType => asString(raw['subagent_type']);

  /// Tokens, tool calls and elapsed time so far.
  TaskUsage? get usage {
    final usage = mapAt(raw, 'usage');
    return usage == null ? null : TaskUsage(usage);
  }

  /// The tool the node is running right now.
  String? get lastToolName => asString(raw['last_tool_name']);
}

/// A node changed state.
final class TaskUpdatedFrame extends SystemFrame with TaskFrame {
  /// Wraps a `system/task_updated` frame.
  const TaskUpdatedFrame(super.raw);

  /// The changed fields only, not the whole node.
  Map<String, Object?> get patch => mapAt(raw, 'patch') ?? const {};

  /// The new status, if the patch carried one. Observed: `completed`.
  ///
  /// Left an open string rather than an enum: one value has been captured, and
  /// INV10 does not let this file name the ones it has not seen.
  String? get status => asString(patch['status']);

  /// Epoch milliseconds, if the patch carried an end time.
  int? get endTime => asInt(patch['end_time']);
}

/// A node finished, with its result. The end of the lifecycle.
///
/// **Not the end of its parent's**, and not the end of the process (INV12): in
/// `B.ndjson` a grandchild notified after its parent had already stopped, and
/// its result was delivered to the *root*.
final class TaskNotificationFrame extends SystemFrame with TaskFrame {
  /// Wraps a `system/task_notification` frame.
  const TaskNotificationFrame(super.raw);

  /// Observed: `completed`. Open for the same reason as
  /// [TaskUpdatedFrame.status].
  String? get status => asString(raw['status']);

  /// Where the node's full output was written.
  String? get outputFile => asString(raw['output_file']);

  /// The node's final message, e.g. `CHILD`.
  String? get summary => asString(raw['summary']);

  /// The node's final token, tool and duration totals.
  TaskUsage? get usage {
    final usage = mapAt(raw, 'usage');
    return usage == null ? null : TaskUsage(usage);
  }
}

/// The set of background nodes that are still live, restated in full.
///
/// A snapshot, not a delta: an empty [tasks] means nothing is running, which is
/// how a subtree is observed to have drained.
final class BackgroundTasksChangedFrame extends SystemFrame {
  /// Wraps a `system/background_tasks_changed` frame.
  const BackgroundTasksChangedFrame(super.raw);

  /// Every currently-live background task.
  List<BackgroundTask> get tasks => [
    for (final task in objectsIn(raw['tasks'])) BackgroundTask(task),
  ];
}

/// One entry of [BackgroundTasksChangedFrame.tasks].
class BackgroundTask {
  /// Wraps one task entry.
  const BackgroundTask(this.raw);

  /// The entry as it arrived.
  final Map<String, Object?> raw;

  /// The node's `agent_id`-namespace id.
  String? get taskId => asString(raw['task_id']);

  /// e.g. `local_agent`.
  String? get taskType => asString(raw['task_type']);

  /// The node's one-line description.
  String? get description => asString(raw['description']);
}

/// Tokens, tool calls and elapsed time for one node.
class TaskUsage {
  /// Wraps a task `usage` object.
  const TaskUsage(this.raw);

  /// The `usage` object as it arrived.
  final Map<String, Object?> raw;

  /// Tokens the node has spent, as the control plane reports them.
  int? get totalTokens => asInt(raw['total_tokens']);

  /// Tool calls the node has made.
  int? get toolUses => asInt(raw['tool_uses']);

  /// Wall-clock milliseconds the node has been running.
  int? get durationMs => asInt(raw['duration_ms']);

  @override
  String toString() =>
      'TaskUsage($totalTokens tokens, $toolUses tools, ${durationMs}ms)';
}

/// A `system` frame whose `subtype` this file does not model.
///
/// See [SystemFrame] for why this is a normal outcome rather than an error, and
/// for the two subtypes already in the fixtures that land here.
final class SystemUnknownFrame extends SystemFrame {
  /// Wraps an unrecognised `system` frame.
  const SystemUnknownFrame(super.raw);
}
