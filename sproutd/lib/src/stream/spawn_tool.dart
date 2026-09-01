/// The one tool that creates a node, and the two names it answers to.
library;

/// Every name the spawn tool is observed under in a single run.
///
/// It is `Agent` in `system/init.tools`, in `PreToolUse.tool_name` and in the
/// assistant `tool_use` block — and `Task` in
/// `result.permission_denials[].tool_name`. Both spellings were captured in the
/// same fixture set (`fixtures/phase0/streams/E.ndjson` has the denial; `Agent`
/// appears in `B.ndjson`'s `tool_use` blocks), so this is not a version skew to
/// pick a winner from. INV10's corollary: a name is not a key. Match one
/// spelling and sprout silently miscounts its own refusals.
const spawnToolNames = {'Agent', 'Task'};

/// Whether [toolName] names the spawn tool under either of its spellings.
bool isSpawnTool(String? toolName) =>
    toolName != null && spawnToolNames.contains(toolName);
