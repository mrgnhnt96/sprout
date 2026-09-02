import 'dart:convert';

import 'package:sprout_protocol/values.dart';

import '../stream/json.dart';
import '../stream/spawn_tool.dart';

/// Whatever arrived on a hook's stdin, as a value.
///
/// Sealed, so a `switch` over it is exhaustive — but the set is closed only in
/// this file, never on the wire. [MalformedHookPayload] is what makes that
/// safe: **this hierarchy never throws on input.** Not on an unknown field, not
/// on a missing `hook_event_name`, not on a field of the wrong type, not on a
/// line that is not JSON at all.
///
/// That is a hard requirement rather than a style. A hook runs *inside the
/// developer's own session*: it is a real process Claude Code starts and waits
/// for, and one that dies on a payload it did not expect breaks the session it
/// was supposed to be observing. The stream parser has the same promise for a
/// weaker reason — there, a crash only takes down the daemon.
///
/// The counterpart rule: **nothing is ever dropped.** Every input yields a
/// value, every value carries a [kind] and its whole payload, and an event name
/// this build does not know keeps its original spelling inside [raw]. sprout is
/// blind to a session it did not launch except through this path, so a payload
/// silently discarded here is a live session that looks idle.
///
/// Every field name below was copied out of a payload under
/// `docs/research/fixtures/phase0/hooks/`, cross-checked against
/// `docs/research/17-observed-schemas.md` §3.
/// `docs/research/06-claude-code-control-plane.md` is superseded and disagrees
/// on five field names.
sealed class HookRecord {
  const HookRecord();

  /// Reads whatever a hook received on stdin.
  ///
  /// Total: non-JSON, JSON that is not an object, and an empty string all come
  /// back as [MalformedHookPayload] carrying the text and the reason. Anything
  /// that decodes to an object comes back as [HookPayload], however little of
  /// it this build recognises.
  factory HookRecord.parse(String stdin) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stdin);
    } on FormatException catch (error) {
      return MalformedHookPayload(stdin, error);
    }
    final map = asMap(decoded);
    if (map == null) {
      return MalformedHookPayload(
        stdin,
        'expected a JSON object, got ${decoded.runtimeType}',
      );
    }
    return HookPayload(map);
  }

  /// The `kind` this record is stored under in the event feed.
  String get kind;

  /// The payload exactly as it arrived.
  ///
  /// Empty on [MalformedHookPayload], whose input was never valid JSON and is
  /// kept as text in [MalformedHookPayload.line] instead.
  Map<String, Object?> get raw;

  /// The payload as it arrived, for storage in the event feed.
  Map<String, Object?> toJson() => raw;
}

/// One decoded hook payload.
///
/// The typed accessors are a **convenience over [raw], never a replacement for
/// it.** Every one of them returns null rather than coercing or throwing when
/// the field is absent or has changed type, so a consumer that needs certainty
/// about what arrived reads [raw]. What gets stored is [raw]; that is what lets
/// a later sprout answer a question this one did not know to ask.
///
/// Deliberately one flat class rather than a variant per event name, unlike
/// `StreamFrame`'s hierarchy. The eleven hook events do not carry eleven
/// disjoint shapes — they carry overlapping subsets of one 22-field union, and
/// which fields are present varies *within* an event as much as between them
/// (`agent_id` on some `PreToolUse` and not others). A class per event would
/// have to model that with nullable fields anyway, and would then also have to
/// decide what to do with the twelfth event name, which is the one decision
/// this file most needs not to get wrong.
final class HookPayload extends HookRecord {
  /// Wraps a decoded payload.
  const HookPayload(this.raw);

  @override
  final Map<String, Object?> raw;

  @override
  String get kind => hookKindForEventName(eventName);

  /// The wire's own name for the event, e.g. `PreToolUse`.
  ///
  /// Null when the payload carried none. Survives verbatim in [raw] whatever
  /// its value, including a name this build does not know — [kind] degrades to
  /// `hook.unknown` and this stays the truth of what arrived.
  String? get eventName => asString(raw['hook_event_name']);

  /// Whether [eventName] is one of the eleven names this build knows.
  bool get isKnownEvent => hookKindsByEventName.containsKey(eventName);

  // ── identity ───────────────────────────────────────────────────────────────

  /// The session id.
  ///
  /// **One per `claude -p` process, shared by every node in the tree** — a
  /// subagent does not get its own (`17` §2). In the B capture the root, its
  /// child and its grandchild all report the same one. It therefore cannot
  /// identify a node, and any hook-path code that reaches for it to do so is
  /// wrong; [agentId] is the only identifier on this path that can.
  String? get sessionId => asString(raw['session_id']);

  /// The emitting subagent's 17-character hex id, or null when the root
  /// emitted this payload.
  ///
  /// Absence is meaningful and is the depth-0 test — see [isFromSubagent].
  String? get agentId => asString(raw['agent_id']);

  /// The subagent's type, e.g. `general-purpose`. Present exactly where
  /// [agentId] is.
  String? get agentType => asString(raw['agent_type']);

  /// The id of the turn this payload belongs to.
  String? get promptId => asString(raw['prompt_id']);

  /// The session's working directory.
  String? get cwd => asString(raw['cwd']);

  /// e.g. `bypassPermissions`.
  String? get permissionMode => asString(raw['permission_mode']);

  // ── transcripts ────────────────────────────────────────────────────────────

  /// **Always the ROOT session's `.jsonl`, even inside a subagent.**
  ///
  /// This is the trap on this path. A liveness probe that timed this file to
  /// decide whether a *subagent* is frozen would be reading the root's
  /// transcript, which moves whenever anything in the tree moves — so a wedged
  /// subagent under a busy root reads as healthy. The subagent's own transcript
  /// is [agentTranscriptPath] and it is available on `SubagentStop` alone.
  String? get transcriptPath => asString(raw['transcript_path']);

  /// The emitting subagent's **own** transcript, at
  /// `…/<session-id>/subagents/agent-<agent_id>.jsonl`.
  ///
  /// Observed on `SubagentStop` and on no other event, so it is not a general
  /// substitute for [transcriptPath] — it is available only once the subagent
  /// has already stopped, which is precisely when a liveness probe no longer
  /// needs it. Anything that wants to time a *running* subagent's transcript
  /// has to construct the path, not read it from here.
  String? get agentTranscriptPath => asString(raw['agent_transcript_path']);

  // ── tool calls ─────────────────────────────────────────────────────────────

  /// The tool being called, on `PreToolUse` and `PostToolUse`.
  String? get toolName => asString(raw['tool_name']);

  /// The `toolu_…` id of the call.
  ///
  /// On a spawn call this is the id that becomes the child's
  /// `parent_tool_use_id` on the stream path — the join between the two
  /// identifier namespaces.
  String? get toolUseId => asString(raw['tool_use_id']);

  /// The tool's arguments, verbatim and untyped.
  ///
  /// Every tool has its own shape and the set of tools is open, so this stays a
  /// raw map. Nothing here should grow a typed view of one tool's arguments
  /// without a fixture for it.
  Map<String, Object?>? get toolInput => asMap(raw['tool_input']);

  /// The tool's result, on `PostToolUse`. Untyped for [toolInput]'s reason.
  ///
  /// The field is `tool_response`; `06`'s `tool_result` does not exist.
  Map<String, Object?>? get toolResponse => asMap(raw['tool_response']);

  /// How long the call took, on `PostToolUse`.
  ///
  /// **Not a measure of the work, on an async spawn.** The B capture has a
  /// spawn returning `duration_ms: 2` with `tool_response.status:
  /// async_launched` — the call returned the moment the child was launched, and
  /// the child then ran for as long as it ran. Its synchronous sibling in the
  /// same capture reports `4269`. Synchrony cannot be inferred from this field
  /// (`17` §6).
  int? get durationMs => asInt(raw['duration_ms']);

  // ── turn state ─────────────────────────────────────────────────────────────

  /// The prompt text, on `UserPromptSubmit`.
  ///
  /// **Not proof a human typed it.** A background node's result is delivered to
  /// the root as a fresh `UserPromptSubmit` whose prompt is a
  /// `<task-notification>` block, byte-for-byte the shape of a person starting
  /// a new task. `UserPromptSubmitPayload` in `package:sproutd/stream.dart`
  /// tells the two apart and is what anything counting or billing prompts must
  /// use.
  ///
  /// The field is `prompt`; `06`'s `prompt_text` does not exist.
  String? get prompt => asString(raw['prompt']);

  /// The reasoning-effort setting, e.g. `{"level": "high"}`.
  ///
  /// **An object, not a string** — a consumer that read it as one would get
  /// null from [asString] rather than a wrong answer, which is why the raw map
  /// is what is exposed. Absent until a turn is underway. See [effortLevel].
  Map<String, Object?>? get effort => asMap(raw['effort']);

  /// The `level` inside [effort], e.g. `high`.
  String? get effortLevel => asString(effort?['level']);

  /// The agent's final message, on `Stop` and `SubagentStop`.
  String? get lastAssistantMessage => asString(raw['last_assistant_message']);

  /// Whether this `Stop` is the hook's own re-entry.
  ///
  /// **A loop guard, not a status.** It is `false` on the first `Stop` and
  /// `true` on the `Stop` that follows a hook having blocked the previous one
  /// (`17` §7). It says nothing about whether the session is finished, healthy
  /// or stuck; a gate that read it as a status would refuse or allow on the
  /// basis of how many times it had already run.
  bool? get stopHookActive => asBool(raw['stop_hook_active']);

  // ── session lifecycle ──────────────────────────────────────────────────────

  /// How the session started, on `SessionStart`. Observed: `startup`.
  String? get source => asString(raw['source']);

  /// Why the session ended, on `SessionEnd`. Observed: `other`.
  ///
  /// Present on `SessionEnd` only. `Stop` has no `reason`, whatever `06` says.
  String? get reason => asString(raw['reason']);

  /// Background tasks the session is carrying, on `Stop` and `SubagentStop`.
  ///
  /// **Empty in all 37 captures**, so its element shape has never been
  /// observed. Left as a raw list on purpose: a type invented for a shape
  /// nobody has seen would be a guess that reads like a finding, and the first
  /// non-empty one would either not fit it or fit it by accident.
  List<Object?>? get backgroundTasks => asList(raw['background_tasks']);

  /// Scheduled work the session is carrying. Empty in all 37 captures; see
  /// [backgroundTasks].
  List<Object?>? get sessionCrons => asList(raw['session_crons']);

  // ── the two derived facts ──────────────────────────────────────────────────

  /// Whether a subagent, rather than the root, emitted this payload.
  ///
  /// **The depth-0 test, and the absence is the signal.** `agent_id` and
  /// `agent_type` appear on `PreToolUse` and `PostToolUse` only when the tool
  /// call comes from inside a subagent (`17` §3), so their absence is what
  /// identifies a root-level call. There is nothing else on this path that
  /// could stand in: [sessionId] is one value for the whole tree however deep
  /// it goes, and `parent_tool_use_id` — which does distinguish nodes — is a
  /// *stream* field and never appears on a hook payload.
  ///
  /// Verified across the corpus: every payload from `hooks/B/` and `hooks/C/`
  /// carrying an `agent_id` is a subagent's, and the root's spawn call in
  /// `hooks/B/1788281000.234816-PostToolUse.stdin.json` carries none.
  bool get isFromSubagent => agentId != null;

  /// The `agent_id` of the node this payload's spawn call **created**.
  ///
  /// This is the parent→child join, and the whole reason the hook path can
  /// reconstruct a tree at all. On the `PostToolUse` of a spawn call:
  ///
  /// - `tool_response.agentId` is the **callee's** id — this getter,
  /// - [agentId] is the **caller's** — absent when the caller is the root.
  ///
  /// Both pairs are in the B capture and are what `hooks_test.dart` asserts:
  /// `1788281000.234816-PostToolUse.stdin.json` has no `agent_id` and
  /// `tool_response.agentId: aab408509339890dd` (root → child), while
  /// `1788280999.057150-PostToolUse.stdin.json` has `agent_id:
  /// aab408509339890dd` and `tool_response.agentId: ac19f9c9fe3fbbac5` (child →
  /// grandchild).
  ///
  /// The spawn tool answers to **two names**, `Agent` and `Task`, in the same
  /// run — [isSpawnTool] is the one declaration of that rule and this reuses it
  /// rather than restating it. Matching one spelling makes sprout silently miss
  /// half its own tree; restating the pair here would be F-11's shape in a
  /// third file.
  ///
  /// Gated on the tool name and not on [eventName] being `PostToolUse`, on
  /// purpose. A `PreToolUse` carries no `tool_response` at all, so it cannot
  /// produce a false positive — and gating on an event name would mean a
  /// renamed or newly-added event that still carries the join would silently
  /// stop joining, which is the failure this path can least afford.
  String? get spawnedAgentId =>
      isSpawnTool(toolName) ? asString(toolResponse?['agentId']) : null;

  /// Whether this payload records a spawn that produced a child node.
  bool get isSpawn => spawnedAgentId != null;

  @override
  String toString() =>
      'HookPayload($kind, session: $sessionId, agent: ${agentId ?? 'root'})';
}

/// Hook input that was not a JSON object.
///
/// Three causes, all real: a truncated write, a process that printed something
/// other than JSON on the pipe, and an empty stdin. None of them is allowed to
/// throw — a hook that crashes here takes the developer's session with it — and
/// none of them is allowed to vanish either, which is why this is a value with
/// a [kind] and not a null.
final class MalformedHookPayload extends HookRecord {
  /// Records input that could not be decoded.
  const MalformedHookPayload(this.line, this.error);

  /// The input exactly as it arrived, so nothing is lost to the failure.
  final String line;

  /// What went wrong. A [FormatException] for invalid JSON, or a message saying
  /// the input decoded to something that was not a JSON object.
  final Object error;

  @override
  Map<String, Object?> get raw => const {};

  @override
  String get kind => hookMalformedKind;

  /// The record as it is stored: the text and the reason, since there is no
  /// payload to store.
  ///
  /// Deliberately not empty. A row saying only `hook.malformed` would record
  /// that something went wrong and lose the only copy of what it was.
  @override
  Map<String, Object?> toJson() => {'line': line, 'error': '$error'};

  @override
  String toString() => 'MalformedHookPayload(${line.length} bytes: $error)';
}
