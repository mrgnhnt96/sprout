/// Containment: what a node is allowed to do before it is allowed to start.
///
/// A depth cap defaulting to 3, dollar budgets per subtree and per run, a
/// concurrency bound, and sprout's own count of the spawns it refused.
/// Containment is decided *before* a launch, and sprout counts its own refusals
/// — a limit that is only described to a model in a prompt is not a limit, so
/// every bound here is checked in code.
///
/// Everything in this library is a pure function over a value: no process, no
/// filesystem, no clock, no SQL. That is what makes it testable enough to be
/// trusted, and it is why the bounds are constructor arguments on an immutable
/// `ContainmentPolicy` with no setter anywhere — the policy is an input to a
/// run, never an output of one (INV9).
///
/// Start at [ContainmentGate.admit]: it takes a [SpawnRequest] over a
/// [SpendLedger] and answers with a [SpawnPermit] or a [SpawnRefusal], and it
/// is the only entry point that also *records* the answer.
///
/// Token budgets are deliberately not here. Phase 1 bounds dollars, which is
/// what `docs/01-plan.md` §2.1 and §14 argue in; a token ceiling would need a
/// per-model price table sprout does not yet have.
///
/// Implementation lives under `lib/src/policy/`. See `docs/01-plan.md` §2.1.
library;

export 'src/policy/containment_gate.dart' show ContainmentGate, RefusalCounts;
export 'src/policy/containment_policy.dart'
    show
        ContainmentPolicy,
        SpawnRequest,
        defaultMaxDepth,
        defaultMaxLiveChildren,
        defaultMaxLiveNodes;
export 'src/policy/refusal.dart'
    show RefusalReason, SpawnDecision, SpawnPermit, SpawnRefusal;
export 'src/policy/spend.dart' show NodeSpend, SpendLedger;
