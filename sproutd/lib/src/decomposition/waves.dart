/// Grouping a decomposition's children into waves that cannot collide.
library;

import 'dart:math' as math;

import '../../policy.dart';
import 'decomposition.dart';
import 'estimate.dart';
import 'mode.dart';

/// One group of children that may run at the same time.
final class Wave {
  /// Records a wave at [index] holding [children].
  const Wave._(this.index, this.children, this.isolationReason);

  /// Where this wave sits in the plan. 0 runs first.
  final int index;

  /// The children in it, in the parent's own order. Never empty.
  final List<PlannedChild> children;

  /// Why this wave holds one child *and nothing else may join it*, or null.
  ///
  /// Non-null exactly when the wave was forced open by an unestimable child.
  /// A wave that happens to hold one child because there was only one left is
  /// **not** isolated and this is null for it — the two look identical in a
  /// count and mean opposite things, which is why the reason is a field rather
  /// than something a reader infers from `children.length == 1`.
  final String? isolationReason;

  /// Whether this wave is held open for a single unestimable child.
  bool get isIsolated => isolationReason != null;

  @override
  String toString() =>
      'Wave($index: ${children.map((c) => c.id).join(', ')}'
      '${isIsolated ? ' — isolated' : ''})';
}

/// An ordered layout of a [Decomposition] into waves.
///
/// The property that makes it worth having: **no two children in one wave have
/// overlapping estimated file sets, and any child whose estimate is unknown is
/// alone.**
final class WavePlan {
  const WavePlan._(this.decomposition, this.waves, this.maxWidth);

  /// What was laid out.
  final Decomposition decomposition;

  /// The waves, in the order they should run. Never empty.
  final List<Wave> waves;

  /// The widest any wave in this plan was allowed to be.
  ///
  /// The smaller of the policy's two concurrency bounds, narrowed again to
  /// [buildWaveWidth] when the decomposition's mode is build — see [planWaves]
  /// for what that does and does not promise.
  final int maxWidth;

  /// How many children the plan places. Equal to the decomposition's count.
  int get childCount =>
      waves.fold(0, (total, wave) => total + wave.children.length);

  /// The plan as a human reads it, one line per wave plus every isolation
  /// reason.
  ///
  /// A plan that cannot say *why* a child is alone teaches the next planner
  /// nothing, and "says why" is half of the behaviour
  /// `docs/research/07-local-harnesses.md` describes.
  String describe() {
    final lines = <String>[
      '${decomposition.children.length} children in ${waves.length} '
          'wave${waves.length == 1 ? '' : 's'} (max width $maxWidth)',
      // The mode, and loudly if nobody chose it. A defaulted mode that read
      // the same as a declared one in the plan a human is handed would be
      // `route`'s silent serialization, which showrunner prints rather than
      // performs.
      '  mode ${decomposition.mode.label}',
    ];
    for (final wave in waves) {
      lines.add(
        '  wave ${wave.index}: ${wave.children.map((c) => c.id).join(', ')}',
      );
      if (wave.isolationReason case final reason?) {
        lines.add('    $reason');
      }
    }
    return lines.join('\n');
  }

  @override
  String toString() =>
      'WavePlan(${waves.length} waves, $childCount children, '
      'max width $maxWidth)';
}

/// Lays [decomposition]'s children out into waves that cannot collide.
///
/// **Pure.** No process, no filesystem, no clock, no SQL, no random — the same
/// decomposition and policy always produce the same waves, in the same order.
/// `test/decomposition_test.dart` asserts that by planning the same input twice
/// and comparing, and `lib/src/decomposition/` is grepped by that same file for
/// the imports that would make it untrue.
///
/// Three rules, in this order:
///
/// 1. **A child whose estimate is [UnknownFiles] gets a wave to itself**, and
///    the wave carries the reason. `docs/01-plan.md` §11 and
///    `docs/research/07-local-harnesses.md` both state it the same way — *an
///    unestimable leaf collides with everything* — and the argument is a cost
///    asymmetry, not a preference: *"a false collision costs one wave of
///    latency; a missed one costs a merge conflict in an unattended run with
///    nobody watching."*
/// 2. **No two children in a wave have overlapping file sets**, decided by
///    [FileEstimate.overlaps], which answers *overlap* whenever it cannot
///    decide.
/// 3. **No wave is wider than the concurrency the gate could permit**, and a
///    **build** decomposition is narrowed again to [buildWaveWidth]. See below;
///    this is the rule with a caveat.
///
/// Placement is first-fit in the parent's own order: each child joins the
/// earliest wave that has room and no collision, and opens a new one otherwise.
/// First-fit rather than anything cleverer because the output has to be stable
/// under a diff, and because a bin-packer that reorders children makes a plan
/// nobody can read against the brief that produced it.
///
/// ## What the width bound does and does not promise
///
/// [ContainmentPolicy.maxLiveChildren] caps one node's simultaneously-live
/// children and [ContainmentPolicy.maxLiveNodes] caps the whole tree, so a wave
/// is capped at the smaller of the two. Both genuinely bite since P4-02:
/// `ContainmentGate.admit` refuses with `RefusalReason.concurrency` and counts
/// the refusal. A wave planned wider than the policy allows is a plan that gets
/// refused halfway through, leaving a half-spawned wave nobody planned for.
///
/// [DelegationMode.build] then narrows it again, to `min(that,
/// buildWaveWidth)`. That is `docs/01-plan.md` §2.3's *"narrow fan-out"* for
/// children whose artifacts have to compose, and it is the second of the two
/// places the mode bites — the first is `Decomposition.briefFor`. Narrowing
/// only: this can never widen a wave past what the policy would permit, so
/// INV9's asymmetry is intact. A build decomposition that still produced a
/// maximum-width wave would be a mode that changed nothing.
///
/// It is a **ceiling, not a guarantee.** `maxLiveNodes` is judged against the
/// whole ledger at admission time, and a decomposition does not know what else
/// in the tree is live — a sibling subtree can consume the budget between
/// planning and spawning. This function bounds the plan by what the policy
/// could permit *at best*; the gate still decides, and it decides last. Said
/// out loud per INV6, because a width bound that looks like a guarantee is
/// worse than no bound at all.
///
/// Throws [ArgumentError] if the policy permits fewer than one live child, in
/// which case no plan is admissible and there is no honest layout to return.
WavePlan planWaves(
  Decomposition decomposition, {
  required ContainmentPolicy policy,
}) {
  final policyWidth = math.min(policy.maxLiveChildren, policy.maxLiveNodes);
  if (policyWidth < 1) {
    throw ArgumentError.value(
      policy,
      'policy',
      'permits no live children at all, so no wave could be admitted. There '
          'is no layout to return and returning an empty one would read as '
          '"nothing to do"',
    );
  }
  // Exhaustive on purpose: a third mode must fail to compile here rather than
  // fall through to whichever branch happens to be the default.
  final maxWidth = switch (decomposition.mode.mode) {
    DelegationMode.map => policyWidth,
    DelegationMode.build => math.min(policyWidth, buildWaveWidth),
  };

  final buckets = <_Bucket>[];
  for (final child in decomposition.children) {
    if (!child.files.isParallelisable) {
      // Its own wave, and closed to everyone else. Not "placed last" and not
      // "placed in the widest gap": alone.
      buckets.add(_Bucket(child, isolationReason: _cannotParallelise(child)));
      continue;
    }
    var placed = false;
    for (final bucket in buckets) {
      if (bucket.isolationReason != null) continue;
      if (bucket.children.length >= maxWidth) continue;
      if (bucket.children.any((c) => c.files.overlaps(child.files))) continue;
      bucket.children.add(child);
      placed = true;
      break;
    }
    if (!placed) buckets.add(_Bucket(child));
  }

  return WavePlan._(
    decomposition,
    List.unmodifiable([
      for (var i = 0; i < buckets.length; i++)
        Wave._(
          i,
          List.unmodifiable(buckets[i].children),
          buckets[i].isolationReason,
        ),
    ]),
    maxWidth,
  );
}

/// The sentence a plan prints for a child it could not parallelise.
///
/// Modelled on what showrunner prints for the same case, because sprout is
/// reimplementing a mechanism that already runs on this machine and a reader
/// comparing the two outputs should not have to translate.
String _cannotParallelise(PlannedChild child) =>
    '${child.id} cannot be parallelised: ${child.files.label}. Treating an '
    'unknown blast radius as colliding with everything — a false collision '
    'costs one wave, a missed one costs a merge conflict nobody is watching.';

/// A wave under construction. Mutable only inside [planWaves].
final class _Bucket {
  _Bucket(PlannedChild first, {this.isolationReason})
    : children = <PlannedChild>[first];

  final List<PlannedChild> children;
  final String? isolationReason;
}
