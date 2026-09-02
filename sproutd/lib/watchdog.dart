/// The watchdog loop — contradiction-triggered, capped, and it never acts.
///
/// P6-01 built the measurement; this is the thing that runs it on a schedule,
/// decides when a verdict is worth a human's attention, and rings. Showing the
/// ring on a board is P6-03's.
///
/// Start at [Watchdog.sweepOnce], which is one iteration of [Watchdog.run] and
/// is the whole of the decision:
///
/// 1. Measure the **whole forest** with `package:sproutd/liveness.dart`.
/// 2. If nothing contradicts, stop — the healthy path costs one sweep.
/// 3. Otherwise **settle, then measure again**, and believe only what survives.
/// 4. Ring each surviving contradiction, unless it is at the [RingLedger] cap.
/// 5. Write the sweep down with a `why` — **always**, and especially when it
///    was quiet.
///
/// ## The four rules of `docs/01-plan.md` §11, and where each one lives
///
/// **Outside the sessions.** [Watchdog] reads the store's node graph, runs
/// `ps` against recorded pids, and stats transcript files. Nothing here asks a
/// watched process for anything, because §1's failure is a run that *"sat
/// inert for six hours with the Stop gate, watchdog, and limit gate all
/// reporting healthy"* — a watchdog inside the session that stopped cannot
/// fire when that session is the thing that stopped.
///
/// **Settle before measuring.** [defaultSettleFor], and it is not a bare
/// sleep: a sleep cannot tell a frozen transcript from one caught mid-write,
/// because both look identical to the reading that already happened. A
/// *second* reading after the wait can, and the nodes that cleared during it
/// are listed in [SweepRecord.settledClear] rather than dropped — so a settle
/// doing nothing and a settle earning its place are distinguishable in the
/// journal.
///
/// **Ring cap on consecutive unproductive rings, resetting on progress.**
/// [RingLedger], per node and never tree-wide. The cap sits between two real
/// failures: a watchdog that rings forever is muted, and a watchdog that stops
/// after N rings has also stopped guarding — quietly, which is worse. The
/// reset is the half that makes the cap safe, so there are two paths to it and
/// both live in [RingLedger.rule] and [RingLedger.progressed].
///
/// **Every quiet exit logged with a `why`.** [SweepRecord.why] is required and
/// never empty, and [FileWatchdogJournal] appends one line per sweep. This is
/// INV8 turned on the watchdog itself: a watchdog silent because the tree is
/// healthy and one silent because it crashed at 03:00 look identical from
/// outside. The journal's own mtime is the watchdog's pulse, readable with
/// `ls -l` by something running none of this code.
///
/// ## What counts as a contradiction
///
/// The plan says *"contradiction-triggered"* and does not define the word, so
/// [ringingVerdicts] states the definition this leaf chose, in terms someone
/// can disagree with: a node whose **recorded state and observed state cannot
/// both be true**. `stalled` and `abandoned`, and nothing else. Explicitly not
/// a trend, a rate or an elapsed timer — §2.5 rejected *"a drift dashboard →
/// per-hop gates"* and §12 warns that *"monitoring trends would mostly display
/// noise and miss the actual failures"*.
///
/// [Liveness.unmeasured] never rings, and is never counted healthy either. A
/// failed look is not a fact about the world, so there is nothing for the
/// record to contradict; and a sweep that could not see half the tree
/// reporting "nothing to ring" is the blind watchdog reporting green. So blind
/// nodes are named in [SweepRecord.blind] and in the `why`, and there is no
/// `healthy` getter anywhere for a caller to read the silence as one. This
/// disagrees with P6-01's `Liveness.pages`, deliberately and on the record —
/// see [Blindness] and F-13 in `docs/02-open-findings.md`.
///
/// ## And it never acts
///
/// No kill, no signal, no reclaim. [WatchdogBell.ring] returns nothing a
/// caller could branch on, because a bell that could answer "handled, go clean
/// it up" is the first half of the thing that must never exist. §5: *"Never
/// auto-reclaim a stalled node"* — the real incident behind that rule held
/// four uncommitted files and a green test suite. `test/watchdog_test.dart`
/// asserts it of the source, exactly as P6-01's test does of
/// `lib/src/liveness/`.
///
/// Implementation lives under `lib/src/watchdog/`. See `docs/01-plan.md` §5
/// and §11.
library;

export 'src/watchdog/bell.dart'
    show FanOutBell, RecordingBell, WatchdogBell, WritingBell;
export 'src/watchdog/contradiction.dart'
    show Blindness, Contradiction, ringingVerdicts;
export 'src/watchdog/journal.dart'
    show
        FanOutJournal,
        FileWatchdogJournal,
        MemoryWatchdogJournal,
        Ring,
        SweepRecord,
        WatchdogJournal;
export 'src/watchdog/ring_ledger.dart'
    show RingLedger, RingOutcome, RingRuling, defaultRingCap;
export 'src/watchdog/watchdog.dart'
    show Watchdog, defaultSettleFor, defaultSweepInterval, watchdogFrozenAfter;
