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
library;
