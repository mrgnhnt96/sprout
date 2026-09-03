/// Splitting a task into children, and laying them out into waves.
///
/// A parent that has decided to delegate produces a [Decomposition]: its own
/// task, the children it plans to spawn, and — required, never inferred — the
/// [ModeChoice] saying whether this is map- or build-shaped work. [planWaves]
/// turns that into an ordered [WavePlan] in which **no two children in a wave
/// have overlapping estimated file sets, and any child whose estimate is
/// unknown is alone.** [DelegationFloor] decides whether any of it should
/// happen at all, and counts the times it said no.
///
/// `docs/01-plan.md` §11 asks Phase 4 for *"waves over estimated file sets
/// (unestimable ⇒ collides with everything)"*, taken from
/// `docs/research/07-local-harnesses.md`, which states the argument as a cost
/// asymmetry rather than a preference:
///
/// > Two leaves can be mutually unblocked and still be the same edit: the graph
/// > models dependencies, not files. A false collision costs one wave of
/// > latency; a missed one costs a merge conflict in an unattended run with
/// > nobody watching.
///
/// **The trap this library is shaped around.** An absent estimate and an empty
/// estimate are not the same value, and modelling both as an empty set of paths
/// inverts the rule exactly: an empty set overlaps nothing, so the child nobody
/// could estimate becomes the one that parallelises with everything. So
/// [FileEstimate] is sealed with three arms — [EstimatedPaths] (non-empty by
/// construction), [TouchesNothing] and [UnknownFiles] — and the last two each
/// carry a reason. It is not possible to build a child that claims to touch no
/// files without saying which of the two it means and why. That is INV8, and
/// F-23 is the same mistake one layer up: a ledger summing dollars with no
/// third state for *unknown*, where an unmeasured node contributes 0 and a
/// permit becomes indistinguishable from evidence.
///
/// Everything here is a **value or a pure function over one**: no process, no
/// filesystem, no clock, no SQL, no random. Nothing in this library spawns
/// anything, and that is what lets the layout be tested exhaustively for
/// nothing. `test/decomposition_test.dart` greps this area's own source for the
/// imports that would break that promise, the way `test/worktree_test.dart`
/// greps its area for `--force`.
///
/// **Its own area rather than a corner of `policy`.** The two answer different
/// questions — `policy` asks *what is this node allowed to start?*, judged
/// against a `SpendLedger` at one moment; this asks *what should run
/// together?*, judged against a decomposition and nothing else — and
/// `lib/policy.dart` says of itself that `ContainmentGate.admit` *"is the only
/// entry point"*, which a planner living there would make false. The dependency
/// runs one way: a plan takes a `ContainmentPolicy` as an input so a wave is
/// never planned wider than the gate could admit, and the gate knows nothing
/// about plans. This is `liveness` versus `watchdog` again — one measures, one
/// decides — and being an area is what lets the determinism promise be asserted
/// over a whole directory instead of over whichever files happen to sit beside
/// it.
///
/// **The two decisions P4-05 added, and where each one bites.** §2.3 requires
/// sprout to *"pick the mode explicitly and default build for code"*, so
/// [ModeChoice] carries both which mode is in force and **whether anybody
/// chose** — [ModeChoice.defaulted] produces `build` and says out loud that it
/// was nobody's decision, the way showrunner's `route` prints `NO RULE MATCHED
/// — defaulted to serialized` rather than quietly serializing. The mode then
/// has to change something or it is a field nobody reads, so it changes two
/// things: [Decomposition.briefFor] pushes the parent's shared decisions down
/// into every child in build and withholds them in map (§2.3's Context column),
/// and [planWaves] narrows a build plan to [buildWaveWidth] (§2.3's *"narrow
/// fan-out"*). A **map** decomposition may not carry shared decisions at all —
/// the constructor refuses it, because decisions that have to reach the
/// children mean the children are not independent.
///
/// §3's delegation floor is [DelegationFloor], and it is a **refusal that gets
/// counted**, on `ContainmentGate`'s exact shape and for its measured reason:
/// the platform counts only its own refusals, and a decision not to decompose
/// makes no tool call at all, so it leaves no trace anywhere unless sprout
/// writes it down. Read that class's doc for the part that matters most —
/// **what it does not do.** It does not implement "plausibly beyond one
/// session" and it computes no score, because neither of §3's two numbers is
/// available at decision time. The rules it does apply are properties of the
/// proposal's own layout, and the size gap it leaves open is `F-28`.
///
/// **What is still deliberately not here.** Evaluating a [SuccessCondition] is
/// P4-06's; this library only guarantees every child declares one. Nothing here
/// spawns, and a [DelegationRefusal] does not stop a caller — INV14's
/// enforcement point is `ContainmentGate.admit`, before a process exists. And
/// nothing here is persisted: the store's schema is at version 1 and a
/// decomposition has no table.
///
/// Implementation lives under `lib/src/decomposition/`. See `docs/01-plan.md`
/// §2.3, §2.4, §3 and §11.
library;

export 'src/decomposition/decomposition.dart'
    show Decomposition, PlannedChild, SuccessCondition;
export 'src/decomposition/estimate.dart'
    show
        EstimatedPaths,
        FileEstimate,
        TouchesNothing,
        UnknownFiles,
        pathsOverlap;
export 'src/decomposition/floor.dart'
    show
        DelegationFloor,
        DelegationPermit,
        DelegationRefusal,
        FloorCounts,
        FloorDecision,
        FloorReason;
export 'src/decomposition/mode.dart'
    show DelegationMode, ModeChoice, buildWaveWidth;
export 'src/decomposition/waves.dart' show Wave, WavePlan, planWaves;
