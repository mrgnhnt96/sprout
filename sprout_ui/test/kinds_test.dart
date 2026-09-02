/// The parts of the producer this board still has to agree with by hand.
///
/// **This file used to compare the two spellings of the event kinds.** That is
/// gone: `runner.observed` and `runner.updated` are declared once, in
/// `package:sprout_protocol/values.dart`, and both `SproutStore.putNode` and
/// `LiveTree.apply` import that one declaration. Drift is now a compile error,
/// so a test that watched for it has nothing left to watch. That was the
/// repair for finding F-11, and their literal values are pinned where the
/// declaration lives — `sproutd/test/protocol_test.dart`, since
/// `sprout_protocol` keeps its tests in sproutd on purpose.
///
/// **What the move did not close is the PAYLOAD.** A kind names an event; it
/// says nothing about the shape of the map that comes with it. `runner.updated`
/// is built in `sproutd` as `{from, to}` per changed field and applied here by
/// reading those two keys, and `runner.observed` carries a whole node built
/// there and unpacked here — two derivations of one shape, in two packages,
/// with no shared declaration and nothing but this file comparing them. That
/// is still F-01's shape, and either side could be reshaped without the kind
/// changing, which is precisely the change a type checker cannot see.
///
/// So the assertions below read the producer as TEXT. That is a blunt
/// instrument and it is deliberate: the alternative is a shared codec, which
/// is a larger change than F-11 was, and until someone makes it the comparison
/// has to exist somewhere.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The producer, read as text rather than imported.
///
/// The store, not the projection: F-10 moved the announcement into
/// `SproutStore.putNode`, so that a node row cannot be written without the
/// feed learning of it whoever writes it. Both payload shapes are built there
/// now, which is why this file is what the assertions below read.
final producer = File('../sproutd/lib/src/store/sprout_store.dart');

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
