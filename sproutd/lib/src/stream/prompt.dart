import 'dart:convert';

import '../hooks/payload.dart';
import 'json.dart';

/// Who actually wrote a `UserPromptSubmit` prompt.
enum PromptOrigin {
  /// A person, or sprout on a person's behalf. The only kind that starts a new
  /// task.
  human,

  /// The harness delivering a background node's result back into the session.
  /// Machine traffic (INV12).
  taskNotification,
}

/// A `UserPromptSubmit` hook payload, classified by who wrote the prompt.
///
/// This is a **hook** payload rather than a stream frame — it arrives on a
/// hook's stdin, not in `--output-format stream-json` — and it lives with the
/// stream parser because it is the same job: a pure function over control-plane
/// bytes. It is here at all because of one trap.
///
/// When a background node finishes, its result is delivered to the *root* as a
/// fresh `UserPromptSubmit` whose `prompt` is a `<task-notification>` block
/// (`fixtures/phase0/hooks/B/1788281001.678994-UserPromptSubmit.stdin.json`).
/// It is byte-for-byte the shape of a human typing a new task. A gate that
/// counts prompts, bills them, or treats one as a new mandate will be wrong
/// every time a background child returns — silently, because nothing else in
/// the payload marks it.
///
/// The field is `prompt`, not `prompt_text`; `06` had that wrong too.
///
/// **It is a [HookPayload], and adds only the classification.** `session_id`,
/// `prompt_id`, `cwd`, `permission_mode`, `transcript_path` and `prompt` are
/// inherited: this class used to declare all six a second time, over the same
/// wire keys with the same null-on-wrong-type discipline, which is finding
/// F-14 — two derivations of one fact with nothing that fails when they stop
/// being equal. Everything below this line is what is genuinely its own.
final class UserPromptSubmitPayload extends HookPayload {
  /// Wraps a decoded payload.
  const UserPromptSubmitPayload(super.raw);

  /// Decodes a payload from the JSON a hook received on stdin.
  ///
  /// Returns null rather than throwing when the input is not a JSON object, for
  /// the same reason the stream parser never throws: a gate that dies on a
  /// surprising payload fails open.
  ///
  /// Narrower than [HookRecord.parse], on purpose: that one is total and hands
  /// back a [MalformedHookPayload] for input this returns null for. A caller
  /// here already knows which event it is holding and wants the classification
  /// or nothing.
  static UserPromptSubmitPayload? tryParse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    final map = asMap(decoded);
    return map == null ? null : UserPromptSubmitPayload(map);
  }

  /// Who wrote [prompt].
  PromptOrigin get origin => taskNotification == null
      ? PromptOrigin.human
      : PromptOrigin.taskNotification;

  /// Whether this prompt is machine traffic and must not be treated as human
  /// input or as a new task.
  bool get isMachineTraffic => origin != PromptOrigin.human;

  /// The parsed notification when this is machine traffic, else null.
  TaskNotification? get taskNotification => TaskNotification.tryParse(prompt);
}

/// A `<task-notification>` block: a background node's result, delivered as a
/// prompt.
///
/// The block is an undocumented XML-ish format with no schema, so this is a
/// tolerant tag scrape rather than a parser: every field is nullable, an
/// unrecognised or reordered block yields nulls instead of an exception, and
/// [raw] keeps the original text so nothing is lost to the scrape.
class TaskNotification {
  const TaskNotification._(this.raw);

  /// Extracts a notification from [prompt], or null if it is not one.
  ///
  /// The test is that the prompt *opens with* the block, after leading
  /// whitespace — the shape the harness generates. A prompt that merely
  /// mentions the tag, such as a person pasting one into a question, stays
  /// human input.
  static TaskNotification? tryParse(String? prompt) {
    if (prompt == null) return null;
    if (!prompt.trimLeft().startsWith(_openingTag)) return null;
    return TaskNotification._(prompt);
  }

  static const _openingTag = '<task-notification>';

  /// The block exactly as it arrived.
  final String raw;

  /// The finished node's `agent_id`-namespace id.
  String? get taskId => _tag('task-id');

  /// The `toolu_…` id of the spawn call that created the finished node.
  String? get toolUseId => _tag('tool-use-id');

  /// Where the node's full output was written.
  String? get outputFile => _tag('output-file');

  /// e.g. `completed`.
  String? get status => _tag('status');

  /// The harness's one-line summary, e.g. `Agent "…" finished`.
  String? get summary => _tag('summary');

  /// The node's actual final message.
  String? get result => _tag('result');

  /// The harness's note about re-notification, when present.
  ///
  /// It says the same task id may notify **more than once**, because a
  /// notification fires each time an agent stops with no live background
  /// children — so a notification is not proof a node will never speak again.
  String? get note => _tag('note');

  /// Tokens the node spent, from `<subagent_tokens>`.
  int? get subagentTokens => int.tryParse(_tag('subagent_tokens') ?? '');

  /// Tool calls the node made.
  int? get toolUses => int.tryParse(_tag('tool_uses') ?? '');

  /// Wall-clock milliseconds the node ran for.
  int? get durationMs => int.tryParse(_tag('duration_ms') ?? '');

  String? _tag(String name) => RegExp(
    '<$name>(.*?)</$name>',
    dotAll: true,
  ).firstMatch(raw)?.group(1)?.trim();

  @override
  String toString() => 'TaskNotification($taskId, $status, $result)';
}
