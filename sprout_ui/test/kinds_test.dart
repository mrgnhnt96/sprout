/// The two event kinds this package spells for itself, compared to the source
/// that emits them.
///
/// `lib/src/live_tree.dart` writes `runner.observed` and `runner.updated` as
/// literals because it cannot import the package that produces them:
/// `package:sproutd` reaches `dart:io` and `package:sqlite3`'s `dart:ffi`, and
/// build_web_compilers refuses an entrypoint on its transitive library import
/// graph — silently, exiting 0 with no bundle. That was F-07 and the split
/// that closed it is deliberate.
///
/// So two files hold one vocabulary. **That is the shape of F-01, and what
/// made F-01 a bug was not the duplication but that nothing compared the two.**
/// This is the comparison. It is the same remedy `servedAssetNames` takes in
/// `sproutd/routes/controllers/ui_controller.dart` against the generated
/// payload, for the same reason.
///
/// The real repair is to move these constants into `sprout_protocol`, beside
/// the frames, where both packages can import one declaration. They are wire
/// vocabulary: the producer writes them into a `kind` column that travels over
/// a socket, and a consumer branches on them. That change touches sproutd and
/// is not this leaf's; `docs/02-open-findings.md` records it.
library;

import 'dart:io';

import 'package:sprout_ui/src/live_tree.dart';
import 'package:test/test.dart';

/// The producer, read as text rather than imported.
final projection = File('../sproutd/lib/src/runner/projection.dart');

/// Reads `const String <name> = '<value>';` out of Dart source.
///
/// Returns null when the declaration is absent, which is a different
/// observation from a value that does not match — a rename must fail loudly
/// rather than pass because a regex found nothing.
String? declaredValue(String source, String name) =>
    RegExp("const String $name = '([^']+)';").firstMatch(source)?.group(1);

void main() {
  test('sproutd is still where the producer lives', () {
    // A failed read is not a fact about the world. If this file has moved,
    // every assertion below would pass vacuously on an empty string.
    expect(
      projection.existsSync(),
      isTrue,
      reason: '${projection.path} is gone, so nothing below compares anything',
    );
  });

  group('the kinds this board branches on', () {
    final source = projection.readAsStringSync();

    test('runner.observed matches the producer, character for character', () {
      expect(declaredValue(source, 'subagentObservedKind'), isNotNull);
      expect(declaredValue(source, 'subagentObservedKind'), 'runner.observed');
      expect(subagentObservedKind, 'runner.observed');
    });

    test('runner.updated matches the producer, character for character', () {
      expect(declaredValue(source, 'subagentUpdatedKind'), isNotNull);
      expect(declaredValue(source, 'subagentUpdatedKind'), 'runner.updated');
      expect(subagentUpdatedKind, 'runner.updated');
    });

    test('and the regex really can fail', () {
      // The half that keeps the two above from passing vacuously. A matcher
      // that returns null for everything would satisfy `isNotNull` never — but
      // one that matched too greedily would satisfy them always.
      expect(declaredValue(source, 'noSuchConstantExists'), isNull);
      expect(
        declaredValue("const String a = 'x';", 'a'),
        'x',
        reason: 'the regex must read a value, not merely find a name',
      );
    });
  });

  test('the payload shapes this board reads are still what is written', () {
    // The kinds alone are not enough: `runner.updated` is applied as a
    // `{from, to}` patch and `runner.observed` as a whole node, and either
    // could be reshaped without the kind changing. Asserted against the
    // producer's own construction of them.
    final source = projection.readAsStringSync();
    expect(source, contains("'status': {'from': previous.status.wire"));
    expect(source, contains("'current_task': {'from': previous.currentTask"));
    expect(source, contains("'parent_id': {'from': previous.parentId"));
    expect(source, contains("'current_task': node.currentTask"));
    expect(source, contains("'parent_id': node.parentId"));
    expect(source, contains("'project': node.project"));
    expect(source, contains("'status': node.status.wire"));
  });

  test('and the producer still appends no event for a node it merely writes', () {
    // The reason `LiveTree.strangers` is not empty in normal operation, pinned
    // where it can be noticed if it is ever repaired. `SproutStore.putNode`
    // writes a row; only `store.append` reaches the feed. A root created by
    // `sprout run` therefore never announces itself to an attached consumer.
    // See `docs/02-open-findings.md`.
    final runner = File('../sproutd/lib/src/runner/session_runner.dart');
    expect(runner.existsSync(), isTrue);
    final source = runner.readAsStringSync();
    expect(
      source,
      contains('store.putNode('),
      reason: 'the root is still created with putNode',
    );
    expect(
      source,
      isNot(contains("kind: 'runner.created'")),
      reason:
          'a creation event for the root now exists, so LiveTree should apply '
          'it instead of listing the root as a stranger',
    );
  });
}
