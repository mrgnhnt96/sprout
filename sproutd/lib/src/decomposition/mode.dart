/// map versus build, and the record of whether anybody actually chose.
library;

/// The two delegation shapes `docs/01-plan.md` §2.3 splits the literature into.
///
/// The isolation-versus-sharing research genuinely disagrees, and the plan's
/// finding is that the disagreement tracks task shape rather than being an
/// unresolved question:
///
/// | Mode | When | Context | Evidence |
/// |---|---|---|---|
/// | **map** | children independent, read-only, mechanically verifiable | isolate; fan out wide | RAH 81→90%; Anthropic +90.2% |
/// | **build** | children produce artifacts that must compose | push shared decisions down; narrow fan-out | Cognition's Flappy Bird failure |
///
/// > Defaulting build-shaped work to map-shaped fan-out is exactly how you get
/// > "a Mario background and a bird that isn't Flappy." sprout must pick the
/// > mode explicitly and **default build for code.**
///
/// **The failure is one-directional, which is why the default is the expensive
/// branch.** Build work fanned out as map produces artifacts that do not
/// compose — the work is wrong and the run cannot tell. Map work run as build
/// merely costs latency: narrower waves, a longer plan, the same artifacts. So
/// the cheap error is the one this vocabulary defaults to making.
///
/// This enum is only half the value. Which mode is in force is one bit; whether
/// anybody *chose* it is a second, and [ModeChoice] is what carries both.
enum DelegationMode {
  /// Children are independent and read-only. Isolate their context; fan out as
  /// wide as the containment policy permits.
  map('map'),

  /// Children produce artifacts that have to compose. Push the parent's shared
  /// decisions down into each brief; narrow the fan-out.
  build('build');

  const DelegationMode(this.wire);

  /// The string used in logs, counters and anything persisted.
  ///
  /// Written out rather than derived from [name] for the reason
  /// `RefusalReason.wire` gives: renaming a Dart identifier must not silently
  /// rewrite a key something else is already reading.
  final String wire;
}

/// The mode a decomposition is in, **and whether anybody chose it.**
///
/// There is no way to construct one of these without saying which of the two
/// happened, and that is the whole design. §2.3's requirement is that sprout
/// *"pick the mode explicitly"*, and a field that merely holds
/// [DelegationMode.build] cannot tell a parent that weighed the two apart from
/// a parent that never thought about it and got the default. Those are the same
/// bit and opposite amounts of evidence.
///
/// The precedent is this repo's own, in a harness that already runs on this
/// machine. showrunner's `route` prints
///
/// ```text
/// NO RULE MATCHED — defaulted to serialized … an unmatched leaf is a missing
/// rule, not a neutral outcome
/// ```
///
/// (`docs/research/07-local-harnesses.md`) rather than quietly serializing.
/// [defaulted] is the same move: it produces a usable answer *and* says the
/// answer was nobody's.
///
/// **An unset mode is not map.** It is not anything — [Decomposition] takes a
/// [ModeChoice] as a required argument, so the omission does not compile, and
/// the only way to get the default is to ask for it by name and supply a
/// reason. See `test/decomposition_test.dart`, which asserts the requirement is
/// still spelled `required` in the source, because the regression that matters
/// here is somebody later giving that parameter a default value.
final class ModeChoice {
  const ModeChoice._(this.mode, this.wasDefaulted, this.reason);

  /// Somebody weighed §2.3's table and picked [mode]. Say why in [reason].
  ///
  /// Throws [ArgumentError] on a blank reason. The reason is the evidence that
  /// a choice was made, and a choice whose evidence is an empty string is
  /// [defaulted] wearing a different name.
  factory ModeChoice.declared(DelegationMode mode, String reason) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        reason,
        'reason',
        'is blank. Say what about this task made it ${mode.wire}-shaped — '
            'docs/01-plan.md §2.3 is a table with a "When" column, and a mode '
            'declared with no answer to it is a defaulted mode that has stopped '
            'admitting so',
      );
    }
    return ModeChoice._(mode, false, trimmed);
  }

  /// Nobody chose. Take §2.3's default — **[DelegationMode.build]** — and
  /// record that it was taken rather than decided.
  ///
  /// [reason] says what could not be determined, exactly as
  /// `UnknownFiles.reason` does: a default that cannot say why it fired teaches
  /// the next planner nothing.
  ///
  /// The mode is not a parameter here. `build` is hard-coded because §2.3's
  /// asymmetry only runs one way, and a `defaulted` that could produce `map`
  /// would be a second spelling of [declared] with the accountability removed.
  factory ModeChoice.defaulted(String reason) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        reason,
        'reason',
        'is blank. Say what could not be determined about this task, so the '
            'next planner knows what to look at',
      );
    }
    return ModeChoice._(DelegationMode.build, true, trimmed);
  }

  /// Which mode is in force.
  final DelegationMode mode;

  /// Whether [mode] was taken from §2.3's default rather than chosen.
  ///
  /// A plan prints this. It is the difference between "we decided this is
  /// build-shaped" and "nobody looked, so it is build-shaped", which are the
  /// same behaviour and different amounts of evidence.
  final bool wasDefaulted;

  /// Why this mode, or what could not be determined.
  final String reason;

  /// Whether the parent's shared decisions are pushed down into each child.
  bool get isBuild => mode == DelegationMode.build;

  /// One line for a plan a human reads. Loud when the mode was defaulted.
  String get label => wasDefaulted
      ? 'NO MODE DECLARED — defaulted to ${mode.wire}: $reason'
      : '${mode.wire}: $reason';

  @override
  String toString() =>
      'ModeChoice(${mode.wire}'
      '${wasDefaulted ? ', defaulted' : ''}: $reason)';
}

/// The widest wave a [DelegationMode.build] decomposition may be laid out into.
///
/// **A knob with no research behind it, stated as one.** §2.3 says "narrow
/// fan-out" and names no number; nothing in the plan or the fixtures fixes one.
/// This follows `defaultMaxLiveChildren`, which says of itself that it *"has no
/// research behind it … it is a knob set low enough that a runaway is caught
/// early, and it is stated as a knob rather than dressed as a finding."*
///
/// 2 is the narrowest width that is still a fan-out at all: 1 would make every
/// build decomposition fully serial, which the delegation floor then refuses
/// outright, so a build mode set to 1 would not be a narrower mode — it would
/// be a ban on decomposing code.
///
/// It is a **ceiling applied on top of the policy's**, never instead of it:
/// `planWaves` takes the smaller of the two, so this constant can only ever
/// narrow a wave. Widening one is INV9's, and there is no path to it here.
const int buildWaveWidth = 2;
