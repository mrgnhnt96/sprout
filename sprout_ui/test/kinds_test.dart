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
///
/// The store, not the projection: F-10 moved the announcement into
/// `SproutStore.putNode`, so that a node row cannot be written without the
/// feed learning of it whoever writes it. Both kinds and both payload shapes
/// are built there now, which is why this file is what the assertions below
/// read.
final producer = File('../sproutd/lib/src/store/sprout_store.dart');

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
      producer.existsSync(),
      isTrue,
      reason: '${producer.path} is gone, so nothing below compares anything',
    );
  });

  group('the kinds this board branches on', () {
    final source = producer.readAsStringSync();

    test('runner.observed matches the producer, character for character', () {
      expect(declaredValue(source, 'nodeObservedKind'), isNotNull);
      expect(declaredValue(source, 'nodeObservedKind'), 'runner.observed');
      expect(nodeObservedKind, 'runner.observed');
    });

    test('runner.updated matches the producer, character for character', () {
      expect(declaredValue(source, 'nodeUpdatedKind'), isNotNull);
      expect(declaredValue(source, 'nodeUpdatedKind'), 'runner.updated');
      expect(nodeUpdatedKind, 'runner.updated');
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
    final source = producer.readAsStringSync();
    expect(source, contains("'status': {'from': previous.status.wire"));
    expect(source, contains("'current_task': {'from': previous.currentTask"));
    expect(source, contains("'parent_id': {'from': previous.parentId"));
    expect(source, contains("'current_task': node.currentTask"));
    expect(source, contains("'parent_id': node.parentId"));
    expect(source, contains("'project': node.project"));
    expect(source, contains("'status': node.status.wire"));
  });

  test('a node the producer merely writes still reaches the feed', () {
    // This test used to assert the opposite, and said so: it pinned F-10 —
    // `SproutStore.putNode` wrote a row and only `store.append` reached the
    // feed, so a root created by `sprout run` never announced itself and an
    // attached consumer rendered it through `LiveTree.strangers`. F-10 is
    // fixed; the row and its event are now written in one call, and this is
    // the assertion that says so.
    final source = producer.readAsStringSync();
    expect(
      source,
      contains('int? putNode('),
      reason: 'putNode still returns the seq of the event it appended',
    );
    // The announcement is inside `putNode` itself rather than at its callers,
    // which is the whole invariant: a future caller cannot forget it.
    final body = source.substring(
      source.indexOf('int? putNode('),
      source.indexOf('/// The node with [id]'),
    );
    expect(body, contains('kind: nodeObservedKind'));
    expect(body, contains('kind: nodeUpdatedKind'));

    // And the root's two writes go through it: creation, and the later status
    // change that `_markRoot` makes. Creation alone would leave a board
    // showing a root stuck on the status it launched with.
    final runner = File('../sproutd/lib/src/runner/session_runner.dart');
    expect(runner.existsSync(), isTrue);
    final launch = runner.readAsStringSync();
    expect(launch, contains('store.putNode('));
    expect(
      launch,
      contains('store.putNode(node.copyWith(status: status)'),
      reason: '_markRoot must announce the transition, not only store it',
    );
  });
}
