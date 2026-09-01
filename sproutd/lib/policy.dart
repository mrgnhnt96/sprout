/// Containment: what a node is allowed to do before it is allowed to start.
///
/// The depth cap of 3, per-subtree token and dollar budgets, and the refusals
/// they produce. Containment is decided *before* a launch, and sprout counts
/// its own refusals — a limit that is only described to a model in a prompt is
/// not a limit, so every bound here is checked in code.
///
/// Implementation lives under `lib/src/policy/`. See `docs/01-plan.md` §2.1.
library;
