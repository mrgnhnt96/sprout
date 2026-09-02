/// Spawning and owning a `claude -p` session process.
///
/// Consults `policy.dart` before the launch, starts the process with stdin
/// at EOF, and streams what it writes — to a raw NDJSON file on disk first,
/// then through `stream.dart`'s parser into `store.dart`, one frame at a time
/// while the process runs. The exact invocation is [claudeArguments], every
/// flag verified against `docs/research/17-observed-schemas.md` §9.
///
/// Two things this library refuses to conclude. It does not infer completion
/// from process exit: [EndedSession] reports what the stream said, and a run
/// emits more than one `result` (INV12). And it does not lose the frames
/// before a truncated last line: a process killed mid-write ends in a
/// `MalformedFrame` that is stored like any other.
///
/// The process is behind [SessionLauncher] so the suite replays captured
/// fixtures instead of spending money; [ClaudeLauncher] is the real one.
/// Streaming input into a live session is Phase 7. Liveness — live, stalled,
/// abandoned — is Phase 6.
///
/// Implementation lives under `lib/src/runner/`. See `docs/01-plan.md` §5.
library;

// The `kind` strings this library appends — the four launch and lifecycle
// events and the one session record — are declared in
// `package:sprout_protocol/values.dart`, not here. They sit in the `kind`
// column of a row that travels over the socket to a browser that branches on
// it, so both ends need one declaration and only one end has a database. That
// was finding F-12; before it, `lib/src/liveness/measure.dart` had to spell
// three of them a second time. Re-exported so this library still publishes the
// vocabulary it writes.
export 'package:sprout_protocol/values.dart'
    show
        runnerExitedKind,
        runnerLaunchFailedKind,
        runnerRefusedKind,
        runnerSessionKind,
        runnerSpawnedKind;

export 'src/runner/launcher.dart'
    show
        ClaudeLauncher,
        SessionLauncher,
        SessionLaunch,
        SessionProcess,
        claudeArguments;
export 'src/runner/projection.dart' show StoreProjection, frameKindPrefix;
export 'src/runner/raw_log.dart' show RawLog;
export 'src/runner/session_runner.dart'
    show
        EndedSession,
        LiveSession,
        RefusedSession,
        SessionOutcome,
        SessionRequest,
        SessionRunner,
        SessionStart,
        rootBudgetUsd;
