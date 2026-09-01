import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sproutd/stream.dart';
import 'package:test/test.dart';

/// The captured corpus. **These are real frames from Claude Code v2.1.252**
/// (`docs/research/fixtures/phase0/`, written up in
/// `docs/research/17-observed-schemas.md`), not mocks. INV10: a control-plane
/// fact is observed or it is not a fact, so every expectation below is a number
/// read out of a committed file rather than a shape this parser finds
/// convenient.
const _fixtureRoot = '../docs/research/fixtures/phase0';

/// The whole corpus, by fixture letter.
const _streams = ['A', 'B', 'C', 'C2', 'D', 'E'];

/// B is the depth-2 run: root spawns a child, the child spawns a grandchild in
/// the background, and the grandchild outlives its parent.
const _childNode = 'toolu_013CdYLPDjwGfSwE5gL5Q7BK';
const _grandchildNode = 'toolu_01HLJXeJprJTzcM7oW2Zz1vp';
const _childTask = 'aab408509339890dd';
const _grandchildTask = 'ac19f9c9fe3fbbac5';

/// Reads a fixture, failing loudly if it is not there.
///
/// A read that quietly returned empty would make every assertion below pass
/// vacuously — "no results" and "the search was wrong" are one observation
/// (INV8), so this refuses to be the second one.
String _fixture(String relative) {
  final file = File(p.join(_fixtureRoot, relative));
  if (!file.existsSync()) {
    fail('fixture missing: ${file.absolute.path} (cwd ${Directory.current})');
  }
  final text = file.readAsStringSync();
  if (text.trim().isEmpty) fail('fixture empty: ${file.absolute.path}');
  return text;
}

String _stream(String name) => _fixture('streams/$name.ndjson');

/// A label per frame variant, for histogram assertions that read like the
/// fixture's own shape.
String _label(StreamFrame frame) => switch (frame) {
  SystemFrame(:final subtype) => 'system/${subtype ?? '?'}',
  StreamEventFrame() => 'stream_event',
  AssistantFrame() => 'assistant',
  UserFrame() => 'user',
  RateLimitFrame() => 'rate_limit_event',
  ResultFrame() => 'result',
  UnknownFrame() => 'unknown',
  MalformedFrame() => 'malformed',
};

Map<String, int> _histogram(Iterable<StreamFrame> frames) {
  final counts = <String, int>{};
  for (final frame in frames) {
    final key = _label(frame);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

void main() {
  group('the corpus is actually being read', () {
    // The positive control for everything else in this file. If the fixture
    // path is wrong, a parser that returns nothing for every input would sail
    // through the negative-case tests below; this is the assertion that cannot
    // be satisfied by absence.
    test('every fixture parses into frames with nothing malformed', () {
      for (final name in _streams) {
        final frames = parseStreamJson(_stream(name));
        expect(frames, isNotEmpty, reason: '$name produced no frames');
        expect(
          frames.whereType<MalformedFrame>(),
          isEmpty,
          reason: '$name has a line this parser could not decode',
        );
      }
    });

    test('the six captures hold 344 frames with 344 distinct uuids', () {
      // The claim that makes `uuid` a safe dedupe key. Asserted over the whole
      // corpus rather than per file, because a key that is unique per file and
      // repeats across them is not a key.
      final uuids = <String>{};
      var total = 0;
      for (final name in _streams) {
        for (final frame in parseStreamJson(_stream(name))) {
          total++;
          expect(frame.uuid, isNotNull, reason: 'a frame in $name has no uuid');
          uuids.add(frame.uuid!);
        }
      }
      expect(total, 344);
      expect(uuids, hasLength(344));
    });
  });

  group('typed frames', () {
    test('A discriminates every frame type it contains', () {
      final frames = parseStreamJson(_stream('A'));
      expect(_histogram(frames), {
        'system/hook_started': 13,
        'system/hook_response': 13,
        'system/init': 1,
        'system/status': 2,
        'system/thinking_tokens': 3,
        'stream_event': 26,
        'assistant': 4,
        'user': 1,
        'rate_limit_event': 1,
        'result': 1,
      });
      // 65 lines in, 65 frames out: nothing was dropped to reach that shape.
      expect(frames, hasLength(65));
    });

    test('init carries the session provenance sprout launches against', () {
      final init = parseStreamJson(_stream('A'))
          .whereType<SystemInitFrame>()
          .single;
      expect(init.model, 'claude-haiku-4-5-20251001');
      expect(init.claudeCodeVersion, '2.1.252');
      expect(init.permissionMode, 'bypassPermissions');
      expect(init.tools, hasLength(48));
    });

    test('B emits one init per TURN, not one per process', () {
      // The trap: two inits in a single `claude -p` process, because the root
      // woke up again for a background child's result. Paired with A, which has
      // exactly one — so this is not a parser that counts every system frame.
      expect(StreamTranscript.parse(_stream('B')).inits, hasLength(2));
      expect(StreamTranscript.parse(_stream('A')).inits, hasLength(1));
    });

    test('assistant and user frames expose their content as typed blocks', () {
      final frames = parseStreamJson(_stream('B'));
      final spoke = frames
          .whereType<AssistantFrame>()
          .where((f) => f.message.text == 'GRANDCHILD')
          .single;
      expect(spoke.parentToolUseId, _grandchildNode);
      expect(spoke.isFromRoot, isFalse);
      expect(spoke.subagentType, 'general-purpose');
      expect(spoke.message.content.single, isA<TextBlock>());

      final result = frames
          .whereType<UserFrame>()
          .expand((f) => f.message.toolResults)
          .where((b) => b.toolUseId == _childNode)
          .single;
      expect(result.isError, isFalse);
    });

    test('rate_limit_event exposes both unified windows', () {
      final rateLimit = parseStreamJson(_stream('B'))
          .whereType<RateLimitFrame>()
          .single;
      expect(rateLimit.status, 'allowed');
      expect(rateLimit.fiveHourUtilization, 0.13);
      expect(rateLimit.sevenDayUtilization, 0.53);
    });

    test('hook_response reports exit 2 as blocking and exit 0 as allowing', () {
      // `06` had these inverted, and built as written every sprout gate would
      // have failed open (INV10). D is the capture that settles it: one Stop
      // hook exited 2 and the model kept working, the rest exited 0.
      final responses = parseStreamJson(_stream('D'))
          .whereType<HookResponseFrame>()
          .toList();
      final blocked = responses.where((r) => r.blocked).toList();
      expect(blocked, hasLength(1));
      expect(blocked.single.exitCode, 2);
      expect(blocked.single.hookEvent, 'Stop');
      expect(blocked.single.outcome, 'error');
      // The paired positive: the other nine did NOT block, so `blocked` is
      // reading the exit code rather than answering true to everything.
      expect(responses.where((r) => !r.blocked), hasLength(9));
      expect(
        responses.where((r) => !r.blocked).every((r) => r.exitCode == 0),
        isTrue,
      );
    });
  });

  group('unknown input does not throw', () {
    test('two real unrecognised subtypes round-trip as preserved raw', () {
      // `system/notification` (D) and `system/commands_changed` (C2) are in the
      // fixtures and are NOT in `17` §4's table. They are the standing proof
      // that closing the subtype set would have been wrong, and they are the
      // reason this parser has an unknown variant at all.
      final unknownSubtypes = <String, Map<String, Object?>>{};
      for (final name in ['C2', 'D']) {
        for (final frame in parseStreamJson(
          _stream(name),
        ).whereType<SystemUnknownFrame>()) {
          unknownSubtypes[frame.subtype!] = frame.raw;
        }
      }
      expect(
        unknownSubtypes.keys,
        unorderedEquals(['notification', 'commands_changed']),
      );
      // Round-trip: re-encoding the preserved payload reproduces the frame, so
      // nothing was lost by not modelling it.
      final notification = unknownSubtypes['notification']!;
      expect(jsonDecode(jsonEncode(notification)), equals(notification));
      expect(notification['key'], 'stop-hook-error');

      // The paired positive: a subtype that IS modelled in the same file does
      // not land here. Without this, a parser that typed nothing would pass.
      expect(
        parseStreamJson(_stream('D')).whereType<SystemInitFrame>(),
        hasLength(1),
      );
    });

    test('an unknown top-level type is preserved beside a known one', () {
      final ndjson =
          '{"type":"assistant","uuid":"u1","message":{"id":"m1","content":[]}}\n'
          '{"type":"a_type_from_a_later_cli","uuid":"u2","payload":{"n":1}}\n';
      final frames = parseStreamJson(ndjson);
      expect(frames, hasLength(2));
      expect(frames.first, isA<AssistantFrame>());

      final unknown = frames.last as UnknownFrame;
      expect(unknown.type, 'a_type_from_a_later_cli');
      expect(jsonDecode(jsonEncode(unknown.toJson())), {
        'type': 'a_type_from_a_later_cli',
        'uuid': 'u2',
        'payload': {'n': 1},
      });
    });

    test('an unknown content block is preserved beside a known one', () {
      final frame =
          parseStreamJson(
                '{"type":"assistant","uuid":"u1","message":{"content":['
                '{"type":"text","text":"hi"},'
                '{"type":"a_block_from_a_later_cli","detail":7}]}}\n',
              ).single
              as AssistantFrame;
      final blocks = frame.message.content;
      expect(blocks.first, isA<TextBlock>());
      expect(blocks.last, isA<UnknownContentBlock>());
      expect(blocks.last.raw['detail'], 7);
    });
  });

  group('dedupe by frame uuid', () {
    test('a repeated uuid is dropped and a fresh one is not', () {
      // Both halves in one test on purpose (INV8): a parser that dropped every
      // frame would satisfy the first assertion alone.
      final parser = StreamParser();
      final first = parser.parseAll(_stream('A'));
      expect(first, hasLength(65));
      expect(parser.duplicatesDropped, 0);

      final second = parser.parseAll(_stream('A'));
      expect(second, isEmpty);
      expect(parser.duplicatesDropped, 65);

      final fresh = parser.parseAll('{"type":"result","uuid":"never-seen"}\n');
      expect(fresh, hasLength(1));
      expect(parser.duplicatesDropped, 65);
    });

    test('a frame with no uuid is passed through and counted, not dropped', () {
      // Absence of a uuid means "cannot dedupe this one", never "discard it" —
      // a silent drop is the failure mode that looks like a clean stream.
      final parser = StreamParser();
      final frames = parser.parseAll(
        '{"type":"result"}\n{"type":"result"}\n{"type":"result","uuid":"x"}\n',
      );
      expect(frames, hasLength(3));
      expect(parser.framesWithoutUuid, 2);
      expect(parser.duplicatesDropped, 0);

      // The paired positive control: across the whole real corpus this counter
      // stays at zero, so a non-zero value is a signal and not the norm.
      for (final name in _streams) {
        final corpus = StreamParser()..parseAll(_stream(name));
        expect(corpus.framesWithoutUuid, 0, reason: name);
      }
    });
  });

  group('the last result wins, and result is not process exit', () {
    test('B emits two results and the second is the true one', () {
      final transcript = StreamTranscript.parse(_stream('B'));
      expect(transcript.results, hasLength(2));

      final first = transcript.results.first;
      final last = transcript.results.last;
      expect(first.totalCostUsd, 0.2316953);
      expect(last.totalCostUsd, 0.2415507);
      // Cumulative, not per-turn: reading the first understates the run.
      expect(last.totalCostUsd, greaterThan(first.totalCostUsd!));

      expect(transcript.result, same(last));
      expect(transcript.totalCostUsd, 0.2415507);

      // What distinguishes them, and it is not `is_error` or `subtype`: both
      // say success. The second was driven by a background child finishing.
      expect(first.isEndOfUserTurn, isTrue);
      expect(first.isTaskNotified, isFalse);
      expect(first.origin, isNull, reason: 'the key is absent, not null');
      expect(last.isTaskNotified, isTrue);
      expect(last.originKind, 'task-notification');
      expect(first.subtype, 'success');
      expect(last.subtype, 'success');
      expect(first.isError, isFalse);
      expect(last.isError, isFalse);
    });

    test('a single-result run still reports that one result', () {
      // The paired case for "take the last": five of the six captures emit
      // exactly one, and `last` must not mean "second or nothing".
      for (final name in ['A', 'C', 'C2', 'D', 'E']) {
        final transcript = StreamTranscript.parse(_stream(name));
        expect(transcript.results, hasLength(1), reason: name);
        expect(
          transcript.result,
          same(transcript.results.single),
          reason: name,
        );
        expect(transcript.hasResult, isTrue, reason: name);
      }
    });

    test('a run with no result yet reports none rather than guessing', () {
      final transcript = StreamTranscript.parse(
        '{"type":"assistant","uuid":"u1","message":{"content":[]}}\n',
      );
      expect(transcript.hasResult, isFalse);
      expect(transcript.result, isNull);
      expect(transcript.totalCostUsd, isNull);
    });
  });

  group('tree reconstruction from parent_tool_use_id', () {
    test('B rebuilds exactly root -> child -> grandchild', () {
      final tree = StreamTranscript.parse(_stream('B')).tree;

      expect(tree.root.isRoot, isTrue);
      expect(tree.root.childIds, [_childNode]);
      expect(tree.childrenOf(null).single.id, _childNode);
      expect(tree.childrenOf(_childNode).single.id, _grandchildNode);
      expect(tree.childrenOf(_grandchildNode), isEmpty);
      expect(tree.subagents.map((n) => n.id), [_childNode, _grandchildNode]);
      expect(tree.orphans, isEmpty);

      // The grandchild's parent is the CHILD, not the root — even though the
      // grandchild's result was delivered to the root. The delivery path is not
      // the spawn path (INV12).
      expect(tree.node(_grandchildNode)!.parentId, _childNode);
      expect(tree.node(_childNode)!.parentId, isNull);
      expect(tree.node(_childNode)!.parentObserved, isTrue);
    });

    test('derived depth agrees with the depth the control plane reported', () {
      // Two independent numbers: `depthOf` walks the edges this parser
      // rebuilt, `spawnDepth` is what `system/task_started` said. Asserting
      // them against each other is what makes either one trustworthy.
      final tree = StreamTranscript.parse(_stream('B')).tree;
      expect(tree.depthOf(null), 0);
      expect(tree.depthOf(_childNode), 1);
      expect(tree.depthOf(_grandchildNode), 2);
      expect(tree.node(_childNode)!.spawnDepth, 1);
      expect(tree.node(_grandchildNode)!.spawnDepth, 2);
      for (final node in tree.subagents) {
        expect(tree.depthOf(node.id), node.spawnDepth, reason: '${node.id}');
      }
    });

    test('a single-agent run has a root and invents no children', () {
      // The paired negative for the rule above: A and D never spawn, so a
      // builder that manufactured a node from every `parent_tool_use_id` it saw
      // would fail here.
      for (final name in ['A', 'D']) {
        final tree = StreamTranscript.parse(_stream(name)).tree;
        expect(tree.subagents, isEmpty, reason: name);
        expect(tree.root.framesEmitted, greaterThan(0), reason: name);
        expect(tree.depthOf(null), 0, reason: name);
      }
    });

    test('a refused spawn is in the tree but is not a spawned node', () {
      // E is the trap: the model emitted a real `Agent` tool_use block with a
      // real id, a gate refused it, and no node ever existed. A tree built from
      // tool_use blocks alone shows a child that never ran.
      final transcript = StreamTranscript.parse(_stream('E'));
      final tree = transcript.tree;
      const deniedId = 'toolu_017EtGD2Cg1UUHkBnG8CjBpb';

      expect(tree.subagents.map((n) => n.id), [deniedId]);
      expect(tree.deniedSpawns.map((n) => n.id), [deniedId]);
      expect(tree.spawnedSubagents, isEmpty);
      expect(tree.node(deniedId)!.spawnDenied, isTrue);
      // Two independent numbers agreeing: the control plane's own count and the
      // tree this parser rebuilt.
      expect(transcript.result!.subagentStats!.spawned, 0);

      // The paired positive: B's two spawns were NOT refused, so `spawnDenied`
      // is reading the denial record rather than answering true to everything.
      final b = StreamTranscript.parse(_stream('B')).tree;
      expect(b.deniedSpawns, isEmpty);
      expect(b.spawnedSubagents, hasLength(2));
      expect(
        StreamTranscript.parse(_stream('B')).result!.subagentStats!.spawned,
        2,
      );
    });

    test('a node whose spawn was never seen is an orphan, not a root child', () {
      // Drop only the assistant frame that spawned the grandchild, keeping
      // every frame the grandchild itself emitted. Guessing a parent here would
      // hide exactly the shape sprout exists to surface: a subtree hanging off
      // nothing.
      final all = parseStreamJson(_stream('B'));
      final withoutSpawn = all.where(
        (f) =>
            f is! AssistantFrame ||
            !f.spawns.any((s) => s.id == _grandchildNode),
      );
      final tree = SessionTree.from(withoutSpawn);

      expect(tree.orphans.map((n) => n.id), [_grandchildNode]);
      expect(tree.depthOf(_grandchildNode), isNull);
      expect(tree.childrenOf(null).map((n) => n.id), [_childNode]);
      expect(tree.childrenOf(_childNode), isEmpty);
      // Paired: the child, whose spawn IS still in the slice, is placed.
      expect(tree.node(_childNode)!.parentObserved, isTrue);
      expect(tree.node(_grandchildNode)!.parentObserved, isFalse);
    });

    test('the tree is order-independent', () {
      final forwards = SessionTree.from(parseStreamJson(_stream('B')));
      final backwards = SessionTree.from(
        parseStreamJson(_stream('B')).reversed,
      );
      expect(backwards.render(), forwards.render());
    });
  });

  group('the system/task_* node lifecycle', () {
    test('B folds both nodes from started through notification', () {
      final tasks = StreamTranscript.parse(_stream('B')).tasks;
      expect(tasks.tasks.keys, unorderedEquals([_childTask, _grandchildTask]));

      final child = tasks[_childTask]!;
      expect(child.started, isTrue);
      expect(child.toolUseId, _childNode);
      expect(child.spawnDepth, 1);
      expect(child.isBackgrounded, isFalse);
      expect(child.taskType, 'local_agent');
      expect(child.progressUpdates, 1);
      expect(child.lastToolName, 'Agent');
      expect(child.status, 'completed');
      expect(child.isCompleted, isTrue);
      expect(child.endTime, 1788281000199);
      expect(child.summary, 'CHILD');
      expect(child.notified, isTrue);
      expect(child.outputFile, contains('$_childTask.output'));
      // The final usage, from task_notification, replaces the mid-run figure
      // from task_progress (25867).
      expect(child.usage!.totalTokens, 29047);
      expect(child.usage!.toolUses, 1);
      expect(child.usage!.durationMs, 4268);

      final grandchild = tasks[_grandchildTask]!;
      expect(grandchild.toolUseId, _grandchildNode);
      expect(grandchild.spawnDepth, 2);
      expect(grandchild.isBackgrounded, isTrue);
      expect(grandchild.summary, 'GRANDCHILD');
      expect(grandchild.usage!.totalTokens, 24510);
      expect(grandchild.usage!.durationMs, 1624);
      // It was launched in the background and never reported progress; a
      // lifecycle that required task_progress would have missed it entirely.
      expect(grandchild.progressUpdates, 0);
    });

    test('the parent completes while its own child is still live', () {
      // INV12 as an assertion rather than a sentence. Fold frames one at a time
      // and stop the moment the CHILD is marked completed: the grandchild is
      // still in the background-task snapshot at that instant.
      final lifecycles = TaskLifecycles();
      var stopped = false;
      for (final frame in parseStreamJson(_stream('B'))) {
        lifecycles.observe(frame);
        if (lifecycles[_childTask]?.isCompleted ?? false) {
          stopped = true;
          break;
        }
      }
      expect(stopped, isTrue, reason: 'the child never completed');
      expect(lifecycles.backgroundTasks.map((t) => t.taskId), [
        _grandchildTask,
      ], reason: 'the grandchild outlived its parent');
      expect(lifecycles.incomplete.map((t) => t.taskId), [_grandchildTask]);

      // The paired end state: by the last frame the snapshot has drained and
      // nothing is incomplete. Without this half, a snapshot that was always
      // non-empty would pass the assertion above.
      final whole = StreamTranscript.parse(_stream('B')).tasks;
      expect(whole.backgroundTasks, isEmpty);
      expect(whole.incomplete, isEmpty);
    });

    test('a run that spawns nothing has no lifecycles', () {
      for (final name in ['A', 'D', 'E']) {
        expect(
          StreamTranscript.parse(_stream(name)).tasks.tasks,
          isEmpty,
          reason: name,
        );
      }
      // Paired with C, which does spawn one: the fold is not simply inert.
      expect(StreamTranscript.parse(_stream('C')).tasks.tasks, hasLength(1));
    });
  });

  group('the spawn tool answers to both Agent and Task', () {
    test('E denies a spawn spelled Task and it is counted as a spawn', () {
      final transcript = StreamTranscript.parse(_stream('E'));
      final denial = transcript.permissionDenials.single;
      expect(denial.toolName, 'Task');
      expect(denial.toolUseId, 'toolu_017EtGD2Cg1UUHkBnG8CjBpb');
      expect(denial.isSpawnDenial, isTrue);
      expect(transcript.spawnDenials, hasLength(1));

      // INV14: the platform's own counters stayed at zero for a refusal sprout
      // caused, so sprout cannot read its containment out of them.
      final stats = transcript.result!.subagentStats!;
      expect(stats.spawned, 0);
      expect(stats.refused.values, everyElement(0));
    });

    test('B spawns a tool spelled Agent and it is the same tool', () {
      final spawns = parseStreamJson(_stream('B'))
          .whereType<AssistantFrame>()
          .expand((f) => f.spawns)
          .toList();
      expect(spawns.map((s) => s.name), ['Agent', 'Agent']);
      expect(spawns.map((s) => s.id), [_childNode, _grandchildNode]);
      expect(spawns.every((s) => s.isSpawn), isTrue);
    });

    test('a non-spawn tool is not counted as one', () {
      // The half that keeps the two above honest: `isSpawnTool` must say no to
      // something. Write and Bash appear in the same captures.
      final toolUses = [
        for (final name in _streams)
          ...parseStreamJson(_stream(name))
              .whereType<AssistantFrame>()
              .expand((f) => f.message.toolUses),
      ];
      final names = toolUses.map((t) => t.name).toSet();
      expect(names, containsAll(['Agent', 'Write', 'Bash']));
      // Three spawn blocks across the corpus: B's two, and E's one that a gate
      // refused — the refusal does not remove the block from the stream.
      expect(toolUses.where((t) => t.isSpawn), hasLength(3));
      expect(isSpawnTool('Write'), isFalse);
      expect(isSpawnTool('Bash'), isFalse);
      expect(isSpawnTool(null), isFalse);
      expect(spawnToolNames, {'Agent', 'Task'});
    });

    test('init.tools spells it Task, correcting `17` §5', () {
      // `17` §5 says "In E, `system/init.tools` lists `Agent`". Its own fixture
      // says otherwise: every one of the six captures lists `Task` in
      // init.tools and none lists `Agent`. That makes matching both spellings
      // MORE necessary than the doc argues, not less — and it is why
      // `canSpawn` goes through `isSpawnTool` rather than a literal.
      for (final name in _streams) {
        final init = parseStreamJson(_stream(name))
            .whereType<SystemInitFrame>()
            .first;
        expect(init.tools, contains('Task'), reason: name);
        expect(init.tools, isNot(contains('Agent')), reason: name);
        expect(init.canSpawn, isTrue, reason: name);
      }
    });
  });

  group('usage is deduped by message.id', () {
    test('A repeats each message across two frames — exactly 2.00x', () {
      // INV13's measured failure, reproduced from a capture: four assistant
      // frames carry two messages, and each message's usage appears twice.
      final frames = parseStreamJson(_stream('A'));
      final withUsage = frames
          .whereType<AssistantFrame>()
          .where((f) => f.message.usage != null)
          .toList();
      expect(withUsage, hasLength(4));

      final naive = withUsage.fold(
        0,
        (sum, f) => sum + f.message.usage!.totalTokens,
      );
      final transcript = StreamTranscript.from(frames);
      expect(transcript.usageByMessageId, hasLength(2));
      expect(transcript.totalMessageTokens, 45020);
      expect(naive, 90040);
      expect(naive, transcript.totalMessageTokens * 2);
    });

    test('B repeats some messages and not others', () {
      // The paired case that stops "dedupe" from meaning "halve": B's eight
      // usage-carrying frames hold six distinct messages, so the correction is
      // 1.33x here, not 2x. A parser that divided by two would fail this.
      final transcript = StreamTranscript.parse(_stream('B'));
      expect(transcript.usageByMessageId, hasLength(6));
      expect(transcript.totalMessageTokens, 192776);

      final naive = parseStreamJson(_stream('B'))
          .whereType<AssistantFrame>()
          .where((f) => f.message.usage != null)
          .fold(0, (sum, f) => sum + f.message.usage!.totalTokens);
      expect(naive, 255951);
    });

    test('the components stay available beside the sum', () {
      // INV7: a sum is not a distribution, and here cache reads dwarf fresh
      // input, which is the whole point of the per-node cost view.
      final usage = StreamTranscript.parse(_stream('A'))
          .usageByMessageId
          .values
          .first;
      expect(usage.cacheReadInputTokens, greaterThan(usage.inputTokens));
      expect(
        usage.totalTokens,
        usage.inputTokens +
            usage.cacheCreationInputTokens +
            usage.cacheReadInputTokens +
            usage.outputTokens,
      );
    });
  });

  group('malformed, truncated and empty input', () {
    test('a malformed line is isolated and its neighbours still parse', () {
      final frames = parseStreamJson(
        '{"type":"assistant","uuid":"u1","message":{"content":[]}}\n'
        'this is not json at all\n'
        '{"type":"result","uuid":"u2","total_cost_usd":1.5}\n',
      );
      expect(frames, hasLength(3));
      expect(frames[0], isA<AssistantFrame>());
      expect(frames[2], isA<ResultFrame>());

      final bad = frames[1] as MalformedFrame;
      expect(bad.line, 'this is not json at all');
      expect(bad.error, isA<FormatException>());
      // The run's history survives the bad line: the result after it is read.
      expect((frames[2] as ResultFrame).totalCostUsd, 1.5);
    });

    test('valid JSON that is not an object is malformed, not a frame', () {
      final frames = parseStreamJson('[1,2,3]\n42\n"a string"\nnull\n');
      expect(frames, hasLength(4));
      expect(frames, everyElement(isA<MalformedFrame>()));
      expect((frames.first as MalformedFrame).line, '[1,2,3]');
    });

    test('a truncated final line is flushed as malformed, not swallowed', () {
      // The killed-mid-write case. The half-frame must surface, and every
      // complete frame before it must stand.
      final parser = StreamParser();
      final complete = parser.addChunk(
        '{"type":"assistant","uuid":"u1","message":{"content":[]}}\n'
        '{"type":"result","uuid":"u2","total_c',
      );
      expect(complete, hasLength(1));
      expect(complete.single, isA<AssistantFrame>());
      expect(parser.hasPendingLine, isTrue);

      final flushed = parser.finish();
      expect(flushed, hasLength(1));
      expect(flushed.single, isA<MalformedFrame>());
      expect((flushed.single as MalformedFrame).line, endsWith('total_c'));
    });

    test('a complete final line without a newline is a real frame', () {
      // The paired positive. A parser that called everything unterminated
      // "truncated" would pass the test above and lose the last real frame of
      // every stream that does not end in a newline.
      final parser = StreamParser();
      expect(parser.addChunk('{"type":"result","uuid":"u1"}'), isEmpty);
      final flushed = parser.finish();
      expect(flushed.single, isA<ResultFrame>());
      expect(parser.finish(), isEmpty, reason: 'nothing left to flush');
    });

    test('an empty stream yields an empty, honest transcript', () {
      for (final empty in ['', '\n', '   \n\n\t\n']) {
        final transcript = StreamTranscript.parse(empty);
        expect(transcript.frames, isEmpty, reason: 'input ${empty.length}');
        expect(transcript.result, isNull);
        expect(transcript.hasResult, isFalse);
        expect(transcript.tasks.tasks, isEmpty);
        expect(transcript.tree.subagents, isEmpty);
        expect(transcript.tree.root.framesEmitted, 0);
        expect(transcript.sessionId, isNull);
      }
      // Paired: one frame in, one frame out — the emptiness above is a property
      // of the input, not of the parser.
      final one = StreamTranscript.parse('{"type":"result","uuid":"u1"}\n');
      expect(one.frames, hasLength(1));
      expect(one.hasResult, isTrue);
    });

    test('blank lines between frames are skipped, not counted', () {
      final frames = parseStreamJson(
        '\n{"type":"result","uuid":"u1"}\n\n   \n{"type":"result","uuid":"u2"}\n',
      );
      expect(frames, hasLength(2));
    });
  });

  group('incremental feeding', () {
    test('one byte at a time gives the same frames as one whole document', () {
      // The runner reads from a pipe, so line boundaries arrive wherever the
      // OS puts them. This is the worst case of that.
      final source = _stream('B');
      final expected = parseStreamJson(source).map((f) => f.uuid).toList();

      final parser = StreamParser();
      final actual = <String?>[];
      for (var i = 0; i < source.length; i++) {
        for (final frame in parser.addChunk(source[i])) {
          actual.add(frame.uuid);
        }
      }
      for (final frame in parser.finish()) {
        actual.add(frame.uuid);
      }
      expect(actual, expected);
      expect(actual, hasLength(122));
    });
  });

  group('UserPromptSubmit: machine traffic versus human input', () {
    test('a task-notification prompt is machine traffic, fully parsed', () {
      // The real payload, captured when B's grandchild finished and its result
      // was delivered to the ROOT as a fresh prompt.
      final payload = UserPromptSubmitPayload.tryParse(
        _fixture('hooks/B/1788281001.678994-UserPromptSubmit.stdin.json'),
      )!;
      expect(payload.origin, PromptOrigin.taskNotification);
      expect(payload.isMachineTraffic, isTrue);
      expect(payload.sessionId, '58be2f96-d11a-4765-8e62-cfed6086ae7f');

      final notification = payload.taskNotification!;
      expect(notification.taskId, _grandchildTask);
      expect(notification.toolUseId, _grandchildNode);
      expect(notification.status, 'completed');
      expect(notification.result, 'GRANDCHILD');
      expect(notification.summary, 'Agent "Reply with single word" finished');
      expect(notification.subagentTokens, 24510);
      expect(notification.toolUses, 0);
      expect(notification.durationMs, 1624);
      expect(notification.outputFile, contains('$_grandchildTask.output'));
      expect(notification.note, contains('may notify more than once'));
    });

    test('the human prompt in the same run is human', () {
      // The paired positive, and the one that matters: without it, a classifier
      // that called everything machine traffic would pass — and sprout would
      // silently stop accepting new tasks.
      final payload = UserPromptSubmitPayload.tryParse(
        _fixture('hooks/B/1788280992.631959-UserPromptSubmit.stdin.json'),
      )!;
      expect(payload.origin, PromptOrigin.human);
      expect(payload.isMachineTraffic, isFalse);
      expect(payload.taskNotification, isNull);
      expect(payload.prompt, startsWith('Use the Task tool'));
      expect(payload.promptId, isNotNull);
    });

    test(
      'every captured UserPromptSubmit classifies, and one of five is machine',
      () {
        // Over the whole hook corpus rather than the two payloads chosen above,
        // so the split is measured and not selected.
        final files = Directory(p.join(_fixtureRoot, 'hooks'))
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('UserPromptSubmit.stdin.json'))
            .toList();
        expect(files, hasLength(5));

        final payloads = [
          for (final file in files)
            UserPromptSubmitPayload.tryParse(file.readAsStringSync())!,
        ];
        expect(payloads.every((p) => p.prompt != null), isTrue);
        expect(payloads.where((p) => p.isMachineTraffic), hasLength(1));
        expect(payloads.where((p) => !p.isMachineTraffic), hasLength(4));
      },
    );

    test('a prompt that merely mentions the tag is still human', () {
      final mentioned = UserPromptSubmitPayload({
        'prompt': 'What does a <task-notification> block look like?',
      });
      expect(mentioned.origin, PromptOrigin.human);

      // Leading whitespace does not hide a real one.
      final indented = UserPromptSubmitPayload({
        'prompt':
            '\n  <task-notification>\n<task-id>abc</task-id>\n'
            '</task-notification>',
      });
      expect(indented.isMachineTraffic, isTrue);
      expect(indented.taskNotification!.taskId, 'abc');
    });

    test('a payload that is not JSON returns null rather than throwing', () {
      expect(UserPromptSubmitPayload.tryParse('not json'), isNull);
      expect(UserPromptSubmitPayload.tryParse('[]'), isNull);
      // Paired: a well-formed payload still parses.
      expect(UserPromptSubmitPayload.tryParse('{"prompt":"hi"}')!.prompt, 'hi');
    });
  });
}
