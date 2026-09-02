import 'dart:convert';
import 'dart:io';

import 'package:sproutd/hooks.dart';
import 'package:sproutd/store.dart';
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

  projectionMain();
}

/// The payloads in one capture directory, in filename order.
///
/// **Filename order is firing order**, because the capture names each file
/// after the wall-clock instant the hook ran at. That is the only ordering the
/// corpus carries — a hook payload has no sequence number — and it is what a
/// replay has to reproduce to be a replay of anything.
List<HookRecord> directory(String name) {
  final files =
      Directory('$fixturesRoot/$name')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.stdin.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) HookRecord.parse(f.readAsStringSync())];
}

/// Folds [records] into [store] through a projection with a fixed clock.
///
/// The clock advances one second per call so that `since` and the event
/// timestamps are distinguishable, and never reads the wall clock — a test
/// that did would be asserting against the machine it runs on.
void replay(SproutStore store, List<HookRecord> records) {
  var tick = DateTime.utc(2026, 1, 1);
  final projection = HookProjection(
    store: store,
    clock: () => tick = tick.add(const Duration(seconds: 1)),
  );
  for (final record in records) {
    projection.observe(record);
  }
}

/// `{child id: parent id}` over every node in [store], for asserting parentage
/// without depending on row order.
Map<String, String?> parentage(SproutStore store) => {
  for (final node in store.nodes()) node.id: node.parentId,
};

/// The events in [store] attributed to [nodeId], in feed order.
List<SproutEvent> feedFor(SproutStore store, String nodeId) =>
    store.eventsSince(0, nodeId: nodeId);

const String sessionA = '5ef39020-313b-487f-8480-6fa2138a7f73';
const String sessionB = '58be2f96-d11a-4765-8e62-cfed6086ae7f';
const String childB = 'aab408509339890dd';
const String grandchildB = 'ac19f9c9fe3fbbac5';

void projectionMain() {
  group('replaying A: one session, no subagents', () {
    late SproutStore store;

    setUp(() {
      store = SproutStore.memory();
      replay(store, directory('A'));
    });

    tearDown(() => store.close());

    test('produces exactly one node, the session root', () {
      final nodes = store.nodes();
      expect(nodes.map((n) => n.id), ['hook/$sessionA']);
      expect(nodes.single.parentId, isNull);
      expect(nodes.single.project, endsWith('/scratchpad/phase0/work'));
    });

    test('and six hook events on it, in firing order', () {
      final kinds = feedFor(store, 'hook/$sessionA')
          .where((e) => e.kind.startsWith(hookKindPrefix))
          .map((e) => e.kind)
          .toList();
      expect(kinds, [
        hookSessionStartKind,
        hookUserPromptSubmitKind,
        hookPreToolUseKind,
        hookPostToolUseKind,
        hookStopKind,
        hookSessionEndKind,
      ]);
    });

    test('each event carrying its payload verbatim', () {
      // The property the whole store depends on: what is folded in is what a
      // later sprout reads back, not a summary of it.
      final captured = directory('A');
      final events = feedFor(
        store,
        'hook/$sessionA',
      ).where((e) => e.kind.startsWith(hookKindPrefix)).toList();
      for (var i = 0; i < captured.length; i++) {
        expect(events[i].payload, (captured[i] as HookPayload).raw);
      }
    });

    test("the root's current_task is the prompt, not a tool name", () {
      final root = store.node('hook/$sessionA')!;
      expect(root.currentTask, startsWith('Write a file named hello.txt'));
      // A/ contains a Write tool call. If tool names reached current_task the
      // board would render `Write` here, and would re-render on every call.
      expect(root.currentTask, isNot(contains('Write"')));
    });

    test('and its final status is checkpointed', () {
      expect(store.node('hook/$sessionA')!.status, NodeStatus.checkpointed);
    });
  });

  group('replaying B: depth 2, and the two orders a join arrives in', () {
    test('the finished tree is root, child, grandchild', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));

      expect(parentage(store), {
        'hook/$sessionB': null,
        'hook/$sessionB/$childB': 'hook/$sessionB',
        'hook/$sessionB/$grandchildB': 'hook/$sessionB/$childB',
      });

      final tree = store.tree();
      expect(
        tree.map((n) => (n.node.id, n.depth)),
        containsAllInOrder([
          ('hook/$sessionB', 0),
          ('hook/$sessionB/$childB', 1),
          ('hook/$sessionB/$grandchildB', 2),
        ]),
      );
    });

    test('the child is detached until the PostToolUse that claims it', () {
      // The assertion that fails if the sentinel is "simplified" away. B's
      // child announces itself at …995.970887 and is not claimed until
      // …1000.234816 — 4.3 seconds later, after it had already stopped.
      final store = SproutStore.memory();
      addTearDown(store.close);
      final records = directory('B');
      final claimAt = records.indexWhere(
        (r) => r is HookPayload && r.spawnedAgentId == childB,
      );
      expect(claimAt, greaterThan(0));

      replay(store, records.sublist(0, claimAt));

      final child = store.node('hook/$sessionB/$childB')!;
      expect(child.parentId, HookProjection.unobservedParentId(sessionB));
      expect(child.parentId, isNot('hook/$sessionB'));
      // Naming no node is the point: the tree reports it as a fragment root.
      expect(store.node(child.parentId!), isNull);
      expect(
        store.tree().firstWhere((n) => n.node.id == child.id).depth,
        0,
        reason:
            'an unclaimed child must be a fragment root, not the root'
            "'"
            's',
      );
      // …and it is not a child of the session root either.
      expect(store.children('hook/$sessionB'), isEmpty);
    });

    test('the grandchild is claimed before it announces itself', () {
      // The opposite order, in the same capture: the async spawn'"'"'s
      // PostToolUse is at …999.057150 and the SubagentStart at …999.058878.
      final store = SproutStore.memory();
      addTearDown(store.close);
      final records = directory('B');
      final claimAt = records.indexWhere(
        (r) => r is HookPayload && r.spawnedAgentId == grandchildB,
      );
      final startAt = records.indexWhere(
        (r) =>
            r is HookPayload &&
            r.eventName == 'SubagentStart' &&
            r.agentId == grandchildB,
      );
      expect(claimAt, lessThan(startAt), reason: 'the join arrives first');

      replay(store, records.sublist(0, startAt));
      final beforeStart = store.node('hook/$sessionB/$grandchildB')!;
      // Created by the join alone: parented correctly, and `spawning` —
      // asked for, not yet reported in.
      expect(beforeStart.parentId, 'hook/$sessionB/$childB');
      expect(beforeStart.status, NodeStatus.spawning);
      expect(beforeStart.currentTask, isNull);
    });

    test('a claim that arrives late does not resurrect a finished child', () {
      // B'"'"'s child stops at …1000.127400 and is claimed at …1000.234816. If
      // the join wrote a status it would walk the child back to `spawning`.
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));
      expect(
        store.node('hook/$sessionB/$childB')!.status,
        NodeStatus.checkpointed,
      );
    });

    test('every payload lands as one event on its emitting node', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      final records = directory('B');
      replay(store, records);

      final hookEvents = store
          .eventsSince(0)
          .where((e) => e.kind.startsWith(hookKindPrefix))
          .toList();
      expect(hookEvents, hasLength(records.length));

      final byNode = <String, int>{};
      for (final event in hookEvents) {
        byNode[event.nodeId] = (byNode[event.nodeId] ?? 0) + 1;
      }
      // 8 from the root, 4 from the child, 2 from the grandchild.
      expect(byNode, {
        'hook/$sessionB': 8,
        'hook/$sessionB/$childB': 4,
        'hook/$sessionB/$grandchildB': 2,
      });
    });

    test('the subagents carry their agent_type as current_task', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));
      expect(
        store.node('hook/$sessionB/$childB')!.currentTask,
        'general-purpose',
      );
      expect(
        store.node('hook/$sessionB/$grandchildB')!.currentTask,
        'general-purpose',
      );
    });

    test("the task-notification prompt does not become the root's task", () {
      // `17` §6: the grandchild's result is delivered to the ROOT as a fresh
      // UserPromptSubmit whose prompt is a <task-notification> block. Writing
      // that into current_task would show B's root working on its own
      // grandchild's answer instead of on the task it was given.
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));

      final root = store.node('hook/$sessionB')!;
      expect(root.currentTask, startsWith('Use the Task tool'));
      expect(root.currentTask, isNot(contains('<task-notification>')));
      expect(root.status, NodeStatus.checkpointed);

      // Paired, so this cannot pass by ignoring UserPromptSubmit entirely:
      // the machine payload is still in the feed.
      final prompts = store
          .eventsSince(0, nodeId: 'hook/$sessionB')
          .where((e) => e.kind == hookUserPromptSubmitKind);
      expect(prompts, hasLength(2));
    });
  });

  group('replaying C and D', () {
    test('C is two sessions, each a whole tree of its own', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('C'));

      // Two SessionStarts, two session_ids, so two roots — not one session
      // that restarted.
      expect(store.nodes(), hasLength(2));
      expect(store.tree().every((n) => n.depth == 0), isTrue);
      expect(
        store.nodes().map((n) => n.status),
        everyElement(NodeStatus.checkpointed),
      );
      expect(
        store
            .eventsSince(0)
            .where((e) => e.kind.startsWith(hookKindPrefix))
            .length,
        14,
      );
    });

    test('D replays without throwing and its tree is intact', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      expect(() => replay(store, directory('D')), returnsNormally);
      // Two sessions: the denied PreToolUse is its own, the two Stops share
      // one. `tree()` throws TreeIntegrityError if the graph is not a forest.
      expect(store.tree(), hasLength(2));
      expect(store.nodes(), hasLength(2));
    });

    test('and every captured payload is folded, all 37 of them', () {
      // The guard against a replay that silently does nothing: the corpus is
      // 37 payloads, so the four directories together owe 37 hook events.
      final store = SproutStore.memory();
      addTearDown(store.close);
      for (final name in ['A', 'B', 'C', 'D']) {
        replay(store, directory(name));
      }
      expect(
        store
            .eventsSince(0)
            .where((e) => e.kind.startsWith(hookKindPrefix))
            .length,
        37,
      );
    });
  });

  group('arrival order is the OS'
      "'"
      's to decide, not ours', () {
    test('B in reverse still lands every event and every node', () {
      // One process per hook event means the interleaving is the OS'"'"'s. A
      // projection that assumed order would append an event against a node it
      // had not created, and `event.node_id`'"'"'s foreign key would refuse the
      // insert — so this test fails as a throw, not as a wrong number.
      final store = SproutStore.memory();
      addTearDown(store.close);
      final reversed = directory('B').reversed.toList();
      expect(() => replay(store, reversed), returnsNormally);

      expect(
        store
            .eventsSince(0)
            .where((e) => e.kind.startsWith(hookKindPrefix))
            .length,
        14,
      );
      // And the tree still comes out right: the join is what builds it, and
      // the join does not care when it arrives.
      expect(parentage(store), {
        'hook/$sessionB': null,
        'hook/$sessionB/$childB': 'hook/$sessionB',
        'hook/$sessionB/$grandchildB': 'hook/$sessionB/$childB',
      });
      expect(store.tree(), hasLength(3));
    });

    test('no event is ever attributed to a node that does not exist', () {
      // Stated over the store rather than trusted to the FK, because an
      // in-memory database with foreign_keys somehow off would make the test
      // above pass while writing dangling rows.
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B').reversed.toList());
      final ids = store.nodes().map((n) => n.id).toSet();
      for (final event in store.eventsSince(0)) {
        expect(ids, contains(event.nodeId));
      }
    });
  });

  group('what the projection will not do', () {
    test('replaying a directory twice duplicates events, not nodes', () {
      // A hook payload carries no unique id — unlike a stream frame, which has
      // `uuid` — so there is nothing to dedupe on and the feed says so
      // honestly rather than guessing. The graph is still a forest.
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));
      expect(() => replay(store, directory('B')), returnsNormally);

      expect(
        store
            .eventsSince(0)
            .where((e) => e.kind.startsWith(hookKindPrefix))
            .length,
        28,
      );
      expect(store.nodes(), hasLength(3));
      expect(store.tree(), hasLength(3));
      expect(parentage(store), {
        'hook/$sessionB': null,
        'hook/$sessionB/$childB': 'hook/$sessionB',
        'hook/$sessionB/$grandchildB': 'hook/$sessionB/$childB',
      });
    });

    test('and the second pass leaves since where the first pass set it', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('A'));
      final first = store.node('hook/$sessionA')!.since;
      replay(store, directory('A'));
      expect(store.node('hook/$sessionA')!.since, first);
    });

    test('a record with no session names no node and writes nothing', () {
      // Malformed input has no `session_id`, so there is no node it belongs
      // to. Inventing one would put a fake agent on the board.
      final store = SproutStore.memory();
      addTearDown(store.close);
      final projection = HookProjection(
        store: store,
        clock: () => DateTime.utc(2026),
      );
      expect(projection.observe(HookRecord.parse('not json at all')), isNull);
      expect(projection.observe(HookRecord.parse('{}')), isNull);
      expect(
        projection.observe(HookRecord.parse('{"hook_event_name":"Stop"}')),
        isNull,
      );
      expect(store.nodes(), isEmpty);
      expect(store.eventsSince(0), isEmpty);
    });

    test('an unknown event name is still recorded, never dropped', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      final projection = HookProjection(
        store: store,
        clock: () => DateTime.utc(2026),
      );
      final id = projection.observe(
        HookRecord.parse(
          '{"hook_event_name":"PostCompactionRitual","session_id":"s1",'
          '"cwd":"/tmp/x"}',
        ),
      );
      expect(id, 'hook/s1');
      final event = store
          .eventsSince(0)
          .lastWhere((e) => e.kind.startsWith(hookKindPrefix));
      expect(event.kind, hookUnknownKind);
      expect(event.payload['hook_event_name'], 'PostCompactionRitual');
      expect(store.node('hook/s1')!.status, NodeStatus.working);
    });
  });

  group('the node rows announce what the row itself cannot hold', () {
    test('a root announces its session_id, which is the runner-path join', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('A'));
      final observed = store
          .eventsSince(0, nodeId: 'hook/$sessionA')
          .firstWhere((e) => e.kind == nodeObservedKind);
      expect(observed.payload['session_id'], sessionA);
    });

    test('and a claimed child announces the tool_use_id that spawned it', () {
      final store = SproutStore.memory();
      addTearDown(store.close);
      replay(store, directory('B'));
      final announcements = store
          .eventsSince(0, nodeId: 'hook/$sessionB/$grandchildB')
          .where((e) => e.kind == nodeObservedKind || e.kind == nodeUpdatedKind)
          .toList();
      expect(
        announcements.map((e) => e.payload['tool_use_id']),
        contains('toolu_01HLJXeJprJTzcM7oW2Zz1vp'),
      );
      expect(
        announcements.map((e) => e.payload['agent_id']),
        everyElement(grandchildB),
      );
    });
  });
}
