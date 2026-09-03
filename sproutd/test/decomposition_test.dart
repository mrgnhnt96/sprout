import 'dart:convert';
import 'dart:io';

import 'package:sproutd/decomposition.dart';
import 'package:sproutd/policy.dart';
import 'package:test/test.dart';

/// A policy with room to spare on both concurrency bounds, so a wave that is
/// narrow in these tests is narrow because of a collision and not because of a
/// width cap. The width cap gets its own group.
const roomy = ContainmentPolicy(
  subtreeBudgetUsd: 1000,
  runBudgetUsd: 1000,
  maxLiveChildren: 1000,
  maxLiveNodes: 1000,
);

/// The one condition every child in these tests declares.
///
/// Real, runnable and mechanical — `docs/01-plan.md` §2.4 — rather than a
/// string that says "it works", because the type would accept the latter only
/// if the field were prose, and it is not.
final passes = SuccessCondition(const [
  'dart',
  'test',
], workingDirectory: 'sproutd');

PlannedChild child(
  String id,
  FileEstimate files, {
  double? costUsd,
  List<SuccessCondition>? conditions,
}) => PlannedChild(
  id: id,
  task: 'do the $id part of the work',
  files: files,
  successConditions: conditions ?? [passes],
  estimatedCostUsd: costUsd,
);

/// The mode every pre-P4-05 group in this file runs under.
///
/// Declared rather than defaulted so those groups keep testing what they were
/// written to test. A defaulted mode is still `build` and lays out identically,
/// but it also changes what `describe()` prints, and a wave test that silently
/// doubled as a defaulting test would report the wrong failure.
final declaredBuild = ModeChoice.declared(
  DelegationMode.build,
  'these children write files that have to compose',
);

/// The other half of §2.3's table, for the tests that need both.
final declaredMap = ModeChoice.declared(
  DelegationMode.map,
  'these children only read, and are checked mechanically',
);

Decomposition split(
  List<PlannedChild> children, {
  ModeChoice? mode,
  List<String> sharedDecisions = const [],
}) => Decomposition(
  parentId: 'n0',
  task: 'the whole job',
  children: children,
  mode: mode ?? declaredBuild,
  sharedDecisions: sharedDecisions,
);

/// A policy that permits exactly one live child, for the tests that have to
/// show `buildWaveWidth` can only ever narrow a wave and never widen one.
const singleFile = ContainmentPolicy(
  subtreeBudgetUsd: 1000,
  runBudgetUsd: 1000,
  maxLiveChildren: 1,
  maxLiveNodes: 1,
);

/// Four children on four disjoint files — the shape that lays out differently
/// under each mode and identically under everything else.
List<PlannedChild> get fourDisjoint => [
  child('a', EstimatedPaths(const ['lib/a.dart'])),
  child('b', EstimatedPaths(const ['lib/b.dart'])),
  child('c', EstimatedPaths(const ['lib/c.dart'])),
  child('d', EstimatedPaths(const ['lib/d.dart'])),
];

List<List<String>> layout(WavePlan plan) => [
  for (final wave in plan.waves) [for (final c in wave.children) c.id],
];

// ---------------------------------------------------------------------------
// The mutant. This is the negative control and it is written out longhand.
// ---------------------------------------------------------------------------

/// What `planWaves` would do **if an unknown estimate were an empty set of
/// paths** — the inversion this whole library exists to prevent.
///
/// A test cannot neuter the library it imports, so the wrong implementation is
/// written here instead. INV8's instruction is to find a hole by mutation:
/// *"neuter the producer … and see what still passes."* Without this function
/// the isolation test is an assertion about an implementation nobody has shown
/// could be wrong, and it would keep passing against the broken model.
///
/// It is deliberately the *same* greedy first-fit as `planWaves`, differing in
/// exactly one line: [_mutantOverlaps] treats [UnknownFiles] as the empty set,
/// which overlaps nothing.
List<List<String>> wavesWithUnknownAsEmptySet(
  Decomposition decomposition, {
  int maxWidth = 1000,
}) {
  final buckets = <List<PlannedChild>>[];
  for (final planned in decomposition.children) {
    var placed = false;
    for (final bucket in buckets) {
      if (bucket.length >= maxWidth) continue;
      if (bucket.any((c) => _mutantOverlaps(c.files, planned.files))) continue;
      bucket.add(planned);
      placed = true;
      break;
    }
    if (!placed) buckets.add([planned]);
  }
  return [
    for (final bucket in buckets) [for (final c in bucket) c.id],
  ];
}

/// Overlap under the broken model: unknown ⇒ no paths ⇒ collides with nothing.
bool _mutantOverlaps(FileEstimate a, FileEstimate b) {
  final left = a is EstimatedPaths ? a.paths : const <String>[];
  final right = b is EstimatedPaths ? b.paths : const <String>[];
  return left.any((x) => right.any((y) => pathsOverlap(x, y)));
}

void main() {
  group('the three-state estimate', () {
    test('an empty set of paths cannot be constructed at all', () {
      // The structural half of the trap: there is no way to say "touches no
      // files" by handing over an empty set, so the sentinel that would
      // parallelise with everything does not exist as a value.
      expect(() => EstimatedPaths(const <String>[]), throwsArgumentError);
      expect(() => EstimatedPaths(const ['  ']), throwsArgumentError);
      // The paired positive, so a constructor mutated to throw always fails
      // here rather than passing the test above vacuously (INV8).
      expect(EstimatedPaths(const ['lib/a.dart']).paths, ['lib/a.dart']);
    });

    test('unknown and touches-nothing are different values, each with a '
        'reason', () {
      final unknown = UnknownFiles('the issue names no real path');
      final readOnly = TouchesNothing('it only runs dart analyze');
      expect(unknown, isNot(isA<TouchesNothing>()));
      expect(readOnly, isNot(isA<UnknownFiles>()));
      expect(unknown.isParallelisable, isFalse);
      expect(readOnly.isParallelisable, isTrue);
      expect(() => UnknownFiles('  '), throwsArgumentError);
      expect(() => TouchesNothing(''), throwsArgumentError);
    });

    test('paths are sorted and deduplicated, so a plan is diffable', () {
      final estimate = EstimatedPaths(const [
        'lib/z.dart',
        'lib/a.dart',
        'lib/z.dart',
      ]);
      expect(estimate.paths, ['lib/a.dart', 'lib/z.dart']);
      expect(() => estimate.paths.add('x'), throwsUnsupportedError);
    });
  });

  group('overlap', () {
    test('a directory overlaps a file inside it, in both directions', () {
      final dir = EstimatedPaths(const ['sproutd/lib/src/policy']);
      final file = EstimatedPaths(const ['sproutd/lib/src/policy/spend.dart']);
      expect(dir.overlaps(file), isTrue);
      expect(file.overlaps(dir), isTrue);
    });

    test('a shared string prefix that is not a path prefix does not', () {
      // The case a `startsWith` test gets wrong: `lib/src` is not a prefix of
      // `lib/srcgen/x.dart` at a segment boundary, so they are different files.
      // The paired positive above is what keeps this from passing against an
      // overlap test mutated to always answer false.
      final a = EstimatedPaths(const ['lib/src']);
      final b = EstimatedPaths(const ['lib/srcgen/x.dart']);
      expect(a.overlaps(b), isFalse);
      expect(b.overlaps(a), isFalse);
    });

    test('an unknown estimate collides with everything, including a child '
        'that promised to write nothing', () {
      final unknown = UnknownFiles('nobody could say');
      final paths = EstimatedPaths(const ['lib/a.dart']);
      final nothing = TouchesNothing('read-only');
      for (final other in [unknown, paths, nothing]) {
        expect(unknown.overlaps(other), isTrue, reason: '$other');
        expect(other.overlaps(unknown), isTrue, reason: '$other');
      }
    });

    test('a child that writes nothing collides with nothing else', () {
      final nothing = TouchesNothing('read-only');
      expect(nothing.overlaps(TouchesNothing('also read-only')), isFalse);
      expect(nothing.overlaps(EstimatedPaths(const ['lib/a.dart'])), isFalse);
      expect(EstimatedPaths(const ['lib/a.dart']).overlaps(nothing), isFalse);
    });

    test('it answers overlap whenever it cannot decide', () {
      // Each of these is a false collision on purpose, and each is named in
      // `pathsOverlap`'s doc as something the test cannot see (INV6).
      expect(pathsOverlap('lib/*.dart', 'lib/src/store.dart'), isTrue);
      expect(pathsOverlap('lib/{a,b}.dart', 'lib/c.dart'), isTrue);
      expect(pathsOverlap('lib/**', 'lib/src/deep/x.dart'), isTrue);
      expect(pathsOverlap('lib/../lib/a.dart', 'other/b.dart'), isTrue);
      expect(pathsOverlap('/abs/a.dart', 'rel/a.dart'), isTrue);
      // And the paired negatives, without which every line above is satisfied
      // by a function that returns true unconditionally.
      expect(pathsOverlap('lib/a.dart', 'lib/b.dart'), isFalse);
      expect(pathsOverlap('sproutd/lib', 'sprout_ui/lib'), isFalse);
      expect(pathsOverlap('lib/a.dart', 'lib/a.dart'), isTrue);
    });

    test('it is symmetric over every pair of estimate shapes', () {
      final estimates = <FileEstimate>[
        EstimatedPaths(const ['lib/a.dart']),
        EstimatedPaths(const ['lib/a.dart', 'lib/b.dart']),
        EstimatedPaths(const ['lib']),
        EstimatedPaths(const ['other/**']),
        TouchesNothing('read-only'),
        UnknownFiles('nobody could say'),
      ];
      for (final a in estimates) {
        for (final b in estimates) {
          expect(a.overlaps(b), b.overlaps(a), reason: '$a vs $b');
        }
      }
    });
  });

  group('waves', () {
    test('THE INVERSION: an unknown-estimate child is alone, and the broken '
        'model proves it would not be', () {
      final plan = planWaves(
        split([
          child('alpha', EstimatedPaths(const ['lib/a.dart'])),
          child('unknown', UnknownFiles('the issue names no real path')),
          child('beta', EstimatedPaths(const ['lib/b.dart'])),
        ]),
        policy: roomy,
      );

      // What the library does: the two disjoint children share a wave and the
      // unestimable one has its own, whatever order it arrived in.
      expect(layout(plan), [
        ['alpha', 'beta'],
        ['unknown'],
      ]);

      // What the library would do if `unknown` were an empty set of paths.
      // This is the negative control, and it is the whole reason the assertion
      // above means something: an empty set overlaps nothing, so the child
      // nobody could estimate becomes the one that parallelises with
      // everything — the exact inversion, measured rather than asserted.
      expect(
        wavesWithUnknownAsEmptySet(
          split([
            child('alpha', EstimatedPaths(const ['lib/a.dart'])),
            child('unknown', UnknownFiles('the issue names no real path')),
            child('beta', EstimatedPaths(const ['lib/b.dart'])),
          ]),
        ),
        [
          ['alpha', 'unknown', 'beta'],
        ],
        reason:
            'the broken model must actually be broken, or the assertion '
            'above is a test of nothing',
      );
    });

    test('the isolated wave says why, in showrunner\'s own words', () {
      final plan = planWaves(
        split([
          child(
            'p4-03',
            UnknownFiles('the issue names no real path and no findable symbol'),
          ),
          child('other', EstimatedPaths(const ['lib/a.dart'])),
        ]),
        policy: roomy,
      );
      final isolated = plan.waves.first;
      expect(isolated.isIsolated, isTrue);
      expect(isolated.isolationReason, contains('p4-03'));
      expect(isolated.isolationReason, contains('cannot be parallelised'));
      expect(isolated.isolationReason, contains('no findable symbol'));
      expect(isolated.isolationReason, contains('merge conflict'));
      expect(plan.describe(), contains('cannot be parallelised'));

      // A wave that holds one child because there was only one left is NOT
      // isolated. Without this the reason field could be set from
      // `children.length == 1` and every assertion above would still pass.
      final single = planWaves(
        split([
          child('only', EstimatedPaths(const ['lib/a.dart'])),
        ]),
        policy: roomy,
      );
      expect(single.waves.single.children, hasLength(1));
      expect(single.waves.single.isIsolated, isFalse);
      expect(single.waves.single.isolationReason, isNull);
    });

    test('overlapping children never share a wave', () {
      final plan = planWaves(
        split([
          child('writes-dir', EstimatedPaths(const ['sproutd/lib/src'])),
          child(
            'writes-file',
            EstimatedPaths(const ['sproutd/lib/src/policy/spend.dart']),
          ),
          child('elsewhere', EstimatedPaths(const ['sprout_ui/lib/main.dart'])),
        ]),
        policy: roomy,
      );
      expect(layout(plan), [
        ['writes-dir', 'elsewhere'],
        ['writes-file'],
      ]);
      for (final wave in plan.waves) {
        for (final a in wave.children) {
          for (final b in wave.children) {
            if (identical(a, b)) continue;
            expect(a.files.overlaps(b.files), isFalse, reason: '$a with $b');
          }
        }
      }
    });

    test('a read-only child parallelises with writers but not with an '
        'unestimable one', () {
      final plan = planWaves(
        split([
          child('reader', TouchesNothing('runs dart analyze and reports')),
          child('writer', EstimatedPaths(const ['lib/a.dart'])),
          child('mystery', UnknownFiles('nobody could say')),
        ]),
        policy: roomy,
      );
      expect(layout(plan), [
        ['reader', 'writer'],
        ['mystery'],
      ]);
    });

    test('every child is placed exactly once', () {
      final decomposition = split([
        for (var i = 0; i < 12; i++)
          child(
            'c$i',
            i % 4 == 0
                ? UnknownFiles('no estimate for c$i')
                : EstimatedPaths(['lib/f${i % 3}.dart']),
          ),
      ]);
      final plan = planWaves(decomposition, policy: roomy);
      expect(plan.childCount, decomposition.children.length);
      expect(
        plan.waves.expand((w) => w.children).map((c) => c.id).toSet(),
        decomposition.children.map((c) => c.id).toSet(),
      );
    });

    test('identical decompositions give identical waves, every time', () {
      Decomposition build() => split([
        for (var i = 0; i < 20; i++)
          child('c$i', switch (i % 5) {
            0 => UnknownFiles('no estimate for c$i'),
            1 => TouchesNothing('read-only c$i'),
            _ => EstimatedPaths(['lib/g${i % 7}.dart', 'test/t$i.dart']),
          }),
      ]);
      final first = planWaves(build(), policy: roomy);
      for (var run = 0; run < 5; run++) {
        expect(layout(planWaves(build(), policy: roomy)), layout(first));
      }
      expect(planWaves(build(), policy: roomy).describe(), first.describe());
    });
  });

  // Every test in this group runs under `declaredMap`, on purpose. P4-05 gave
  // `build` a second, narrower ceiling of `buildWaveWidth`, so under build the
  // policy's number would stop being the thing that caps and these tests would
  // silently start measuring the mode instead. Map is the mode in which the
  // policy is the *only* bound, which is what each of these is about. That the
  // narrower build ceiling exists at all, and that it can only narrow, is
  // asserted in 'the mode has consequences over the same children'.
  group('the width bound', () {
    test('no wave is wider than the policy\'s maxLiveChildren', () {
      const narrow = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
        maxLiveChildren: 2,
        maxLiveNodes: 1000,
      );
      final plan = planWaves(
        split([
          for (var i = 0; i < 5; i++)
            child('c$i', EstimatedPaths(['lib/f$i.dart'])),
        ], mode: declaredMap),
        policy: narrow,
      );
      expect(plan.maxWidth, 2);
      expect(layout(plan), [
        ['c0', 'c1'],
        ['c2', 'c3'],
        ['c4'],
      ]);
      // The paired positive: the same five disjoint children fit in one wave
      // under a roomy policy, so this is the cap biting and not the overlap
      // test having an opinion.
      expect(
        planWaves(
          split([
            for (var i = 0; i < 5; i++)
              child('c$i', EstimatedPaths(['lib/f$i.dart'])),
          ], mode: declaredMap),
          policy: roomy,
        ).waves,
        hasLength(1),
      );
    });

    test('the tree-wide bound caps a wave too, when it is the smaller', () {
      const narrowTree = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
        maxLiveChildren: 1000,
        maxLiveNodes: 3,
      );
      final plan = planWaves(
        split([
          for (var i = 0; i < 4; i++)
            child('c$i', EstimatedPaths(['lib/f$i.dart'])),
        ], mode: declaredMap),
        policy: narrowTree,
      );
      expect(plan.maxWidth, 3);
      expect(plan.waves.first.children, hasLength(3));
    });

    test('the defaults are the policy\'s, not a number invented here', () {
      const defaults = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
      );
      final plan = planWaves(
        split([
          for (var i = 0; i < 10; i++)
            child('c$i', EstimatedPaths(['lib/f$i.dart'])),
        ], mode: declaredMap),
        policy: defaults,
      );
      expect(plan.maxWidth, defaultMaxLiveChildren);
      expect(plan.waves.first.children, hasLength(defaultMaxLiveChildren));
    });

    test('a policy that permits nothing throws rather than returning a plan '
        'that reads as "nothing to do"', () {
      const forbidding = ContainmentPolicy(
        subtreeBudgetUsd: 1000,
        runBudgetUsd: 1000,
        maxLiveChildren: 0,
        maxLiveNodes: 1000,
      );
      expect(
        () => planWaves(
          split([
            child('c0', EstimatedPaths(const ['lib/a.dart'])),
          ], mode: declaredMap),
          policy: forbidding,
        ),
        throwsArgumentError,
      );
    });
  });

  group('what the type refuses to hold', () {
    test('a child with no machine-checkable success condition', () {
      // docs/01-plan.md §2.4. The refusal is in the constructor rather than in
      // a later check, because a later check runs after a child has already
      // been spawned against an unverifiable brief.
      expect(
        () => PlannedChild(
          id: 'c0',
          task: 'do the thing',
          files: EstimatedPaths(const ['lib/a.dart']),
          successConditions: const [],
        ),
        throwsArgumentError,
      );
      expect(() => SuccessCondition(const []), throwsArgumentError);
      expect(() => SuccessCondition(const ['  ']), throwsArgumentError);
    });

    test('a child with no task, and a decomposition with no children', () {
      expect(
        () => child('c0', EstimatedPaths(const ['lib/a.dart'])).task,
        returnsNormally,
      );
      expect(
        () => PlannedChild(
          id: 'c0',
          task: '   ',
          files: EstimatedPaths(const ['lib/a.dart']),
          successConditions: [passes],
        ),
        throwsArgumentError,
      );
      // Not decomposing is a decision (§3), not a decomposition into nothing.
      expect(() => split(const []), throwsArgumentError);
    });

    test('two children sharing an id', () {
      expect(
        () => split([
          child('same', EstimatedPaths(const ['lib/a.dart'])),
          child('same', EstimatedPaths(const ['lib/b.dart'])),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('the cost estimate keeps its own unknown', () {
    test('an uncosted child is null, not zero, and the sum says how many', () {
      // F-23 and INV7: a plan that carries 0 for a child nobody costed adds up
      // to a total that reads as an estimate and is not one.
      final decomposition = split([
        child('a', EstimatedPaths(const ['lib/a.dart']), costUsd: 0.25),
        child('b', EstimatedPaths(const ['lib/b.dart'])),
        child('c', EstimatedPaths(const ['lib/c.dart']), costUsd: 0.5),
      ]);
      expect(decomposition.children[1].estimatedCostUsd, isNull);
      expect(decomposition.knownEstimatedCostUsd, closeTo(0.75, 1e-9));
      expect(decomposition.childrenWithoutCostEstimate, 1);
      // A costed-nothing child really is zero, and is distinguishable from the
      // one nobody costed.
      final free = split([
        child('a', EstimatedPaths(const ['lib/a.dart']), costUsd: 0),
      ]);
      expect(free.children.single.estimatedCostUsd, 0);
      expect(free.childrenWithoutCostEstimate, 0);
    });

    test('a negative estimate is refused', () {
      expect(
        () => child('a', EstimatedPaths(const ['lib/a.dart']), costUsd: -1),
        throwsArgumentError,
      );
    });
  });

  group('the mode is chosen, and a default says it was one', () {
    test('a defaulted mode and a declared build mode are the same mode and '
        'different evidence', () {
      // §2.3's requirement is that sprout "pick the mode explicitly". A field
      // that only holds `build` cannot tell a parent that weighed the table
      // apart from one that never looked, and those are opposite amounts of
      // evidence about the plan that follows.
      final defaulted = ModeChoice.defaulted('nothing said which shape');
      expect(defaulted.mode, DelegationMode.build);
      expect(defaulted.wasDefaulted, isTrue);
      expect(defaulted.label, startsWith('NO MODE DECLARED'));

      expect(declaredBuild.mode, DelegationMode.build);
      expect(declaredBuild.wasDefaulted, isFalse);
      expect(declaredBuild.label, isNot(contains('NO MODE DECLARED')));

      // Same bit, distinguishable values. This is the assertion that fails if
      // somebody later collapses ModeChoice back down to the bare enum.
      expect(defaulted.mode, declaredBuild.mode);
      expect(defaulted.wasDefaulted, isNot(declaredBuild.wasDefaulted));
    });

    test('the default is build, and there is no way to default to map', () {
      // The failure §2.3 names is one-directional: build work fanned out as map
      // produces artifacts that do not compose, and map work run as build costs
      // latency. So the default is the expensive branch, and `defaulted` takes
      // no mode argument at all — a `defaulted(map)` would be `declared` with
      // the accountability removed.
      expect(ModeChoice.defaulted('unknown shape').mode, DelegationMode.build);
      expect(declaredMap.mode, DelegationMode.map);
      expect(declaredMap.wasDefaulted, isFalse);
    });

    test('neither kind of choice can be made without a reason', () {
      expect(() => ModeChoice.defaulted('   '), throwsArgumentError);
      expect(
        () => ModeChoice.declared(DelegationMode.map, ''),
        throwsArgumentError,
      );
      // Paired positive, so a constructor mutated to throw always cannot pass
      // the two above vacuously (INV8).
      expect(ModeChoice.defaulted('x').reason, 'x');
      expect(ModeChoice.declared(DelegationMode.map, ' y ').reason, 'y');
    });

    test('the mode parameter is still `required`, so an unset mode does not '
        'compile', () {
      // A test cannot assert a compile error, and the regression that matters
      // is somebody giving this parameter a default value — at which point an
      // unset mode silently becomes build with nothing saying so, which is the
      // exact thing ModeChoice exists to prevent one layer up. So this reads
      // the source, the way the purity group below reads the whole directory.
      final source = File('lib/src/decomposition/decomposition.dart')
          .readAsStringSync();
      expect(source, contains('required ModeChoice mode,'));
      expect(source, isNot(contains('ModeChoice mode =')));
      // The positive control: the pattern that would catch a defaulted mode
      // does match a defaulted parameter, checked against the one in the same
      // constructor that legitimately has a default.
      expect(source, contains('sharedDecisions = const []'));
      expect(RegExp(r'\w+ \w+ = ').hasMatch(source), isTrue);
    });

    test('a plan says out loud when nobody chose the mode', () {
      // showrunner's `route` prints "NO RULE MATCHED — defaulted to
      // serialized" rather than quietly serializing, because an unmatched leaf
      // is a missing rule and not a neutral outcome. Same move.
      final chosen = split(fourDisjoint, mode: declaredBuild);
      final nobody = split(
        fourDisjoint,
        mode: ModeChoice.defaulted('the issue does not say what composes'),
      );
      expect(
        planWaves(chosen, policy: roomy).describe(),
        isNot(contains('NO MODE DECLARED')),
      );
      expect(
        planWaves(nobody, policy: roomy).describe(),
        contains('NO MODE DECLARED — defaulted to build'),
      );
    });
  });

  group('the mode has consequences over the same children', () {
    test('build and map lay the same four children out differently', () {
      // The whole point of §2.3 being two modes rather than a note: build
      // narrows the fan-out because the artifacts have to compose (Cognition's
      // Flappy Bird failure), map fans out as wide as containment permits (RAH
      // 81→90%). A build decomposition that still produced a maximum-width
      // wave would be a mode that changed nothing.
      final asBuild = planWaves(
        split(fourDisjoint, mode: declaredBuild),
        policy: roomy,
      );
      final asMap = planWaves(
        split(fourDisjoint, mode: declaredMap),
        policy: roomy,
      );

      expect(layout(asMap), [
        ['a', 'b', 'c', 'd'],
      ]);
      expect(layout(asBuild), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
      expect(asBuild.maxWidth, buildWaveWidth);
      expect(asMap.maxWidth, greaterThan(asBuild.maxWidth));
      // Same children, same order, same file estimates — only the mode moved.
      expect(asBuild.childCount, asMap.childCount);
    });

    test('build narrows a wave and can never widen one', () {
      // INV9's asymmetry, applied to the one number this leaf added. Under a
      // policy that permits a single live child, `buildWaveWidth` of 2 must not
      // buy a wave of 2 — it is a second ceiling, not a replacement for the
      // first.
      final asBuild = planWaves(
        split(fourDisjoint, mode: declaredBuild),
        policy: singleFile,
      );
      final asMap = planWaves(
        split(fourDisjoint, mode: declaredMap),
        policy: singleFile,
      );
      expect(asBuild.maxWidth, 1);
      expect(asMap.maxWidth, 1);
      expect(layout(asBuild), layout(asMap));
    });

    test('the parent\'s decisions are pushed down in build and withheld in '
        'map', () {
      // §2.3's Context column, as a value rather than an instruction to
      // whoever writes the briefs. The failure it exists against is children
      // that each re-decide the same thing — "a Mario background and a bird
      // that isn't Flappy" — where the decisions were never in dispute, only
      // never transmitted.
      final decisions = ['the store schema stays at version 1', 'no new deps'];
      final built = split(fourDisjoint, sharedDecisions: decisions);
      final mapped = split(fourDisjoint, mode: declaredMap);

      final builtBrief = built.briefFor(built.children.first);
      final mappedBrief = mapped.briefFor(mapped.children.first);
      for (final decision in decisions) {
        expect(builtBrief, contains(decision));
        expect(mappedBrief, isNot(contains(decision)));
      }
      // Both still carry the child's own task; the mode changes what is added
      // to it, not what it is. Map adds nothing at all — that is "isolate".
      expect(builtBrief, contains('do the a part of the work'));
      expect(mappedBrief, 'do the a part of the work');
    });

    test('a map brief never carries the parent\'s framing, and a build brief '
        'always does', () {
      // Found by mutation, and this test is the repair. The version before it
      // differed only by sharedDecisions — which a map decomposition cannot
      // hold — so no constructible input could tell the two branches of
      // briefFor apart, and a briefFor mutated to push decisions down in map
      // too passed the entire suite. INV8: "neuter the producer and see what
      // still passes."
      //
      // The parent's own task is what makes the branches differ for EVERY
      // decomposition, including one with nothing shared, so the switch is
      // enforcement rather than decoration.
      final built = split(fourDisjoint);
      final mapped = split(fourDisjoint, mode: declaredMap);
      expect(built.sharedDecisions, isEmpty);
      expect(built.briefFor(built.children.first), contains('the whole job'));
      expect(
        mapped.briefFor(mapped.children.first),
        isNot(contains('the whole job')),
      );
      expect(
        built.briefFor(built.children.first),
        isNot(mapped.briefFor(mapped.children.first)),
      );
    });

    test('a map decomposition cannot hold shared decisions at all', () {
      // Map isolates context by definition, so decisions that have to reach the
      // children mean the children are not independent. Refusing here rather
      // than dropping the field at briefFor: a field silently ignored is the
      // same class of bug one layer down.
      expect(
        () => split(fourDisjoint, mode: declaredMap, sharedDecisions: ['x']),
        throwsArgumentError,
      );
      // The paired positive: the identical call in build is fine.
      expect(split(fourDisjoint, sharedDecisions: ['x']).sharedDecisions, [
        'x',
      ]);
      expect(
        () => split(fourDisjoint, sharedDecisions: ['  ']),
        throwsArgumentError,
      );
    });

    test('the two consequences are independent, so neither carries the mode '
        'alone', () {
      // The brief and the wave width are separate seams and a mutation to
      // either one has to be caught by its own assertion. Measured: setting
      // buildWaveWidth to a number that never narrows fails the layout tests
      // and leaves the brief tests green, and vice versa.
      final built = split(fourDisjoint);
      final mapped = split(fourDisjoint, mode: declaredMap);
      expect(
        built.briefFor(built.children.first),
        isNot(mapped.briefFor(mapped.children.first)),
      );
      expect(
        planWaves(built, policy: roomy).maxWidth,
        isNot(planWaves(mapped, policy: roomy).maxWidth),
      );
    });

    test('a brief cannot be built for a child of a different split', () {
      final built = split(fourDisjoint);
      expect(
        () => built.briefFor(child('stranger', TouchesNothing('read-only'))),
        throwsArgumentError,
      );
    });
  });

  group('the delegation floor refuses, and counts what it refused', () {
    test('the same two children are refused when they collide and permitted '
        'when they do not', () {
      // The negative control the floor needs, with exactly one variable moved:
      // two children, same ids, same mode, same policy, same success
      // conditions. Only the paths differ. A gate that always says yes is
      // INV8's exact failure, and P1-04's containment gate shipped that shape
      // for three phases — it ran on every launch and could not refuse any of
      // them, because the ledger it decided over was always empty.
      final floor = DelegationFloor(roomy);

      final collide = split([
        child('a', EstimatedPaths(const ['lib/same.dart'])),
        child('b', EstimatedPaths(const ['lib/same.dart'])),
      ]);
      final refused = floor.decide(collide);
      expect(refused, isA<DelegationRefusal>());
      expect(refused.shouldDecompose, isFalse);
      expect(
        (refused as DelegationRefusal).reason,
        FloorReason.noConcurrencyWon,
      );
      expect(floor.refusals[FloorReason.noConcurrencyWon], 1);
      expect(floor.permitted, 0);

      final disjoint = split([
        child('a', EstimatedPaths(const ['lib/a.dart'])),
        child('b', EstimatedPaths(const ['lib/b.dart'])),
      ]);
      final permit = floor.decide(disjoint);
      expect(permit, isA<DelegationPermit>());
      expect(permit.shouldDecompose, isTrue);
      expect(floor.permitted, 1);
      // The refusal count did not move on the permit, and the permit did not
      // move on the refusal. Either half staying still is what would make the
      // other half unreadable.
      expect(floor.refusals.total, 1);
    });

    test('a permit carries the layout it was judged on, and that layout is '
        'genuinely concurrent', () {
      final floor = DelegationFloor(roomy);
      final decision = floor.decide(split(fourDisjoint, mode: declaredMap));
      final permit = decision as DelegationPermit;
      expect(permit.plan.childCount, 4);
      expect(permit.waveCount, 1);
      expect(permit.widestWave, 4);
      // The property every permit has and no refusal does: strictly fewer
      // waves than children, which is the concurrency the coordination bought.
      expect(permit.waveCount, lessThan(permit.plan.childCount));
    });

    test('a split into one child is a handoff, not a split', () {
      final floor = DelegationFloor(roomy);
      final decision = floor.decide(
        split([
          child('a', EstimatedPaths(const ['lib/a.dart'])),
        ]),
      );
      expect((decision as DelegationRefusal).reason, FloorReason.singleChild);
      expect(decision.explanation, contains('do it yourself'));
      expect(floor.refusals[FloorReason.singleChild], 1);
    });

    test('a split nobody could estimate is refused for that, not for the '
        'layout it happens to produce', () {
      // Both rules fire on this input — every child unestimable also lays out
      // fully serially — and the reason has to be the one whose remedy is
      // right: estimate the file sets, not split on different files.
      final floor = DelegationFloor(roomy);
      final decision = floor.decide(
        split([
          child('a', UnknownFiles('the issue names no path')),
          child('b', UnknownFiles('nor does this one')),
        ]),
      );
      expect(
        (decision as DelegationRefusal).reason,
        FloorReason.nothingEstimable,
      );
      expect(decision.explanation, contains('Estimate the file sets'));
      expect(floor.refusals[FloorReason.noConcurrencyWon], 0);
    });

    test('the check order is fixed, so a proposal that trips several always '
        'reports the same one', () {
      // ContainmentPolicy.decide fixes its order for the same reason: a refusal
      // string nobody can assert on is one nobody can test.
      final floor = DelegationFloor(roomy);
      final decision = floor.decide(
        split([child('a', UnknownFiles('no path'))]),
      );
      // One child AND unestimable AND fully serial. singleChild is first.
      expect((decision as DelegationRefusal).reason, FloorReason.singleChild);
      expect(floor.refusals[FloorReason.nothingEstimable], 0);
      expect(floor.refusals[FloorReason.noConcurrencyWon], 0);
    });

    test('every decision is counted somewhere, and a zero reason is still a '
        'key', () {
      // The counted-ness itself, rather than any one rule. `permitted + total`
      // has to equal the number of calls or a decision went uncounted, which
      // by INV8 is indistinguishable from a floor that never ran.
      final floor = DelegationFloor(roomy);
      expect(floor.permitted, 0);
      expect(floor.refusals.total, 0);

      final proposals = [
        split([
          child('a', EstimatedPaths(const ['lib/a.dart'])),
        ]),
        split([
          child('a', UnknownFiles('no path')),
          child('b', UnknownFiles('no path')),
        ]),
        split([
          child('a', EstimatedPaths(const ['lib/same.dart'])),
          child('b', EstimatedPaths(const ['lib/same.dart'])),
        ]),
        split(fourDisjoint),
      ];
      for (final proposal in proposals) {
        floor.decide(proposal);
      }
      expect(floor.permitted + floor.refusals.total, proposals.length);
      expect(floor.permitted, 1);

      // Every reason present even at zero: "never refused for this" and "this
      // is not being counted" must not read the same, which is the confusion
      // RefusalCounts.toWireMap exists to prevent.
      final wire = FloorCounts.zero().toWireMap();
      expect(wire.keys.toSet(), FloorReason.values.map((r) => r.wire).toSet());
      expect(wire.values.every((v) => v == 0), isTrue);
      expect(floor.refusals.toWireMap()['noConcurrencyWon'], 1);
    });

    test('the tally cannot be reset, and the counts are read-only', () {
      final floor = DelegationFloor(roomy);
      floor.decide(
        split([
          child('a', EstimatedPaths(const ['lib/a.dart'])),
        ]),
      );
      expect(
        () => floor.refusals.byReason[FloorReason.singleChild] = 0,
        throwsUnsupportedError,
      );
      expect(floor.refusals[FloorReason.singleChild], 1);
    });

    test('narrowing a build plan does not turn a sound split into a refused '
        'one', () {
      // buildWaveWidth is 2, so a build decomposition of disjoint children
      // still wins concurrency and the floor still permits it. If this ever
      // fails, the knob has been narrowed to 1 and `build` has quietly become
      // a ban on decomposing code rather than a narrower fan-out.
      final floor = DelegationFloor(roomy);
      expect(
        floor.decide(split(fourDisjoint, mode: declaredBuild)),
        isA<DelegationPermit>(),
      );
      expect(floor.refusals.total, 0);
    });

    test('the floor decides the same way twice, over the same proposal', () {
      // Pure, like everything else in this area: no clock, no ledger, no I/O.
      final proposal = split(fourDisjoint);
      final first = DelegationFloor(roomy).decide(proposal);
      final second = DelegationFloor(roomy).decide(proposal);
      expect(first.runtimeType, second.runtimeType);
      expect(
        (first as DelegationPermit).plan.describe(),
        (second as DelegationPermit).plan.describe(),
      );
    });
  });

  group('the area is pure', () {
    test('nothing under lib/src/decomposition/ can reach a clock, a process, '
        'a filesystem or a random', () {
      // The determinism promise, made structural. `test/worktree_test.dart`
      // greps its own area for `--force` on the same argument: a promise a test
      // can read over a whole directory is a property; one each author has to
      // remember is a habit. A planner whose output depends on a clock or on
      // map iteration order is one nobody can diff.
      final banned = RegExp(
        r"import 'dart:(io|isolate|ffi|mirrors)'|package:sqlite3|"
        r'DateTime\.now|Random\(|\.shuffle\(',
      );
      final sources = Directory('lib/src/decomposition')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      // The positive control: an observation that comes back empty because it
      // looked at nothing is indistinguishable from one that found nothing.
      expect(sources, isNotEmpty);
      expect(
        sources
            .where((f) => banned.hasMatch(f.readAsStringSync()))
            .map((f) => f.path),
        isEmpty,
      );
      // And the grep itself works, checked against a file that does import
      // dart:io.
      expect(
        banned.hasMatch(File('lib/src/worktree/git.dart').readAsStringSync()),
        isTrue,
      );
    });
  });

  group('a plan read out of a file', () {
    // P4-07. The reader is what gives this library a producer; before it, the
    // only `Decomposition` in the repository was built by this file (F-27).

    String plan({
      Object? mode = const {
        'declared': {'mode': 'map', 'reason': 'independent and read-only'},
      },
      List<Object?>? children,
      Map<String, Object?> extra = const {},
    }) => jsonEncode({
      'parent_id': 'the-split',
      'task': 'do several things',
      'mode': mode,
      'children':
          children ??
          [
            {
              'id': 'a',
              'task': 'do a',
              'files': {
                'paths': ['lib/a.dart'],
              },
              'success_conditions': [
                {
                  'command': ['dart', 'test'],
                },
              ],
            },
          ],
      ...extra,
    });

    test('round-trips the fields the types require', () {
      final decomposition = parsePlan(plan());
      expect(decomposition.parentId, 'the-split');
      expect(decomposition.task, 'do several things');
      expect(decomposition.mode.mode, DelegationMode.map);
      expect(decomposition.mode.wasDefaulted, isFalse);
      expect(decomposition.children, hasLength(1));
      final child = decomposition.children.single;
      expect(child.id, 'a');
      expect(child.files, isA<EstimatedPaths>());
      expect(child.successConditions.single.command, ['dart', 'test']);
      expect(child.successConditions.single.workingDirectory, isNull);
    });

    test('all THREE file estimates are spellable, and they are three '
        'different values', () {
      // The inversion this area exists against: if the reader could spell only
      // two of them, the third would have to be written as one of the others,
      // and an absent estimate written as an empty set overlaps nothing — so
      // the child nobody could estimate would parallelise with everything.
      final decomposition = parsePlan(
        plan(
          children: [
            {
              'id': 'paths',
              'task': 't',
              'files': {
                'paths': ['lib/a.dart'],
              },
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
            {
              'id': 'nothing',
              'task': 't',
              'files': {'touches_nothing': 'it only reads'},
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
            {
              'id': 'unknown',
              'task': 't',
              'files': {'unknown': 'the issue names no path'},
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
          ],
        ),
      );
      final byId = {
        for (final child in decomposition.children) child.id: child.files,
      };
      expect(byId['paths'], isA<EstimatedPaths>());
      expect(byId['nothing'], isA<TouchesNothing>());
      expect(byId['unknown'], isA<UnknownFiles>());
      // And the third one still collides with everything, which is the whole
      // reason it has to be spellable.
      expect(byId['unknown']!.overlaps(byId['nothing']!), isTrue);
      expect(byId['nothing']!.overlaps(byId['paths']!), isFalse);
    });

    test('an empty path list is refused by the type, and the message says '
        'which of the other two to use', () {
      expect(
        () => parsePlan(
          plan(
            children: [
              {
                'id': 'a',
                'task': 't',
                'files': {'paths': <String>[]},
                'success_conditions': [
                  {
                    'command': ['true'],
                  },
                ],
              },
            ],
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('TouchesNothing'), contains('UnknownFiles')),
          ),
        ),
      );
    });

    test('two estimates at once is refused, and so is none', () {
      for (final files in [
        <String, Object?>{
          'paths': ['lib/a.dart'],
          'unknown': 'nobody knows',
        },
        <String, Object?>{},
      ]) {
        expect(
          () => parsePlan(
            plan(
              children: [
                {
                  'id': 'a',
                  'task': 't',
                  'files': files,
                  'success_conditions': [
                    {
                      'command': ['true'],
                    },
                  ],
                },
              ],
            ),
          ),
          throwsA(
            isA<PlanFormatException>().having(
              (e) => e.where,
              'where',
              'children[0].files',
            ),
          ),
        );
      }
    });

    test('an absent cost is UNKNOWN and is not a measured zero', () {
      final decomposition = parsePlan(
        plan(
          children: [
            {
              'id': 'costed',
              'task': 't',
              'files': {
                'paths': ['lib/a.dart'],
              },
              'estimated_cost_usd': 0.25,
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
            {
              'id': 'uncosted',
              'task': 't',
              'files': {
                'paths': ['lib/b.dart'],
              },
              'success_conditions': [
                {
                  'command': ['true'],
                },
              ],
            },
          ],
        ),
      );
      // F-23 and INV7 at the file boundary: a sum is not a distribution, so
      // the count of what was never estimated has to survive the read.
      expect(decomposition.knownEstimatedCostUsd, 0.25);
      expect(decomposition.childrenWithoutCostEstimate, 1);
      expect(decomposition.children.last.estimatedCostUsd, isNull);
    });

    test('the mode is one of declared or defaulted, never both and never '
        'absent', () {
      expect(
        parsePlan(plan(mode: {'defaulted': 'nobody looked'})).mode.wasDefaulted,
        isTrue,
      );
      expect(
        parsePlan(plan(mode: {'defaulted': 'nobody looked'})).mode.mode,
        DelegationMode.build,
      );
      for (final mode in <Object>[
        <String, Object?>{},
        {
          'declared': {'mode': 'map', 'reason': 'r'},
          'defaulted': 'nobody looked',
        },
      ]) {
        expect(
          () => parsePlan(plan(mode: mode)),
          throwsA(
            isA<PlanFormatException>().having((e) => e.where, 'where', 'mode'),
          ),
        );
      }
      // And an absent mode does not quietly become the default. §2.3 requires
      // the choice to be made; a reader that filled it in would be the field
      // nobody set, one layer up.
      expect(
        () => parsePlan(
          jsonEncode({
            'parent_id': 'x',
            'task': 'y',
            'children': [
              {
                'id': 'a',
                'task': 't',
                'files': {
                  'paths': ['lib/a.dart'],
                },
                'success_conditions': [
                  {
                    'command': ['true'],
                  },
                ],
              },
            ],
          }),
        ),
        throwsA(isA<PlanFormatException>()),
      );
    });

    test('an unknown key is refused wherever it appears, and named', () {
      for (final (source, where) in <(String, String)>[
        (plan(extra: {'childrne': <Object?>[]}), 'the file'),
        (
          plan(
            children: [
              {
                'id': 'a',
                'task': 't',
                'files': {
                  'paths': ['lib/a.dart'],
                },
                'succes_conditions': [
                  {
                    'command': ['true'],
                  },
                ],
                'success_conditions': [
                  {
                    'command': ['true'],
                  },
                ],
              },
            ],
          ),
          'children[0]',
        ),
      ]) {
        expect(
          () => parsePlan(source),
          throwsA(
            isA<PlanFormatException>().having((e) => e.where, 'where', where),
          ),
        );
      }
    });

    test('the message says where, down to the element', () {
      expect(
        () => parsePlan(
          plan(
            children: [
              {
                'id': 'a',
                'task': 't',
                'files': {
                  'paths': ['lib/a.dart'],
                },
                'success_conditions': [
                  {
                    'command': ['true'],
                  },
                  {'command': 7},
                ],
              },
            ],
          ),
        ),
        throwsA(
          isA<PlanFormatException>().having(
            (e) => e.where,
            'where',
            'children[0].success_conditions[1].command',
          ),
        ),
      );
    });

    test('a map decomposition carrying shared decisions is refused by the '
        'constructor, not softened by the reader', () {
      expect(
        () => parsePlan(
          plan(
            extra: {
              'shared_decisions': ['use package:args'],
            },
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('map decomposition'),
          ),
        ),
      );
    });

    test('text that is not JSON at all is refused as the file, not as a '
        'field', () {
      expect(
        () => parsePlan('not json'),
        throwsA(
          isA<PlanFormatException>().having(
            (e) => e.where,
            'where',
            'the file',
          ),
        ),
      );
    });
  });
}
