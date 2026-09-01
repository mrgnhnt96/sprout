import 'frame.dart';

/// The observed lifecycle of one node, folded from the `system/task_*` family.
///
/// ```
/// task_started → task_progress* → task_updated → task_notification
/// ```
///
/// That sequence is a complete node lifecycle — creation with depth and
/// description, live token spend and current tool, a state transition, and a
/// final result — delivered live, with **no transcript parsing and no
/// `isSidechain` heuristic** (INV13, which is the rule this family exists to
/// let sprout obey). `docs/research/17-observed-schemas.md` §4 records that the
/// whole family is absent from the superseded `06`.
///
/// The two status fields are open strings rather than an enum. Only
/// `completed` has been captured; INV10 does not let this file name the values
/// it has not seen, and an enum would have to invent them.
class TaskLifecycle {
  TaskLifecycle._(this.taskId);

  /// The node's `agent_id`-namespace id, e.g. `aab408509339890dd`.
  final String taskId;

  /// The `toolu_…` id of the spawn call that created this node — the join to
  /// the tree, whose nodes are keyed by that id.
  String? toolUseId;

  /// The node's one-line description. Refreshed by later frames, which have
  /// been observed to carry a *different* description from `task_started`.
  String? description;

  /// The subagent type, e.g. `general-purpose`.
  String? subagentType;

  /// Whether the node was launched in the background.
  bool? isBackgrounded;

  /// Depth as the control plane reported it.
  int? spawnDepth;

  /// e.g. `local_agent`.
  String? taskType;

  /// The prompt the node was given, from `task_started`.
  String? prompt;

  /// The most recent usage seen, from `task_progress` and then
  /// `task_notification`. Monotonic in practice but not assumed to be.
  TaskUsage? usage;

  /// The tool the node was last seen running.
  String? lastToolName;

  /// The latest status from `task_updated` or `task_notification`.
  String? status;

  /// Epoch milliseconds from `task_updated.patch.end_time`.
  int? endTime;

  /// The node's final message, from `task_notification`.
  String? summary;

  /// Where the node's full output was written.
  String? outputFile;

  /// How many `task_progress` frames arrived.
  int progressUpdates = 0;

  /// Whether `task_started` was seen, as opposed to the node being known only
  /// from a later frame.
  bool started = false;

  /// Whether `task_notification` was seen.
  bool notified = false;

  /// Whether the last status seen was `completed`.
  ///
  /// **Says nothing about this node's subtree** (INV12). In `B.ndjson` the
  /// child completed while its own grandchild was still running, and the
  /// grandchild's result was delivered to the root two levels up. Subtree
  /// completion is a question for the tree, not for one node's status.
  bool get isCompleted => status == 'completed';

  @override
  String toString() =>
      'TaskLifecycle($taskId, depth $spawnDepth, '
      '${status ?? 'running'}, ${usage?.totalTokens} tokens)';
}

/// Every node's lifecycle, keyed by `task_id`, plus what is still live.
class TaskLifecycles {
  /// Creates an empty set of lifecycles.
  TaskLifecycles();

  /// Folds [frames] in one call.
  factory TaskLifecycles.from(Iterable<StreamFrame> frames) {
    final lifecycles = TaskLifecycles();
    for (final frame in frames) {
      lifecycles.observe(frame);
    }
    return lifecycles;
  }

  final Map<String, TaskLifecycle> _tasks = {};
  List<BackgroundTask> _backgroundTasks = const [];

  /// Every node seen, keyed by `task_id`.
  Map<String, TaskLifecycle> get tasks => Map.unmodifiable(_tasks);

  /// The node with [taskId], or null if no frame has mentioned it.
  TaskLifecycle? operator [](String taskId) => _tasks[taskId];

  /// The most recent `background_tasks_changed` snapshot.
  ///
  /// A full restatement each time, not a delta, so an empty list means nothing
  /// is running — which is how a subtree is observed to have drained.
  List<BackgroundTask> get backgroundTasks => _backgroundTasks;

  /// Nodes whose last seen status is not `completed`.
  List<TaskLifecycle> get incomplete => [
    for (final task in _tasks.values)
      if (!task.isCompleted) task,
  ];

  /// Folds one frame in. Frames that are not `system/task_*` are ignored.
  void observe(StreamFrame frame) {
    switch (frame) {
      case TaskStartedFrame(:final taskId?):
        final task = _ensure(taskId);
        task
          ..started = true
          ..toolUseId = frame.toolUseId
          ..description = frame.description ?? task.description
          ..subagentType = frame.subagentType ?? task.subagentType
          ..isBackgrounded = frame.isBackgrounded
          ..spawnDepth = frame.spawnDepth
          ..taskType = frame.taskType
          ..prompt = frame.prompt;
      case TaskProgressFrame(:final taskId?):
        final task = _ensure(taskId);
        task
          ..toolUseId = frame.toolUseId ?? task.toolUseId
          ..description = frame.description ?? task.description
          ..subagentType = frame.subagentType ?? task.subagentType
          ..usage = frame.usage ?? task.usage
          ..lastToolName = frame.lastToolName ?? task.lastToolName;
        task.progressUpdates++;
      case TaskUpdatedFrame(:final taskId?):
        final task = _ensure(taskId);
        task
          ..status = frame.status ?? task.status
          ..endTime = frame.endTime ?? task.endTime;
      case TaskNotificationFrame(:final taskId?):
        final task = _ensure(taskId);
        task
          ..notified = true
          ..toolUseId = frame.toolUseId ?? task.toolUseId
          ..status = frame.status ?? task.status
          ..outputFile = frame.outputFile ?? task.outputFile
          ..summary = frame.summary ?? task.summary
          ..usage = frame.usage ?? task.usage;
      case BackgroundTasksChangedFrame(:final tasks):
        _backgroundTasks = tasks;
      case _:
        return;
    }
  }

  TaskLifecycle _ensure(String taskId) =>
      _tasks.putIfAbsent(taskId, () => TaskLifecycle._(taskId));
}
