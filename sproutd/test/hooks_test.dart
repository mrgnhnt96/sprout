import 'dart:convert';
import 'dart:io';

import 'package:sproutd/hooks.dart';
import 'package:test/test.dart';

/// The 37 hook payloads captured in Phase 0, under `A/`, `B/`, `C/` and `D/`.
///
/// Read from disk rather than transcribed: a hand-written payload is this
/// file's own idea of the schema being checked against itself, which is the one
/// thing a parser test must not be. `docs/research/17-observed-schemas.md` §3
/// lists these fields too, and it is prose — the files are the artifact.
const String fixturesRoot = '../docs/research/fixtures/phase0/hooks';

/// Every captured payload, as `(path, text)`, in a stable order.
List<(String, String)> capturedPayloads() {
  final files =
      Directory(fixturesRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.stdin.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) (f.path, f.readAsStringSync())];
}

/// One typed accessor per field observed in the corpus, keyed by the wire name
/// it reads.
///
/// This map is the assertion, not a convenience: `every accessor is
/// non-null exactly where its key is present` is checked against it per
/// payload, so a field that appears in a future capture with no entry here
/// fails rather than being quietly ignored.
final Map<String, Object? Function(HookPayload)> accessorsByField = {
  'agent_id': (p) => p.agentId,
  'agent_transcript_path': (p) => p.agentTranscriptPath,
  'agent_type': (p) => p.agentType,
  'background_tasks': (p) => p.backgroundTasks,
  'cwd': (p) => p.cwd,
  'duration_ms': (p) => p.durationMs,
  'effort': (p) => p.effort,
  'hook_event_name': (p) => p.eventName,
  'last_assistant_message': (p) => p.lastAssistantMessage,
  'permission_mode': (p) => p.permissionMode,
  'prompt': (p) => p.prompt,
  'prompt_id': (p) => p.promptId,
  'reason': (p) => p.reason,
  'session_crons': (p) => p.sessionCrons,
  'session_id': (p) => p.sessionId,
  'source': (p) => p.source,
  'stop_hook_active': (p) => p.stopHookActive,
  'tool_input': (p) => p.toolInput,
  'tool_name': (p) => p.toolName,
  'tool_response': (p) => p.toolResponse,
  'tool_use_id': (p) => p.toolUseId,
  'transcript_path': (p) => p.transcriptPath,
};

/// The two `PostToolUse` spawn payloads in `hooks/B/`, which are the whole
/// point of this leaf: they carry the caller and the callee together and are
/// the only record on the hook path that joins a parent to a child.
const String rootSpawnsChild =
    '$fixturesRoot/B/1788281000.234816-PostToolUse.stdin.json';
const String childSpawnsGrandchild =
    '$fixturesRoot/B/1788280999.057150-PostToolUse.stdin.json';

void main() {
  final corpus = capturedPayloads();

  group('the captured corpus', () {
    test('is the 37 payloads Phase 0 recorded', () {
      // A guard on the guard: every test below is over `corpus`, and a glob
      // that silently matched nothing would make all of them pass vacuously.
      expect(corpus, hasLength(37));
    });

    test('every payload parses, with no throw', () {
      for (final (path, text) in corpus) {
        final record = HookRecord.parse(text);
        expect(
          record,
          isA<HookPayload>(),
          reason: '$path decoded to ${record.runtimeType}',
        );
      }
    });

    test('and every payload round-trips its raw map', () {
      // What P8-02 stores is `raw`, so this is the property the store depends
      // on: nothing is dropped, reordered into a different value, or coerced.
      for (final (path, text) in corpus) {
        final record = HookRecord.parse(text);
        expect(record.toJson(), jsonDecode(text), reason: path);
      }
    });

    test('every payload records under a kind, and all eight fired events '
        'are known ones', () {
      final kinds = <String>{};
      for (final (path, text) in corpus) {
        final record = HookRecord.parse(text);
        expect(record.kind, startsWith(hookKindPrefix), reason: path);
        expect(
          record.kind,
          isNot(hookUnknownKind),
          reason: '$path has an event name this build does not know',
        );
        kinds.add(record.kind);
      }
      // Eight of the eleven registered events fired in the six Phase 0 runs;
      // Notification, PreCompact and PostCompact never did.
      expect(kinds, hasLength(8));
      expect(kinds, everyElement(isIn(hookKindsByEventName.values)));
    });
  });

  group('the typed accessors', () {
    test('cover exactly the fields the corpus contains', () {
      // Computed from the files at test time and in both directions, so a
      // field ADDED to a future capture fails here rather than being silently
      // ignored, and an accessor for a field nobody has ever observed fails
      // too rather than sitting there implying evidence that does not exist.
      final observed = <String>{};
      for (final (_, text) in corpus) {
        observed.addAll((jsonDecode(text) as Map<String, Object?>).keys);
      }
      expect(observed, hasLength(22));
      expect(accessorsByField.keys.toSet(), observed);
    });

    test('are non-null exactly where their field is present', () {
      // The stronger half. The test above compares two sets of NAMES and would
      // pass with every accessor reading the wrong key or the wrong type; this
      // one compares, per payload, the keys that are really there against the
      // accessors that really answer.
      for (final (path, text) in corpus) {
        final present = (jsonDecode(text) as Map<String, Object?>).keys.toSet();
        final payload = HookRecord.parse(text) as HookPayload;
        final answered = {
          for (final MapEntry(key: field, value: read)
              in accessorsByField.entries)
            if (read(payload) != null) field,
        };
        expect(answered, present, reason: path);
      }
    });

    test('read effort as the object it is, not a string', () {
      final withEffort = [
        for (final (_, text) in corpus) HookRecord.parse(text) as HookPayload,
      ].where((p) => p.effort != null).toList();
      expect(withEffort, isNotEmpty);
      for (final payload in withEffort) {
        expect(payload.effortLevel, isNotNull);
        expect(payload.effort, isA<Map<String, Object?>>());
      }
    });

    test('find agent_transcript_path on SubagentStop and nowhere else', () {
      // The trap `transcript_path`'s doc names: every payload's
      // `transcript_path` is the ROOT's, so the subagent's own transcript is
      // available on exactly one event. Anything timing a running subagent's
      // file has to construct the path.
      for (final (path, text) in corpus) {
        final payload = HookRecord.parse(text) as HookPayload;
        expect(payload.transcriptPath, isNotNull, reason: path);
        if (payload.agentTranscriptPath != null) {
          expect(payload.eventName, 'SubagentStop', reason: path);
          expect(payload.agentTranscriptPath, isNot(payload.transcriptPath));
        }
      }
      expect(
        corpus
            .map((e) => HookRecord.parse(e.$2) as HookPayload)
            .where((p) => p.agentTranscriptPath != null),
        isNotEmpty,
      );
    });

    test('read stop_hook_active as false then true across the D capture', () {
      // A loop guard, not a status: false on the first Stop, true on the
      // re-entry after a hook blocked it (`17` §7).
      final stops =
          [
              for (final (path, text) in corpus)
                if (path.contains('/D/'))
                  (path, HookRecord.parse(text) as HookPayload),
            ].where((e) => e.$2.eventName == 'Stop').toList()
            ..sort((a, b) => a.$1.compareTo(b.$1));
      expect(stops.map((e) => e.$2.stopHookActive), [false, true]);
    });
  });

  group('the parent to child join', () {
    HookPayload load(String path) =>
        HookRecord.parse(File(path).readAsStringSync()) as HookPayload;

    test('the root spawning its child: no agent_id, callee aab4…', () {
      // The assertion this leaf exists to make true. `agent_id` absent means
      // the CALLER is the root; `tool_response.agentId` is the CALLEE.
      final payload = load(rootSpawnsChild);
      expect(payload.eventName, 'PostToolUse');
      expect(payload.toolName, 'Agent');
      expect(payload.agentId, isNull);
      expect(payload.isFromSubagent, isFalse);
      expect(payload.spawnedAgentId, 'aab408509339890dd');
      expect(payload.isSpawn, isTrue);
    });

    test('the child spawning the grandchild: caller aab4…, callee ac19…', () {
      final payload = load(childSpawnsGrandchild);
      expect(payload.eventName, 'PostToolUse');
      expect(payload.toolName, 'Agent');
      expect(payload.agentId, 'aab408509339890dd');
      expect(payload.isFromSubagent, isTrue);
      expect(payload.spawnedAgentId, 'ac19f9c9fe3fbbac5');
    });

    test('so the two payloads chain into a depth-2 tree', () {
      // Stated as the edge list P8-02 will build from, because the pair above
      // asserted separately would still pass if the two ids had been swapped
      // between the files.
      final edges = {
        for (final path in [rootSpawnsChild, childSpawnsGrandchild])
          load(path).agentId: load(path).spawnedAgentId,
      };
      expect(edges, {
        null: 'aab408509339890dd',
        'aab408509339890dd': 'ac19f9c9fe3fbbac5',
      });
    });

    test('and duration_ms does not say which of them was async', () {
      // `17` §6: the async spawn returned in 2ms with status async_launched.
      // A reader inferring synchrony from the field would conclude the
      // grandchild finished instantly.
      expect(load(childSpawnsGrandchild).durationMs, 2);
      expect(
        load(childSpawnsGrandchild).toolResponse?['status'],
        'async_launched',
      );
      expect(load(rootSpawnsChild).durationMs, 4269);
    });

    test('a non-spawn tool call joins nothing', () {
      // The negative control for the join, from the corpus rather than
      // hand-written: every Bash and Write PostToolUse must yield null.
      final nonSpawns = [
        for (final (_, text) in corpus) HookRecord.parse(text) as HookPayload,
      ].where((p) => p.toolResponse != null && p.toolName != 'Agent');
      expect(nonSpawns, isNotEmpty);
      for (final payload in nonSpawns) {
        expect(payload.spawnedAgentId, isNull);
        expect(payload.isSpawn, isFalse);
      }
    });

    test('and both spellings of the spawn tool are matched', () {
      // The tool is `Agent` in tool_name and `Task` in permission denials, in
      // the SAME run. Only `Agent` appears in this corpus, so the `Task` half
      // is asserted against a synthesised payload — which is honest here
      // precisely because it is the half no fixture covers.
      final asTask = HookPayload(const {
        'hook_event_name': 'PostToolUse',
        'tool_name': 'Task',
        'tool_response': {'agentId': 'deadbeefdeadbeef0'},
      });
      expect(asTask.spawnedAgentId, 'deadbeefdeadbeef0');
    });
  });

  group('nothing is ever dropped', () {
    test('garbage text yields a malformed record that keeps the text', () {
      final record = HookRecord.parse('not json at all');
      expect(record, isA<MalformedHookPayload>());
      expect(record.kind, hookMalformedKind);
      expect((record as MalformedHookPayload).line, 'not json at all');
      expect(record.raw, isEmpty);
      // The stored form must not be empty: a row saying only `hook.malformed`
      // would record that something went wrong and lose what it was.
      expect(record.toJson()['line'], 'not json at all');
      expect(record.toJson()['error'], isNotNull);
    });

    test('empty stdin and a truncated payload are malformed, not a throw', () {
      for (final input in ['', '   ', '{"session_id": "abc"']) {
        final record = HookRecord.parse(input);
        expect(record, isA<MalformedHookPayload>(), reason: input);
        expect(record.kind, hookMalformedKind);
      }
    });

    test('a JSON array is malformed and says so', () {
      final record = HookRecord.parse('[1, 2, 3]');
      expect(record, isA<MalformedHookPayload>());
      expect('${(record as MalformedHookPayload).error}', contains('object'));
    });

    test('an empty object parses, with every accessor null', () {
      final record = HookRecord.parse('{}');
      expect(record, isA<HookPayload>());
      final payload = record as HookPayload;
      expect(payload.eventName, isNull);
      expect(payload.kind, hookUnknownKind);
      expect(payload.isKnownEvent, isFalse);
      expect(payload.isFromSubagent, isFalse);
      expect(payload.spawnedAgentId, isNull);
      for (final MapEntry(key: field, value: read)
          in accessorsByField.entries) {
        expect(read(payload), isNull, reason: field);
      }
    });

    test('an unknown event name survives verbatim into what gets stored', () {
      // The rule this vocabulary exists to keep. sprout is blind to a session
      // it did not launch except through this path, so a payload discarded
      // here is a live session that reads as idle.
      final record = HookRecord.parse(
        '{"hook_event_name": "PostCompactionRitual", "session_id": "s1"}',
      );
      final payload = record as HookPayload;
      expect(payload.kind, hookUnknownKind);
      expect(payload.isKnownEvent, isFalse);
      expect(payload.eventName, 'PostCompactionRitual');
      expect(payload.toJson()['hook_event_name'], 'PostCompactionRitual');
      expect(payload.sessionId, 's1');
    });

    test('a field of the wrong type reads as absent, not as a wrong value', () {
      // The stream parser's rule, applied here: an id that arrives as a number
      // is a schema change worth noticing as an absence, never a value worth
      // coercing into place.
      final payload = HookPayload(const {
        'hook_event_name': 'PreToolUse',
        'session_id': 42,
        'stop_hook_active': 'yes',
        'effort': 'high',
        'tool_input': 'not-an-object',
        'background_tasks': {'not': 'a list'},
        'duration_ms': 'soon',
      });
      expect(payload.kind, hookPreToolUseKind);
      expect(payload.sessionId, isNull);
      expect(payload.stopHookActive, isNull);
      expect(payload.effort, isNull);
      expect(payload.effortLevel, isNull);
      expect(payload.toolInput, isNull);
      expect(payload.backgroundTasks, isNull);
      expect(payload.durationMs, isNull);
      // …and the truth of what arrived is still there.
      expect(payload.raw['session_id'], 42);
    });

    test('a spawn whose tool_response is the wrong shape joins nothing', () {
      for (final response in <Object?>[
        null,
        'ok',
        <Object?>[],
        <String, Object?>{},
      ]) {
        final payload = HookPayload({
          'hook_event_name': 'PostToolUse',
          'tool_name': 'Agent',
          'tool_response': response,
        });
        expect(payload.spawnedAgentId, isNull, reason: '$response');
      }
    });
  });
}
