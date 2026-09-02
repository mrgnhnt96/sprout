/// Live, stalled or abandoned — measured from outside the session.
///
/// `docs/01-plan.md` §5 asks for **three** liveness verdicts, not two, and the
/// reason is the whole premise of sprout: *"A live pid proves nothing — `ps`
/// reports the same state for a parked and a computing session. A frozen
/// transcript mtime beside a live pid is the signal."*
///
/// Start at [LivenessMeasure.sweep]. It reads the node graph and the event
/// feed, and for every node answers with a [LivenessVerdict] carrying the
/// evidence it was drawn from:
///
/// - **[Liveness.live]** — the process is working, *or it is waiting on a
///   descendant that is.* The second half is the one a naive implementation
///   gets wrong, and getting it wrong is how a watchdog gets switched off.
/// - **[Liveness.stalled]** — pid alive and start-time-verified, transcript
///   frozen past [defaultFrozenAfter], nothing in the subtree advancing.
/// - **[Liveness.abandoned]** — no live process, and no honest ending.
///
/// Two answers here are **not** verdicts, and exist so a measurement never has
/// to launder something it did not see: [Liveness.ended] for a node that
/// reached one of §5's endings, and [Liveness.unmeasured] for a look that
/// failed. A `ps` that could not run is not evidence that a process is gone.
///
/// **Three things this library refuses to do.**
///
/// It does not store a verdict. Liveness is recomputed every sweep, because a
/// stalled node that recovers must stop being stalled without anything having
/// to write a row — which is why `NodeStatus` has no `stalled` member and must
/// not gain one.
///
/// It does not time the store. The signal is the raw NDJSON transcript
/// `SessionRunner` writes per node; the database's mtime would prove only that
/// *sprout* is alive, and a watcher outside the session must never confuse the
/// two.
///
/// **And it never acts.** There is no kill, no signal, no reclaim anywhere
/// under `lib/src/liveness/`, and `test/liveness_test.dart` asserts that of the
/// source. §5: *"Never auto-reclaim a stalled node"* — the real incident behind
/// that rule held four uncommitted files and a green test suite. Surface it,
/// page, never act. Consuming the verdicts is P6-02's watchdog loop; showing
/// them is P6-03.
///
/// Implementation lives under `lib/src/liveness/`. See `docs/01-plan.md` §5
/// and §11.
library;

// The three kinds this library reads are declared in
// `package:sprout_protocol/values.dart` (F-12), beside the values they label
// and where the runner writes them from. Re-exported here so every importer
// that got them from this library still does.
export 'package:sprout_protocol/values.dart'
    show runnerLaunchFailedKind, runnerRefusedKind, runnerSpawnedKind;

export 'src/liveness/measure.dart'
    show
        LivenessMeasure,
        defaultFrozenAfter,
        defaultStartTimeTolerance,
        endedStatuses;
export 'src/liveness/process_probe.dart'
    show
        ProcessGone,
        ProcessLook,
        ProcessProbe,
        ProcessRunning,
        ProcessUnreadable,
        PsProcessProbe;
export 'src/liveness/transcript.dart'
    show
        FileTranscripts,
        TranscriptAbsent,
        TranscriptIndex,
        TranscriptLook,
        TranscriptUnreadable,
        TranscriptWritten;
export 'src/liveness/verdict.dart' show Liveness, LivenessVerdict;
