/// The consumer's position in the event feed, namespaced to one sproutd.
///
/// A cursor is two facts glued together: **which sproutd** produced it, and
/// **how far** into that daemon's `event.seq` the consumer has been fed. The
/// second is meaningless without the first — `~/.sprout/sprout.db` outlives
/// any one process, and a daemon that is restarted against a *different*
/// database hands out seq values that collide with the ones a consumer is
/// holding from before. Resuming there is not a small error: it silently skips
/// or replays a stretch of the feed, and nothing in the stream says so.
///
/// sprout keeps **no durable position of its own**. The cursor belongs to the
/// consumer: it is handed out on every frame, passed back on `--since`, and
/// never recorded as proof of delivery before the consumer has actually taken
/// the frames (`docs/01-plan.md` §7).
class Cursor {
  /// Creates a cursor at [position] in the feed of [instanceId].
  ///
  /// [position] is an `event.seq`, or 0 for "before the first event". A
  /// negative one is refused rather than clamped: it can only come from a
  /// caller doing arithmetic on a cursor, which is not an operation the
  /// protocol offers.
  Cursor({required this.instanceId, required this.position}) {
    if (!isWellFormedInstanceId(instanceId)) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'must be $instanceIdLength lowercase hex characters',
      );
    }
    if (position < 0) {
      throw ArgumentError.value(position, 'position', 'must not be negative');
    }
  }

  /// The id of the sproutd process this position belongs to.
  final String instanceId;

  /// The `event.seq` the consumer has been fed up to, inclusive. 0 means none.
  final int position;

  /// The number of hex characters in an instance id.
  static const int instanceIdLength = 16;

  /// The wire format's version tag.
  ///
  /// Present so that a *future* cursor shape is rejected as malformed by this
  /// build rather than misread as a v1 cursor with a strange instance id. A
  /// format change without this tag would be indistinguishable from garbage,
  /// and the two deserve different messages.
  static const String version = 's1';

  /// Whether [value] could be an instance id: exactly [instanceIdLength]
  /// lowercase hex characters.
  static bool isWellFormedInstanceId(String value) =>
      RegExp('^[0-9a-f]{$instanceIdLength}\$').hasMatch(value);

  /// The single opaque-ish token a CLI consumer passes back on `--since`.
  ///
  /// `s1.<instance>.<seq>`. Deliberately one token with no spaces or shell
  /// metacharacters, because its whole job is to survive a round trip through
  /// a copy-paste and an argument vector.
  String encode() => '$version.$instanceId.$position';

  @override
  String toString() => encode();

  @override
  bool operator ==(Object other) =>
      other is Cursor &&
      other.instanceId == instanceId &&
      other.position == position;

  @override
  int get hashCode => Object.hash(instanceId, position);

  /// Parses [text] **structurally**, with no opinion about whose instance it
  /// names. Returns null when [text] is not a cursor at all.
  ///
  /// This is the right entry point for a *consumer* decoding frames: the
  /// cursors on inbound frames belong to the daemon, and it is from them that
  /// a consumer learns the instance id in the first place. Checking the
  /// instance is the *daemon's* job on `--since` input — see
  /// [SproutInstance.accept] — and doing it here would leave a consumer unable
  /// to read the very first frame it is sent.
  static Cursor? tryParse(String text) {
    final parts = text.split('.');
    if (parts.length != 3) return null;
    if (parts[0] != version) return null;
    if (!isWellFormedInstanceId(parts[1])) return null;
    // `int.tryParse` accepts a leading '+' and '-'; both would round-trip to a
    // different string, so the digits are checked first.
    if (!RegExp(r'^\d+$').hasMatch(parts[2])) return null;
    final position = int.tryParse(parts[2]);
    if (position == null) return null;
    return Cursor(instanceId: parts[1], position: position);
  }

  /// Like [tryParse], but throws [FormatException] instead of returning null.
  static Cursor parse(String text) {
    final cursor = tryParse(text);
    if (cursor == null) {
      throw FormatException('not a sprout cursor', text);
    }
    return cursor;
  }
}

/// The outcome of offering a `--since` value to a running sproutd.
///
/// Three outcomes, never two. Collapsing "from another instance" into
/// "malformed" would tell a reconnecting consumer that its own cursor is
/// corrupt when the truth is that the daemon it is talking to is a different
/// one; collapsing it into "accepted" is the failure this type exists to
/// prevent. Sealed, so a caller's `switch` has to say what it does with each.
sealed class CursorParse {
  const CursorParse();
}

/// The cursor is well formed and names this instance. Resume from it.
final class CursorAccepted extends CursorParse {
  /// Wraps the parsed [cursor].
  const CursorAccepted(this.cursor);

  /// The position to resume from.
  final Cursor cursor;

  @override
  String toString() => 'CursorAccepted(${cursor.encode()})';
}

/// A cursor sproutd will not resume from, and why.
///
/// Every refusal carries a [reason] that is safe to print and safe to put in a
/// [ByeFrame]'s detail: a refusal that does not say what it refused is the
/// silent failure over again (INV8 — a refusal is the half of a rail that
/// proves itself, but only if it speaks).
sealed class CursorRefused extends CursorParse {
  const CursorRefused();

  /// The text the consumer is shown.
  String get reason;

  /// The `--since` value exactly as it was offered.
  String get text;
}

/// The cursor parses, but names a **different** sproutd.
///
/// The consumer's position is not stale, it is meaningless: seq 412 in another
/// daemon's feed is not seq 412 in this one. The remedy is a fresh `snapshot`,
/// not a retry, so the reason names **both** instance ids rather than saying
/// "invalid cursor".
final class CursorFromAnotherInstance extends CursorRefused {
  /// Records the mismatch.
  const CursorFromAnotherInstance({
    required this.text,
    required this.offered,
    required this.expectedInstanceId,
  });

  @override
  final String text;

  /// The cursor as offered, carrying the *other* daemon's instance id.
  final Cursor offered;

  /// The instance id of the sproutd that was asked to resume.
  final String expectedInstanceId;

  /// The instance id the cursor actually names.
  String get offeredInstanceId => offered.instanceId;

  @override
  String get reason =>
      'cursor belongs to sproutd instance $offeredInstanceId, but this is '
      'instance $expectedInstanceId — its position is meaningless here; take '
      'a fresh snapshot';

  @override
  String toString() => 'CursorFromAnotherInstance($text)';
}

/// The value is not a cursor at all.
final class CursorMalformed extends CursorRefused {
  /// Records what was offered and what was wrong with it.
  const CursorMalformed({required this.text, required this.detail});

  @override
  final String text;

  /// What is wrong with [text], in the shape's own terms.
  final String detail;

  @override
  String get reason => 'not a sprout cursor ($detail): "$text"';

  @override
  String toString() => 'CursorMalformed($text)';
}
