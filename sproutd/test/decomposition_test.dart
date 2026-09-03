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

Decomposition split(List<PlannedChild> children) =>
    Decomposition(parentId: 'n0', task: 'the whole job', children: children);

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
        ]),
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
          ]),
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
        ]),
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
        ]),
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
          ]),
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
}
