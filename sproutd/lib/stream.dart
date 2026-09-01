/// Parser for the `claude -p --output-format stream-json` control plane.
///
/// Turns the NDJSON a session emits into typed frames. Every field name here
/// comes from `docs/research/17-observed-schemas.md`, captured from a live CLI;
/// `docs/research/06-claude-code-control-plane.md` is superseded and disagrees
/// in six places. Usage is deduped by `message.id`, and cost is attributed from
/// the control plane rather than inferred — never from `isSidechain`, which
/// misses the overwhelming majority of multi-agent spend.
///
/// Implementation lives under `lib/src/stream/`.
///
/// The parser is a pure function over bytes: no process, no clock, no
/// filesystem. Start at [StreamParser] for frames, [StreamTranscript] for the
/// folded view of a whole run, [SessionTree] for the agent tree, and
/// [UserPromptSubmitPayload] for the one hook payload that has to be told apart
/// from human input.
library;

export 'src/stream/content.dart'
    show
        AgentMessage,
        ContentBlock,
        TextBlock,
        ThinkingBlock,
        ToolResultBlock,
        ToolUseBlock,
        UnknownContentBlock,
        Usage;
export 'src/stream/frame.dart'
    show
        AssistantFrame,
        BackgroundTask,
        BackgroundTasksChangedFrame,
        EmittedFrame,
        HookResponseFrame,
        HookStartedFrame,
        MalformedFrame,
        PermissionDenial,
        RateLimitFrame,
        ResultFrame,
        StreamEventFrame,
        StreamFrame,
        SubagentStats,
        SystemFrame,
        SystemInitFrame,
        SystemStatusFrame,
        SystemThinkingTokensFrame,
        SystemUnknownFrame,
        TaskFrame,
        TaskNotificationFrame,
        TaskProgressFrame,
        TaskStartedFrame,
        TaskUpdatedFrame,
        TaskUsage,
        UnknownFrame,
        UserFrame;
export 'src/stream/lifecycle.dart' show TaskLifecycle, TaskLifecycles;
export 'src/stream/parser.dart' show StreamParser, parseStreamJson;
export 'src/stream/prompt.dart'
    show PromptOrigin, TaskNotification, UserPromptSubmitPayload;
export 'src/stream/spawn_tool.dart' show isSpawnTool, spawnToolNames;
export 'src/stream/transcript.dart' show StreamTranscript;
export 'src/stream/tree.dart' show AgentNode, SessionTree;
