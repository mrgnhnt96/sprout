/// Reading a decomposition out of a file, and refusing everything else.
library;

import 'dart:convert';

import 'decomposition.dart';
import 'estimate.dart';
import 'mode.dart';

/// A plan file that could not be turned into a [Decomposition].
///
/// **It always names where.** [where] is a dotted path into the document —
/// `children[1].files` — because the one thing a caller cannot recover from
/// "invalid plan" is which of forty children was wrong, and a reader that made
/// them bisect the file by hand would cost more than it saved.
///
/// A [FormatException] rather than an [ArgumentError] on purpose, and the split
/// is the whole design of this file: **this exception is for what the document
/// is, and an [ArgumentError] out of a constructor is for what the plan
/// says.** A missing `id` key, a number where a list belongs, two file
/// estimates at once — those are this file's. A child with no success
/// condition, an empty path set, a `map` decomposition carrying shared
/// decisions — those are [PlannedChild]'s, [EstimatedPaths]'s and
/// [Decomposition]'s, they already throw with the argument the rule exists for,
/// and [parsePlan] lets them out untouched. Re-checking them here would be two
/// derivations of one rule that agree today, and softening them would be worse:
/// the reader would become the place a plan gets in that the types refuse.
final class PlanFormatException implements FormatException {
  /// Records what was wrong, and where in the document.
  PlanFormatException(this.where, String message) : message = '$where $message';

  /// The dotted path to the offending value.
  final String where;

  @override
  final String message;

  @override
  String? get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => 'plan: $message';
}

/// Turns the JSON text of a plan file into a [Decomposition].
///
/// **Pure**, like everything else in this area: it takes the text, not a path.
/// Opening the file is `bin/sprout.dart`'s, which is what keeps
/// `test/decomposition_test.dart`'s grep over this directory — no `dart:io`, no
/// clock, no random — true of the one file here that a human hand-writes input
/// for.
///
/// ## The shape
///
/// ```json
/// {
///   "parent_id": "the-split",
///   "task": "what is being split, in the parent's own words",
///   "mode": {"declared": {"mode": "build", "reason": "they compose"}},
///   "shared_decisions": ["use package:args"],
///   "children": [
///     {
///       "id": "reader",
///       "task": "write the reader",
///       "files": {"paths": ["lib/src/read.dart"]},
///       "success_conditions": [
///         {"command": ["dart", "test"], "working_directory": "sproutd"}
///       ],
///       "estimated_cost_usd": 0.40
///     }
///   ]
/// }
/// ```
///
/// `mode` is exactly one of `declared` (an object with `mode` — `map` or
/// `build` — and a `reason`) or `defaulted` (the reason nobody could choose).
/// There is no third spelling and no way to omit it: §2.3 requires the mode to
/// be picked explicitly, so a plan file that does not mention one is refused
/// rather than defaulted silently. Taking the default is spelled out, in the
/// file, with a reason — which is the only difference between
/// [ModeChoice.defaulted] and a field nobody filled in.
///
/// `files` is exactly one of `paths` (a non-empty list), `touches_nothing` (the
/// reason it writes nothing) or `unknown` (the reason nobody could estimate).
/// **All three are spellable and exactly one must be given.** A reader that
/// could express only two of them would re-introduce the inversion this whole
/// area is shaped against — an absent estimate modelled as an empty set
/// overlaps nothing, so the child nobody could estimate becomes the one that
/// parallelises with everything. `{"paths": []}` is *not* a way to say either
/// of the other two: it reaches [EstimatedPaths], which refuses it by name and
/// says which of the two to use instead.
///
/// `estimated_cost_usd` is **absent or `null` for unknown**, and a number for
/// known. Those are different values here for [PlannedChild.estimatedCostUsd]'s
/// reason: a plan that carries 0 for a child nobody costed adds up to a total
/// that reads as an estimate and is not one (F-23, INV7).
///
/// `shared_decisions` may be omitted, and must be omitted (or empty) under
/// `map` — [Decomposition]'s constructor is what refuses that, not this
/// function.
///
/// ## What it refuses
///
/// An unknown key anywhere, at every level. That is the one rule here that is
/// stricter than it has to be, and it is deliberate: a plan is hand-written or
/// model-written, `succes_conditions` is a plausible typo, and a reader that
/// ignored the key it did not recognise would spawn a child with no gate and
/// report nothing. The types below refuse the *empty* list; only this refuses
/// the *misspelled* one.
///
/// Throws [PlanFormatException] for anything about the document, and whatever
/// the value constructors throw — [ArgumentError], with the argument the rule
/// exists for — for anything about the plan.
Decomposition parsePlan(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw PlanFormatException('the file', 'is not JSON: ${error.message}');
  }
  final root = _object(decoded, 'the file', required: true)!;
  _onlyKeys(root, 'the file', const {
    'parent_id',
    'task',
    'mode',
    'shared_decisions',
    'children',
  });

  final rawChildren = _list(root['children'], 'children', required: true)!;
  if (rawChildren.isEmpty) {
    // Refused here as well as by the constructor, because the constructor's
    // message is about a decomposition and this one can name the file. Not a
    // second rule: an empty list would be refused either way.
    throw PlanFormatException(
      'children',
      'is empty. Not decomposing is a decision (docs/01-plan.md §3), and it '
          'is spelled by not writing a plan file at all',
    );
  }

  return Decomposition(
    parentId: _string(root['parent_id'], 'parent_id', required: true)!,
    task: _string(root['task'], 'task', required: true)!,
    mode: _mode(root['mode']),
    sharedDecisions: [
      for (final (index, value)
          in (_list(root['shared_decisions'], 'shared_decisions') ?? [])
              .indexed)
        _string(value, 'shared_decisions[$index]', required: true)!,
    ],
    children: [
      for (final (index, value) in rawChildren.indexed)
        _child(value, 'children[$index]'),
    ],
  );
}

ModeChoice _mode(Object? value) {
  final mode = _object(value, 'mode', required: true)!;
  _onlyKeys(mode, 'mode', const {'declared', 'defaulted'});
  final declared = mode.containsKey('declared');
  final defaulted = mode.containsKey('defaulted');
  if (declared == defaulted) {
    throw PlanFormatException(
      'mode',
      declared
          ? 'is both declared and defaulted. It is one or the other: somebody '
                'weighed docs/01-plan.md §2.3 and chose, or nobody did'
          : 'names neither "declared" nor "defaulted". §2.3 requires the mode '
                'to be picked explicitly, so an absent mode is refused rather '
                'than defaulted quietly — write {"defaulted": "<why nobody '
                'could choose>"} to take the default on the record',
    );
  }
  if (defaulted) {
    return ModeChoice.defaulted(
      _string(mode['defaulted'], 'mode.defaulted', required: true)!,
    );
  }
  final body = _object(mode['declared'], 'mode.declared', required: true)!;
  _onlyKeys(body, 'mode.declared', const {'mode', 'reason'});
  final wire = _string(body['mode'], 'mode.declared.mode', required: true)!;
  for (final candidate in DelegationMode.values) {
    if (candidate.wire == wire) {
      return ModeChoice.declared(
        candidate,
        _string(body['reason'], 'mode.declared.reason', required: true)!,
      );
    }
  }
  throw PlanFormatException(
    'mode.declared.mode',
    'is "$wire", which is not a delegation mode. It is one of '
        '${DelegationMode.values.map((m) => m.wire).join(' or ')}',
  );
}

PlannedChild _child(Object? value, String where) {
  final child = _object(value, where, required: true)!;
  _onlyKeys(child, where, const {
    'id',
    'task',
    'files',
    'success_conditions',
    'estimated_cost_usd',
  });
  final conditions =
      _list(
        child['success_conditions'],
        '$where.success_conditions',
      )?.indexed ??
      const <(int, Object?)>[];
  return PlannedChild(
    id: _string(child['id'], '$where.id', required: true)!,
    task: _string(child['task'], '$where.task', required: true)!,
    files: _files(child['files'], '$where.files'),
    successConditions: [
      for (final (index, condition) in conditions)
        _condition(condition, '$where.success_conditions[$index]'),
    ],
    // Absent and `null` are the same thing and both mean **unknown**; a number
    // means known. This is the one place the third state has to survive a
    // round trip through a file, and JSON gives it for free — which is why the
    // key is optional rather than a `-1` sentinel.
    estimatedCostUsd: _number(
      child['estimated_cost_usd'],
      '$where.estimated_cost_usd',
    ),
  );
}

FileEstimate _files(Object? value, String where) {
  final files = _object(value, where, required: true)!;
  const arms = {'paths', 'touches_nothing', 'unknown'};
  _onlyKeys(files, where, arms);
  final given = arms.where(files.containsKey).toList();
  if (given.length != 1) {
    throw PlanFormatException(
      where,
      given.isEmpty
          ? 'names none of ${arms.join(', ')}. Every child says what it is '
                'expected to touch, including that nobody could say — an '
                'absent estimate modelled as an empty set overlaps nothing, so '
                'it would parallelise with everything'
          : 'names ${given.join(' and ')} at once, and they are three '
                'different states. Pick one',
    );
  }
  return switch (given.single) {
    'paths' => EstimatedPaths([
      for (final (index, path) in _list(
        files['paths'],
        '$where.paths',
        required: true,
      )!.indexed)
        _string(path, '$where.paths[$index]', required: true)!,
    ]),
    'touches_nothing' => TouchesNothing(
      _string(
        files['touches_nothing'],
        '$where.touches_nothing',
        required: true,
      )!,
    ),
    _ => UnknownFiles(
      _string(files['unknown'], '$where.unknown', required: true)!,
    ),
  };
}

SuccessCondition _condition(Object? value, String where) {
  final condition = _object(value, where, required: true)!;
  _onlyKeys(condition, where, const {'command', 'working_directory'});
  return SuccessCondition(
    [
      for (final (index, word) in _list(
        condition['command'],
        '$where.command',
        required: true,
      )!.indexed)
        _string(word, '$where.command[$index]', required: true)!,
    ],
    workingDirectory: _string(
      condition['working_directory'],
      '$where.working_directory',
    ),
  );
}

// ---------------------------------------------------------------------------
// The readers. Each answers with the value or throws naming [where]; `required`
// distinguishes "absent is fine" from "absent is the error", so that no caller
// has to spell a null check that would report the wrong path.

Map<String, Object?>? _object(
  Object? value,
  String where, {
  bool required = false,
}) {
  if (value == null) {
    if (!required) return null;
    throw PlanFormatException(where, 'is missing');
  }
  if (value is! Map<String, Object?>) {
    throw PlanFormatException(where, 'is ${_typeOf(value)}, not an object');
  }
  return value;
}

List<Object?>? _list(Object? value, String where, {bool required = false}) {
  if (value == null) {
    if (!required) return null;
    throw PlanFormatException(where, 'is missing');
  }
  if (value is! List<Object?>) {
    throw PlanFormatException(where, 'is ${_typeOf(value)}, not a list');
  }
  return value;
}

String? _string(Object? value, String where, {bool required = false}) {
  if (value == null) {
    if (!required) return null;
    throw PlanFormatException(where, 'is missing');
  }
  if (value is! String) {
    throw PlanFormatException(where, 'is ${_typeOf(value)}, not a string');
  }
  return value;
}

double? _number(Object? value, String where) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw PlanFormatException(
    where,
    'is ${_typeOf(value)}, not a number. Leave it out entirely for unknown — '
    'a cost of 0 for a child nobody costed is a sum that reads as an '
    'estimate and is not one',
  );
}

void _onlyKeys(Map<String, Object?> value, String where, Set<String> allowed) {
  final unknown = value.keys.where((k) => !allowed.contains(k)).toList()
    ..sort();
  if (unknown.isEmpty) return;
  throw PlanFormatException(
    where,
    'has ${unknown.length == 1 ? 'an unknown key' : 'unknown keys'} '
    '${unknown.map((k) => '"$k"').join(', ')}. '
    'Known here: ${(allowed.toList()..sort()).join(', ')}. '
    'A key sprout does not recognise is ignored by a lenient reader, and '
    'a misspelled "success_conditions" would spawn a child with no gate',
  );
}

String _typeOf(Object value) => switch (value) {
  String() => 'a string',
  num() => 'a number',
  bool() => 'a boolean',
  List() => 'a list',
  Map() => 'an object',
  _ => 'a ${value.runtimeType}',
};
