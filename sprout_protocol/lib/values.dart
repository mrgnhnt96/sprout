/// The values that travel on the wire and sit in the store.
///
/// Pure data with no I/O of any kind: a [SproutEvent] is a row that was read
/// back, a [SproutNode] is one agent session, and neither knows how it was
/// obtained. They live here rather than in `package:sproutd/store.dart`
/// because both ends of the protocol need them and only one end has a database
/// — that was finding F-07, and `pubspec.yaml` records what it cost.
///
/// `package:sproutd/store.dart` re-exports this library, so every existing
/// importer of `SproutEvent`, `SproutNode`, `NodeStatus` and `TreeNode` reads
/// exactly the same declarations from exactly the same path as before.
///
/// The event `kind` strings live here too, for the same reason the types do:
/// the producer writes them into a column that travels over the socket and the
/// browser branches on what it reads back, so they are wire vocabulary that
/// both ends need one declaration of. That was finding F-11 for the two node
/// kinds and F-12 for the five `runner.*` launch and lifecycle kinds.
///
/// The `hook.*` kinds are here for the same reason, declared ahead of their
/// producer rather than behind it: P8-01 added the vocabulary and the parser,
/// and P8-02 is what writes a row. The parser itself is deliberately **not**
/// here — it lives in `package:sproutd/hooks.dart`, on `StreamFrame`'s
/// precedent, because parsing what an external producer sends is the daemon's
/// job and only the kinds cross sprout's own wire.
///
/// The `worktree.*` kinds are P4-03's, and are here for the third time over
/// the same argument. They record what sprout did to the git worktree a child
/// session runs in — created, torn down, or *kept* because tearing it down
/// would have destroyed work — and a board branching on them reads them off the
/// same socket as everything else.
///
/// The `acceptance.*` kinds are P4-06's, and are the fourth. They record the
/// parent's per-return judgement of one child against the machine-checkable
/// success condition its brief carried (`docs/01-plan.md` §2.4, §2.5) — three
/// kinds, because *undecidable* is not a variety of rejected.
///
/// Implementation lives under `lib/src/values/`.
library;

export 'src/values/event.dart' show SproutEvent;
export 'src/values/kinds.dart'
    show
        acceptanceAcceptedKind,
        acceptanceKindPrefix,
        acceptanceRejectedKind,
        acceptanceUndecidableKind,
        hookKindForEventName,
        hookKindPrefix,
        hookKindsByEventName,
        hookMalformedKind,
        hookNotificationKind,
        hookPostCompactKind,
        hookPostToolUseKind,
        hookPreCompactKind,
        hookPreToolUseKind,
        hookSessionEndKind,
        hookSessionStartKind,
        hookStopKind,
        hookSubagentStartKind,
        hookSubagentStopKind,
        hookUnknownKind,
        hookUserPromptSubmitKind,
        nodeObservedKind,
        nodeUpdatedKind,
        observedProcessKind,
        runnerExitedKind,
        runnerLaunchFailedKind,
        runnerRefusedKind,
        runnerSessionKind,
        runnerSpawnedKind,
        worktreeCreatedKind,
        worktreeKeptKind,
        worktreeKindPrefix,
        worktreeRemovedKind;
export 'src/values/node.dart' show NodeStatus, SproutNode, TreeNode;
