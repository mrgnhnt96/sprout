/// Spawning and owning a `claude -p` session process.
///
/// Launches the session with sprout holding both ends of the pipe
/// (`--input-format stream-json --output-format stream-json`), applies the
/// bounds `policy.dart` decided, streams frames to disk and into the store, and
/// reports the process's real ending. A live pid is not evidence of progress,
/// so liveness is three-valued: live, stalled, abandoned.
///
/// Implementation lives under `lib/src/runner/`. See `docs/01-plan.md` §5.
library;
