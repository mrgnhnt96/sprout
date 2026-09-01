import 'json.dart';
import 'spawn_tool.dart';

/// One block of an assistant or user message.
///
/// Sealed so a caller has to say what it does with a block it does not know,
/// but [UnknownContentBlock] means "does not know" is always answerable without
/// an exception. Observed block types across the phase-0 captures: `text`,
/// `thinking`, `tool_use`, `tool_result`.
sealed class ContentBlock {
  const ContentBlock(this.raw);

  /// Parses one block, never throwing.
  ///
  /// A block that is not a JSON object at all still yields a
  /// [UnknownContentBlock] wrapping an empty map, so a caller iterating content
  /// gets the same shape for every element.
  factory ContentBlock.parse(Object? value) {
    final raw = asMap(value);
    if (raw == null) return UnknownContentBlock(const {});
    return switch (asString(raw['type'])) {
      'text' => TextBlock(raw),
      'thinking' => ThinkingBlock(raw),
      'tool_use' => ToolUseBlock(raw),
      'tool_result' => ToolResultBlock(raw),
      _ => UnknownContentBlock(raw),
    };
  }

  /// The block exactly as it arrived. Preserved on every variant, not only the
  /// unknown one, so nothing is lost by parsing.
  final Map<String, Object?> raw;

  /// The wire discriminator, or null if the block carried none.
  String? get type => asString(raw['type']);
}

/// Assistant or user prose.
final class TextBlock extends ContentBlock {
  /// Wraps a `text` block.
  const TextBlock(super.raw);

  /// The text, or the empty string if the field was missing.
  String get text => asString(raw['text']) ?? '';
}

/// Extended thinking. Present in the stream but not part of the message a user
/// sees, so it is kept distinct from [TextBlock] rather than folded into it.
final class ThinkingBlock extends ContentBlock {
  /// Wraps a `thinking` block.
  const ThinkingBlock(super.raw);

  /// The thinking text, or the empty string if the field was missing.
  String get thinking => asString(raw['thinking']) ?? '';

  /// The signature the API returns alongside redacted thinking, if any.
  String? get signature => asString(raw['signature']);
}

/// A tool call the model made.
///
/// This is the block the whole tree hangs off: when [isSpawn] is true, [id] is
/// the identifier the spawned node will report as its `parent_tool_use_id`.
final class ToolUseBlock extends ContentBlock {
  /// Wraps a `tool_use` block.
  const ToolUseBlock(super.raw);

  /// The `toolu_…` id of this call.
  String? get id => asString(raw['id']);

  /// The tool's name, e.g. `Agent`, `Bash`, `Write`.
  String? get name => asString(raw['name']);

  /// The arguments, or an empty map if the field was missing.
  Map<String, Object?> get input => mapAt(raw, 'input') ?? const {};

  /// Whether this call spawns a node, under either spelling of the spawn tool.
  bool get isSpawn => isSpawnTool(name);
}

/// The result of a tool call, delivered back on a `user` frame.
final class ToolResultBlock extends ContentBlock {
  /// Wraps a `tool_result` block.
  const ToolResultBlock(super.raw);

  /// The call this answers.
  String? get toolUseId => asString(raw['tool_use_id']);

  /// Whether the tool failed. A denied `PreToolUse` gate arrives this way, with
  /// the refusal reason as [content] (`fixtures/phase0/streams/E.ndjson`).
  bool get isError => asBool(raw['is_error']) ?? false;

  /// The body, which is a string on some tools and a list of blocks on others.
  /// Left untyped rather than guessed at, because only two shapes were observed
  /// and INV10 forbids inventing the rest.
  Object? get content => raw['content'];
}

/// A block whose `type` this parser does not model.
///
/// Not an error. The stream is an unstable API and new block types appear
/// without notice; [ContentBlock.raw] keeps the whole thing so a caller can
/// still read it and a later version can promote it to a typed variant.
final class UnknownContentBlock extends ContentBlock {
  /// Wraps an unrecognised block.
  const UnknownContentBlock(super.raw);
}

/// Token counts for one model turn.
///
/// The four component counts are kept alongside [totalTokens] on purpose:
/// INV7 — a sum is not a distribution, and here the distribution is the whole
/// story, since cache reads are an order of magnitude larger than input and are
/// billed differently.
class Usage {
  /// Reads a `usage` object.
  Usage(this.raw);

  /// The `usage` object exactly as it arrived.
  final Map<String, Object?> raw;

  /// Fresh input tokens.
  int get inputTokens => asInt(raw['input_tokens']) ?? 0;

  /// Tokens written into the prompt cache.
  int get cacheCreationInputTokens =>
      asInt(raw['cache_creation_input_tokens']) ?? 0;

  /// Tokens served from the prompt cache.
  int get cacheReadInputTokens => asInt(raw['cache_read_input_tokens']) ?? 0;

  /// Tokens generated.
  int get outputTokens => asInt(raw['output_tokens']) ?? 0;

  /// The sum of the four components above.
  ///
  /// A convenience for a headline number only. Anything that reasons about
  /// spend should read the components, which stay available.
  int get totalTokens =>
      inputTokens +
      cacheCreationInputTokens +
      cacheReadInputTokens +
      outputTokens;

  @override
  String toString() =>
      'Usage(in $inputTokens, cache +$cacheCreationInputTokens '
      '/$cacheReadInputTokens, out $outputTokens)';
}

/// An assembled `assistant` or `user` message.
class AgentMessage {
  /// Reads a `message` object.
  AgentMessage(this.raw);

  /// The `message` object exactly as it arrived.
  final Map<String, Object?> raw;

  /// The API message id, e.g. `msg_011Ced…`.
  ///
  /// **The dedupe key for usage (INV13).** One message id spans several
  /// `assistant` frames — `B.ndjson` splits one message across a `thinking`
  /// frame and a `tool_use` frame carrying identical `usage` — and counting
  /// both inflates every token figure. Null on `user` messages, which carry no
  /// id and no usage.
  String? get id => asString(raw['id']);

  /// `assistant` or `user`.
  String? get role => asString(raw['role']);

  /// The model that produced this message, on assistant messages.
  String? get model => asString(raw['model']);

  /// Why generation stopped, e.g. `tool_use`, `end_turn`.
  String? get stopReason => asString(raw['stop_reason']);

  /// Usage for this message, or null if it carried none.
  Usage? get usage {
    final usage = mapAt(raw, 'usage');
    return usage == null ? null : Usage(usage);
  }

  /// The content as blocks.
  ///
  /// `content` arrives as a list of blocks on most messages and as a bare
  /// string on some `user` messages (four of them across the phase-0 captures);
  /// a bare string is surfaced as a single [TextBlock] so callers have one
  /// shape to handle. [rawText] tells the two cases apart when that matters.
  List<ContentBlock> get content {
    final value = raw['content'];
    if (value is String) {
      return [
        TextBlock({'type': 'text', 'text': value}),
      ];
    }
    return [
      for (final block in asList(value) ?? const <Object?>[])
        ContentBlock.parse(block),
    ];
  }

  /// The content when it arrived as a bare string, else null.
  String? get rawText => asString(raw['content']);

  /// Every `tool_use` block in [content].
  List<ToolUseBlock> get toolUses => content.whereType<ToolUseBlock>().toList();

  /// Every `tool_result` block in [content].
  List<ToolResultBlock> get toolResults =>
      content.whereType<ToolResultBlock>().toList();

  /// The concatenated text of every [TextBlock], with no separator.
  String get text => content.whereType<TextBlock>().map((b) => b.text).join();
}
