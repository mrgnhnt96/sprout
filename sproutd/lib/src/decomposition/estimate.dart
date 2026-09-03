/// What files a planned child is expected to touch — including not knowing.
library;

/// The files a planned child is expected to touch.
///
/// **Three states, and the third one is the whole point.** A concrete set of
/// paths ([EstimatedPaths]), an explicit promise to write nothing
/// ([TouchesNothing]), and nobody could say ([UnknownFiles]). Modelling the
/// last two as one — an empty set of paths — inverts the rule this type exists
/// to enforce, because an empty set overlaps nothing, so the child whose blast
/// radius is unknown would be the one that parallelises with everything.
///
/// That is INV8 in the shape it takes here: *an unmeasured thing is not a
/// measured zero.* F-23 is the same mistake one layer up and it is still open —
/// `SpendLedger` sums dollars and has no third state for *unknown*, so a node
/// that reported no cost contributes 0 and a permit becomes indistinguishable
/// from evidence. A ledger cannot be fixed after the fact without changing what
/// a sum means; a sealed type can only be built right the first time, so it is.
///
/// The design source is `docs/research/07-local-harnesses.md`, which showrunner
/// implements and `docs/01-plan.md` §11 restates as sprout's own requirement:
/// waves group leaves *"whose estimated file sets do not overlap"*, and **an
/// unestimable leaf collides with everything, reason printed.** The reason is
/// not decoration — [UnknownFiles.reason] is what a plan prints to say why a
/// child could not be parallelised, and a refusal that cannot say why teaches
/// the next planner nothing.
///
/// Nothing here asks a model to produce an estimate. Who supplies one — a
/// parent session, static analysis, a human — is not settled and is not this
/// type's business. It accepts one, and it is honest when it does not have one.
sealed class FileEstimate {
  const FileEstimate();

  /// Whether these two estimates could name the same file.
  ///
  /// **Answers `true` whenever it cannot decide**, which is the entire trick.
  /// The cost is asymmetric and the research states it in one line: *"a false
  /// collision costs one wave of latency; a missed one costs a merge conflict
  /// in an unattended run with nobody watching."*
  ///
  /// Symmetric by construction: every branch below is written over an
  /// unordered pair, and `overlaps` is asserted symmetric in
  /// `test/decomposition_test.dart` over a matrix of estimates rather than
  /// left as a promise in this sentence.
  bool overlaps(FileEstimate other) {
    // An unknown estimate collides with everything, INCLUDING a child that
    // promised to touch nothing. Both source documents say "everything" with no
    // exception, and the exception a reader reaches for — a read-only child
    // cannot conflict — requires trusting that the *other* child's promise is
    // accurate, which is exactly the assumption the unknown child's isolation
    // exists to survive. It costs one wave; it is written down here so the next
    // reader knows it was a decision and not an oversight.
    return switch ((this, other)) {
      (UnknownFiles(), _) || (_, UnknownFiles()) => true,
      (TouchesNothing(), _) || (_, TouchesNothing()) => false,
      (
        EstimatedPaths(paths: final mine),
        EstimatedPaths(paths: final theirs),
      ) =>
        mine.any((a) => theirs.any((b) => pathsOverlap(a, b))),
    };
  }

  /// Whether a wave planner may put this child beside any other at all.
  ///
  /// False only for [UnknownFiles]. Named separately from [overlaps] because
  /// "collides with everything" and "collides with that one" are different
  /// questions, and a plan reports the first one differently: the child is
  /// alone, and the layout says why.
  bool get isParallelisable => this is! UnknownFiles;

  /// One line naming what this estimate is, for a plan a human reads.
  String get label;
}

/// A concrete, non-empty set of paths or globs, relative to the repository.
///
/// **The set may not be empty.** An empty [EstimatedPaths] is the sentinel this
/// whole type exists to make unconstructable: it would mean "touches nothing"
/// and "nobody looked" at the same time, and it overlaps nothing, so it would
/// parallelise with everything. Say [TouchesNothing] or [UnknownFiles] instead —
/// both require a reason, which is the point.
final class EstimatedPaths extends FileEstimate {
  /// Records an estimate of the files a child will touch.
  ///
  /// Throws [ArgumentError] on an empty set, or on a blank path. Not an
  /// `assert`: asserts are stripped outside a debug run, and a constraint that
  /// disappears in the build that matters is a comment.
  factory EstimatedPaths(Iterable<String> paths) {
    final normalised = <String>{};
    for (final path in paths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty) {
        throw ArgumentError.value(paths, 'paths', 'contains a blank path');
      }
      normalised.add(trimmed);
    }
    if (normalised.isEmpty) {
      throw ArgumentError.value(
        paths,
        'paths',
        'is empty. An empty estimate reads as "overlaps nothing", so it would '
            'parallelise with everything. Use TouchesNothing if the child '
            'writes nothing, or UnknownFiles if nobody could estimate it',
      );
    }
    // Sorted, not just deduped: a wave layout has to be diffable, and a set's
    // iteration order is an implementation detail nobody should have to trust.
    final sorted = normalised.toList()..sort();
    return EstimatedPaths._(List.unmodifiable(sorted));
  }

  const EstimatedPaths._(this.paths);

  /// The paths and globs, deduplicated, trimmed, sorted, and never empty.
  final List<String> paths;

  @override
  String get label => paths.join(', ');

  @override
  String toString() => 'EstimatedPaths(${paths.join(', ')})';
}

/// The child writes nothing, and somebody said so on purpose.
///
/// A third state rather than an empty [EstimatedPaths] for two reasons beyond
/// the sentinel argument above. It carries a [reason], so a plan can print why
/// a child was free to run beside everything instead of asserting it. And it is
/// the shape `docs/01-plan.md` §2.3 calls **map** — *"children independent,
/// read-only, mechanically verifiable"* — which P4-05 has to be able to tell
/// apart from a child that happens to write one file; folding it into
/// [EstimatedPaths] would lose the one bit that distinguishes them.
final class TouchesNothing extends FileEstimate {
  /// Records a read-only child, and why it is known to be one.
  ///
  /// Throws [ArgumentError] on a blank reason. The reason is the evidence, and
  /// a state whose evidence is an empty string is the sentinel again wearing a
  /// different name.
  factory TouchesNothing(String reason) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        reason,
        'reason',
        'is blank. Say how the child is known to write nothing',
      );
    }
    return TouchesNothing._(trimmed);
  }

  const TouchesNothing._(this.reason);

  /// How the child is known to write nothing — the read it did, the tool it
  /// runs, the contract it was given.
  final String reason;

  @override
  String get label => 'writes nothing ($reason)';

  @override
  String toString() => 'TouchesNothing($reason)';
}

/// Nobody could estimate this child's file set.
///
/// Collides with everything, and the [reason] is printed rather than kept. The
/// behaviour to match is showrunner's own, observed on this campaign:
///
/// ```text
/// p4-03-worktree-per-child cannot be parallelised: NOTHING ESTIMABLE — the
/// issue names no real path and no findable symbol. Treating an unknown blast
/// radius as colliding with everything — a false collision costs one wave, a
/// missed one costs a merge conflict nobody is watching.
/// ```
final class UnknownFiles extends FileEstimate {
  /// Records that the estimate is missing, and why it could not be made.
  ///
  /// Throws [ArgumentError] on a blank reason — for [TouchesNothing]'s reason,
  /// and one more: this is the state that costs a wave of latency every time it
  /// appears, so it has to be able to justify itself to whoever pays for it.
  factory UnknownFiles(String reason) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        reason,
        'reason',
        'is blank. An unestimable child costs a whole wave, so say what could '
            'not be estimated',
      );
    }
    return UnknownFiles._(trimmed);
  }

  const UnknownFiles._(this.reason);

  /// Why no estimate could be made.
  final String reason;

  @override
  String get label => 'NOTHING ESTIMABLE — $reason';

  @override
  String toString() => 'UnknownFiles($reason)';
}

/// Whether two paths or globs could name the same file. **Conservative.**
///
/// Compared segment by segment, so a directory contains the files beneath it
/// (`lib/src` overlaps `lib/src/policy/spend.dart`) while a shared string
/// prefix that is not a path prefix does not (`lib/src` does not overlap
/// `lib/srcgen/x.dart` — which a `startsWith` test would get wrong).
///
/// **What this test cannot see, stated per INV6, all of it erring toward
/// `true`:**
///
/// - **Any glob metacharacter wins the comparison.** A segment containing
///   `*`, `?`, `[` or `{` is treated as matching whatever sits opposite it, so
///   `lib/*.dart` is reported as overlapping `lib/src/store.dart` even though
///   `*` does not cross a `/`. That is a false collision — one wave — and the
///   alternative is a glob matcher whose bugs are missed collisions.
/// - **`..` is undecidable without a filesystem**, and this function has none,
///   so a path containing a `..` segment overlaps everything.
/// - **Mixed absolute and relative** paths cannot be compared without knowing
///   the repository root, so they overlap.
/// - **It does not know about links, case-insensitive filesystems, or the fact
///   that two different paths can be the same inode.** All three would be
///   missed collisions and none is detectable from a string.
bool pathsOverlap(String a, String b) {
  final left = _Path.parse(a);
  final right = _Path.parse(b);
  if (left.undecidable || right.undecidable) return true;
  if (left.isAbsolute != right.isAbsolute) return true;

  final shared = left.segments.length < right.segments.length
      ? left.segments.length
      : right.segments.length;
  for (var i = 0; i < shared; i++) {
    final x = left.segments[i];
    final y = right.segments[i];
    if (_hasGlobMeta(x) || _hasGlobMeta(y)) return true;
    if (x != y) return false;
  }
  // Every shared segment matched, so the shorter path is a prefix of the longer
  // one at a segment boundary: a directory and something inside it, or the same
  // path twice.
  return true;
}

bool _hasGlobMeta(String segment) =>
    segment.contains('*') ||
    segment.contains('?') ||
    segment.contains('[') ||
    segment.contains('{');

/// A path split for comparison, with the two cases it refuses to interpret.
final class _Path {
  const _Path(this.segments, this.isAbsolute, this.undecidable);

  factory _Path.parse(String raw) {
    final isAbsolute = raw.startsWith('/');
    final segments = <String>[];
    var undecidable = false;
    for (final segment in raw.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') undecidable = true;
      segments.add(segment);
    }
    return _Path(segments, isAbsolute, undecidable);
  }

  final List<String> segments;
  final bool isAbsolute;
  final bool undecidable;
}
