/// Total accessors for decoded JSON.
///
/// The stream is not a stable API (INV10), so every read of it has to survive a
/// field that changed type or vanished between CLI versions. These return null
/// instead of throwing, which is what lets the parser hold to its one hard
/// promise: an unrecognised frame must not take the daemon down with it.
library;

/// The value at [key] of [map] as a JSON object, or null if it is anything else.
Map<String, Object?>? mapAt(Map<String, Object?>? map, String key) =>
    asMap(map?[key]);

/// [value] as a JSON object, or null if it is not one.
Map<String, Object?>? asMap(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// [value] as a JSON array, or null if it is not one.
List<Object?>? asList(Object? value) => value is List<Object?> ? value : null;

/// [value] as a string, or null if it is not one.
///
/// Deliberately does *not* stringify numbers or booleans: an id that arrives as
/// a number is a schema change worth noticing as an absence, not a value worth
/// coercing into place.
String? asString(Object? value) => value is String ? value : null;

/// [value] as an int, or null if it is not a number.
int? asInt(Object? value) => switch (value) {
  final int v => v,
  final double v when v == v.roundToDouble() => v.toInt(),
  _ => null,
};

/// [value] as a double, or null if it is not a number.
///
/// Accepts an int because JSON makes no distinction and a cost that happens to
/// land on a whole number arrives as one.
double? asDouble(Object? value) => switch (value) {
  final double v => v,
  final int v => v.toDouble(),
  _ => null,
};

/// [value] as a bool, or null if it is not one.
bool? asBool(Object? value) => value is bool ? value : null;

/// Every JSON object in [value], skipping entries that are not objects.
List<Map<String, Object?>> objectsIn(Object? value) => [
  for (final entry in asList(value) ?? const <Object?>[]) ?asMap(entry),
];
